import AppKit
import GridCore
import simd
import SwiftUI

// Contract between the map renderer/view (workstream C) and the rest of the Maps feature
// (MapModel, TileStore, ALPRStore: workstream D/E). FROZEN; changes go through the lead.
// See docs/maps/IMPLEMENTATION.md §3.2.

/// Theme colours for the map, as linear-ish sRGB floats premultiplied by nothing (the shader
/// premultiplies). Built from GRID's `Theme` so a theme switch only changes uniforms.
struct MapPalette: Equatable {
    var bg0, bg1, bg2, bg3: SIMD4<Float>
    var text, textDim, textMute: SIMD4<Float>
    var accent, glow, line, lineStrong: SIMD4<Float>
    var warn, danger, ok: SIMD4<Float>
    /// The chosen route's colour when it must differ from the roads (paper).
    var route: SIMD4<Float>? = nil

    /// Black on white for printing: roads in greys, water pale blue, the route in strong blue.
    static let paper = MapPalette(
        bg0: SIMD4(1, 1, 1, 1), bg1: SIMD4(0.97, 0.97, 0.96, 1), bg2: SIMD4(0.86, 0.86, 0.85, 1), bg3: SIMD4(0.78, 0.86, 0.93, 1),
        text: SIMD4(0.05, 0.05, 0.05, 1), textDim: SIMD4(0.25, 0.25, 0.25, 1), textMute: SIMD4(0.5, 0.5, 0.5, 1),
        accent: SIMD4(0.35, 0.35, 0.38, 1), glow: SIMD4(0, 0, 0, 0), line: SIMD4(0.8, 0.8, 0.8, 1), lineStrong: SIMD4(0.6, 0.6, 0.6, 1),
        warn: SIMD4(0.85, 0.35, 0.0, 1), danger: SIMD4(0.8, 0.1, 0.1, 1), ok: SIMD4(0.1, 0.55, 0.2, 1),
        route: SIMD4(0.05, 0.35, 0.85, 1))

    @MainActor private static var cache: (ThemeID, MapPalette)?

    /// `make`, remembered per theme (the colour conversions are not free at 60 frames a second).
    @MainActor static func cached(_ t: Theme) -> MapPalette {
        if let (id, p) = cache, id == t.id { return p }
        let p = make(t)
        cache = (t.id, p)
        return p
    }

    @MainActor static func make(_ t: Theme) -> MapPalette {
        func c(_ color: Color) -> SIMD4<Float> {
            let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
            return SIMD4(Float(ns.redComponent), Float(ns.greenComponent), Float(ns.blueComponent), Float(ns.alphaComponent))
        }
        return MapPalette(bg0: c(t.bg0), bg1: c(t.bg1), bg2: c(t.bg2), bg3: c(t.bg3),
                          text: c(t.text), textDim: c(t.textDim), textMute: c(t.textMute),
                          accent: c(t.accent), glow: c(t.glow), line: c(t.line), lineStrong: c(t.lineStrong),
                          warn: c(t.warn), danger: c(t.danger), ok: c(t.ok))
    }
}

/// One ALPR camera to draw (zoom ≥ 12). `index` is the camera's index in the model's array, used
/// for selection and hit testing.
struct CameraMarker: Equatable {
    var world: Mercator
    var directions: [UInt16]
    var isFlock: Bool
    var selected: Bool
    var index: Int
    /// The shown route passes it (drawn in the warning colour).
    var onRoute = false
}

/// A cluster block (zoom < 12): `▣ count`.
struct ClusterMarker: Equatable {
    var world: Mercator
    var count: Int
}

/// The user's position after ⌖ LOCATE (memory only).
struct LocationMarker: Equatable {
    var world: Mercator
    var accuracyMeters: Double
}

/// The chosen place (a search result or a clicked point of interest): a pin with its name.
struct PlaceMarker: Equatable {
    var world: Mercator
    var title: String
}

/// A route on the map: the chosen one bright and glowing, the alternative dim and dashed.
struct RouteLine: Equatable {
    var points: [Mercator]
    var primary: Bool
}

/// A route's start or end ("A", "B") or the step under the pointer.
struct RouteMark: Equatable {
    var world: Mercator
    var label: String
}

/// A region outline to draw (the downloaded regions, and the rectangle being drawn).
struct RegionOutline: Equatable {
    var rings: [[Mercator]]
    var highlighted: Bool
}

/// Everything the renderer draws for one frame. The renderer keeps GPU buffers per TileID and
/// uploads `tiles` it hasn't seen; tiles absent from the list may be evicted (LRU, ≤ 160).
struct MapFrame: Equatable {
    var camera: MapCamera
    /// Changes whenever the tile source changes (new planet build, custom tile URL, cleared
    /// cache): the renderer then drops every GPU tile, since the same TileID means new geometry.
    var tileGeneration: Int
    /// Source tiles to draw: the wanted tiles plus loaded ancestors standing in for missing ones.
    /// Order is informational; the renderer draws descendants first and masks ancestors (stencil).
    var tiles: [TileGeometry]
    var cameras: [CameraMarker] = []
    var clusters: [ClusterMarker] = []
    var location: LocationMarker?
    var pin: PlaceMarker?
    var routes: [RouteLine] = []
    var routeMarks: [RouteMark] = []
    /// The step under the pointer in the route panel.
    var stepMark: Mercator?
    /// Point-of-interest categories to draw, one bit per `POICategory.rawValue` (0: none).
    var poiMask: UInt16 = 0
    var regions: [RegionOutline] = []
    var palette: MapPalette
    /// Effects › Glow.
    var glow: Bool
    /// Draw extruded buildings (also requires pitch > 5°).
    var buildings: Bool
    /// Scan-sweep reveal 0…1 (1 = fully drawn). Animated by the model, only when Motion is on.
    var reveal: Float = 1
    /// Draw the procedural grid floor.
    var gridFloor: Bool = true
    /// Elevation grids for the tiles in view (empty when the terrain layer is off).
    var terrain: [TerrainGrid] = [] {
        didSet {
            terrainIndex = Dictionary(terrain.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
            terrainZooms = Set(terrain.map { Int($0.id.z) }).sorted(by: >)
        }
    }
    private var terrainIndex: [TileID: Int] = [:]
    /// Zoom levels present in `terrain`, deepest first (lookups try only these).
    private var terrainZooms: [Int] = []
    /// How elevation is drawn (flat until the view is tilted; see `TerrainLift`). It depends on the
    /// camera, so whoever draws or hit-tests sets it from `lift(for:viewport:)` for the camera in use.
    var lift: TerrainLift = .flat
    /// Vertical exaggeration of the 3D terrain (1 = true scale); 0 when the terrain layer is off.
    var exaggeration: Double = 0
    /// Identifies one build of the frame by the model (the same stamp = the same contents).
    var stamp = 0
    /// Shaded relief and contour styling on.
    var hillshade: Bool = false
    /// Lowest ground in view (metres, ≥ 0): high ground glows relative to it.
    var terrainFloor: Float = 0

    /// Raw elevation (metres) at a world point from the deepest grid covering it; nil if none.
    func rawElevation(at p: Mercator) -> Double? {
        guard p.x >= 0, p.y >= 0, p.x < 1, p.y < 1 else { return nil }
        for z in terrainZooms {
            let n = Double(1 << z)
            let fx = p.x * n, fy = p.y * n
            let x = fx.rounded(.down), y = fy.rounded(.down)
            guard let i = terrainIndex[TileID(z: z, x: Int(x), y: Int(y))] else { continue }
            return terrain[i].height(u: fx - x, v: fy - y)
        }
        return nil
    }

    /// Metres drawn above the ground plane at a world point (0 while flat).
    func elevation(at p: Mercator) -> Double {
        // No elevation yet: at the camera's ground level (where the GPU draws such tiles too).
        guard !lift.isFlat, let h = rawElevation(at: p) else { return 0 }
        return lift.lift(h)
    }

    /// The lift for a camera: exaggeration × a tilt ease (0 when looking straight down, so the flat
    /// map stays true to scale, easing in by 20° of tilt), relative to the ground under the camera
    /// centre, with peaks kept below 92% of the camera's height.
    func lift(for camera: MapCamera, viewport: SIMD2<Double>) -> TerrainLift {
        guard exaggeration > 0, !camera.isGlobe else { return .flat }
        let x = min(1, max(0, (camera.pitch - 4) / 16))
        // Zoomed out the camera is far away and relief flattens, so it gets up to 1.5× more.
        let zoomBoost = 1 + 0.5 * min(1, max(0, (13 - camera.zoom) / 3))
        let s = exaggeration * zoomBoost * x * x * (3 - 2 * x)
        guard s > 0 else { return .flat }
        let base = max(0, rawElevation(at: camera.center) ?? 0)
        let dist = 0.5 * max(1, viewport.y) / tan(MapProjection.fovY / 2)
        let lat = TileMath.unproject(camera.center).lat
        let camHeight = dist * cos(camera.pitch * .pi / 180) * TileMath.metersPerPoint(lat: lat, zoom: camera.zoom)
        return TerrainLift(scale: Float(s), base: Float(base), ceiling: Float(camHeight * 0.92))
    }

    static func == (a: MapFrame, b: MapFrame) -> Bool {
        a.camera == b.camera && a.tileGeneration == b.tileGeneration && a.tiles.map(\.id) == b.tiles.map(\.id) && a.cameras == b.cameras
            && a.clusters == b.clusters && a.location == b.location && a.regions == b.regions && a.palette == b.palette
            && a.glow == b.glow && a.buildings == b.buildings && a.reveal == b.reveal && a.gridFloor == b.gridFloor
            && a.terrain.map(\.id) == b.terrain.map(\.id) && a.exaggeration == b.exaggeration && a.hillshade == b.hillshade && a.terrainFloor == b.terrainFloor
            && a.tiles.map(\.revision) == b.tiles.map(\.revision)
    }
}

/// Input from the map view to the model. Points are view coordinates, top-left origin.
enum MapGesture {
    /// Drag: pan by a screen delta.
    case pan(SIMD2<Double>)
    /// Scroll-wheel / pinch zoom around a screen point (delta in zoom levels).
    case zoom(Double, around: SIMD2<Double>)
    /// ⌥-drag / two-finger rotate (degrees) and pitch (degrees).
    case rotate(bearingDelta: Double, pitchDelta: Double)
    /// Click (no drag) at a point.
    case click(SIMD2<Double>)
    /// ⇧-drag rectangle for "download this area" while region drawing is on (start, current, ended).
    case rectangle(SIMD2<Double>, SIMD2<Double>, ended: Bool)
    /// Keyboard: arrow keys pan, +/- zoom, 0 resets north and pitch.
    case key(MapKey)
    /// Right-click (or control-click) at a view point; `screen` is the same point in screen
    /// coordinates (bottom-left origin) for placing the menu.
    case contextMenu(SIMD2<Double>, screen: SIMD2<Double>)
}

enum MapKey { case left, right, up, down, zoomIn, zoomOut, resetNorth }
