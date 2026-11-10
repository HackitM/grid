import Foundation
import simd

// Shared data contracts for GRID Maps (docs/maps/IMPLEMENTATION.md §3). FROZEN: workstreams build
// on these types in parallel; changes go through the lead. Pure value types, no AppKit, Metal or
// CoreLocation. Every decoder that produces them treats its input as untrusted.

// MARK: - Coordinates

/// A slippy-map tile (Web Mercator, XYZ scheme, y = 0 at the north edge).
public struct TileID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let z: UInt8
    public let x: UInt32
    public let y: UInt32
    public init(z: Int, x: Int, y: Int) {
        self.z = UInt8(clamping: z); self.x = UInt32(clamping: x); self.y = UInt32(clamping: y)
    }
    public var description: String { "\(z)/\(x)/\(y)" }
    /// x and y are inside 0..<2^z.
    public var isValid: Bool { z <= 24 && x < (UInt32(1) << z) && y < (UInt32(1) << z) }
}

/// Geographic position in degrees (WGS84).
public struct LonLat: Hashable, Sendable, Codable {
    public var lon: Double
    public var lat: Double
    public init(lon: Double, lat: Double) { self.lon = lon; self.lat = lat }
    /// Finite, lat within ±90 and lon within ±180.
    public var isValid: Bool { lon.isFinite && lat.isFinite && abs(lat) <= 90 && abs(lon) <= 180 }
}

/// Web Mercator world position, normalised: x and y in 0…1, y = 0 at the north edge
/// (latitude ≈ 85.0511°). One world unit = the width of the z0 tile.
public struct Mercator: Hashable, Sendable, Codable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

/// Geographic rectangle in degrees. `west <= east` (no antimeridian wrap in v1: a box that would
/// cross it is split by its producer).
public struct BBox: Hashable, Sendable, Codable {
    public var west: Double
    public var south: Double
    public var east: Double
    public var north: Double
    public init(west: Double, south: Double, east: Double, north: Double) {
        self.west = west; self.south = south; self.east = east; self.north = north
    }
    public func contains(_ p: LonLat) -> Bool { p.lon >= west && p.lon <= east && p.lat >= south && p.lat <= north }
    public func intersects(_ b: BBox) -> Bool { !(b.west > east || b.east < west || b.south > north || b.north < south) }
    public var isValid: Bool {
        [west, south, east, north].allSatisfy(\.isFinite) && west <= east && south <= north
            && west >= -180 && east <= 180 && south >= -90 && north <= 90
    }
}

/// The map's view. `zoom` is fractional (tile zoom = floor), `bearing` is degrees clockwise from
/// north (0 = north up), `pitch` is degrees from straight down (0…MapCamera.maxPitch).
public struct MapCamera: Equatable, Sendable, Codable {
    public static let maxPitch: Double = 45
    public static let minZoom: Double = 1
    public static let maxZoom: Double = 18
    public var center: Mercator
    public var zoom: Double
    public var bearing: Double
    public var pitch: Double
    public init(center: Mercator, zoom: Double, bearing: Double = 0, pitch: Double = 0) {
        self.center = center; self.zoom = zoom; self.bearing = bearing; self.pitch = pitch
    }
}

// MARK: - Mapbox Vector Tile model (decoded, still in tile integer coordinates)

public enum MVTValue: Hashable, Sendable {
    case string(String)
    case int(Int64)
    case double(Double)
    case bool(Bool)

    public var string: String? { if case .string(let s) = self { s } else { nil } }
    public var number: Double? {
        switch self {
        case .int(let i): Double(i)
        case .double(let d): d
        default: nil
        }
    }
}

/// Geometry in the layer's integer coordinate space (0…extent, y down; values may lie a little
/// outside the extent in the tile buffer).
public enum MVTGeometry: Sendable, Equatable {
    case points([SIMD2<Int32>])
    case lines([[SIMD2<Int32>]])
    /// Each polygon is [exterior ring, hole rings…]; rings are not explicitly closed (the first
    /// point is not repeated) and have at least 3 points.
    case polygons([[[SIMD2<Int32>]]])
}

public struct MVTFeature: Sendable, Equatable {
    public var id: UInt64?
    public var tags: [String: MVTValue]
    public var geometry: MVTGeometry
    public init(id: UInt64?, tags: [String: MVTValue], geometry: MVTGeometry) {
        self.id = id; self.tags = tags; self.geometry = geometry
    }
}

public struct MVTLayer: Sendable, Equatable {
    public var name: String
    public var extent: Int32
    public var features: [MVTFeature]
    public init(name: String, extent: Int32, features: [MVTFeature]) {
        self.name = name; self.extent = extent; self.features = features
    }
}

public struct MVTTile: Sendable, Equatable {
    public var layers: [MVTLayer]
    public init(layers: [MVTLayer]) { self.layers = layers }
    public func layer(_ name: String) -> MVTLayer? { layers.first { $0.name == name } }
}

/// Hard limits applied while decoding untrusted tiles (exceeding one throws or skips, never traps).
public struct MVTLimits: Sendable {
    public var maxBytes = 8 << 20
    public var maxLayers = 64
    public var maxFeaturesPerLayer = 200_000
    public var maxGeometryInts = 4_000_000          // per tile
    public var maxVerticesPerFeature = 100_000      // larger features are skipped
    public var maxStringBytes = 4096
    public var maxKeysOrValuesPerLayer = 100_000
    public init() {}
}

public enum MVTError: Error, Equatable {
    case tooLarge, truncated, malformed(String), limitExceeded(String)
}

// MARK: - Render geometry (tile-local, ready for GPU upload)

/// What a fill or line is drawn as. Colours and widths come from per-frame uniform tables indexed
/// by `rawValue` (so zoom and theme changes never re-tessellate). Order = draw order for lines
/// (later classes are drawn on top).
public enum RenderClass: UInt16, CaseIterable, Sendable {
    case water, waterway, landuse, park, building
    case path, rail, service, minor, tertiary, secondary, primary, trunk, motorway
    case boundary, aeroway
}

/// One vertex of a tessellated line, matching the Metal `LineVertex` struct byte for byte
/// (stride 32: float2 pos, float2 normal, float side, float along, ushort cls, ushort flags).
/// `pos` is tile-local 0…1; the shader expands it by `normal * side * halfWidthPx` in screen space.
public struct LineVertex: Sendable, Equatable {
    public var pos: SIMD2<Float>
    /// Miter-scaled offset direction (unit length on straight segments, up to the miter limit).
    public var normal: SIMD2<Float>
    /// -1 or +1: which side of the centre line.
    public var side: Float
    /// Distance along the line in tile units (0…1 per tile width), for dashes and caps.
    public var along: Float
    public var cls: UInt16
    /// Bit 0: tunnel (drawn dimmed). Bit 1: bridge. Others reserved (0).
    public var flags: UInt16
    public init(pos: SIMD2<Float>, normal: SIMD2<Float>, side: Float, along: Float, cls: UInt16, flags: UInt16 = 0) {
        self.pos = pos; self.normal = normal; self.side = side; self.along = along; self.cls = cls; self.flags = flags
    }
    public static let tunnel: UInt16 = 1, bridge: UInt16 = 2
}

public struct FillBatch: Sendable, Equatable {
    public var cls: RenderClass
    public var positions: [SIMD2<Float>]   // tile-local 0…1
    public var indices: [UInt32]           // triangles
    public init(cls: RenderClass, positions: [SIMD2<Float>], indices: [UInt32]) {
        self.cls = cls; self.positions = positions; self.indices = indices
    }
}

public struct LineBatch: Sendable, Equatable {
    public var cls: RenderClass
    public var vertices: [LineVertex]
    public var indices: [UInt32]           // triangles
    public init(cls: RenderClass, vertices: [LineVertex], indices: [UInt32]) {
        self.cls = cls; self.vertices = vertices; self.indices = indices
    }
}

/// Building geometry: roofs and walls (stride 16: float2 pos, float height, ushort shade,
/// ushort flags). Wall-top vertices carry `wallTop`, so the fragment shader can draw the accent
/// roof edge where the interpolated flag approaches 1.
public struct ExtrusionVertex: Sendable, Equatable {
    public var pos: SIMD2<Float>   // tile-local 0…1
    public var height: Float       // metres above ground
    /// Lighting 0…65535 → 0…1 (roofs 65535; walls darker the more they face away from the light).
    public var shade: UInt16
    /// Bit 0: roof. Bit 1: wall top (wall vertices at roof height).
    public var flags: UInt16
    public init(pos: SIMD2<Float>, height: Float, shade: UInt16, flags: UInt16) {
        self.pos = pos; self.height = height; self.shade = shade; self.flags = flags
    }
    public static let roof: UInt16 = 1, wallTop: UInt16 = 2
}

public struct ExtrusionBatch: Sendable, Equatable {
    public var vertices: [ExtrusionVertex]
    public var indices: [UInt32]
    public init(vertices: [ExtrusionVertex], indices: [UInt32]) { self.vertices = vertices; self.indices = indices }
}

public enum LabelKind: UInt8, Sendable { case place, road, water }

/// A label candidate in tile-local coordinates. Lower `priority` = more important.
public struct LabelAnchor: Sendable, Equatable {
    public var text: String
    public var kind: LabelKind
    public var priority: Int
    public var pos: SIMD2<Float>
    /// Minimum camera zoom at which the label may show.
    public var minZoom: Float
    public init(text: String, kind: LabelKind, priority: Int, pos: SIMD2<Float>, minZoom: Float) {
        self.text = text; self.kind = kind; self.priority = priority; self.pos = pos; self.minZoom = minZoom
    }
}

/// Everything the renderer needs from one source tile. Placement in the world comes only from `id`.
public struct TileGeometry: Sendable, Equatable {
    public let id: TileID
    public var fills: [FillBatch]
    public var lines: [LineBatch]
    public var extrusion: ExtrusionBatch?
    public var labels: [LabelAnchor]
    /// Approximate memory held (for LRU accounting).
    public var byteCount: Int
    public init(id: TileID, fills: [FillBatch], lines: [LineBatch], extrusion: ExtrusionBatch?, labels: [LabelAnchor], byteCount: Int) {
        self.id = id; self.fills = fills; self.lines = lines; self.extrusion = extrusion; self.labels = labels; self.byteCount = byteCount
    }
}

// MARK: - ALPR cameras

public enum OSMElementID: Hashable, Sendable, Codable, CustomStringConvertible {
    case node(Int64)
    case way(Int64)
    public var description: String {
        switch self { case .node(let n): "node/\(n)"; case .way(let w): "way/\(w)" }
    }
    /// The element's page on openstreetmap.org (built from the numeric id only).
    public var webURL: URL { URL(string: "https://www.openstreetmap.org/\(description)")! }
}

public enum ALPRVendor: Hashable, Sendable, Codable {
    case flock, motorola, genetec, axis, leonardo, rekor, axon, neology
    case other(String)
    case unknown

    public var label: String {
        switch self {
        case .flock: "Flock Safety"; case .motorola: "Motorola Solutions"; case .genetec: "Genetec"
        case .axis: "Axis"; case .leonardo: "Leonardo"; case .rekor: "Rekor"; case .axon: "Axon"
        case .neology: "Neology"; case .other(let s): s; case .unknown: "Unknown vendor"
        }
    }
}

public struct ALPRCamera: Hashable, Sendable, Codable {
    public let id: OSMElementID
    public let coordinate: LonLat
    /// Facing directions in whole degrees 0…359; empty = unknown.
    public let directions: [UInt16]
    public let vendor: ALPRVendor
    public let operatorName: String?
    public let mount: String?
    public let zone: String?
    public let lastEdited: Date?
    public init(id: OSMElementID, coordinate: LonLat, directions: [UInt16], vendor: ALPRVendor,
                operatorName: String?, mount: String?, zone: String?, lastEdited: Date?) {
        self.id = id; self.coordinate = coordinate; self.directions = directions; self.vendor = vendor
        self.operatorName = operatorName; self.mount = mount; self.zone = zone; self.lastEdited = lastEdited
    }
}

/// A (multi)polygon in degrees: each element is [exterior, holes…]; rings not explicitly closed.
public struct GeoPolygon: Sendable, Codable, Equatable {
    public var polygons: [[[LonLat]]]
    public init(polygons: [[[LonLat]]]) { self.polygons = polygons }
    public static func rectangle(_ b: BBox) -> GeoPolygon {
        GeoPolygon(polygons: [[[LonLat(lon: b.west, lat: b.south), LonLat(lon: b.east, lat: b.south),
                                LonLat(lon: b.east, lat: b.north), LonLat(lon: b.west, lat: b.north)]]])
    }
}

/// Where a region's cameras are downloaded from.
public enum ALPRSource: String, Sendable, Codable {
    /// DeFlock/FlockHopper hourly z11 vector tiles (US).
    case deflockUS
    /// Same, Canadian build.
    case deflockCA
    /// An Overpass endpoint, bbox-chunked (everywhere else).
    case overpass
}

/// A downloadable region: a Geofabrik catalogue entry or a user-drawn rectangle.
public struct RegionDescriptor: Identifiable, Hashable, Sendable, Codable {
    public let id: String                 // Geofabrik id ("us/colorado") or "rect-<hash>"
    public let name: String
    public let parent: String?
    public let iso3166_1: [String]
    public let iso3166_2: [String]
    public init(id: String, name: String, parent: String?, iso3166_1: [String], iso3166_2: [String]) {
        self.id = id; self.name = name; self.parent = parent; self.iso3166_1 = iso3166_1; self.iso3166_2 = iso3166_2
    }
    /// A safe folder name derived from `id` (lowercase a–z, 0–9, '-' only, ≤ 80 chars; never empty).
    public var storageKey: String {
        var out = ""
        for ch in id.lowercased().unicodeScalars {
            if (ch >= "a" && ch <= "z") || (ch >= "0" && ch <= "9") { out.unicodeScalars.append(ch) }
            else if ch == "/" { out += "--" }
            else if !out.hasSuffix("-") { out += "-" }
        }
        out = String(out.prefix(80)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return out.isEmpty ? "region" : out
    }
}

/// Clustered cameras for low zooms.
public struct CameraCluster: Sendable, Equatable {
    public var count: Int
    public var center: LonLat
    /// Index of one camera in the cluster (the camera itself when count == 1).
    public var representative: Int
    public init(count: Int, center: LonLat, representative: Int) {
        self.count = count; self.center = center; self.representative = representative
    }
}
