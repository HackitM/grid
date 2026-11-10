import Foundation
import GridCore
import Observation

// On-device routing: road graphs built on this Mac from OpenStreetMap extracts (Geofabrik), and
// routes worked out locally. Nothing about a route leaves the Mac; the only network use is
// downloading a region's extract, after asking.

/// Installed road graphs, one per region, and the download / build job.
@Observable
@MainActor
final class RoutingStore {
    struct Meta: Codable, Equatable, Identifiable {
        var id: String
        var name: String
        var bbox: BBox
        var builtAt: Date
        var graphBytes: Int64
        var vertices: Int
        var edges: Int
    }

    enum Job: Equatable {
        case none
        case sizing(String)
        case downloading(String, done: Int64, total: Int64)
        case building(String, stage: String, fraction: Double)
        case failed(String)
    }

    private(set) var installed: [Meta] = []
    private(set) var job: Job = .none
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var cancelFlag = BuildCancelFlag()

    static let host = "download.geofabrik.de"
    /// Extracts bigger than this are refused (building needs several times this in memory).
    static let maxExtractBytes: Int64 = 700 << 20

    nonisolated static var dir: URL { MapStorage.root.appendingPathComponent("routing", isDirectory: true) }
    nonisolated static func graphFile(_ key: String) -> URL { dir.appendingPathComponent("\(key).grdg") }
    nonisolated static func metaFile(_ key: String) -> URL { dir.appendingPathComponent("\(key).json") }

    init() { loadInstalled() }

    var busy: Bool {
        switch job { case .sizing, .downloading, .building: true; default: false }
    }

    private func loadInstalled() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: Self.dir.path) else { installed = []; return }
        installed = names.filter { $0.hasSuffix(".json") }.compactMap { n in
            MapStorage.read(Self.dir.appendingPathComponent(n), maxBytes: 64 << 10).flatMap { try? JSONDecoder().decode(Meta.self, from: $0) }
        }.sorted { $0.name < $1.name }
    }

    /// The installed graph covering both points (the smallest).
    func graph(covering a: LonLat, _ b: LonLat) -> Meta? {
        installed.filter { $0.bbox.contains(a) && $0.bbox.contains(b) }
            .min { ($0.bbox.east - $0.bbox.west) * ($0.bbox.north - $0.bbox.south) < ($1.bbox.east - $1.bbox.west) * ($1.bbox.north - $1.bbox.south) }
    }

    /// The smallest catalogue region whose boundary contains `p` (a state rather than its country).
    static func region(containing p: LonLat, in cat: RegionCatalog) -> RegionDescriptor? {
        var best: (RegionDescriptor, Double)?
        for r in cat.regions {
            guard let poly = cat.polygon(r.id) else { continue }
            let b = poly.bbox
            guard b.contains(p), poly.contains(p) else { continue }
            let area = (b.east - b.west) * (b.north - b.south)
            if best == nil || area < best!.1 { best = (r, area) }
        }
        return best?.0
    }

    /// The extract's size (HEAD), for the confirmation.
    func size(of url: URL, name: String) async -> Int64? {
        job = .sizing(name)
        defer { if case .sizing = job { job = .none } }
        return try? await MapNetwork.shared.size(of: url, hosts: [Self.host]).bytes
    }

    /// Downloads the region's extract, builds its road graph off the main thread, saves it and
    /// deletes the extract. `done` runs on success.
    func install(_ region: RegionDescriptor, from url: URL, done: (() -> Void)? = nil) {
        guard !busy else { return }
        let flag = BuildCancelFlag()
        cancelFlag = flag
        let key = region.storageKey
        let name = region.name
        job = .downloading(name, done: 0, total: -1)
        task = Task { [weak self] in
            let part = Self.dir.appendingPathComponent("\(key).pbf.part")
            do {
                try MapStorage.ensureDirectory(Self.dir)
                try? MapStorage.remove(part)
                guard FileManager.default.createFile(atPath: part.path, contents: nil) else { throw MapStorage.StorageError.io("Couldn't create the download file.") }
                defer { try? MapStorage.remove(part) }
                let throttle = Throttle(interval: 0.15)
                let r = try await MapNetwork.shared.download(url, to: part, hosts: [Self.host], maxBytes: Self.maxExtractBytes) { [weak self] sofar, total in
                    guard throttle.ready() else { return }
                    Task { @MainActor [weak self] in
                        if case .downloading = self?.job { self?.job = .downloading(name, done: sofar, total: total) }
                    }
                }
                guard r.status == 200 else { throw MapNetwork.NetError.http(r.status) }
                guard let data = try? Data(contentsOf: part, options: [.alwaysMapped]) else { throw MapStorage.StorageError.io("Couldn't read the download.") }
                await MainActor.run { self?.job = .building(name, stage: "Reading roads", fraction: 0) }
                let built = try await Task.detached(priority: .utility) { () -> (Data, RoadGraph) in
                    let (g, _) = try RoadGraphBuilder.build(pbf: data, progress: { stage, f in
                        let label: String
                        let overall: Double
                        switch stage {
                        case .ways: label = "Reading roads"; overall = f * 0.45
                        case .nodes: label = "Reading positions"; overall = 0.45 + f * 0.4
                        case .building: label = "Building the network"; overall = 0.85 + f * 0.15
                        }
                        Task { @MainActor [weak self] in
                            if case .building = self?.job { self?.job = .building(name, stage: label, fraction: overall) }
                        }
                    }, cancelled: { flag.isSet })
                    return (RoadGraphFile.encode(g), g)
                }.value
                let (file, g) = built
                guard g.edgeCount > 0 else { throw MapStorage.StorageError.io("No drivable roads were found in \(name).") }
                var west = 180.0, east = -180.0, south = 90.0, north = -90.0
                for i in 0..<g.vertexCount {
                    let la = Double(g.lat[i]) / 1e7, lo = Double(g.lon[i]) / 1e7
                    west = min(west, lo); east = max(east, lo); south = min(south, la); north = max(north, la)
                }
                let meta = Meta(id: key, name: name, bbox: BBox(west: west, south: south, east: east, north: north), builtAt: Date(),
                                graphBytes: Int64(file.count), vertices: g.vertexCount, edges: g.edgeCount)
                try MapStorage.write(file, to: Self.graphFile(key))
                try MapStorage.write(try JSONEncoder().encode(meta), to: Self.metaFile(key))
                await MainActor.run {
                    guard let self else { return }
                    self.job = .none
                    self.loadInstalled()
                    done?()
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    if flag.isSet || (error as? PBFError) == .cancelled || (error as? MapNetwork.NetError) == .cancelled || error is CancellationError {
                        self.job = .none
                    } else {
                        self.job = .failed(Self.describe(error, name))
                    }
                }
            }
        }
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

/// Routes off the main thread on one loaded graph.
actor RouteService {
    private var loadedID: String?
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

    func load(_ meta: RoutingStore.Meta) throws {
        guard loadedID != meta.id else { return }
        engine = nil; loadedID = nil
        guard let data = MapStorage.read(RoutingStore.graphFile(meta.id), maxBytes: 2 << 30) else { throw Failure.noGraph }
        let g = try RoadGraphFile.decode(data)
        engine = RouteEngine(graph: g)
        loadedID = meta.id
    }

    func unload() { engine = nil; loadedID = nil }

    /// The fastest route and, when `avoid` is on, the one that avoids the mapped cameras it can.
    func route(from a: LonLat, to b: LonLat, cameras: [(Int, ALPRCamera)], avoid: Bool, options: ExposureOptions) throws -> Outcome {
        guard let engine else { throw Failure.noGraph }
        guard let sa = engine.snap(a) else { throw Failure.farFromRoad(true) }
        guard let sb = engine.snap(b) else { throw Failure.farFromRoad(false) }
        guard let fast = engine.route(from: sa, to: sb) else { throw Failure.noRoute }
        func leg(_ p: RoutePath) -> Leg { Leg(path: p, hits: CameraExposure.hits(route: p.points, candidates: cameras, options: options)) }
        let fastest = leg(fast)
        var avoiding: Leg?
        if avoid, !fastest.hits.isEmpty {
            let pen = engine.cameraPenalties(cameras.map(\.1), options: options)
            if let p = engine.route(from: sa, to: sb, penalty: pen) { avoiding = leg(p) }
        }
        return Outcome(fastest: fastest, avoiding: avoiding, snapFrom: sa.distance, snapTo: sb.distance)
    }
}

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
    var avoid: Bool { didSet { d.set(avoid, forKey: "map.route.avoid"); invalidate() } }
    var directional: Bool { didSet { d.set(directional, forKey: "map.route.directional"); invalidate() } }
    var buffer: Double { didSet { d.set(buffer, forKey: "map.route.buffer"); invalidate() } }
    private(set) var state: State = .idle
    private(set) var outcome: RouteService.Outcome?
    var shown: Which = .avoiding
    /// The step the pointer is over (highlighted on the map).
    var hoveredStep: Int?

    let store = RoutingStore()
    @ObservationIgnored let service = RouteService()
    @ObservationIgnored weak var model: MapModel?
    @ObservationIgnored private let d = UserDefaults.standard
    @ObservationIgnored private var job: Task<Void, Never>?
    /// The camera indices that the shown route passes (for the map).
    private(set) var camerasOnRoute: Set<Int> = []

    init() {
        d.register(defaults: ["map.route.avoid": true, "map.route.directional": true, "map.route.buffer": 75.0])
        avoid = d.bool(forKey: "map.route.avoid")
        directional = d.bool(forKey: "map.route.directional")
        buffer = min(150, max(10, d.double(forKey: "map.route.buffer")))
    }

    var options: ExposureOptions { ExposureOptions(buffer: buffer, directional: directional) }

    /// The leg on the map and in the steps list.
    var shownLeg: RouteService.Leg? {
        guard let o = outcome else { return nil }
        return shown == .avoiding ? (o.avoiding ?? o.fastest) : o.fastest
    }

    private func invalidate() {
        job?.cancel()
        outcome = nil; camerasOnRoute = []; hoveredStep = nil
        state = .idle
        model?.routeChanged()
        if from != nil && to != nil { compute() }
    }

    func swapEnds() { let f = from; from = to; to = f }

    func clear() { from = nil; to = nil }

    func compute() {
        guard let a = from?.coordinate, let b = to?.coordinate, let model else { return }
        guard let meta = store.graph(covering: a, b) else {
            Task {
                await model.alpr.loadCatalog()
                guard let cat = model.alpr.catalog else {
                    state = .needsData(nil, reason: "GRID needs road data for this area. Enable map data to download it."); return
                }
                let ra = RoutingStore.region(containing: a, in: cat), rb = RoutingStore.region(containing: b, in: cat)
                if let ra, let rb, ra.id != rb.id, store.installed.contains(where: { $0.id == ra.storageKey }) {
                    state = .needsData(rb, reason: "This trip leaves the area your road data covers. Routes between regions aren't supported yet.")
                } else if let r = (store.installed.contains { $0.id == ra?.storageKey }) ? rb : ra {
                    state = .needsData(r, reason: "Routing needs road data for \(r.name), downloaded once and kept on this Mac.")
                } else {
                    state = .needsData(nil, reason: "No downloadable road data covers this point.")
                }
            }
            return
        }
        state = .working
        let span = max(abs(a.lon - b.lon), abs(a.lat - b.lat))
        let pad = max(0.05, span * 0.5)
        let box = BBox(west: max(-180, min(a.lon, b.lon) - pad), south: max(-85, min(a.lat, b.lat) - pad),
                       east: min(180, max(a.lon, b.lon) + pad), north: min(85, max(a.lat, b.lat) + pad))
        let cams = model.alpr.index.query(box).prefix(20_000).map { ($0, model.alpr.index.cameras[$0]) }
        let avoid = avoid, opts = options
        let service = service
        job = Task { [weak self] in
            do {
                try await service.load(meta)
                let o = try await service.route(from: a, to: b, cameras: cams, avoid: avoid, options: opts)
                guard !Task.isCancelled, let self else { return }
                self.outcome = o
                self.shown = o.avoiding != nil ? .avoiding : .fastest
                self.state = .done
                self.refreshCameras()
                self.model?.routeChanged(fit: true)
            } catch {
                guard !Task.isCancelled, let self else { return }
                switch error as? RouteService.Failure {
                case .farFromRoad(let start)?: self.state = .failed("The \(start ? "start" : "destination") is more than 1.5 km from a road GRID can drive on.")
                case .noRoute?: self.state = .failed("No drivable route connects these two points in \(meta.name)'s road data.")
                case .noGraph?: self.state = .failed("\(meta.name)'s road data couldn't be loaded. Remove it in Settings › Map and download it again.")
                case nil: self.state = .failed("\(meta.name)'s road data is damaged (\(error)). Remove it in Settings › Map and download it again.")
                }
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

    /// Downloads the road data a route needs (asks first, with the size).
    func requestData(_ region: RegionDescriptor) {
        guard let model, let app = model.app, let cat = model.alpr.catalog else { return }
        guard let url = cat.extractURL(region.id) else {
            state = .failed("Geofabrik lists no road data download for \(region.name)."); return
        }
        Task {
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
        if let (p, _) = model.location.fix { setEnd(from: isFrom, End(name: "My location", coordinate: p)); return }
        model.locate()
        Task {
            for _ in 0..<600 {
                if let (p, _) = model.location.fix { setEnd(from: isFrom, End(name: "My location", coordinate: p)); return }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    func clearAllData() {
        clear()
        Task { await service.unload() }
        store.clearAll()
    }
}
