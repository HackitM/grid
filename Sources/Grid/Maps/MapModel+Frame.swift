import GridCore
import QuartzCore

// The `MapFrame` handed to the renderer. A frame is rebuilt whenever a tile arrives, so the
// parts that are expensive to make and rarely change (camera markers, the route, region
// outlines) are kept between builds, and the camera markers of a large index are worked out off
// the main thread.

/// Identifies one set of camera markers: the index they come from, the area, and how they are
/// grouped (`level` as in `MapModel.markerLevel(zoom:)`).
struct CameraMarkerKey: Equatable, Sendable {
    var indexRevision: Int
    var box: BBox
    var level: Int
}

/// The camera markers (zoomed in) or clusters (zoomed out) for one key.
struct CameraMarkerSet: Sendable {
    static let maxCameras = 4000, maxClusters = 3000

    var key: CameraMarkerKey
    /// Without selection or route state, which the frame adds.
    var cameras: [CameraMarker] = []
    /// The clusters as the index returned them (a click needs their representative camera).
    var clusters: [CameraCluster] = []
    var clusterMarkers: [ClusterMarker] = []

    /// Width of a cluster cell in world units: 44 points at the level's zoom.
    static func clusterCell(level: Int) -> Double { 44 / (256 * pow(2, Double(level) / 4)) }

    static func build(index: CameraIndex, key: CameraMarkerKey) -> CameraMarkerSet {
        var set = CameraMarkerSet(key: key)
        if key.level < 0 {
            set.cameras = index.query(key.box).prefix(maxCameras).map { i in
                let c = index.cameras[i]
                return CameraMarker(world: TileMath.project(c.coordinate), directions: c.directions,
                                    isFlock: c.vendor == .flock, selected: false, index: i)
            }
        } else {
            set.clusters = Array(index.clusters(key.box, cellWorld: clusterCell(level: key.level)).prefix(maxClusters))
            set.clusterMarkers = set.clusters.map { ClusterMarker(world: TileMath.project($0.center), count: $0.count) }
        }
        return set
    }
}

extension MapModel {
    /// What the last frame was built from.
    struct FrameKey: Equatable {
        var tiles, cameras, outlines, frame, terrain, generation: Int
        var palette: MapPalette
        var glow, enabled: Bool
        var location: LocationMarker?
    }

    struct FrameCache {
        var key: FrameKey?
        /// The last frame built (its terrain lift also places markers for hit-testing).
        var frame: MapFrame?
        var stamp = 0
        /// Region outlines in world coordinates, for `ALPRStore.outlineRevision`.
        var outlines: (revision: Int, outlines: [RegionOutline])?
        /// The route lines in world coordinates, for `MapRouting.pathRevision`.
        var routes: (revision: Int, lines: [RouteLine])?
    }

    struct MarkerCache {
        var current: CameraMarkerSet?
        /// The key being worked out off the main thread (one at a time).
        var computing: CameraMarkerKey?
    }

    /// Up to this many cameras, markers are made during the frame build (well under a
    /// millisecond); a larger index is queried off the main thread and the frame redrawn when
    /// the markers are ready.
    static let inlineMarkerLimit = 20_000

    // MARK: The frame

    /// The frame for the map view. Rebuilt only when its inputs change (an unrelated SwiftUI
    /// update gets the same frame back); the camera in it is the current one.
    func frame(palette: MapPalette, glow: Bool) -> MapFrame {
        let fix = location.fix.map { LocationMarker(world: TileMath.project($0.0), accuracyMeters: $0.1) }
        let key = FrameKey(tiles: tiles.revision, cameras: alpr.revision, outlines: alpr.outlineRevision, frame: frameRevision,
                           terrain: terrain.revision, generation: tiles.generation, palette: palette, glow: glow,
                           enabled: enabled, location: fix)
        if key == frameCache.key, let frame = frameCache.frame { return frame }
        frameCache.key = key
        #if DEBUG
        let started = CACurrentMediaTime()
        defer { MapDebugTimes.add("frame", since: started) }
        #endif
        let terrainOn = terrainActive
        var geometry = key.enabled ? tiles.geometry(for: tilePlan.cover + tilePlan.ring) : []
        let grids = terrainOn ? addTerrain(to: &geometry) : []

        var f = MapFrame(camera: liveCamera, tileGeneration: tiles.generation, tiles: geometry,
                         palette: palette, glow: glow, buildings: showBuildings, reveal: reveal, gridFloor: showGrid)
        frameCache.stamp &+= 1
        f.stamp = frameCache.stamp
        f.terrain = grids
        f.exaggeration = terrainOn ? terrainExaggeration : 0
        f.hillshade = terrainOn
        f.terrainFloor = max(0, grids.map(\.minHeight).min() ?? 0)
        f.location = fix
        f.poiMask = poiMask
        if let place { f.pin = PlaceMarker(world: TileMath.project(place.coordinate), title: place.name) }
        addCameraMarkers(to: &f)
        addRoute(to: &f)
        addRegionOutlines(to: &f)
        frameCache.frame = f
        return f
    }

    /// Joins each tile's contours to its geometry (a new revision tells the renderer to upload
    /// it again) and returns the elevation grids of the tiles that have one.
    private func addTerrain(to geometry: inout [TileGeometry]) -> [TerrainGrid] {
        var grids: [TerrainGrid] = []
        for k in geometry.indices {
            guard let t = terrain.terrain(for: geometry[k].id) else { continue }
            grids.append(t.grid)
            guard !t.contours.isEmpty || !t.labels.isEmpty else { continue }
            geometry[k].lines = t.contours + geometry[k].lines
            geometry[k].labels += t.labels
            geometry[k].revision = 2
        }
        return grids
    }

    // MARK: Camera markers

    private func addCameraMarkers(to f: inout MapFrame) {
        guard showCameras, let box = tilePlan.markerBox else { return }
        let level = tilePlan.contentKey?.markerLevel ?? Self.markerLevel(zoom: liveCamera.zoom)
        let wanted = CameraMarkerKey(indexRevision: alpr.revision, box: box, level: level)
        if markers.current?.key != wanted { updateMarkers(wanted) }
        // Until the wanted set is ready the previous one is drawn (its markers are in world
        // coordinates, so they stay in place), unless it is from an index that no longer exists.
        guard let set = markers.current, set.key.indexRevision == wanted.indexRevision else { return }
        f.clusters = set.clusterMarkers
        f.cameras = set.cameras
        let onRoute = routing.camerasOnRoute
        guard selected != nil || !onRoute.isEmpty else { return }
        for k in f.cameras.indices {
            let i = f.cameras[k].index
            if i == selected { f.cameras[k].selected = true }
            if onRoute.contains(i) { f.cameras[k].onRoute = true }
        }
    }

    private func updateMarkers(_ key: CameraMarkerKey) {
        let index = alpr.index
        if index.cameras.count <= Self.inlineMarkerLimit {
            markers.current = CameraMarkerSet.build(index: index, key: key)
            return
        }
        // One query at a time. When it finishes the frame is rebuilt, and that build asks again
        // if the view has moved on meanwhile, so queries never pile up behind a gesture.
        guard markers.computing == nil else { return }
        markers.computing = key
        Task { [weak self] in
            let built = await Task.detached(priority: .userInitiated) { CameraMarkerSet.build(index: index, key: key) }.value
            guard let self else { return }
            self.markers.computing = nil
            if key.indexRevision == self.alpr.revision { self.markers.current = built }
            self.invalidateFrame()
        }
    }

    /// The clusters on screen, when the view is zoomed out far enough to draw clusters.
    var drawnClusters: [CameraCluster]? {
        guard showCameras, let set = markers.current, set.key.level >= 0, set.key.indexRevision == alpr.revision else { return nil }
        return set.clusters
    }

    // MARK: Route

    private func addRoute(to f: inout MapFrame) {
        f.routes = routeLines()
        if let hovered = routing.hoveredStep, let steps = routing.shownLeg?.path.steps, steps.indices.contains(hovered) {
            f.stepMark = TileMath.project(steps[hovered].location)
        }
        if let a = routing.from { f.routeMarks.append(RouteMark(world: TileMath.project(a.coordinate), label: "A")) }
        if let b = routing.to { f.routeMarks.append(RouteMark(world: TileMath.project(b.coordinate), label: "B")) }
    }

    /// The shown route (bright) over the alternative (dim), projected once per route rather than
    /// on every frame build: a long route has tens of thousands of points.
    private func routeLines() -> [RouteLine] {
        if let cached = frameCache.routes, cached.revision == routing.pathRevision { return cached.lines }
        var lines: [RouteLine] = []
        if let outcome = routing.outcome {
            let alternative: RoutePath?
            switch routing.shown {
            case .avoiding: alternative = outcome.avoiding != nil ? outcome.fastest.path : nil
            case .fastest: alternative = outcome.avoiding?.path
            }
            if let alternative { lines.append(RouteLine(points: alternative.points.map(TileMath.project), primary: false)) }
            if let shown = routing.shownLeg?.path { lines.append(RouteLine(points: shown.points.map(TileMath.project), primary: true)) }
        }
        frameCache.routes = (routing.pathRevision, lines)
        return lines
    }

    // MARK: Region outlines

    private func addRegionOutlines(to f: inout MapFrame) {
        if showRegions { f.regions = regionOutlines() }
        if let (a, b) = draftRect {
            let corners = [a, Mercator(x: b.x, y: a.y), b, Mercator(x: a.x, y: b.y)]
            f.regions.append(RegionOutline(rings: [corners], highlighted: true))
        }
    }

    /// The downloaded regions' outer rings, projected once per change of the region list (a
    /// country's boundary has many thousands of points).
    private func regionOutlines() -> [RegionOutline] {
        if let cached = frameCache.outlines, cached.revision == alpr.outlineRevision { return cached.outlines }
        let outlines = alpr.regions.map { region in
            RegionOutline(rings: region.meta.polygon.polygons.compactMap { $0.first?.map(TileMath.project) }, highlighted: false)
        }
        frameCache.outlines = (alpr.outlineRevision, outlines)
        return outlines
    }

    // MARK: Printing

    /// A frame of the whole route in the paper palette, for printing: flat, north up, no
    /// buildings or terrain, the route, its ends and the cameras it passes.
    func printFrame(leg: RouteService.Leg, viewport: SIMD2<Double>) -> MapFrame? {
        let points = leg.path.points.map(TileMath.project)
        guard let framed = Self.cameraFitting(points, viewport: viewport, margin: 60, minZoom: 3) else { return nil }
        let cam = MapCamera(center: framed.center, zoom: framed.zoom)
        // Tiles a level finer than the page's zoom (it prints at 3× resolution); missing ones fall
        // back to loaded ancestors.
        var fine = cam
        fine.zoom += 1
        let cover = TileMath.cover(fine, viewport: viewport * 2, maxZoom: tiles.source?.maxZoom ?? 14, limit: 96)
        var f = MapFrame(camera: cam, tileGeneration: tiles.generation, tiles: tiles.geometry(for: cover),
                         palette: .paper, glow: false, buildings: false, reveal: 1, gridFloor: false)
        f.stamp = 0
        f.routes = [RouteLine(points: points, primary: true)]
        if let a = routing.from { f.routeMarks.append(RouteMark(world: TileMath.project(a.coordinate), label: "A")) }
        if let b = routing.to { f.routeMarks.append(RouteMark(world: TileMath.project(b.coordinate), label: "B")) }
        let cameras = alpr.index.cameras
        for hit in leg.hits where cameras.indices.contains(hit.camera) {
            let c = cameras[hit.camera]
            f.cameras.append(CameraMarker(world: TileMath.project(c.coordinate), directions: c.directions, isFlock: c.vendor == .flock,
                                          selected: false, index: hit.camera, onRoute: true))
        }
        return f
    }
}
