import AppKit
import GridCore
import Observation

@Observable
@MainActor
final class AppCatalog {
    private(set) var records: [AppRecord] = []
    private(set) var scanning = false
    private(set) var lastScan: Date?
    private(set) var disambiguators: [String: String] = [:]
    private(set) var favorites: [String] { didSet { UserDefaults.standard.set(favorites, forKey: "apps.favorites") } }
    private(set) var recents: [String] { didSet { UserDefaults.standard.set(recents, forKey: "apps.recents") } }
    /// bundle IDs remembered for favorites/recents so moved apps can be found again.
    @ObservationIgnored private var knownBundleIDs: [String: String] {
        didSet { UserDefaults.standard.set(knownBundleIDs, forKey: "apps.bundleIDs") }
    }
    @ObservationIgnored private var iconCache: [String: NSImage] = [:]
    @ObservationIgnored var onError: ((String) -> Void)?
    @ObservationIgnored var onLaunched: ((AppRecord) -> Void)?

    init() {
        let d = UserDefaults.standard
        favorites = d.stringArray(forKey: "apps.favorites") ?? []
        recents = d.stringArray(forKey: "apps.recents") ?? []
        knownBundleIDs = (d.dictionary(forKey: "apps.bundleIDs") as? [String: String]) ?? [:]
        rescan()
    }

    func refreshIfStale() {
        if let t = lastScan, Date().timeIntervalSince(t) < 60 { return }
        rescan()
    }

    func rescan() {
        guard !scanning else { return }
        scanning = true
        Task {
            let found = await Task.detached(priority: .userInitiated) {
                AppDiscovery.scan(roots: AppDiscovery.standardRoots())
                    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            }.value
            records = found
            disambiguators = AppDiscovery.disambiguators(for: found)
            scanning = false
            lastScan = Date()
            healMovedApps()
        }
    }

    /// If a pinned/recent app moved (same bundle ID, new path), follow it.
    private func healMovedApps() {
        let byBundle = Dictionary(records.compactMap { r in r.bundleID.map { ($0, r.path) } }, uniquingKeysWith: { a, _ in a })
        func heal(_ list: [String]) -> [String] {
            list.map { path in
                if FileManager.default.fileExists(atPath: path) { return path }
                if let bid = knownBundleIDs[path], let newPath = byBundle[bid] {
                    knownBundleIDs[newPath] = bid
                    return newPath
                }
                return path
            }
        }
        favorites = heal(favorites)
        recents = heal(recents)
    }

    func record(forPath p: String) -> AppRecord? { records.first { $0.path == p } }

    func isMissing(_ path: String) -> Bool { !FileManager.default.fileExists(atPath: path) }

    func ranked(_ query: String) -> [AppRecord] {
        AppDiscovery.rank(records, query: query, favorites: Set(favorites), recents: recents)
    }

    func icon(for path: String) -> NSImage {
        if let i = iconCache[path] { return i }
        let i = NSWorkspace.shared.icon(forFile: path)
        i.size = NSSize(width: 32, height: 32)
        iconCache[path] = i
        return i
    }

    // MARK: Launch

    func launch(_ r: AppRecord) {
        guard FileManager.default.fileExists(atPath: r.path) else {
            onError?("“\(r.name)” is no longer at \(PathResolver.abbreviate(r.path)). Rescanning…")
            rescan()
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: r.url, configuration: config) { [weak self] _, err in
            DispatchQueue.main.async {
                guard let self else { return }
                if let err {
                    self.onError?("Could not open “\(r.name)”: \(err.localizedDescription)")
                } else {
                    self.noteLaunch(r)
                    self.onLaunched?(r)
                }
            }
        }
    }

    private func noteLaunch(_ r: AppRecord) {
        recents.removeAll { $0 == r.path }
        recents.insert(r.path, at: 0)
        if recents.count > 12 { recents.removeLast(recents.count - 12) }
        if let b = r.bundleID { knownBundleIDs[r.path] = b }
    }

    // MARK: Pins

    func isFavorite(_ r: AppRecord) -> Bool { favorites.contains(r.path) }

    func toggleFavorite(_ r: AppRecord) {
        if let i = favorites.firstIndex(of: r.path) {
            favorites.remove(at: i)
        } else {
            favorites.append(r.path)
            if let b = r.bundleID { knownBundleIDs[r.path] = b }
        }
    }

    func removeFavorite(path: String) { favorites.removeAll { $0 == path } }
    func clearRecents() { recents.removeAll() }
}
