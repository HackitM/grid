import AppKit
import GridCore
import Observation
import SwiftUI

/// The Map page's state: camera, layers, selection, the tile and camera stores and location.
/// Created the first time the Map page opens (nothing here runs before that).
@Observable
@MainActor
final class MapModel {
    let tiles = TileStore()
    let alpr = ALPRStore()
    let terrain = TerrainStore()
    let location = LocationProvider()
    @ObservationIgnored weak var app: AppState?

    /// The camera, always current: gestures land here at once. While a gesture runs, views that
    /// read it are told about ten times a second (the map view draws gestures from its own copy
    /// at full frame rate, and the frame is rebuilt only when what it draws changes).
    var camera: MapCamera {
        get { access(keyPath: \.camera); return cameraStore }
        set { withMutation(keyPath: \.camera) { cameraStore = newValue } }
    }
    @ObservationIgnored private var cameraStore: MapCamera
    private(set) var viewport = SIMD2<Double>(1000, 700)

    // Layers and options
    var showCameras: Bool { didSet { d.set(showCameras, forKey: "map.layer.alpr"); refresh() } }
    var showRegions: Bool { didSet { d.set(showRegions, forKey: "map.layer.regions"); refresh() } }
    var showBuildings: Bool { didSet { d.set(showBuildings, forKey: "map.layer.buildings"); refresh() } }
    var showGrid: Bool { didSet { d.set(showGrid, forKey: "map.layer.grid"); refresh() } }
    /// Elevation: shaded relief, contour lines, and 3D terrain when tilted.
    var showTerrain: Bool { didSet { d.set(showTerrain, forKey: "map.layer.terrain"); terrain.enabled = enabledStore && showTerrain; refresh() } }
    /// Vertical exaggeration of the 3D terrain (1 = true scale).
    var terrainExaggeration: Double { didSet { d.set(terrainExaggeration, forKey: "map.terrain.exaggeration"); frameRevision &+= 1 } }

    /// ⇧-drag draws a download rectangle while on.
    var drawingRegion = false
    private(set) var draftRect: (Mercator, Mercator)?
    private(set) var selected: Int?
    private(set) var reveal: Float = 1
    private(set) var frameRevision = 0
    /// Error or progress line for the page (downloads, catalogue).
    var notice: String?

    @ObservationIgnored private let d = UserDefaults.standard
    @ObservationIgnored private var revealTask: Task<Void, Never>?
    @ObservationIgnored private var lastCover: Set<TileID> = []
    /// The cover, nearest first.
    @ObservationIgnored private var coverList: [TileID] = []
    /// What the frame draws besides tiles that depends on the camera; a gesture rebuilds the frame
    /// only when this (or the cover) changes.
    private struct ContentKey: Equatable { var cover: Set<TileID>; var ring: Set<TileID>; var globe: Bool; var markerLevel: Int }
    /// Prefetched tiles around the view that the frame carries too (drawn the moment they scroll
    /// in, without waiting for the next frame): same level as the cover or coarser.
    @ObservationIgnored private var ringList: [TileID] = []
    @ObservationIgnored private var contentKey: ContentKey?
    /// Geographic box of the cover: markers are collected for all of it, so panning inside it
    /// needs no new frame.
    @ObservationIgnored private var markerBox: BBox?
    @ObservationIgnored private var tileObserver: Task<Void, Never>?

    /// "Enable map data" (MAP-NET consent): nothing is fetched before it.
    var enabled: Bool {
        get { access(keyPath: \.enabledStore); return enabledStore }
        set { withMutation(keyPath: \.enabledStore) { enabledStore = newValue }; d.set(newValue, forKey: "map.enabled"); onEnabledChange() }
    }
    @ObservationIgnored private var enabledStore: Bool

    init() {
        d.register(defaults: ["map.layer.alpr": true, "map.layer.regions": true, "map.layer.buildings": true, "map.layer.grid": true,
                              "map.layer.terrain": true, "map.terrain.exaggeration": 1.5,
                              "map.enabled": false, "map.rememberView": false])
        showCameras = d.bool(forKey: "map.layer.alpr")
        showRegions = d.bool(forKey: "map.layer.regions")
        showBuildings = d.bool(forKey: "map.layer.buildings")
        showGrid = d.bool(forKey: "map.layer.grid")
        showTerrain = d.bool(forKey: "map.layer.terrain")
        terrainExaggeration = min(3, max(1, d.double(forKey: "map.terrain.exaggeration")))
        enabledStore = d.bool(forKey: "map.enabled")
        // Start over the continental US (or the remembered view, if that setting is on).
        if d.bool(forKey: "map.rememberView"), let data = d.data(forKey: "map.lastView"),
           let cam = try? JSONDecoder().decode(MapCamera.self, from: data) {
            cameraStore = cam
        } else {
            // Open on the globe, facing North America.
            cameraStore = MapCamera(center: TileMath.project(LonLat(lon: -96, lat: 36)), zoom: 2.3)
        }
        tiles.enabled = enabledStore
        alpr.enabled = enabledStore
        terrain.enabled = enabledStore && showTerrain
    }

    /// Set once Locate has centred the map this session: the remembered view must never hold the
    /// user's position.
    @ObservationIgnored private var located = false

    var rememberView: Bool {
        get { d.bool(forKey: "map.rememberView") }
        set { d.set(newValue, forKey: "map.rememberView"); if !newValue { d.removeObject(forKey: "map.lastView") } }
    }

    func appeared() {
        if enabled {
            // The scan-in plays once per page open (and when the tile source changes), not on
            // every pan or zoom step.
            Task {
                let gen = tiles.generation
                await tiles.loadSource()
                if app?.settings.effects.motion == true && (lastCover.isEmpty || gen != tiles.generation || !revealedThisVisit) { startReveal() }
                revealedThisVisit = true
                refresh()
            }
            Task { await alpr.checkFreshness(manual: false) }
        }
        refresh()
    }

    @ObservationIgnored private var revealedThisVisit = false

    func disappeared() {
        revealedThisVisit = false
        location.clear()
        if rememberView, !located, let data = try? JSONEncoder().encode(camera) { d.set(data, forKey: "map.lastView") }
    }

    private func onEnabledChange() {
        tiles.enabled = enabledStore
        alpr.enabled = enabledStore
        terrain.enabled = enabledStore && showTerrain
        if !enabledStore { alpr.cancel() }
        if enabledStore { Task { await tiles.loadSource(); refresh() } }
    }

    // MARK: Frame

    /// Recomputes the wanted tiles and bumps the frame (call after camera, viewport or data changes).
    func refresh() {
        plan()
        frameRevision &+= 1
    }

    /// Asks the stores for the tiles of the current camera: the view, a low-zoom backdrop under
    /// it, and the tiles around it and ahead of the gesture in progress. True when what the frame
    /// draws changed.
    @discardableResult
    private func plan() -> Bool {
        let cam = cameraStore
        lastPlanTime = CACurrentMediaTime()
        #if DEBUG
        defer { MapDebugTimes.add("plan", since: lastPlanTime) }
        #endif
        let maxZoom = tiles.source?.maxZoom ?? 14
        let cover = TileMath.cover(cam, viewport: viewport, maxZoom: maxZoom, limit: 48)
        let coverSet = Set(cover)

        // Backdrop: the cover's ancestors two and four levels up. A handful of tiles that span
        // many screens, so ground that scrolls or zooms into view is never empty.
        var backdrop: [TileID] = []
        var seen = Set<TileID>()
        let top = Int(cover.map(\.z).max() ?? 0)
        for level in [top - 2, top - 4] where level >= 0 {
            for t in cover where Int(t.z) > level {
                let shift = Int(t.z) - level
                let a = TileID(z: level, x: Int(t.x) >> shift, y: Int(t.y) >> shift)
                if seen.insert(a).inserted { backdrop.append(a) }
            }
        }

        // Prefetch: a ring around the view at rest; where the gesture is heading while it moves.
        var prefetch: [TileID] = []
        func add(_ c: MapCamera, pad: Double, limit: Int) {
            for t in TileMath.cover(c, viewport: viewport * pad, maxZoom: maxZoom, limit: limit)
            where !coverSet.contains(t) && seen.insert(t).inserted { prefetch.append(t) }
        }
        if let v = gestureVelocity() {
            for dt in [0.3, 0.6] { add(Self.advance(cam, by: v, seconds: dt, viewport: viewport), pad: 1.15, limit: 56) }
        } else {
            add(cam, pad: 1.35, limit: 80)
        }
        if prefetch.count > 48 { prefetch.removeSubrange(48...) }

        // Deeper tiles ahead of a zoom-in are loaded but not drawn until the view reaches their level.
        let ring = prefetch.filter { Int($0.z) <= top }
        let ahead = prefetch.filter { Int($0.z) > top }
        lastCover = coverSet
        coverList = cover
        ringList = ring
        tiles.want(cover, ring: ring, backdrop: backdrop, prefetch: ahead)
        if showTerrain && !cam.isGlobe { terrain.want(cover + backdrop, ahead: prefetch) }

        let key = ContentKey(cover: coverSet, ring: Set(ring), globe: cam.isGlobe, markerLevel: cam.zoom >= 12 ? -1 : Int((cam.zoom * 4).rounded(.down)))
        guard key != contentKey else { return false }
        contentKey = key
        markerBox = Self.box(of: cover)
        return true
    }

    private static func box(of tiles: [TileID]) -> BBox? {
        guard !tiles.isEmpty else { return nil }
        var w = 180.0, s = 90.0, e = -180.0, n = -90.0
        for t in tiles {
            let b = TileMath.geoBounds(t)
            w = min(w, b.west); s = min(s, b.south); e = max(e, b.east); n = max(n, b.north)
        }
        return BBox(west: max(-180, w), south: max(-85.06, s), east: min(180, e), north: min(85.06, n))
    }

    /// Terrain draws on the flat map only (not on the globe or mid-morph).
    var terrainActive: Bool { enabled && showTerrain && !cameraStore.isGlobe }

    /// What the last frame was built from.
    private struct FrameKey: Equatable {
        var tiles, alpr, frame, terrain, generation: Int
        var palette: MapPalette
        var glow, enabled: Bool
        var location: LocationMarker?
        var regions: [String]
    }
    @ObservationIgnored private var frameKey: FrameKey?
    @ObservationIgnored private var frameStamp = 0

    /// The frame for the map view. Rebuilt only when its inputs change (an unrelated SwiftUI
    /// update gets the same frame back); the camera in it is the current one.
    func frame(palette: MapPalette, glow: Bool) -> MapFrame {
        let fix = location.fix.map { LocationMarker(world: TileMath.project($0.0), accuracyMeters: $0.1) }
        let key = FrameKey(tiles: tiles.revision, alpr: alpr.revision, frame: frameRevision, terrain: terrain.revision,
                           generation: tiles.generation, palette: palette, glow: glow, enabled: enabled, location: fix,
                           regions: showRegions ? alpr.regions.map { "\($0.id)#\($0.meta.cameraCount)" } : [])
        if key == frameKey, let f = lastFrame { return f }
        frameKey = key
        #if DEBUG
        let t0 = CACurrentMediaTime()
        defer { MapDebugTimes.add("frame", since: t0) }
        #endif
        let camera = cameraStore
        let terrainOn = terrainActive
        var geometry = key.enabled ? tiles.geometry(for: coverList + ringList) : []
        var grids: [TerrainGrid] = []
        if terrainOn {
            // Contours join their tile's geometry (a new revision tells the renderer to re-upload it).
            for k in geometry.indices {
                guard let t = terrain.terrain(for: geometry[k].id) else { continue }
                grids.append(t.grid)
                guard !t.contours.isEmpty || !t.labels.isEmpty else { continue }
                geometry[k].lines = t.contours + geometry[k].lines
                geometry[k].labels += t.labels
                geometry[k].revision = 2
            }
        }
        var f = MapFrame(camera: camera, tileGeneration: tiles.generation, tiles: geometry,
                         palette: palette, glow: glow, buildings: showBuildings, reveal: reveal, gridFloor: showGrid)
        frameStamp &+= 1
        f.stamp = frameStamp
        f.terrain = grids
        f.exaggeration = terrainOn ? terrainExaggeration : 0
        f.hillshade = terrainOn
        f.terrainFloor = max(0, grids.map(\.minHeight).min() ?? 0)
        if showCameras, let box = markerBox {
            if camera.zoom >= 12 {
                for i in alpr.index.query(box).prefix(4000) {
                    let c = alpr.index.cameras[i]
                    f.cameras.append(CameraMarker(world: TileMath.project(c.coordinate), directions: c.directions,
                                                  isFlock: c.vendor == .flock, selected: i == selected, index: i))
                }
            } else {
                let cell = 44 / (256 * pow(2, camera.zoom))
                for c in alpr.index.clusters(box, cellWorld: cell).prefix(3000) {
                    f.clusters.append(ClusterMarker(world: TileMath.project(c.center), count: c.count))
                }
            }
        }
        f.location = fix
        if showRegions {
            for r in alpr.regions {
                f.regions.append(RegionOutline(rings: r.meta.polygon.polygons.compactMap { $0.first?.map(TileMath.project) }, highlighted: false))
            }
        }
        if let (a, b) = draftRect {
            f.regions.append(RegionOutline(rings: [[a, Mercator(x: b.x, y: a.y), b, Mercator(x: a.x, y: b.y)]], highlighted: true))
        }
        lastFrame = f
        return f
    }

    /// Geographic box of the ground in view (nil when it can't be computed).
    func visibleBBox() -> BBox? {
        if camera.isGlobe {
            // The facing hemisphere, roughly (the renderer hides anything on the far side).
            let c = TileMath.unproject(camera.center)
            return BBox(west: max(-180, c.lon - 95), south: max(-85, c.lat - 90), east: min(180, c.lon + 95), north: min(85, c.lat + 90))
        }
        let proj = MapProjection(camera: camera, viewport: viewport)
        var pts: [LonLat] = []
        for sx in [0.0, 0.5, 1.0] { for sy in [0.0, 1.0] {
            if let g = proj.groundPoint(screen: SIMD2(sx * viewport.x, sy * viewport.y)) {
                pts.append(TileMath.unproject(Mercator(x: min(max(g.x, 0), 1), y: min(max(g.y, 0), 1))))
            }
        } }
        guard !pts.isEmpty else { return nil }
        return BBox(west: pts.map(\.lon).min()!, south: pts.map(\.lat).min()!, east: pts.map(\.lon).max()!, north: pts.map(\.lat).max()!)
    }

    var selectedCamera: ALPRCamera? {
        guard let s = selected, alpr.index.cameras.indices.contains(s) else { return nil }
        return alpr.index.cameras[s]
    }

    func select(_ i: Int?) { selected = i; frameRevision &+= 1 }

    func camerasInViewCount() -> Int { visibleBBox().map { alpr.index.query($0).count } ?? 0 }

    /// Cameras in view, nearest to the centre first (the accessible list).
    func camerasInView(limit: Int = 200) -> [(Int, ALPRCamera, Double)] {
        guard let box = visibleBBox() else { return [] }
        let c = TileMath.unproject(camera.center)
        return alpr.index.query(box).map { i -> (Int, ALPRCamera, Double) in
            let cam = alpr.index.cameras[i]
            return (i, cam, Self.distance(c, cam.coordinate))
        }.sorted { $0.2 < $1.2 }.prefix(limit).map { $0 }
    }

    static func distance(_ a: LonLat, _ b: LonLat) -> Double {
        let r = 6_371_000.0, p1 = a.lat * .pi / 180, p2 = b.lat * .pi / 180
        let dp = (b.lat - a.lat) * .pi / 180, dl = (b.lon - a.lon) * .pi / 180
        let h = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }

    private func startReveal() {
        revealTask?.cancel()
        reveal = 0
        revealTask = Task { @MainActor in
            let start = Date()
            while !Task.isCancelled {
                let t = Float(Date().timeIntervalSince(start) / 0.45)
                reveal = min(1, t)
                frameRevision &+= 1
                if t >= 1 { break }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    // MARK: Input

    func setViewport(_ v: SIMD2<Double>) {
        guard v != viewport, v.x > 10, v.y > 10 else { return }
        viewport = v
        refresh()
    }

    // Gestures. The camera changes at once; the tile plan follows at ≤ 30 Hz with a last pass
    // once the gesture has stopped (which swaps the look-ahead for the ring around the view).
    @ObservationIgnored private var lastPlanTime: CFTimeInterval = 0
    @ObservationIgnored private var planScheduled = false
    @ObservationIgnored private var notifyScheduled = false
    @ObservationIgnored private var settleScheduled = false
    @ObservationIgnored private var lastGestureTime: CFTimeInterval = 0
    /// Cameras of the last ~0.2 s of gestures (oldest first), for the velocity.
    @ObservationIgnored private var trail: [(at: CFTimeInterval, camera: MapCamera)] = []

    private static let planInterval = 1.0 / 30

    private func gestured(_ c: MapCamera) {
        guard c != cameraStore else { return }
        cameraStore = c
        let now = CACurrentMediaTime()
        lastGestureTime = now
        trail.append((now, c))
        if let i = trail.firstIndex(where: { now - $0.at <= 0.2 }), i > 0 { trail.removeFirst(i) }
        if now - lastPlanTime >= Self.planInterval {
            gesturePlan()
        } else if !planScheduled {
            planScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.planInterval - (now - lastPlanTime)) { [weak self] in
                self?.planScheduled = false
                self?.gesturePlan()
            }
        }
        if !notifyScheduled {
            notifyScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self else { return }
                self.notifyScheduled = false
                self.withMutation(keyPath: \.camera) {}
            }
        }
        scheduleSettle()
    }

    private func gesturePlan() {
        if plan() { frameRevision &+= 1 }
    }

    private func scheduleSettle() {
        guard !settleScheduled else { return }
        settleScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            self.settleScheduled = false
            if CACurrentMediaTime() - self.lastGestureTime >= 0.18 {
                self.trail.removeAll(keepingCapacity: true)
                self.gesturePlan()
            } else {
                self.scheduleSettle()
            }
        }
    }

    /// Camera change per second over the last moments of a gesture; nil at rest.
    private func gestureVelocity() -> (center: SIMD2<Double>, zoom: Double, bearing: Double, pitch: Double)? {
        guard let a = trail.first, let b = trail.last, CACurrentMediaTime() - b.at < 0.12, b.at - a.at >= 0.03 else { return nil }
        let dt = b.at - a.at
        var db = b.camera.bearing - a.camera.bearing
        if db > 180 { db -= 360 } else if db < -180 { db += 360 }
        return (SIMD2(b.camera.center.x - a.camera.center.x, b.camera.center.y - a.camera.center.y) / dt,
                (b.camera.zoom - a.camera.zoom) / dt, db / dt, (b.camera.pitch - a.camera.pitch) / dt)
    }

    /// Where the camera will be in `seconds` at this velocity (no further than about a screen and
    /// a half, one zoom level or a sixth of a turn).
    private static func advance(_ cam: MapCamera, by v: (center: SIMD2<Double>, zoom: Double, bearing: Double, pitch: Double),
                                seconds: Double, viewport: SIMD2<Double>) -> MapCamera {
        var c = cam
        var d = v.center * seconds
        let reach = 1.5 * max(viewport.x, viewport.y) / (256 * pow(2, cam.zoom))
        let len = (d.x * d.x + d.y * d.y).squareRoot()
        if len > reach { d *= reach / len }
        c.center = Mercator(x: cam.center.x + d.x, y: cam.center.y + d.y)
        c.zoom += min(1, max(-1, v.zoom * seconds))
        c.bearing += min(60, max(-60, v.bearing * seconds))
        c.pitch += min(20, max(-20, v.pitch * seconds))
        return MapGestureMath.clamp(c)
    }

    func handle(_ g: MapGesture) {
        // Pan, zoom and rotate go through MapGestureMath, exactly as the map view applies them.
        let cam = cameraStore
        let mid = viewport / 2
        switch g {
        case .pan(let delta):
            gestured(MapGestureMath.pan(cam, by: delta, viewport: viewport))
        case .zoom(let dz, let p):
            gestured(MapGestureMath.zoom(cam, by: dz, around: p, viewport: viewport))
        case .rotate(let db, let dp):
            gestured(MapGestureMath.rotate(cam, bearing: db, pitch: dp))
        case .click(let p):
            click(p, mapProjection(camera: camera, viewport: viewport))
        case .rectangle(let a, let b, let ended):
            let pr = mapProjection(camera: camera, viewport: viewport)
            guard drawingRegion, let ga = pr.groundPoint(screen: a), let gb = pr.groundPoint(screen: b) else { return }
            draftRect = (Mercator(x: min(ga.x, gb.x), y: min(ga.y, gb.y)), Mercator(x: max(ga.x, gb.x), y: max(ga.y, gb.y)))
            frameRevision &+= 1
            if ended { finishRectangle() }
        case .contextMenu(let p, let screen):
            showContextMenu(at: p, screen: screen)
        case .key(let k):
            switch k {
            case .left: handle(.pan(SIMD2(120, 0)))
            case .right: handle(.pan(SIMD2(-120, 0)))
            case .up: handle(.pan(SIMD2(0, 120)))
            case .down: handle(.pan(SIMD2(0, -120)))
            case .zoomIn: handle(.zoom(1, around: mid))
            case .zoomOut: handle(.zoom(-1, around: mid))
            case .resetNorth: var c = camera; c.bearing = 0; c.pitch = 0; setCamera(c)
            }
        }
    }

    /// Clamped to the world (no antimeridian wrap in v1), exactly as the map view clamps its own
    /// camera, so both stay identical during gestures.
    static func wrap(_ c: Mercator) -> Mercator {
        Mercator(x: min(1, max(0, c.x)), y: min(1, max(0, c.y)))
    }

    /// The last frame built (its terrain lift places markers for hit-testing).
    @ObservationIgnored private var lastFrame: MapFrame?

    /// The last frame with the terrain lift of the current camera (what is on screen).
    private var drawnFrame: MapFrame? {
        guard var f = lastFrame else { return nil }
        f.lift = f.lift(for: cameraStore, viewport: viewport)
        return f
    }

    /// Screen point of a world point on the drawn terrain.
    private func screenOnTerrain(_ w: Mercator, _ proj: any MapScreenProjection, _ f: MapFrame?) -> SIMD2<Double>? {
        proj.screen(w, heightMeters: f?.elevation(at: w) ?? 0)
    }

    /// The world point under a screen point on the drawn terrain: the ground-plane hit, refined a
    /// few times by the lift's screen offset there.
    private func pick(_ p: SIMD2<Double>, _ proj: any MapScreenProjection) -> Mercator? {
        guard var g = proj.groundPoint(screen: p) else { return nil }
        guard let f = drawnFrame, !f.lift.isFlat else { return g }
        for _ in 0..<4 {
            guard let lifted = proj.screen(g, heightMeters: f.elevation(at: g)), let flat = proj.screen(g),
                  let next = proj.groundPoint(screen: p - (lifted - flat)) else { break }
            g = next
        }
        return g
    }

    private func click(_ p: SIMD2<Double>, _ proj: any MapScreenProjection) {
        if camera.zoom < 12 {
            // A cluster: zoom in on it.
            // The same box and cell as the frame's clusters, so a click finds what is drawn.
            if let box = markerBox ?? visibleBBox() {
                let cell = 44 / (256 * pow(2, lastFrame?.camera.zoom ?? camera.zoom))
                let drawn = drawnFrame
                let hit = alpr.index.clusters(box, cellWorld: cell).compactMap { c -> (CameraCluster, Double)? in
                    guard let s = screenOnTerrain(TileMath.project(c.center), proj, drawn) else { return nil }
                    let dist = hypot(s.x - p.x, s.y - p.y)
                    return dist < 18 ? (c, dist) : nil
                }.min { $0.1 < $1.1 }
                if let (c, _) = hit {
                    if c.count == 1 { select(c.representative) }
                    else { handle(.zoom(min(3, 12.2 - camera.zoom), around: proj.screen(TileMath.project(c.center)) ?? p)) }
                    return
                }
            }
            select(nil)
            return
        }
        guard let ground = pick(p, proj) else { select(nil); return }
        let maxWorld = 12 / proj.worldScale
        select(alpr.index.nearest(to: TileMath.unproject(ground), maxWorldDistance: maxWorld))
    }

    // MARK: Right-click menu

    private func showContextMenu(at p: SIMD2<Double>, screen: SIMD2<Double>) {
        let proj = mapProjection(camera: camera, viewport: viewport)
        guard let ground = pick(p, proj) else { return }
        let ll = TileMath.unproject(ground)
        let coords = String(format: "%.5f, %.5f", ll.lat, ll.lon)
        let title = String(format: "%.4f %@ · %.4f %@", abs(ll.lat), ll.lat >= 0 ? "N" : "S", abs(ll.lon), ll.lon >= 0 ? "E" : "W")
        let camIndex = camera.zoom >= 12 ? alpr.index.nearest(to: ll, maxWorldDistance: 12 / proj.worldScale) : nil
        let z = Int(camera.zoom.rounded())
        var items: [GridMenuItem] = []
        if let i = camIndex {
            items.append(.action("Inspect Camera") { [weak self] in self?.select(i); self?.app?.inspectorVisible = true })
            items.append(.divider)
        }
        items.append(.action("Centre Map Here") { [weak self] in self?.flyTo(ll) })
        items.append(.action("Copy Coordinates") { [weak self] in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(coords, forType: .string)
            self?.app?.flash(.info, "Copied \(coords)")
        })
        items.append(.divider)
        items.append(.action("Open in Apple Maps") {
            if let u = URL(string: String(format: "https://maps.apple.com/?ll=%.6f,%.6f&z=%d", ll.lat, ll.lon, max(3, z))) { NSWorkspace.shared.open(u) }
        })
        items.append(.action("View on OpenStreetMap") { [weak self] in
            self?.app?.openURL(String(format: "https://www.openstreetmap.org/#map=%d/%.5f/%.5f", max(3, min(19, z)), ll.lat, ll.lon))
        })
        items.append(.divider)
        items.append(.action("Download Cameras for This View", enabled: enabled && !camera.isGlobe && !alpr.busy) { [weak self] in
            guard let self, let box = self.visibleBBox(), box.isValid else { return }
            let key = String(format: "rect-%.3f_%.3f_%.3f_%.3f", box.west, box.south, box.east, box.north)
            let name = String(format: "Area %.2f°, %.2f°", (box.north + box.south) / 2, (box.east + box.west) / 2)
            self.requestDownload(RegionDescriptor(id: key, name: name, parent: nil, iso3166_1: [], iso3166_2: []),
                                 polygon: .rectangle(box), isRectangle: true)
        })
        GridMenu.shared.show(items, title: title, anchor: .point(NSPoint(x: screen.x, y: screen.y)), window: NSApp.keyWindow ?? NSApp.mainWindow)
    }

    func flyTo(_ p: LonLat, zoom: Double? = nil) {
        var c = camera
        c.center = TileMath.project(p)
        if let zoom { c.zoom = zoom }
        setCamera(c)
    }

    /// Every programmatic camera change (fly to, reset, tilt toggle, QA): drops a pending
    /// gesture update so it can't overwrite this one.
    func setCamera(_ c: MapCamera) {
        trail.removeAll(keepingCapacity: true)
        var c = c
        c.center = Self.wrap(c.center)
        c.pitch = min(MapCamera.maxPitch, max(0, c.pitch))
        c.zoom = min(MapCamera.maxZoom, max(MapCamera.minZoom, c.zoom))
        camera = c
        refresh()
    }

    func locate() {
        location.locate()
        observeLocation()
    }

    private func observeLocation() {
        Task { @MainActor in
            for _ in 0..<600 {          // up to 60 s
                if let (p, _) = location.fix {
                    located = true
                    d.removeObject(forKey: "map.lastView")
                    flyTo(p, zoom: max(camera.zoom, 14)); return
                }
                switch location.state {
                case .locating, .asking, .explaining: break
                default: return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    // MARK: Regions

    private func finishRectangle() {
        guard let (a, b) = draftRect else { return }
        let nw = TileMath.unproject(a), se = TileMath.unproject(b)
        let box = BBox(west: max(-180, nw.lon), south: max(-85, se.lat), east: min(180, se.lon), north: min(85, nw.lat))
        drawingRegion = false
        guard box.isValid, box.east - box.west > 0.001, box.north - box.south > 0.001 else { draftRect = nil; return }
        let key = String(format: "rect-%.3f_%.3f_%.3f_%.3f", box.west, box.south, box.east, box.north)
        let name = String(format: "Area %.2f°, %.2f°", (box.north + box.south) / 2, (box.east + box.west) / 2)
        let d = RegionDescriptor(id: key, name: name, parent: nil, iso3166_1: [], iso3166_2: [])
        requestDownload(d, polygon: GeoPolygon.rectangle(box), isRectangle: true) { [weak self] in self?.draftRect = nil; self?.frameRevision &+= 1 }
    }

    func requestDownload(_ d: RegionDescriptor, polygon: GeoPolygon, isRectangle: Bool, done: (() -> Void)? = nil) {
        guard enabled, let app else { done?(); return }
        notice = "Planning the download for \(d.name)…"
        Task {
            do {
                let plan = try await alpr.plan(d, polygon: polygon, isRectangle: isRectangle)
                notice = nil
                guard plan.requests > 0 else {
                    app.flash(.info, "No mapped cameras in \(d.name)")
                    done?(); return
                }
                let estKB = max(1, plan.estimatedCameras * 60 / 1024 + plan.overpassChunks.count * 40)
                var msg = "\(plan.requests) request\(plan.requests == 1 ? "" : "s") to \(plan.hosts.joined(separator: " and "))"
                if plan.estimatedCameras > 0 { msg += ", about \(plan.estimatedCameras.formatted()) cameras (≈ \(estKB.formatted()) KB)" }
                msg += ". That host learns which area you downloaded. The cameras are stored on this Mac and shown offline; update or remove them in the Regions list."
                if !plan.overpassChunks.isEmpty { msg += " Overpass requests go one at a time and may take a few minutes." }
                app.present(Confirmation(code: "ALPR-NET", title: "Download cameras for \(d.name)?", message: msg,
                                         confirmLabel: "Download", destructive: false,
                                         onConfirm: { [weak self] in
                                             self?.alpr.start(plan) { done?(); self?.refresh() }
                                         },
                                         onCancel: { done?() }))
            } catch {
                notice = "Couldn't plan the download: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
                done?()
            }
        }
    }

    func clearAllData() {
        alpr.clearAll()
        try? MapStorage.remove(MapStorage.tiles)
        try? MapStorage.remove(MapStorage.terrain)
        terrain.clear()
        tiles.clearMemory()
        select(nil)
        Task { await tiles.loadSource(); refresh() }
    }
}
