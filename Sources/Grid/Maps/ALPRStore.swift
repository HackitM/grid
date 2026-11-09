import Foundation
import GridCore
import Observation

/// ALPR cameras by region: the region catalogue (Geofabrik), downloads (DeFlock z11 tiles in the
/// US and Canada, Overpass elsewhere), offline storage per region, the combined spatial index the
/// map draws from, and freshness checks. Every download is confirmed first with its host, request
/// count and size (see MapsFeature.confirmDownload).
@Observable
@MainActor
final class ALPRStore {
    struct RegionMeta: Codable, Equatable {
        var descriptor: RegionDescriptor
        var polygon: GeoPolygon
        var sources: [ALPRSource]
        /// DeFlock build per source (for freshness).
        var builds: [String: String]
        var osmBase: Date?
        var fetchedAt: Date
        var cameraCount: Int
        var requests: Int
        var isRectangle: Bool
    }

    enum Status: Equatable {
        case idle, checking, current, outdated
        case downloading(done: Int, total: Int)
        case failed(String)
    }

    struct Region: Identifiable, Equatable {
        var meta: RegionMeta
        var status: Status
        var id: String { meta.descriptor.id }
    }

    /// What a download will do, shown in the confirmation before anything is fetched.
    struct DownloadPlan {
        var descriptor: RegionDescriptor
        var polygon: GeoPolygon
        var isRectangle: Bool
        var sources: [ALPRSource]
        var deflockTiles: [(ALPRSource, DeFlockBuild, [TileID])]
        var overpassChunks: [BBox]
        var estimatedCameras: Int
        var requests: Int { deflockTiles.reduce(0) { $0 + $1.2.count } + overpassChunks.count }
        var hosts: [String] {
            var h: [String] = []
            if !deflockTiles.isEmpty { h.append("deflock.dontgetflocked.com") }
            if !overpassChunks.isEmpty { h.append(ALPRStore.overpassHost) }
            return h
        }
    }

    private(set) var regions: [Region] = []
    private(set) var index = CameraIndex([])
    /// Bumped when `index` changes.
    private(set) var revision = 0
    private(set) var catalog: RegionCatalog?
    private(set) var catalogState: String?
    private(set) var lastCheck: Date? = UserDefaults.standard.object(forKey: "map.alpr.lastCheck") as? Date
    private(set) var busy = false

    @ObservationIgnored private var builds: [ALPRSource: (DeFlockBuild, Date)] = [:]
    @ObservationIgnored private var overpassPolicy: FetchPolicy = {
        (UserDefaults.standard.data(forKey: "map.overpass.policy")).flatMap { try? JSONDecoder().decode(FetchPolicy.self, from: $0) } ?? FetchPolicy()
    }()

    nonisolated static let deflockHosts: Set<String> = ["deflock.dontgetflocked.com", "tiles.dontgetflocked.com"]
    static let buildURLs: [ALPRSource: URL] = [
        .deflockUS: URL(string: "https://deflock.dontgetflocked.com/cameras-us-hourly.json")!,
        .deflockCA: URL(string: "https://deflock.dontgetflocked.com/cameras-ca-hourly.json")!,
    ]
    static let catalogURL = URL(string: "https://download.geofabrik.de/index-v1.json")!
    nonisolated static let defaultOverpass = "https://overpass-api.de/api/interpreter"

    nonisolated static var overpassEndpoint: URL {
        let raw = UserDefaults.standard.string(forKey: "map.overpass.endpoint") ?? defaultOverpass
        if let u = URL(string: raw), u.scheme == "https", u.user == nil, u.port == nil, u.host != nil { return u }
        return URL(string: defaultOverpass)!
    }
    nonisolated static var overpassHost: String { overpassEndpoint.host ?? "overpass-api.de" }

    init() { loadStored() }

    // MARK: Stored regions

    private func loadStored() {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: MapStorage.alpr, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return }
        var out: [Region] = []
        for d in dirs where !d.lastPathComponent.hasPrefix("_") {
            guard let v = try? d.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]), v.isDirectory == true, v.isSymbolicLink != true,
                  let data = MapStorage.read(d.appendingPathComponent("meta.json"), maxBytes: 32 << 20),
                  let meta = try? JSONDecoder().decode(RegionMeta.self, from: data),
                  meta.descriptor.storageKey == d.lastPathComponent else { continue }
            var fixed = meta
            if fixed.descriptor.name.contains("/") {
                // Saved before region names were derived from Geofabrik ids ("us/rhode-island").
                let dsc = fixed.descriptor
                fixed.descriptor = RegionDescriptor(id: dsc.id, name: RegionCatalog.displayName(fromID: dsc.name), parent: dsc.parent,
                                                    iso3166_1: dsc.iso3166_1, iso3166_2: dsc.iso3166_2)
            }
            out.append(Region(meta: fixed, status: .idle))
        }
        regions = out.sorted { $0.meta.descriptor.name < $1.meta.descriptor.name }
        rebuildIndex()
    }

    private func folder(_ d: RegionDescriptor) -> URL { MapStorage.alpr.appendingPathComponent(d.storageKey, isDirectory: true) }

    private func rebuildIndex() {
        var seen = Set<OSMElementID>()
        var all: [ALPRCamera] = []
        for r in regions {
            guard let data = MapStorage.read(folder(r.meta.descriptor).appendingPathComponent("cameras.gridalpr"), maxBytes: 256 << 20),
                  let cams = try? RegionPackage.decode(data) else { continue }
            for c in cams where seen.insert(c.id).inserted { all.append(c) }
        }
        let built = CameraIndex(all)
        index = built
        revision &+= 1
    }

    func remove(_ id: String) {
        guard let r = regions.first(where: { $0.id == id }) else { return }
        try? MapStorage.remove(folder(r.meta.descriptor))
        regions.removeAll { $0.id == id }
        rebuildIndex()
    }

    func clearAll() {
        try? MapStorage.remove(MapStorage.alpr)
        try? MapStorage.remove(MapStorage.regions)
        regions = []; catalog = nil; builds = [:]
        rebuildIndex()
    }

    // MARK: Catalogue (Geofabrik)

    /// Loads the cached catalogue, or downloads it (at most monthly).
    func loadCatalog(forceRefresh: Bool = false) async {
        guard catalog == nil || forceRefresh else { return }
        let file = MapStorage.regions.appendingPathComponent("catalog.json")
        let fresh = (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)
            .map { Date().timeIntervalSince($0) < 30 * 86400 } ?? false
        var data: Data? = fresh && !forceRefresh ? MapStorage.read(file, maxBytes: 16 << 20) : nil
        if data == nil {
            catalogState = "Downloading the region list from download.geofabrik.de…"
            do {
                let r = try await MapNetwork.shared.get(Self.catalogURL, hosts: ["download.geofabrik.de"], maxBytes: 16 << 20, timeout: 60)
                guard r.status == 200 else { throw MapNetwork.NetError.http(r.status) }
                data = r.data
                try? MapStorage.write(r.data, to: file)
            } catch {
                data = MapStorage.read(file, maxBytes: 16 << 20)   // stale is better than nothing
                if data == nil { catalogState = "Couldn't load the region list: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"; return }
            }
        }
        guard let bytes = data else { return }
        let parsed = await Task.detached(priority: .userInitiated) { try? RegionCatalog.parse(bytes) }.value
        if let parsed { catalog = parsed; catalogState = nil } else { catalogState = "The region list couldn't be read." }
    }

    // MARK: Planning a download

    private func build(_ s: ALPRSource) async throws -> DeFlockBuild {
        if let (b, at) = builds[s], Date().timeIntervalSince(at) < 3600 { return b }
        guard let url = Self.buildURLs[s] else { throw MapNetwork.NetError.blockedURL(s.rawValue) }
        let r = try await MapNetwork.shared.get(url, hosts: Self.deflockHosts, maxBytes: 1 << 20)
        guard r.status == 200 else { throw MapNetwork.NetError.http(r.status) }
        let b = try DeFlockBuild.parse(r.data, from: url)
        builds[s] = (b, Date())
        return b
    }

    private func deflockIndex(_ s: ALPRSource, _ b: DeFlockBuild) async throws -> DeFlockIndex {
        let file = MapStorage.alpr.appendingPathComponent("_deflock", isDirectory: true)
            .appendingPathComponent("\(s.rawValue)-\(b.build).bin")
        if let d = MapStorage.read(file, maxBytes: 64 << 20), let idx = try? DeFlockIndex(d) { return idx }
        let r = try await MapNetwork.shared.get(b.indexURL, hosts: Self.deflockHosts, maxBytes: 64 << 20, timeout: 60)
        guard r.status == 200 else { throw MapNetwork.NetError.http(r.status) }
        let idx = try DeFlockIndex(r.data)
        // Keep only the current build's index.
        if let old = try? FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path) {
            for name in old where name.hasPrefix(s.rawValue + "-") { try? FileManager.default.removeItem(at: file.deletingLastPathComponent().appendingPathComponent(name)) }
        }
        try? MapStorage.write(r.data, to: file)
        return idx
    }

    func plan(_ d: RegionDescriptor, polygon: GeoPolygon, isRectangle: Bool) async throws -> DownloadPlan {
        let us = try? await build(.deflockUS), ca = try? await build(.deflockCA)
        let sources = ALPRSourcePlanner.sources(for: isRectangle ? nil : d, polygon: polygon, us: us?.bounds, ca: ca?.bounds)
        var tiles: [(ALPRSource, DeFlockBuild, [TileID])] = []
        var chunks: [BBox] = []
        var estimate = 0
        for s in sources {
            switch s {
            case .deflockUS, .deflockCA:
                guard let b = (s == .deflockUS ? us : ca) else { throw MapNetwork.NetError.transport("DeFlock's camera index is unavailable right now.") }
                let idx = try await deflockIndex(s, b)
                let ts = idx.nonEmptyTiles(z: 11, in: polygon)
                estimate += idx.count(in: polygon)
                tiles.append((s, b, ts))
            case .overpass:
                // chunks() returns at most `limit`; one more than the budget means "too big".
                chunks = OverpassQuery.chunks(polygon, z: 7, limit: 61)
                if chunks.count > 60 {
                    throw MapNetwork.NetError.transport("This area is too large to download from Overpass in one go. Pick a smaller region or draw a smaller area.")
                }
            }
        }
        return DownloadPlan(descriptor: d, polygon: polygon, isRectangle: isRectangle, sources: sources,
                            deflockTiles: tiles, overpassChunks: chunks, estimatedCameras: estimate)
    }

    // MARK: Downloading

    func download(_ p: DownloadPlan) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        let total = max(1, p.requests)
        var done = 0
        setStatus(p.descriptor, .downloading(done: 0, total: total), meta: placeholderMeta(p))
        var cameras: [OSMElementID: ALPRCamera] = [:]
        var builds: [String: String] = [:]
        var osmBase: Date?
        do {
            for (source, build, tiles) in p.deflockTiles {
                builds[source.rawValue] = build.build
                // ≤ 4 in flight.
                var i = 0
                while i < tiles.count {
                    let batch = Array(tiles[i..<min(i + 4, tiles.count)])
                    i += batch.count
                    let results = try await withThrowingTaskGroup(of: [ALPRCamera].self) { g -> [[ALPRCamera]] in
                        for t in batch {
                            g.addTask {
                                guard let url = build.tileURL(t) else { return [] }
                                let r = try await MapNetwork.shared.get(url, hosts: Self.deflockHosts, maxBytes: 8 << 20)
                                guard r.status == 200 || r.status == 204 || r.status == 404 else { throw MapNetwork.NetError.http(r.status) }
                                guard !r.data.isEmpty, let tile = try? MVTDecoder.decode(r.data, layers: ["cameras"]) else { return [] }
                                return DeFlockTile.cameras(tile, id: t)
                            }
                        }
                        var out: [[ALPRCamera]] = []
                        for try await r in g { out.append(r) }
                        return out
                    }
                    for list in results { for c in list where p.polygon.contains(c.coordinate) { cameras[c.id] = c } }
                    done += batch.count
                    setStatus(p.descriptor, .downloading(done: done, total: total), meta: nil)
                }
            }
            for box in p.overpassChunks {
                var attempts = 0
                while true {
                    while !overpassPolicy.canRequest(now: Date()) {
                        guard let retry = overpassPolicy.retryAt, retry.timeIntervalSinceNow < 900 else {
                            throw MapNetwork.NetError.transport("Overpass's daily limit for GRID is reached; try again tomorrow.")
                        }
                        try await Task.sleep(for: .seconds(max(1, retry.timeIntervalSinceNow)))
                    }
                    var comps = URLComponents(url: Self.overpassEndpoint, resolvingAgainstBaseURL: false)!
                    comps.queryItems = [URLQueryItem(name: "data", value: OverpassQuery.alpr(box))]
                    guard let url = comps.url else { break }
                    let r = try await MapNetwork.shared.get(url, hosts: [Self.overpassHost], maxBytes: 64 << 20, timeout: 120)
                    if r.status != 200 {
                        overpassPolicy.failed(status: r.status, now: Date()); savePolicy()
                        // Busy or rate-limited: wait out the backoff and retry this chunk (3 tries).
                        if [429, 406, 504].contains(r.status) && attempts < 3 { attempts += 1; continue }
                        throw MapNetwork.NetError.http(r.status)
                    }
                    overpassPolicy.succeeded(now: Date()); savePolicy()
                    let parsed = try OverpassQuery.parse(r.data)
                    if let base = parsed.osmBase { osmBase = base }
                    for c in parsed.cameras where p.polygon.contains(c.coordinate) { cameras[c.id] = c }
                    break
                }
                done += 1
                setStatus(p.descriptor, .downloading(done: done, total: total), meta: nil)
            }
            let list = Array(cameras.values)
            let meta = RegionMeta(descriptor: p.descriptor, polygon: p.polygon, sources: p.sources, builds: builds, osmBase: osmBase,
                                  fetchedAt: Date(), cameraCount: list.count, requests: p.requests, isRectangle: p.isRectangle)
            let dir = folder(p.descriptor)
            try MapStorage.write(RegionPackage.encode(list), to: dir.appendingPathComponent("cameras.gridalpr"))
            try MapStorage.write(try JSONEncoder().encode(meta), to: dir.appendingPathComponent("meta.json"))
            setStatus(p.descriptor, .current, meta: meta)
            rebuildIndex()
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            if FileManager.default.fileExists(atPath: folder(p.descriptor).appendingPathComponent("meta.json").path) {
                setStatus(p.descriptor, .failed(msg), meta: nil)
            } else {
                regions.removeAll { $0.id == p.descriptor.id }
                setStatusError(msg)
            }
        }
    }

    /// The last download error for a region that wasn't stored.
    private(set) var lastError: String?
    private func setStatusError(_ m: String) { lastError = m }

    private func placeholderMeta(_ p: DownloadPlan) -> RegionMeta {
        RegionMeta(descriptor: p.descriptor, polygon: p.polygon, sources: p.sources, builds: [:], osmBase: nil,
                   fetchedAt: Date(), cameraCount: 0, requests: p.requests, isRectangle: p.isRectangle)
    }

    private func setStatus(_ d: RegionDescriptor, _ s: Status, meta: RegionMeta?) {
        lastError = nil
        if let i = regions.firstIndex(where: { $0.id == d.id }) {
            regions[i].status = s
            if let meta { regions[i].meta = meta }
        } else if let meta {
            regions.append(Region(meta: meta, status: s))
            regions.sort { $0.meta.descriptor.name < $1.meta.descriptor.name }
        }
    }

    private func savePolicy() {
        if let d = try? JSONEncoder().encode(overpassPolicy) { UserDefaults.standard.set(d, forKey: "map.overpass.policy") }
    }

    // MARK: Freshness

    /// Compares each region's DeFlock build with the current one (a 1.4 KB request per source);
    /// Overpass regions go stale after 7 days. Automatic checks run at most daily, only while the
    /// Map page is in use.
    func checkFreshness(manual: Bool) async {
        if !manual, let last = lastCheck, Date().timeIntervalSince(last) < 86400 { return }
        guard !regions.isEmpty else { return }
        for i in regions.indices where !regions[i].status.isBusy { regions[i].status = .checking }
        var current: [String: String] = [:]
        for s in [ALPRSource.deflockUS, .deflockCA] where regions.contains(where: { $0.meta.sources.contains(s) }) {
            builds[s] = nil
            if let b = try? await build(s) { current[s.rawValue] = b.build }
        }
        for i in regions.indices where regions[i].status == .checking {
            let m = regions[i].meta
            var outdated = false
            for (src, b) in m.builds { if let now = current[src], now != b { outdated = true } }
            if m.sources.contains(.overpass), Date().timeIntervalSince(m.fetchedAt) > 7 * 86400 { outdated = true }
            regions[i].status = outdated ? .outdated : .current
        }
        lastCheck = Date()
        UserDefaults.standard.set(lastCheck, forKey: "map.alpr.lastCheck")
    }
}

extension ALPRStore.Status {
    var isBusy: Bool { if case .downloading = self { true } else { self == .checking } }
}

extension ALPRParseError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .tooLarge: "The camera data was larger than expected."
        case .truncated: "The camera data was cut short."
        case .malformed(let what): "The camera data couldn't be read (\(what))."
        case .serverRemark(let r): "The Overpass server reported a problem: \(r.prefix(160))"
        }
    }
}

extension TileSourceError: LocalizedError {
    public var errorDescription: String? { "The map tile source couldn't be used (\(self))." }
}
