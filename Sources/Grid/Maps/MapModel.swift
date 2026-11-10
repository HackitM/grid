import AppKit
import GridCore
import Observation
import SwiftUI

/// The Map page's state: camera, layers, selection, the tile and camera stores and location.
/// Created the first time the Map page opens (nothing here runs before that).
///
/// The class is split by concern:
/// - `MapModel.swift`: state, page lifecycle, layers, selection, camera regions.
/// - `MapModel+TilePlan.swift`: which tiles the view needs (cover, backdrop, prefetch).
/// - `MapModel+Frame.swift`: the `MapFrame` handed to the renderer, and its caches.
/// - `MapModel+Gestures.swift`: pan / zoom / rotate, programmatic camera moves.
/// - `MapModel+Picking.swift`: clicks, the right-click menu, what is in view.
@Observable
@MainActor
final class MapModel {
    let tiles = TileStore()
    let alpr = ALPRStore()
    let terrain = TerrainStore()
    let location = LocationProvider()
    let search = MapSearch()
    let routing = MapRouting()
    /// The cameras in view (count and nearest list), worked out off the main thread.
    let inView = CamerasInView()
    @ObservationIgnored weak var app: AppState?

    // MARK: Camera and viewport

    /// The camera, always current: gestures land here at once. While a gesture runs, views that
    /// read it are told about ten times a second (the map view draws gestures from its own copy
    /// at full frame rate, and the frame is rebuilt only when what it draws changes).
    var camera: MapCamera {
        get { access(keyPath: \.camera); return liveCamera }
        set { withMutation(keyPath: \.camera) { liveCamera = newValue } }
    }
    /// The camera without observation: what gestures write and the tile plan and frame read, so
    /// neither registers (nor triggers) a SwiftUI dependency sixty times a second.
    @ObservationIgnored var liveCamera: MapCamera
    private(set) var viewport = SIMD2<Double>(1000, 700)

    // MARK: Layers and options

    var showCameras: Bool { didSet { defaults.set(showCameras, forKey: Key.cameras); refresh() } }
    var showRegions: Bool { didSet { defaults.set(showRegions, forKey: Key.regions); refresh() } }
    var showBuildings: Bool { didSet { defaults.set(showBuildings, forKey: Key.buildings); refresh() } }
    var showGrid: Bool { didSet { defaults.set(showGrid, forKey: Key.grid); refresh() } }
    /// Elevation: shaded relief, contour lines, and 3D terrain when tilted.
    var showTerrain: Bool {
        didSet {
            defaults.set(showTerrain, forKey: Key.terrain)
            terrain.enabled = enabledStore && showTerrain
            refresh()
        }
    }
    /// Points of interest (shops, stops, sights…) from the map tiles, as glyphs.
    var showPlaces: Bool { didSet { defaults.set(showPlaces, forKey: Key.places); refresh() } }
    /// Place categories switched off with the chips under the Places layer.
    var hiddenCategories: Set<POICategory> {
        didSet {
            defaults.set(hiddenCategories.map { Int($0.rawValue) }.sorted(), forKey: Key.hiddenPlaces)
            refresh()
        }
    }
    /// Vertical exaggeration of the 3D terrain (1 = true scale).
    var terrainExaggeration: Double {
        didSet { defaults.set(terrainExaggeration, forKey: Key.exaggeration); invalidateFrame() }
    }

    /// Bits of the place categories drawn (0 when the Places layer is off).
    var poiMask: UInt16 {
        guard showPlaces else { return 0 }
        var mask: UInt16 = 0
        for c in POICategory.allCases where !hiddenCategories.contains(c) { mask |= 1 << UInt16(c.rawValue) }
        return mask
    }

    /// Terrain draws on the flat map only (not on the globe or mid-morph).
    var terrainActive: Bool { enabled && showTerrain && !liveCamera.isGlobe }

    // MARK: Selection and page state

    /// ⇧-drag draws a download rectangle while on.
    var drawingRegion = false
    private(set) var draftRect: (Mercator, Mercator)?
    /// The selected camera's index in `alpr.index`.
    private(set) var selected: Int?
    /// The chosen place: a search result or a clicked point of interest.
    private(set) var place: PlaceResult?
    private(set) var reveal: Float = 1
    /// Bumped whenever the frame must be rebuilt for a reason its other inputs don't show.
    private(set) var frameRevision = 0
    /// Error or progress line for the page (downloads, catalogue).
    var notice: String?

    // MARK: Internal state of the extensions (not observed)

    /// The tiles asked for by the last plan (see `MapModel+TilePlan.swift`).
    @ObservationIgnored var tilePlan = TilePlan()
    /// Gesture pacing and velocity (see `MapModel+Gestures.swift`).
    @ObservationIgnored var gesture = GestureState()
    /// The last frame built and the pieces of it that outlive one build (see `MapModel+Frame.swift`).
    @ObservationIgnored var frameCache = FrameCache()
    /// Camera markers and clusters for the planned area (see `MapModel+Frame.swift`).
    @ObservationIgnored var markers = MarkerCache()

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var revealTask: Task<Void, Never>?
    @ObservationIgnored private var locateTask: Task<Void, Never>?
    @ObservationIgnored private var revealedThisVisit = false
    /// The selected camera's OSM id, to find it again when the index is rebuilt.
    @ObservationIgnored private var selectedID: OSMElementID?
    /// Set once Locate has centred the map this session: the remembered view must never hold the
    /// user's position.
    @ObservationIgnored private var located = false

    private enum Key {
        static let cameras = "map.layer.alpr", regions = "map.layer.regions", buildings = "map.layer.buildings"
        static let grid = "map.layer.grid", terrain = "map.layer.terrain", places = "map.layer.places"
        static let hiddenPlaces = "map.places.hidden", exaggeration = "map.terrain.exaggeration"
        static let enabled = "map.enabled", rememberView = "map.rememberView", lastView = "map.lastView"
    }

    // MARK: Consent

    /// "Enable map data" (MAP-NET consent): nothing is fetched before it.
    var enabled: Bool {
        get { access(keyPath: \.enabledStore); return enabledStore }
        set {
            withMutation(keyPath: \.enabledStore) { enabledStore = newValue }
            defaults.set(newValue, forKey: Key.enabled)
            enabledChanged()
        }
    }
    @ObservationIgnored private var enabledStore: Bool

    var rememberView: Bool {
        get { defaults.bool(forKey: Key.rememberView) }
        set {
            defaults.set(newValue, forKey: Key.rememberView)
            if !newValue { defaults.removeObject(forKey: Key.lastView) }
        }
    }

    init() {
        defaults.register(defaults: [Key.cameras: true, Key.regions: true, Key.buildings: true, Key.grid: true,
                                     Key.terrain: true, Key.exaggeration: 1.5, Key.places: true,
                                     Key.enabled: false, Key.rememberView: false])
        showCameras = defaults.bool(forKey: Key.cameras)
        showRegions = defaults.bool(forKey: Key.regions)
        showBuildings = defaults.bool(forKey: Key.buildings)
        showGrid = defaults.bool(forKey: Key.grid)
        showTerrain = defaults.bool(forKey: Key.terrain)
        showPlaces = defaults.bool(forKey: Key.places)
        let hidden = defaults.array(forKey: Key.hiddenPlaces) as? [Int] ?? []
        hiddenCategories = Set(hidden.compactMap { POICategory(rawValue: UInt8(clamping: $0)) })
        terrainExaggeration = min(3, max(1, defaults.double(forKey: Key.exaggeration)))
        enabledStore = defaults.bool(forKey: Key.enabled)
        if defaults.bool(forKey: Key.rememberView), let data = defaults.data(forKey: Key.lastView),
           let remembered = try? JSONDecoder().decode(MapCamera.self, from: data), Self.isUsable(remembered) {
            // Stored by an earlier run: checked and clamped like any other camera before use.
            liveCamera = MapGestureMath.clamp(remembered)
        } else {
            // Open on the globe, facing North America.
            liveCamera = MapCamera(center: TileMath.project(LonLat(lon: -96, lat: 36)), zoom: 2.3)
        }
        tiles.enabled = enabledStore
        alpr.enabled = enabledStore
        terrain.enabled = enabledStore && showTerrain
        search.model = self
        routing.model = self
        alpr.onIndexChange = { [weak self] in self?.cameraIndexChanged() }
    }

    private static func isUsable(_ c: MapCamera) -> Bool {
        c.center.x.isFinite && c.center.y.isFinite && c.zoom.isFinite && c.bearing.isFinite && c.pitch.isFinite
    }

    // MARK: Page lifecycle

    func appeared() {
        if enabled {
            // The scan-in plays once per page open (and when the tile source changes), not on
            // every pan or zoom step.
            Task {
                let generationBefore = tiles.generation
                await tiles.loadSource()
                let firstLook = tilePlan.cover.isEmpty || generationBefore != tiles.generation || !revealedThisVisit
                if app?.settings.effects.motion == true && firstLook { startReveal() }
                revealedThisVisit = true
                refresh()
            }
            Task { await alpr.checkFreshness(manual: false) }
        }
        refresh()
    }

    func disappeared() {
        revealedThisVisit = false
        locateTask?.cancel()
        location.clear()
        if rememberView, !located, let data = try? JSONEncoder().encode(camera) { defaults.set(data, forKey: Key.lastView) }
    }

    private func enabledChanged() {
        tiles.enabled = enabledStore
        alpr.enabled = enabledStore
        terrain.enabled = enabledStore && showTerrain
        if !enabledStore { alpr.cancel() }
        if enabledStore { Task { await tiles.loadSource(); refresh() } }
    }

    // MARK: Redrawing

    /// Recomputes the wanted tiles and rebuilds the frame (call after camera, viewport or data changes).
    func refresh() {
        plan()
        invalidateFrame()
        updateCamerasInView()
    }

    /// The next `frame(palette:glow:)` builds a new frame.
    func invalidateFrame() { frameRevision &+= 1 }

    func setViewport(_ v: SIMD2<Double>) {
        guard v != viewport, v.x > 10, v.y > 10 else { return }
        viewport = v
        refresh()
    }

    private func startReveal() {
        revealTask?.cancel()
        reveal = 0
        revealTask = Task { @MainActor in
            let start = Date()
            while !Task.isCancelled {
                let t = Float(Date().timeIntervalSince(start) / 0.45)
                reveal = min(1, t)
                invalidateFrame()
                if t >= 1 { break }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    // MARK: Selection

    var selectedCamera: ALPRCamera? {
        guard let s = selected, alpr.index.cameras.indices.contains(s) else { return nil }
        return alpr.index.cameras[s]
    }

    /// Selects a camera by its index (nil clears); a selected camera replaces a chosen place.
    func select(_ i: Int?) {
        let closesPlace = i != nil && place != nil
        guard i != selected || closesPlace else { return }
        selected = i
        selectedID = selectedCamera?.id
        if closesPlace { place = nil }
        invalidateFrame()
    }

    /// The camera index was rebuilt (a region was downloaded, updated or removed). Cameras are
    /// referred to by their index in it, and those have all moved: the selection is found again
    /// by its OSM id, and a route's cameras are worked out afresh.
    private func cameraIndexChanged() {
        if let id = selectedID {
            selected = alpr.index.cameras.firstIndex { $0.id == id }
            if selected == nil { selectedID = nil }
        }
        routing.camerasChanged()
        updateCamerasInView()
    }

    /// Shows a place (pin, inspector); `fly` moves the map to it.
    func selectPlace(_ r: PlaceResult?, fly: Bool = false) {
        if r == nil && place == nil { return }
        place = r
        if r != nil { selected = nil }
        invalidateFrame()
        guard let r else { return }
        app?.inspectorVisible = true
        if fly {
            var c = camera
            c.center = TileMath.project(r.coordinate)
            // Keep the view as close as it is when that already shows the place well.
            let z = r.suggestedZoom
            c.zoom = camera.isGlobe || abs(camera.zoom - z) > 1.5 ? z : max(camera.zoom, min(z, 17))
            setCamera(c)
        }
    }

    /// The route or its ends changed: redraw, and with `fit` frame the whole route.
    func routeChanged(fit: Bool = false) {
        invalidateFrame()
        guard fit, let points = routing.shownLeg?.path.points,
              let framed = Self.cameraFitting(points.map(TileMath.project), viewport: viewport, margin: 140, minZoom: 4) else { return }
        // The margin leaves room for the side column and search box, which cover part of the view.
        var c = camera
        c.center = framed.center
        c.zoom = framed.zoom
        c.bearing = 0
        setCamera(c)
    }

    /// The centre and zoom that show all of `points` in `viewport` with `margin` points to spare.
    static func cameraFitting(_ points: [Mercator], viewport: SIMD2<Double>, margin: Double, minZoom: Double) -> (center: Mercator, zoom: Double)? {
        guard points.count >= 2, var minX = points.first?.x, var minY = points.first?.y else { return nil }
        var maxX = minX, maxY = minY
        for p in points {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        let widthPoints = max(1e-9, maxX - minX) * 256, heightPoints = max(1e-9, maxY - minY) * 256
        let zoom = log2(min((viewport.x - margin) / widthPoints, (viewport.y - margin) / heightPoints))
        return (Mercator(x: (minX + maxX) / 2, y: (minY + maxY) / 2), min(16.5, max(minZoom, zoom)))
    }

    // MARK: Location

    /// ⌖: asks for one fix and centres the map on it when it arrives.
    func locate() {
        location.locate()
        locateTask?.cancel()
        locateTask = Task { [weak self] in
            guard let self, let position = await self.location.waitForFix() else { return }
            // From here on the camera shows where the user is: never remember it.
            self.located = true
            self.defaults.removeObject(forKey: Key.lastView)
            self.flyTo(position, zoom: max(self.camera.zoom, 14))
        }
    }

    // MARK: Camera regions

    /// The rectangle being drawn with ⇧-drag, as two view points.
    func dragRectangle(from a: SIMD2<Double>, to b: SIMD2<Double>, ended: Bool) {
        let projection = mapProjection(camera: camera, viewport: viewport)
        guard drawingRegion, let ga = projection.groundPoint(screen: a), let gb = projection.groundPoint(screen: b) else { return }
        draftRect = (Mercator(x: min(ga.x, gb.x), y: min(ga.y, gb.y)), Mercator(x: max(ga.x, gb.x), y: max(ga.y, gb.y)))
        invalidateFrame()
        if ended { finishRectangle() }
    }

    private func finishRectangle() {
        guard let (a, b) = draftRect else { return }
        let nw = TileMath.unproject(a), se = TileMath.unproject(b)
        let box = BBox(west: max(-180, nw.lon), south: max(-85, se.lat), east: min(180, se.lon), north: min(85, nw.lat))
        drawingRegion = false
        guard box.isValid, box.east - box.west > 0.001, box.north - box.south > 0.001 else {
            draftRect = nil
            invalidateFrame()
            return
        }
        requestDownload(of: box) { [weak self] in
            self?.draftRect = nil
            self?.invalidateFrame()
        }
    }

    /// Offers to download the cameras inside a drawn or visible rectangle.
    func requestDownload(of box: BBox, done: (() -> Void)? = nil) {
        let key = String(format: "rect-%.3f_%.3f_%.3f_%.3f", box.west, box.south, box.east, box.north)
        let name = String(format: "Area %.2f°, %.2f°", (box.north + box.south) / 2, (box.east + box.west) / 2)
        requestDownload(RegionDescriptor(id: key, name: name, parent: nil, iso3166_1: [], iso3166_2: []),
                        polygon: .rectangle(box), isRectangle: true, done: done)
    }

    /// Plans a camera download and asks before fetching anything (ALPR-NET): the confirmation
    /// names the hosts, the request count and the size. `done` runs when the download has
    /// finished or was declined.
    func requestDownload(_ region: RegionDescriptor, polygon: GeoPolygon, isRectangle: Bool, done: (() -> Void)? = nil) {
        guard enabled, let app else { done?(); return }
        notice = "Planning the download for \(region.name)…"
        Task { [weak self] in
            guard let self else { return }
            do {
                let plan = try await alpr.plan(region, polygon: polygon, isRectangle: isRectangle)
                notice = nil
                guard plan.requests > 0 else {
                    app.flash(.info, "No mapped cameras in \(region.name)")
                    done?(); return
                }
                app.present(Confirmation(code: "ALPR-NET", title: "Download cameras for \(region.name)?",
                                         message: Self.downloadMessage(plan),
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

    private static func downloadMessage(_ plan: ALPRStore.DownloadPlan) -> String {
        let estimatedKB = max(1, plan.estimatedCameras * 60 / 1024 + plan.overpassChunks.count * 40)
        var message = "\(plan.requests) request\(plan.requests == 1 ? "" : "s") to \(plan.hosts.joined(separator: " and "))"
        if plan.estimatedCameras > 0 {
            message += ", about \(plan.estimatedCameras.formatted()) cameras (≈ \(estimatedKB.formatted()) KB)"
        }
        message += ". That host learns which area you downloaded. The cameras are stored on this Mac and shown offline; update or remove them in the Regions list."
        if !plan.overpassChunks.isEmpty { message += " Overpass requests go one at a time and may take a few minutes." }
        return message
    }

    // MARK: Clearing

    /// Asks, then deletes everything the Map page has stored. `done` runs once the files are gone.
    func confirmClearAllData(then done: (() -> Void)? = nil) {
        guard let app else { return }
        _ = app.present(Confirmation(code: "MAP-CLEAR", title: "Clear all map data?",
                                     message: "Deletes cached map tiles, elevation, road data for directions, the region list and every downloaded camera region from this Mac. You can download them again later.",
                                     confirmLabel: "Clear", destructive: true,
                                     onConfirm: { [weak self] in self?.clearAllData(then: done) }))
    }

    /// Deletes all stored map data. The tile and elevation caches can hold tens of thousands of
    /// files, so they are removed off the main thread; `done` runs when that has finished.
    func clearAllData(then done: (() -> Void)? = nil) {
        alpr.clearAll()
        terrain.clear()
        tiles.clearMemory()
        select(nil)
        selectPlace(nil)
        search.clear()
        search.forgetOnline()
        routing.clearAllData()
        Task {
            await Task.detached(priority: .userInitiated) {
                try? MapStorage.remove(MapStorage.tiles)
                try? MapStorage.remove(MapStorage.terrain)
            }.value
            await tiles.loadSource()
            refresh()
            done?()
        }
    }
}
