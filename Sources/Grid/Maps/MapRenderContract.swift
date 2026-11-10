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

/// A region outline to draw (the downloaded regions, and the rectangle being drawn).
struct RegionOutline: Equatable {
    var rings: [[Mercator]]
    var highlighted: Bool
}

/// Everything the renderer draws for one frame. The renderer keeps GPU buffers per TileID and
/// uploads `tiles` it hasn't seen; tiles absent from the list may be evicted (LRU, ≤ 60).
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
    var terrain: [TerrainGrid] = [] { didSet { terrainIndex = Dictionary(terrain.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a }) } }
    private var terrainIndex: [TileID: Int] = [:]
    /// How elevation is drawn (flat until the view is tilted; see `TerrainLift`).
    var lift: TerrainLift = .flat
    /// Shaded relief and contour styling on.
    var hillshade: Bool = false

    /// Raw elevation (metres) at a world point from the deepest grid covering it; nil if none.
    func rawElevation(at p: Mercator) -> Double? {
        guard !terrainIndex.isEmpty else { return nil }
        for z in stride(from: 18, through: 0, by: -1) {
            let n = Double(1 << z)
            let x = Int((p.x * n).rounded(.down)), y = Int((p.y * n).rounded(.down))
            guard x >= 0, y >= 0, Double(x) < n, Double(y) < n else { return nil }
            let id = TileID(z: z, x: x, y: y)
            guard let i = terrainIndex[id] else { continue }
            let (nw, se) = TileMath.bounds(id)
            return terrain[i].height(u: (p.x - nw.x) / (se.x - nw.x), v: (p.y - nw.y) / (se.y - nw.y))
        }
        return nil
    }

    /// Metres drawn above the ground plane at a world point (0 while flat).
    func elevation(at p: Mercator) -> Double {
        guard !lift.isFlat, let h = rawElevation(at: p) else { return lift.isFlat ? 0 : lift.lift(0) }
        return lift.lift(h)
    }

    static func == (a: MapFrame, b: MapFrame) -> Bool {
        a.camera == b.camera && a.tileGeneration == b.tileGeneration && a.tiles.map(\.id) == b.tiles.map(\.id) && a.cameras == b.cameras
            && a.clusters == b.clusters && a.location == b.location && a.regions == b.regions && a.palette == b.palette
            && a.glow == b.glow && a.buildings == b.buildings && a.reveal == b.reveal && a.gridFloor == b.gridFloor
            && a.terrain.map(\.id) == b.terrain.map(\.id) && a.lift == b.lift && a.hillshade == b.hillshade
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

/// A label placed on screen for this frame (from GridCore `LabelPlacer`).
struct PlacedMapLabel: Equatable, Hashable {
    var text: String
    var kind: LabelKind
    var center: CGPoint
    /// Rotation in radians (clockwise, screen space) for labels that run along a line.
    var angle: Double = 0
}
