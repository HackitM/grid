import Foundation
import GridCore
import Observation

/// The Map page's place search. Typing searches only the names in the map tiles already loaded
/// on this Mac (no network). Online search (Nominatim, OpenStreetMap's geocoder) runs only when
/// asked (⏎ with no local match, ⌘⏎, or the "Search online" row), after a one-time consent, at
/// most once a second, with answers cached in memory for 24 hours. Queries are never written to
/// disk or logged.
@Observable
@MainActor
final class MapSearch {
    enum Online: Equatable { case idle, searching, done, failed(String) }

    var query = "" { didSet { if query != oldValue { queryChanged() } } }
    private(set) var local: [PlaceResult] = []
    private(set) var online: [PlaceResult] = []
    private(set) var onlineState: Online = .idle
    /// The query the online results belong to.
    private(set) var onlineQuery = ""
    /// Keyboard highlight in the combined list (local, then online).
    var highlight = 0
    /// The results list under the search box is showing.
    var listOpen = false

    @ObservationIgnored weak var model: MapModel?
    @ObservationIgnored private var localTask: Task<Void, Never>?
    @ObservationIgnored private var onlineTask: Task<Void, Never>?
    /// The cache key of the online request under way (nil when none is).
    @ObservationIgnored private var onlineKeyInFlight: String?
    /// Search entries per decoded tile (tile revision), built off the main thread on first use.
    @ObservationIgnored private var index: [TileID: (rev: Int, entries: [SearchEntry])] = [:]
    @ObservationIgnored private var spacer = RequestSpacer(interval: 1.05)
    @ObservationIgnored private var cache = ExpiringCache<String, [PlaceResult]>(ttl: 24 * 3600, capacity: 200)

    nonisolated static let onlineKey = "map.search.online"       // Bool; absent = not asked yet
    nonisolated static let endpointKey = "map.search.endpoint"

    nonisolated static var endpoint: URL {
        let raw = UserDefaults.standard.string(forKey: endpointKey) ?? Nominatim.defaultEndpoint
        return Nominatim.endpoint(raw) ?? Nominatim.endpoint(Nominatim.defaultEndpoint)!
    }
    nonisolated static var host: String { endpoint.host ?? "nominatim.openstreetmap.org" }

    /// nil: not asked yet; false: turned off in Settings.
    var onlineAllowed: Bool? {
        get { UserDefaults.standard.object(forKey: Self.onlineKey) as? Bool }
        set { if let v = newValue { UserDefaults.standard.set(v, forKey: Self.onlineKey) } else { UserDefaults.standard.removeObject(forKey: Self.onlineKey) } }
    }

    var results: [PlaceResult] { local + online }
    var isEmptyQuery: Bool { LocalSearch.clean(query).isEmpty }

    // MARK: Local

    private func queryChanged() {
        let q = LocalSearch.clean(query)
        highlight = 0
        listOpen = !q.isEmpty
        if LocalSearch.fold(q) != LocalSearch.fold(onlineQuery) {
            // The online answer belongs to another query: drop it (and a request still under way).
            onlineTask?.cancel(); online = []; onlineState = .idle
        }
        localTask?.cancel()
        guard !q.isEmpty, let model else { local = []; return }
        let near = model.camera.center
        // Reuse entries for tiles already indexed; build the rest off the main thread.
        var indexed: [[SearchEntry]] = []
        var unindexed: [TileGeometry] = []
        var live = Set<TileID>()
        for g in model.tiles.allGeometry() {
            live.insert(g.id)
            if let known = index[g.id], known.rev == g.revision { indexed.append(known.entries) } else { unindexed.append(g) }
        }
        if index.count > live.count + 64 { index = index.filter { live.contains($0.key) } }
        localTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(90))      // let fast typing settle
            guard !Task.isCancelled else { return }
            let (built, found) = await Task.detached(priority: .userInitiated) { () -> ([(TileID, Int, [SearchEntry])], [PlaceResult]) in
                let built = unindexed.map { ($0.id, $0.revision, LocalSearch.entries(for: $0)) }
                let all = indexed.flatMap { $0 } + built.flatMap(\.2)
                return (built, LocalSearch.search(q, in: all, near: near, limit: 12))
            }.value
            guard let self else { return }
            // The entries are good whatever was typed since: keep them, so the next keystroke
            // doesn't index the same tiles again.
            for (id, rev, entries) in built { self.index[id] = (rev, entries) }
            guard !Task.isCancelled else { return }
            self.local = found
        }
    }

    // MARK: Online

    /// Runs the online search for the current query (asking first, the first time).
    func searchOnline() {
        let q = LocalSearch.clean(query)
        guard !q.isEmpty, let model, let app = model.app else { return }
        switch onlineAllowed {
        case nil:
            _ = app.present(Confirmation(code: "SEARCH-NET", title: "Search online?",
                                     message: "Searching online sends what you type and the area you're looking at to \(Self.host) (the OpenStreetMap Foundation's geocoder, Nominatim). It only happens when you press Return or choose Search Online, never while you type. GRID keeps answers in memory for up to a day and never saves your searches. You can turn this off in Settings › Map.",
                                     confirmLabel: "Search Online", destructive: false,
                                     onConfirm: { [weak self] in self?.onlineAllowed = true; self?.searchOnline() }))
            return
        case false?:
            onlineState = .failed("Online search is off. Turn it on in Settings › Map.")
            return
        case true?:
            break
        }
        guard model.enabled else { onlineState = .failed("Map data is off."); return }
        let endpoint = Self.endpoint
        let box = model.visibleBBox()
        let lang = Locale.preferredLanguages.first
        guard let url = Nominatim.searchURL(endpoint: endpoint, query: q, viewbox: box, language: lang) else { return }
        let near = model.camera.center
        let key = [endpoint.absoluteString, LocalSearch.fold(q),
                   box.map { String(format: "%.1f,%.1f,%.1f,%.1f", $0.west, $0.south, $0.east, $0.north) } ?? "", lang ?? ""].joined(separator: "|")
        // Pressing Return again while the same search is on its way must not send it twice.
        if onlineState == .searching, key == onlineKeyInFlight { return }
        // Whatever was under way is for an older query or view: its answer must not land on top of this one.
        onlineTask?.cancel()
        onlineKeyInFlight = nil
        onlineQuery = q
        if let hit = cache.value(key, now: Date()) {
            online = hit.map { var r = $0; r.distance = LocalSearch.meters(near, TileMath.project(r.coordinate)); return r }
            onlineState = .done
            return
        }
        onlineState = .searching
        onlineKeyInFlight = key
        let wait = spacer.reserve(now: Date())
        let host = endpoint.host ?? ""
        onlineTask = Task { [weak self] in
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard !Task.isCancelled else { return }
            do {
                let r = try await MapNetwork.shared.get(url, hosts: [host], maxBytes: Nominatim.maxResponseBytes, timeout: 20)
                guard !Task.isCancelled, let self else { return }
                guard r.status == 200 else {
                    self.onlineState = .failed(r.status == 429 || r.status == 503
                        ? "The search server is busy. Try again in a minute."
                        : "The search server answered \(r.status).")
                    return
                }
                // The answer is untrusted JSON of up to half a megabyte: checked and parsed off the main thread.
                let body = r.data
                let found = try await Task.detached(priority: .userInitiated) { try Nominatim.parse(body, near: near) }.value
                guard !Task.isCancelled else { return }
                self.cache.set(key, found, now: Date())
                self.online = found
                self.onlineState = .done
            } catch is CancellationError {
            } catch MapNetwork.NetError.cancelled {
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.onlineState = .failed(error is Nominatim.ParseError
                    ? "The search server sent something GRID couldn't read."
                    : ((error as? LocalizedError)?.errorDescription ?? "Couldn't reach the search server."))
            }
        }
    }

    // MARK: Choosing

    /// ⏎: the highlighted result, or online search when nothing matched locally.
    /// Returns true when a result was chosen (the list can close).
    @discardableResult
    func submit(forceOnline: Bool = false) -> Bool {
        if !forceOnline, results.indices.contains(highlight) { choose(results[highlight]); return true }
        if forceOnline || local.isEmpty { searchOnline() }
        return false
    }

    func choose(_ r: PlaceResult) {
        listOpen = false
        model?.selectPlace(r, fly: true)
    }

    func moveHighlight(_ by: Int) {
        let n = results.count
        guard n > 0 else { return }
        highlight = (highlight + by + n) % n
    }

    func clear() {
        query = ""
        local = []; online = []; onlineState = .idle; onlineQuery = ""
        listOpen = false
    }

    /// Settings › Map turned online search off, or Clear Map Data: drop remembered answers.
    func forgetOnline() {
        cache.removeAll(); onlineTask?.cancel(); onlineKeyInFlight = nil
        online = []; onlineState = .idle
    }

    #if DEBUG
    var debugState: [String: Any] {
        ["query": query, "local": local.map { "\($0.name)|\($0.kind.rawValue)|\($0.detail)" },
         "online": online.map { "\($0.name)|\($0.kind.rawValue)|\($0.detail)" }, "onlineState": "\(onlineState)",
         "indexedTiles": index.count]
    }
    #endif
}
