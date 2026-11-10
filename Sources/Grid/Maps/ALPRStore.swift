import Foundation
import GridCore
import Observation

/// ALPR cameras by region: the region catalogue (Geofabrik), downloads (DeFlock z11 tiles in the
/// US and Canada, Overpass elsewhere), offline storage per region, the combined spatial index the
/// map draws from, and freshness checks. Every download is confirmed first with its host, request
/// count and size (see `MapModel.requestDownload`).
///
/// The store lives on the main actor, but parsing, point-in-polygon filtering and file writes
/// (all of which grow with the size of a region) run off it.
@Observable
@MainActor
final class ALPRStore {
    struct RegionMeta: Codable, Equatable, Sendable {
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

    enum Status: Equatable, Sendable {
        case idle, checking, current, outdated
        case downloading(done: Int, total: Int)
        case failed(String)
    }

    struct Region: Identifiable, Equatable, Sendable {
        var meta: RegionMeta
        var status: Status
        var id: String { meta.descriptor.id }
    }

    /// What a download will do, shown in the confirmation before anything is fetched.
    struct DownloadPlan: Sendable {
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

    private(set) var regions: [Region] = [] {
        didSet { if Self.outlineKey(regions) != Self.outlineKey(oldValue) { outlineRevision &+= 1 } }
    }
    /// Bumped when the set of regions or a region's stored data changes, but not for status
    /// changes such as download progress: the map rebuilds its region outlines only then.
    private(set) var outlineRevision = 0
    private(set) var index = CameraIndex([])
    /// Bumped when `index` changes.
    private(set) var revision = 0
    private(set) var catalog: RegionCatalog?
    private(set) var catalogState: String?
    private(set) var lastCheck: Date? = UserDefaults.standard.object(forKey: "map.alpr.lastCheck") as? Date
    private(set) var busy = false
    /// The last download error for a region that wasn't stored.
    private(set) var lastError: String?

    /// Mirrors "Enable map data": checked again here before any request (defence in depth).
    @ObservationIgnored var enabled = false
    /// Called after `index` changed (the model recounts the cameras in view).
    @ObservationIgnored var onIndexChange: (() -> Void)?
    @ObservationIgnored private var downloadTask: Task<Void, Never>?
    /// The region being downloaded, if any.
    @ObservationIgnored private var downloadingID: String?
    @ObservationIgnored private var builds: [ALPRSource: (DeFlockBuild, Date)] = [:]
    /// Reading the stored regions at start; whatever needs `regions` waits for it.
    @ObservationIgnored private var storedLoad: Task<Void, Never>?
    /// Bumped by `clearAll()`: a read of the stored regions begun before it is dropped.
    @ObservationIgnored private var storeGeneration = 0
    @ObservationIgnored private var indexGeneration = 0
    @ObservationIgnored private var overpassPolicy: FetchPolicy = {
        (UserDefaults.standard.data(forKey: "map.overpass.policy")).flatMap { try? JSONDecoder().decode(FetchPolicy.self, from: $0) } ?? FetchPolicy()
    }()

    // MARK: Hosts

    nonisolated static let deflockHosts: Set<String> = ["deflock.dontgetflocked.com", "tiles.dontgetflocked.com"]
    static let buildURLs: [ALPRSource: URL] = [
        .deflockUS: URL(string: "https://deflock.dontgetflocked.com/cameras-us-hourly.json")!,
        .deflockCA: URL(string: "https://deflock.dontgetflocked.com/cameras-ca-hourly.json")!,
    ]
    static let catalogURL = URL(string: "https://download.geofabrik.de/index-v1.json")!
    nonisolated static let defaultOverpass = "https://overpass-api.de/api/interpreter"

    /// The Overpass server from Settings › Map (set there only after a confirmation), or the default.
    nonisolated static var overpassEndpoint: URL {
        let raw = UserDefaults.standard.string(forKey: "map.overpass.endpoint") ?? defaultOverpass
        if let u = URL(string: raw), u.scheme == "https", u.user == nil, u.port == nil, u.host != nil { return u }
        return URL(string: defaultOverpass)!
    }
    nonisolated static var overpassHost: String { overpassEndpoint.host ?? "overpass-api.de" }

    private static let maxOverpassChunks = 60

    init() { loadStored() }

    private func requireEnabled() throws {
        guard enabled else { throw MapNetwork.NetError.transport("Map data is turned off.") }
    }

    // MARK: Stored regions

    private nonisolated static func folder(_ d: RegionDescriptor) -> URL {
        MapStorage.alpr.appendingPathComponent(d.storageKey, isDirectory: true)
    }
    private nonisolated static func packageFile(_ d: RegionDescriptor) -> URL { folder(d).appendingPathComponent("cameras.gridalpr") }
    private nonisolated static func metaFile(_ d: RegionDescriptor) -> URL { folder(d).appendingPathComponent("meta.json") }

    private struct OutlineKey: Equatable {
        var id: String
        var fetchedAt: Date
        var cameraCount: Int
    }
    private static func outlineKey(_ regions: [Region]) -> [OutlineKey] {
        regions.map { OutlineKey(id: $0.id, fetchedAt: $0.meta.fetchedAt, cameraCount: $0.meta.cameraCount) }
    }

    /// Reads the stored regions off the main thread: each `meta.json` carries the region's
    /// boundary, which for a country is a large document to parse.
    private func loadStored() {
        let generation = storeGeneration
        storedLoad = Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) { Self.readStoredRegions() }.value
            guard let self, generation == self.storeGeneration else { return }
            // A region added meanwhile (a download that finished first) is newer than the disk copy.
            let known = Set(self.regions.map(\.id))
            self.regions = (self.regions + found.filter { !known.contains($0.id) }).sorted { $0.meta.descriptor.name < $1.meta.descriptor.name }
            self.rebuildIndex()
        }
    }

    /// Returns once the stored regions are in `regions`.
    private func storedRegionsLoaded() async { await storedLoad?.value }

    /// Every valid region folder under `Maps/alpr/`. The files are untrusted: a folder counts
    /// only if it is a real directory whose metadata decodes and names that same folder.
    private nonisolated static func readStoredRegions() -> [Region] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let folders = try? FileManager.default.contentsOfDirectory(at: MapStorage.alpr, includingPropertiesForKeys: keys) else { return [] }
        var found: [Region] = []
        for folder in folders where !folder.lastPathComponent.hasPrefix("_") {
            guard let values = try? folder.resourceValues(forKeys: Set(keys)), values.isDirectory == true, values.isSymbolicLink != true,
                  let data = MapStorage.read(folder.appendingPathComponent("meta.json"), maxBytes: 32 << 20),
                  var meta = try? JSONDecoder().decode(RegionMeta.self, from: data),
                  meta.descriptor.storageKey == folder.lastPathComponent else { continue }
            if meta.descriptor.name.contains("/") {
                // Saved before region names were derived from Geofabrik ids ("us/rhode-island").
                let old = meta.descriptor
                meta.descriptor = RegionDescriptor(id: old.id, name: RegionCatalog.displayName(fromID: old.name), parent: old.parent,
                                                   iso3166_1: old.iso3166_1, iso3166_2: old.iso3166_2)
            }
            found.append(Region(meta: meta, status: .idle))
        }
        return found
    }

    /// Decodes every stored region and rebuilds the combined index off the main thread.
    private func rebuildIndex() {
        indexGeneration &+= 1
        let generation = indexGeneration
        let files = regions.map { Self.packageFile($0.meta.descriptor) }
        Task {
            let built = await Task.detached(priority: .userInitiated) { () -> CameraIndex in
                var seen = Set<OSMElementID>()
                var all: [ALPRCamera] = []
                for file in files {
                    guard let data = MapStorage.read(file, maxBytes: 256 << 20), let cameras = try? RegionPackage.decode(data) else { continue }
                    for c in cameras where seen.insert(c.id).inserted { all.append(c) }
                }
                return CameraIndex(all)
            }.value
            guard generation == indexGeneration else { return }
            index = built
            revision &+= 1
            onIndexChange?()
        }
    }

    func remove(_ id: String) {
        guard let region = regions.first(where: { $0.id == id }) else { return }
        // A download of this very region would otherwise finish and bring it back.
        if downloadingID == id { cancel() }
        try? MapStorage.remove(Self.folder(region.meta.descriptor))
        regions.removeAll { $0.id == id }
        rebuildIndex()
    }

    func clearAll() {
        cancel()
        storeGeneration &+= 1
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
        var downloaded = false
        if data == nil {
            guard enabled else { catalogState = "Turn on map data to load the region list."; return }
            catalogState = "Downloading the region list from download.geofabrik.de…"
            do {
                let r = try await MapNetwork.shared.get(Self.catalogURL, hosts: ["download.geofabrik.de"], maxBytes: 16 << 20, timeout: 60)
                guard r.status == 200 else { throw MapNetwork.NetError.http(r.status) }
                data = r.data
                downloaded = true
            } catch {
                data = MapStorage.read(file, maxBytes: 16 << 20)   // stale is better than nothing
                if data == nil {
                    catalogState = "Couldn't load the region list: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
                    return
                }
            }
        }
        guard let bytes = data else { return }
        let parsed = await Task.detached(priority: .userInitiated) { () -> RegionCatalog? in
            guard let catalog = try? RegionCatalog.parse(bytes) else { return nil }
            // Only a list that parsed is kept (a captive portal page never lands on disk).
            if downloaded { try? MapStorage.write(bytes, to: file) }
            return catalog
        }.value
        if let parsed { catalog = parsed; catalogState = nil } else { catalogState = "The region list couldn't be read." }
    }

    // MARK: Planning a download

    /// DeFlock's current build for a source (remembered for an hour).
    private func build(_ s: ALPRSource) async throws -> DeFlockBuild {
        try requireEnabled()
        if let (b, at) = builds[s], Date().timeIntervalSince(at) < 3600 { return b }
        guard let url = Self.buildURLs[s] else { throw MapNetwork.NetError.blockedURL(s.rawValue) }
        let r = try await MapNetwork.shared.get(url, hosts: Self.deflockHosts, maxBytes: 1 << 20)
        guard r.status == 200 else { throw MapNetwork.NetError.http(r.status) }
        let b = try DeFlockBuild.parse(r.data, from: url)
        builds[s] = (b, Date())
        return b
    }

    /// The build's camera index (every camera position, tens of megabytes), from disk or the
    /// network. Read, parsed and stored off the main thread.
    private func deflockIndex(_ s: ALPRSource, _ b: DeFlockBuild) async throws -> DeFlockIndex {
        let folder = MapStorage.alpr.appendingPathComponent("_deflock", isDirectory: true)
        let file = folder.appendingPathComponent("\(s.rawValue)-\(b.build).bin")
        let stored = await Task.detached(priority: .userInitiated) {
            MapStorage.read(file, maxBytes: 64 << 20).flatMap { try? DeFlockIndex($0) }
        }.value
        if let stored { return stored }
        try requireEnabled()
        let r = try await MapNetwork.shared.get(b.indexURL, hosts: Self.deflockHosts, maxBytes: 64 << 20, timeout: 60)
        guard r.status == 200 else { throw MapNetwork.NetError.http(r.status) }
        let data = r.data
        return try await Task.detached(priority: .userInitiated) {
            let index = try DeFlockIndex(data)
            // Keep only the current build's index.
            if let old = try? FileManager.default.contentsOfDirectory(atPath: folder.path) {
                for name in old where name.hasPrefix(s.rawValue + "-") { try? MapStorage.remove(folder.appendingPathComponent(name)) }
            }
            try? MapStorage.write(data, to: file)
            return index
        }.value
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
                let index = try await deflockIndex(s, b)
                // Testing every indexed camera against the region's boundary takes a while for a large region.
                let (wanted, count) = await Task.detached(priority: .userInitiated) {
                    (index.nonEmptyTiles(z: 11, in: polygon), index.count(in: polygon))
                }.value
                estimate += count
                tiles.append((s, b, wanted))
            case .overpass:
                chunks = try Self.overpassChunks(polygon, tooLarge: "This area is too large to download from Overpass in one go. Pick a smaller region or draw a smaller area.")
            }
        }
        // A drawn area that DeFlock's US/Canada index has nothing for (e.g. just across the border,
        // which its coarse bounds include) falls back to Overpass, which covers everywhere.
        var finalSources = sources
        if isRectangle, chunks.isEmpty, !tiles.isEmpty, tiles.allSatisfy({ $0.2.isEmpty }) {
            chunks = try Self.overpassChunks(polygon, tooLarge: "This area is too large to download from Overpass in one go. Draw a smaller area.")
            tiles = []
            finalSources = [.overpass]
        }
        return DownloadPlan(descriptor: d, polygon: polygon, isRectangle: isRectangle, sources: finalSources,
                            deflockTiles: tiles, overpassChunks: chunks, estimatedCameras: estimate)
    }

    private static func overpassChunks(_ polygon: GeoPolygon, tooLarge message: String) throws -> [BBox] {
        // chunks() returns at most `limit`; one more than the budget means "too big".
        let chunks = OverpassQuery.chunks(polygon, z: 7, limit: maxOverpassChunks + 1)
        guard chunks.count <= maxOverpassChunks else { throw MapNetwork.NetError.transport(message) }
        return chunks
    }

    // MARK: Downloading

    /// Starts a confirmed download (one at a time); `cancel()` stops it.
    func start(_ p: DownloadPlan, done: (() -> Void)? = nil) {
        guard enabled, !busy else { done?(); return }
        downloadTask = Task { await download(p); done?() }
    }

    /// Stops the current download. A region that already existed keeps its previous data.
    func cancel() { downloadTask?.cancel() }

    private func download(_ p: DownloadPlan) async {
        guard !busy, enabled else { return }
        busy = true
        downloadingID = p.descriptor.id
        defer { busy = false; downloadingID = nil; downloadTask = nil }
        await storedRegionsLoaded()
        let total = max(1, p.requests)
        var done = 0
        // An existing region keeps its stored metadata until the new data is saved.
        let existing = regions.contains { $0.id == p.descriptor.id }
        setStatus(p.descriptor, .downloading(done: 0, total: total), meta: existing ? nil : placeholderMeta(p))
        let progress: (Int) -> Void = { [weak self] finished in
            done += finished
            self?.setStatus(p.descriptor, .downloading(done: done, total: total), meta: nil)
        }
        do {
            var cameras: [OSMElementID: ALPRCamera] = [:]
            var builds: [String: String] = [:]
            for (source, build, tiles) in p.deflockTiles {
                builds[source.rawValue] = build.build
                for c in try await deflockCameras(build, tiles: tiles, in: p.polygon, progress: progress) { cameras[c.id] = c }
            }
            var osmBase: Date?
            for box in p.overpassChunks {
                try Task.checkCancellation()
                let chunk = try await overpassCameras(box, in: p.polygon)
                if let base = chunk.osmBase { osmBase = base }
                for c in chunk.cameras { cameras[c.id] = c }
                progress(1)
            }
            let list = Array(cameras.values)
            let meta = RegionMeta(descriptor: p.descriptor, polygon: p.polygon, sources: p.sources, builds: builds, osmBase: osmBase,
                                  fetchedAt: Date(), cameraCount: list.count, requests: p.requests, isRectangle: p.isRectangle)
            try Task.checkCancellation()
            try await Self.save(list, meta, isNew: !existing)
            setStatus(p.descriptor, .current, meta: meta)
            rebuildIndex()
        } catch {
            downloadFailed(p.descriptor, error, existing: existing)
        }
    }

    /// The cameras of DeFlock's tiles that lie inside `polygon`, at most four requests in flight.
    /// Decoding and the boundary test run in the request's own task, off the main thread.
    private func deflockCameras(_ build: DeFlockBuild, tiles: [TileID], in polygon: GeoPolygon,
                                progress: (Int) -> Void) async throws -> [ALPRCamera] {
        var cameras: [ALPRCamera] = []
        var next = 0
        while next < tiles.count {
            try Task.checkCancellation()
            try requireEnabled()
            let batch = Array(tiles[next..<min(next + 4, tiles.count)])
            next += batch.count
            cameras += try await withThrowingTaskGroup(of: [ALPRCamera].self) { group -> [ALPRCamera] in
                for t in batch {
                    group.addTask {
                        guard let url = build.tileURL(t) else { return [] }
                        let r = try await MapNetwork.shared.get(url, hosts: Self.deflockHosts, maxBytes: 8 << 20)
                        guard r.status == 200 || r.status == 204 || r.status == 404 else { throw MapNetwork.NetError.http(r.status) }
                        guard !r.data.isEmpty, let tile = try? MVTDecoder.decode(r.data, layers: ["cameras"]) else { return [] }
                        return DeFlockTile.cameras(tile, id: t).filter { polygon.contains($0.coordinate) }
                    }
                }
                var found: [ALPRCamera] = []
                for try await list in group { found += list }
                return found
            }
            progress(batch.count)
        }
        return cameras
    }

    /// One Overpass request for `box`, honouring the backoff and the daily budget; a busy or
    /// rate-limited answer is retried up to three times after waiting out the backoff.
    private func overpassCameras(_ box: BBox, in polygon: GeoPolygon) async throws -> (cameras: [ALPRCamera], osmBase: Date?) {
        var attempts = 0
        while true {
            try requireEnabled()
            while !overpassPolicy.canRequest(now: Date()) {
                guard let retry = overpassPolicy.retryAt, retry.timeIntervalSinceNow < 900 else {
                    throw MapNetwork.NetError.transport("Overpass's daily limit for GRID is reached; try again tomorrow.")
                }
                try await Task.sleep(for: .seconds(max(1, retry.timeIntervalSinceNow)))
            }
            var components = URLComponents(url: Self.overpassEndpoint, resolvingAgainstBaseURL: false)
            components?.queryItems = [URLQueryItem(name: "data", value: OverpassQuery.alpr(box))]
            guard let url = components?.url else { throw MapNetwork.NetError.blockedURL(Self.overpassHost) }
            let r = try await MapNetwork.shared.get(url, hosts: [Self.overpassHost], maxBytes: 64 << 20, timeout: 120)
            if r.status != 200 {
                overpassPolicy.failed(status: r.status, now: Date()); savePolicy()
                if [429, 406, 504].contains(r.status) && attempts < 3 { attempts += 1; continue }
                throw MapNetwork.NetError.http(r.status)
            }
            overpassPolicy.succeeded(now: Date()); savePolicy()
            let body = r.data
            return try await Task.detached(priority: .userInitiated) {
                let parsed = try OverpassQuery.parse(body)
                return (parsed.cameras.filter { polygon.contains($0.coordinate) }, parsed.osmBase)
            }.value
        }
    }

    /// Writes a region's package and metadata (off the main thread).
    private nonisolated static func save(_ cameras: [ALPRCamera], _ meta: RegionMeta, isNew: Bool) async throws {
        try await Task.detached(priority: .userInitiated) {
            do {
                try MapStorage.write(RegionPackage.encode(cameras), to: packageFile(meta.descriptor))
                try MapStorage.write(try JSONEncoder().encode(meta), to: metaFile(meta.descriptor))
            } catch {
                // Don't leave a package without metadata (invisible to Remove) for a new region.
                if isNew { try? MapStorage.remove(folder(meta.descriptor)) }
                throw error
            }
        }.value
    }

    private func downloadFailed(_ d: RegionDescriptor, _ error: Error, existing: Bool) {
        if error is CancellationError || (error as? MapNetwork.NetError) == .cancelled || Task.isCancelled {
            if existing {
                if let i = regions.firstIndex(where: { $0.id == d.id }) { regions[i].status = .idle }
            } else {
                regions.removeAll { $0.id == d.id }
            }
            return
        }
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        if FileManager.default.fileExists(atPath: Self.metaFile(d).path) {
            setStatus(d, .failed(message), meta: nil)
        } else {
            regions.removeAll { $0.id == d.id }
            lastError = message
        }
    }

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
        await storedRegionsLoaded()
        guard enabled, !regions.isEmpty else { return }
        for i in regions.indices where !regions[i].status.isBusy { regions[i].status = .checking }
        var current: [String: String] = [:]
        for s in [ALPRSource.deflockUS, .deflockCA] where regions.contains(where: { $0.meta.sources.contains(s) }) {
            builds[s] = nil
            if let b = try? await build(s) { current[s.rawValue] = b.build }
        }
        for i in regions.indices where regions[i].status == .checking {
            let m = regions[i].meta
            var outdated = false
            for (source, build) in m.builds { if let now = current[source], now != build { outdated = true } }
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
