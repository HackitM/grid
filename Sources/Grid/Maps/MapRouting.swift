import Foundation
import GridCore
import Observation

// On-device routing: road graphs built on this Mac from OpenStreetMap extracts (Geofabrik), and
// routes worked out locally. Nothing about a route leaves the Mac; the only network use is
// downloading a region's extract, after asking.

// MARK: - Road data

/// Installed road graphs, one per region, and the download / build job.
@Observable
@MainActor
final class RoutingStore {
    struct Meta: Codable, Equatable, Identifiable, Sendable {
        var id: String
        var name: String
        var bbox: BBox
        var builtAt: Date
        var graphBytes: Int64
        var vertices: Int
        var edges: Int
    }

    enum Job: Equatable, Sendable {
        case none
        case sizing(String)
        case downloading(String, done: Int64, total: Int64)
        case building(String, stage: String, fraction: Double)
        case failed(String)
    }

    private(set) var installed: [Meta] = []
    private(set) var job: Job = .none
    @ObservationIgnored private var task: Task<Void, Never>?
    /// The flag of the install under way (or of the last one). It also identifies that install:
    /// one that was cancelled and replaced must not touch `job` when it winds down.
    @ObservationIgnored private var cancelFlag = BuildCancelFlag()

    nonisolated static let host = "download.geofabrik.de"
    /// Extracts bigger than this are refused (building needs several times this in memory).
    nonisolated static let maxExtractBytes: Int64 = 700 << 20

    nonisolated static var dir: URL { MapStorage.root.appendingPathComponent("routing", isDirectory: true) }
    nonisolated static func graphFile(_ key: String) -> URL { dir.appendingPathComponent("\(key).grdg") }
    nonisolated static func metaFile(_ key: String) -> URL { dir.appendingPathComponent("\(key).json") }
    private nonisolated static let partSuffix = ".pbf.part"

    init() {
        loadInstalled()
        // A download cut short by a crash or a forced quit leaves its extract behind (up to 700 MB).
        Task.detached(priority: .utility) { Self.removeLeftoverDownloads() }
    }

    var busy: Bool {
        switch job { case .sizing, .downloading, .building: true; default: false }
    }

    /// Reads the installed graphs' metadata. The files are untrusted: one counts only if it
    /// decodes and names itself (its id is used to build the graph's file name).
    private func loadInstalled() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: Self.dir.path)) ?? []
        installed = names.filter { $0.hasSuffix(".json") }.compactMap { name -> Meta? in
            guard let data = MapStorage.read(Self.dir.appendingPathComponent(name), maxBytes: 64 << 10),
                  let meta = try? JSONDecoder().decode(Meta.self, from: data), meta.id + ".json" == name else { return nil }
            return meta
        }.sorted { $0.name < $1.name }
    }

    private nonisolated static func removeLeftoverDownloads() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in names where name.hasSuffix(partSuffix) { try? MapStorage.remove(dir.appendingPathComponent(name)) }
    }

    /// The installed graph covering both points (the smallest).
    func graph(covering a: LonLat, _ b: LonLat) -> Meta? {
        func area(_ box: BBox) -> Double { (box.east - box.west) * (box.north - box.south) }
        return installed.filter { $0.bbox.contains(a) && $0.bbox.contains(b) }.min { area($0.bbox) < area($1.bbox) }
    }

    /// The smallest catalogue region whose boundary contains `p` (a state rather than its country).
    static func region(containing p: LonLat, in cat: RegionCatalog) -> RegionDescriptor? {
        var best: (region: RegionDescriptor, area: Double)?
        for r in cat.regions {
            guard let poly = cat.polygon(r.id) else { continue }
            let b = poly.bbox
            guard b.contains(p), poly.contains(p) else { continue }
            let area = (b.east - b.west) * (b.north - b.south)
            if area < (best?.area ?? .infinity) { best = (r, area) }
        }
        return best?.region
    }

    /// The extract's size (HEAD), for the confirmation.
    func size(of url: URL, name: String) async -> Int64? {
        guard !busy else { return nil }
        job = .sizing(name)
        defer { if case .sizing = job { job = .none } }
        return try? await MapNetwork.shared.size(of: url, hosts: [Self.host]).bytes
    }

    // MARK: Installing

    /// Downloads the region's extract, builds its road graph, saves it and deletes the extract,
    /// all off the main thread. `done` runs on success.
    func install(_ region: RegionDescriptor, from url: URL, done: (() -> Void)? = nil) {
        guard !busy else { return }
        let flag = BuildCancelFlag()
        cancelFlag = flag
        let key = region.storageKey, name = region.name
        job = .downloading(name, done: 0, total: -1)
        let report: @Sendable (Job) -> Void = { [weak self] progress in
            Task { @MainActor in self?.report(progress, from: flag) }
        }
        task = Task { [weak self] in
            do {
                _ = try await Self.downloadAndBuild(key: key, name: name, url: url, flag: flag, progress: report)
                guard let self else { return }
                self.loadInstalled()
                guard self.cancelFlag === flag, !flag.isSet else { return }
                self.job = .none
                done?()
            } catch {
                guard let self, self.cancelFlag === flag else { return }
                let cancelled = flag.isSet || (error as? PBFError) == .cancelled || (error as? MapNetwork.NetError) == .cancelled || error is CancellationError
                self.job = cancelled ? .none : .failed(Self.describe(error, name))
            }
        }
    }

    /// Progress from the install identified by `flag`. Reports arrive a moment late, so one from
    /// a job that has since ended, or an earlier stage's after a later stage began, is dropped.
    private func report(_ progress: Job, from flag: BuildCancelFlag) {
        guard cancelFlag === flag, !flag.isSet else { return }
        switch (job, progress) {
        case (.downloading, .downloading), (.downloading, .building), (.building, .building): job = progress
        default: break
        }
    }

    /// The whole install, away from the main actor. The extract goes to a file of its own name
    /// (so an install that is still winding down after Cancel can't delete its successor's), and
    /// that file is removed however this ends.
    private nonisolated static func downloadAndBuild(key: String, name: String, url: URL, flag: BuildCancelFlag,
                                                     progress: @escaping @Sendable (Job) -> Void) async throws -> Meta {
        try MapStorage.ensureDirectory(dir)
        let part = dir.appendingPathComponent("\(key)-\(UUID().uuidString)\(partSuffix)")
        guard FileManager.default.createFile(atPath: part.path, contents: nil) else {
            throw MapStorage.StorageError.io("Couldn't create the download file.")
        }
        defer { try? MapStorage.remove(part) }

        let downloadPace = Throttle(interval: 0.15)
        let response = try await MapNetwork.shared.download(url, to: part, hosts: [host], maxBytes: maxExtractBytes) { sofar, total in
            if downloadPace.ready() { progress(.downloading(name, done: sofar, total: total)) }
        }
        guard response.status == 200 else { throw MapNetwork.NetError.http(response.status) }
        try Task.checkCancellation()

        progress(.building(name, stage: "Reading roads", fraction: 0))
        return try await Task.detached(priority: .utility) {
            // Mapped, not read: the extract can be hundreds of megabytes.
            guard let pbf = try? Data(contentsOf: part, options: [.alwaysMapped]) else {
                throw MapStorage.StorageError.io("Couldn't read the download.")
            }
            let buildPace = Throttle(interval: 0.1)
            let (graph, _) = try RoadGraphBuilder.build(pbf: pbf, progress: { stage, fraction in
                guard buildPace.ready() else { return }
                switch stage {
                case .ways: progress(.building(name, stage: "Reading roads", fraction: fraction * 0.45))
                case .nodes: progress(.building(name, stage: "Reading positions", fraction: 0.45 + fraction * 0.4))
                case .building: progress(.building(name, stage: "Building the network", fraction: 0.85 + fraction * 0.15))
                }
            }, cancelled: { flag.isSet })
            guard graph.edgeCount > 0 else { throw MapStorage.StorageError.io("No drivable roads were found in \(name).") }
            return try save(graph, key: key, name: name, flag: flag)
        }.value
    }

    /// Writes the graph, then its metadata (which is what makes it count as installed).
    private nonisolated static func save(_ graph: RoadGraph, key: String, name: String, flag: BuildCancelFlag) throws -> Meta {
        let file = RoadGraphFile.encode(graph)
        var west = 180.0, east = -180.0, south = 90.0, north = -90.0
        for i in 0..<graph.vertexCount {
            let lat = Double(graph.lat[i]) / 1e7, lon = Double(graph.lon[i]) / 1e7
            west = min(west, lon); east = max(east, lon); south = min(south, lat); north = max(north, lat)
        }
        let meta = Meta(id: key, name: name, bbox: BBox(west: west, south: south, east: east, north: north), builtAt: Date(),
                        graphBytes: Int64(file.count), vertices: graph.vertexCount, edges: graph.edgeCount)
        // Cancelled during the last stage: nothing is installed.
        guard !flag.isSet else { throw CancellationError() }
        let replacing = FileManager.default.fileExists(atPath: metaFile(key).path)
        do {
            try MapStorage.write(file, to: graphFile(key))
            try MapStorage.write(try JSONEncoder().encode(meta), to: metaFile(key))
        } catch {
            // A graph without metadata is invisible (and can't be removed in Settings): don't leave one.
            if !replacing { try? MapStorage.remove(graphFile(key)) }
            throw error
        }
        return meta
    }

    static func describe(_ e: Error, _ name: String) -> String {
        switch e {
        case MapNetwork.NetError.tooLarge: "\(name)'s road data is too large to build on this Mac (over \(maxExtractBytes >> 20) MB). Pick a smaller region."
        case MapNetwork.NetError.http(let s): "The download server answered \(s)."
        case let p as PBFError: "The road data couldn't be read (\(p))."
        case let l as LocalizedError: l.errorDescription ?? "\(e)"
        default: "\(e.localizedDescription)"
        }
    }

    func cancel() {
        cancelFlag.set()
        task?.cancel()
        job = .none
    }

    func dismissError() { if case .failed = job { job = .none } }

    func remove(_ id: String) {
        try? MapStorage.remove(Self.graphFile(id))
        try? MapStorage.remove(Self.metaFile(id))
        loadInstalled()
    }

    func clearAll() {
        cancel()
        try? MapStorage.remove(Self.dir)
        loadInstalled()
    }
}

/// Lets through at most one call per `interval` (progress reports).
final class Throttle: @unchecked Sendable {
    private let lock = NSLock()
    private var last = 0.0
    let interval: Double
    init(interval: Double) { self.interval = interval }
    func ready() -> Bool {
        lock.withLock {
            let now = CFAbsoluteTimeGetCurrent()
            guard now - last >= interval else { return false }
            last = now
            return true
        }
    }
}

/// A flag a background build polls to stop early.
final class BuildCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

// MARK: - Route engine

/// Routes off the main thread on one loaded graph.
actor RouteService {
    /// Identifies the loaded graph: its region and when it was built (a region downloaded again
    /// is a new graph).
    private var loadedKey: String?
    private var engine: RouteEngine?

    struct Leg: Sendable {
        var path: RoutePath
        var hits: [CameraExposure.Hit]
    }
    struct Outcome: Sendable {
        var fastest: Leg
        var avoiding: Leg?
        var snapFrom: Double, snapTo: Double
    }
    enum Failure: Error, Equatable { case noGraph, farFromRoad(Bool), noRoute }

    /// Most cameras considered for one route.
    static let maxCandidates = 20_000

    func load(_ meta: RoutingStore.Meta) throws {
        let key = "\(meta.id)@\(meta.builtAt.timeIntervalSinceReferenceDate)"
        guard loadedKey != key else { return }
        engine = nil; loadedKey = nil
        guard let data = MapStorage.read(RoutingStore.graphFile(meta.id), maxBytes: 2 << 30) else { throw Failure.noGraph }
        let g = try RoadGraphFile.decode(data)
        engine = RouteEngine(graph: g)
        loadedKey = key
    }

    func unload() { engine = nil; loadedKey = nil }

    /// The route between two points, counting (and with `avoid`, avoiding) the cameras of `index`
    /// near it. Throws `CancellationError` without doing the work if the request was cancelled
    /// while it waited its turn.
    func route(from a: LonLat, to b: LonLat, index: CameraIndex, avoid: Bool, options: ExposureOptions) throws -> Outcome {
        try Task.checkCancellation()
        // Cameras that could matter: those in the two ends' box, grown by half its size.
        let span = max(abs(a.lon - b.lon), abs(a.lat - b.lat))
        let pad = max(0.05, span * 0.5)
        let box = BBox(west: max(-180, min(a.lon, b.lon) - pad), south: max(-85, min(a.lat, b.lat) - pad),
                       east: min(180, max(a.lon, b.lon) + pad), north: min(85, max(a.lat, b.lat) + pad))
        let cameras = index.query(box).prefix(Self.maxCandidates).map { ($0, index.cameras[$0]) }
        return try route(from: a, to: b, cameras: cameras, avoid: avoid, options: options)
    }

    /// The fastest route and, when `avoid` is on, the one that avoids the mapped cameras it can.
    func route(from a: LonLat, to b: LonLat, cameras: [(Int, ALPRCamera)], avoid: Bool, options: ExposureOptions) throws -> Outcome {
        guard let engine else { throw Failure.noGraph }
        guard let sa = engine.snap(a) else { throw Failure.farFromRoad(true) }
        guard let sb = engine.snap(b) else { throw Failure.farFromRoad(false) }
        // A newer request cancels this task: stop searching instead of finishing a stale route.
        guard let fast = engine.route(from: sa, to: sb, cancelled: { Task.isCancelled }) else {
            throw Task.isCancelled ? CancellationError() : Failure.noRoute
        }
        func leg(_ p: RoutePath) -> Leg { Leg(path: p, hits: CameraExposure.hits(route: p.points, candidates: cameras, options: options)) }
        let fastest = leg(fast)
        var avoiding: Leg?
        if avoid, !fastest.hits.isEmpty {
            let penalties = engine.cameraPenalties(cameras.map(\.1), options: options)
            if let p = engine.route(from: sa, to: sb, penalty: penalties, cancelled: { Task.isCancelled }) { avoiding = leg(p) }
        }
        // A search stopped part way returns nil: never report that as "no avoiding route".
        try Task.checkCancellation()
        return Outcome(fastest: fastest, avoiding: avoiding, snapFrom: sa.distance, snapTo: sb.distance)
    }
}

// MARK: - Route state

/// The Map page's routing state: the two ends, options and the result.
@Observable
@MainActor
final class MapRouting {
    struct End: Equatable {
        var name: String
        var coordinate: LonLat
    }
    enum Which: Equatable { case avoiding, fastest }
    enum State: Equatable {
        case idle
        case needsData(RegionDescriptor?, reason: String)
        case working
        case done
        case failed(String)
    }

    var open = false
    var from: End? { didSet { if from != oldValue { invalidate() } } }
    var to: End? { didSet { if to != oldValue { invalidate() } } }
    var avoid: Bool { didSet { defaults.set(avoid, forKey: "map.route.avoid"); invalidate() } }
    var directional: Bool { didSet { defaults.set(directional, forKey: "map.route.directional"); invalidate() } }
    var buffer: Double { didSet { defaults.set(buffer, forKey: "map.route.buffer"); invalidate() } }
    private(set) var state: State = .idle
    private(set) var outcome: RouteService.Outcome? { didSet { pathRevision &+= 1 } }
    var shown: Which = .avoiding { didSet { pathRevision &+= 1 } }
    /// The step the pointer is over (marked on the map).
    var hoveredStep: Int? { didSet { if hoveredStep != oldValue { model?.routeChanged() } } }
    /// The camera indices that the shown route passes (for the map).
    private(set) var camerasOnRoute: Set<Int> = []
    /// Changes whenever the lines drawn for the route do (the model keeps them between frames).
    @ObservationIgnored private(set) var pathRevision = 0

    let store = RoutingStore()
    @ObservationIgnored let service = RouteService()
    @ObservationIgnored weak var model: MapModel?
    @ObservationIgnored private let defaults = UserDefaults.standard
    /// The route (or the lookup of which road data is missing) being worked out.
    @ObservationIgnored private var job: Task<Void, Never>?
    @ObservationIgnored private var computeScheduled = false
    /// The next result moves the map to show the whole route (not when only the cameras changed).
    @ObservationIgnored private var fitsNextResult = true
    @ObservationIgnored private var locationTask: Task<Void, Never>?

    init() {
        defaults.register(defaults: ["map.route.avoid": true, "map.route.directional": true, "map.route.buffer": 75.0])
        avoid = defaults.bool(forKey: "map.route.avoid")
        directional = defaults.bool(forKey: "map.route.directional")
        buffer = min(150, max(10, defaults.double(forKey: "map.route.buffer")))
    }

    var options: ExposureOptions { ExposureOptions(buffer: buffer, directional: directional) }

    /// The leg on the map and in the steps list.
    var shownLeg: RouteService.Leg? {
        guard let o = outcome else { return nil }
        return shown == .avoiding ? (o.avoiding ?? o.fastest) : o.fastest
    }

    // MARK: Working out the route

    /// An end or an option changed: the result is void, and a new one is worked out. With `fit`
    /// the map then moves to show the whole route.
    private func invalidate(fit: Bool = true) {
        job?.cancel()
        job = nil
        outcome = nil; camerasOnRoute = []; hoveredStep = nil
        state = .idle
        fitsNextResult = fit
        model?.routeChanged()
        scheduleCompute()
    }

    /// The camera index was rebuilt. A route counts its cameras by their index there, so it is
    /// worked out again; the map stays where it is.
    func camerasChanged() {
        guard outcome != nil || state == .working else { return }
        invalidate(fit: false)
    }

    /// Computes on the next turn of the main actor, so several changes made together (swapping
    /// the ends, an end and an option) cost one route, not one each.
    private func scheduleCompute() {
        guard from != nil, to != nil, !computeScheduled else { return }
        computeScheduled = true
        Task { [weak self] in
            guard let self else { return }
            self.computeScheduled = false
            self.compute()
        }
    }

    func swapEnds() { let f = from; from = to; to = f }

    func clear() { from = nil; to = nil }

    func compute() {
        job?.cancel()
        job = nil
        guard let a = from?.coordinate, let b = to?.coordinate, let model else { return }
        guard let meta = store.graph(covering: a, b) else {
            explainMissingData(from: a, to: b, model: model)
            return
        }
        state = .working
        let index = model.alpr.index
        let avoid = avoid, options = options
        let service = service
        let fit = fitsNextResult
        fitsNextResult = true
        job = Task { [weak self] in
            do {
                try await service.load(meta)
                let outcome = try await service.route(from: a, to: b, index: index, avoid: avoid, options: options)
                guard !Task.isCancelled, let self else { return }
                self.outcome = outcome
                self.shown = outcome.avoiding != nil ? .avoiding : .fastest
                self.state = .done
                self.refreshCameras()
                self.model?.routeChanged(fit: fit)
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.state = .failed(Self.describe(error, graphName: meta.name))
            }
        }
    }

    private static func describe(_ error: Error, graphName name: String) -> String {
        switch error as? RouteService.Failure {
        case .farFromRoad(let start)?: "The \(start ? "start" : "destination") is more than 1.5 km from a road GRID can drive on."
        case .noRoute?: "No drivable route connects these two points in \(name)'s road data."
        case .noGraph?: "\(name)'s road data couldn't be loaded. Remove it in Settings › Map and download it again."
        case nil: "\(name)'s road data is damaged (\(error)). Remove it in Settings › Map and download it again."
        }
    }

    /// No installed road data covers both ends: says which region is missing (looked up in the
    /// catalogue, which may have to be loaded first).
    private func explainMissingData(from a: LonLat, to b: LonLat, model: MapModel) {
        job = Task { [weak self] in
            await model.alpr.loadCatalog()
            // The ends may have changed while the catalogue loaded; that change has its own lookup.
            guard !Task.isCancelled, let self else { return }
            guard let catalog = model.alpr.catalog else {
                self.state = .needsData(nil, reason: "GRID needs road data for this area. Enable map data to download it.")
                return
            }
            let startRegion = RoutingStore.region(containing: a, in: catalog), endRegion = RoutingStore.region(containing: b, in: catalog)
            let hasStart = self.store.installed.contains { $0.id == startRegion?.storageKey }
            if let startRegion, let endRegion, startRegion.id != endRegion.id, hasStart {
                self.state = .needsData(endRegion, reason: "This trip leaves the area your road data covers. Routes between regions aren't supported yet.")
            } else if let missing = hasStart ? endRegion : startRegion {
                self.state = .needsData(missing, reason: "Routing needs road data for \(missing.name), downloaded once and kept on this Mac.")
            } else {
                self.state = .needsData(nil, reason: "No downloadable road data covers this point.")
            }
        }
    }

    func show(_ w: Which) {
        shown = w
        refreshCameras()
        model?.routeChanged()
    }

    private func refreshCameras() {
        camerasOnRoute = Set(shownLeg?.hits.map(\.camera) ?? [])
    }

    // MARK: Road data

    /// Downloads the road data a route needs (asks first, with the size).
    func requestData(_ region: RegionDescriptor) {
        // One download at a time, and none while map data is off.
        guard let model, model.enabled, !store.busy, let app = model.app, let cat = model.alpr.catalog else { return }
        guard let url = cat.extractURL(region.id) else {
            state = .failed("Geofabrik lists no road data download for \(region.name)."); return
        }
        Task { [weak self] in
            guard let self else { return }
            let size = await store.size(of: url, name: region.name)
            if let size, size > RoutingStore.maxExtractBytes {
                state = .failed("\(region.name)'s road data is \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)), too large to build on this Mac. Routing works with state-sized regions.")
                return
            }
            let sizeText = size.map { "about \(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file))" } ?? "a few hundred MB at most"
            _ = app.present(Confirmation(code: "ROUTE-DATA", title: "Download road data for \(region.name)?",
                                         message: "GRID downloads \(region.name)'s OpenStreetMap extract from \(RoutingStore.host) (\(sizeText); the server learns which region you chose) and builds a road network from it on this Mac. The extract is deleted afterwards; the network is kept for routing offline. Routes are worked out on this Mac and never sent anywhere.",
                                         confirmLabel: "Download", destructive: false,
                                         onConfirm: { [weak self] in
                                             self?.store.install(region, from: url) { self?.compute() }
                                         }))
        }
    }

    // MARK: Ends

    func setEnd(from isFrom: Bool, _ end: End) {
        open = true
        if isFrom { from = end } else { to = end }
        model?.app?.inspectorVisible = true
    }

    /// Fills an end with the user's position (asks for location first if needed).
    func useLocation(from isFrom: Bool) {
        guard let model else { return }
        let myLocation: (LonLat) -> End = { End(name: "My location", coordinate: $0) }
        if let (position, _) = model.location.fix { setEnd(from: isFrom, myLocation(position)); return }
        model.locate()
        locationTask?.cancel()
        locationTask = Task { [weak self] in
            guard let position = await model.location.waitForFix(), !Task.isCancelled else { return }
            self?.setEnd(from: isFrom, myLocation(position))
        }
    }

    func clearAllData() {
        locationTask?.cancel()
        clear()
        Task { await service.unload() }
        store.clearAll()
    }
}
