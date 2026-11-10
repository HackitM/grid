import Foundation
import simd

/// Web Mercator math, tile cover and the view projection shared by the renderer, hit testing and
/// label placement (so all of them agree to the pixel). Owned by the lead (frozen contract).
public enum TileMath {
    public static let maxLatitude = 85.05112878

    public static func project(_ p: LonLat) -> Mercator {
        let lat = max(-maxLatitude, min(maxLatitude, p.lat)) * .pi / 180
        let x = (p.lon + 180) / 360
        let y = (1 - log(tan(lat) + 1 / cos(lat)) / .pi) / 2
        return Mercator(x: x, y: y)
    }

    public static func unproject(_ m: Mercator) -> LonLat {
        let lon = m.x * 360 - 180
        let n = Double.pi - 2 * .pi * m.y
        let lat = 180 / .pi * atan(0.5 * (exp(n) - exp(-n)))
        return LonLat(lon: lon, lat: lat)
    }

    /// `floor(v)` clamped to 0…count-1, computed in Double so huge or non-finite input can't trap.
    public static func cell(_ v: Double, count: Int) -> Int {
        guard v.isFinite, count > 0 else { return 0 }
        return Int(max(0, min(Double(count - 1), v.rounded(.down))))
    }

    public static func tile(containing m: Mercator, z: Int) -> TileID {
        let z = max(0, min(24, z))
        let n = 1 << z
        return TileID(z: z, x: cell(m.x * Double(n), count: n), y: cell(m.y * Double(n), count: n))
    }

    /// North-west and south-east corners of a tile in world units.
    public static func bounds(_ t: TileID) -> (nw: Mercator, se: Mercator) {
        let n = Double(UInt64(1) << UInt64(t.z))
        return (Mercator(x: Double(t.x) / n, y: Double(t.y) / n), Mercator(x: Double(t.x + 1) / n, y: Double(t.y + 1) / n))
    }

    public static func geoBounds(_ t: TileID) -> BBox {
        let (nw, se) = bounds(t)
        let a = unproject(nw), b = unproject(se)
        return BBox(west: a.lon, south: b.lat, east: b.lon, north: a.lat)
    }

    public static func parent(_ t: TileID) -> TileID? {
        t.z == 0 ? nil : TileID(z: Int(t.z) - 1, x: Int(t.x >> 1), y: Int(t.y >> 1))
    }

    public static func children(_ t: TileID) -> [TileID] {
        let z = Int(t.z) + 1, x = Int(t.x) * 2, y = Int(t.y) * 2
        return [TileID(z: z, x: x, y: y), TileID(z: z, x: x + 1, y: y), TileID(z: z, x: x, y: y + 1), TileID(z: z, x: x + 1, y: y + 1)]
    }

    /// Ground metres per screen point at a latitude and zoom (256-point tiles).
    public static func metersPerPoint(lat: Double, zoom: Double) -> Double {
        40_075_016.686 * cos(lat * .pi / 180) / (256 * pow(2, zoom))
    }

    /// Tiles at integer zoom `min(maxZoom, floor(camera.zoom + 0.3))` covering the viewport,
    /// nearest to the centre first, at most `limit`. Above `maxZoom` the source tiles are reused
    /// (overzoom).
    public static func cover(_ cam: MapCamera, viewport: SIMD2<Double>, maxZoom: Int, limit: Int = 48) -> [TileID] {
        guard cam.zoom.isFinite, cam.center.x.isFinite, cam.center.y.isFinite else { return [] }
        let z = max(0, min(min(maxZoom, 24), Int(max(0, min(24, (cam.zoom + 0.3).rounded(.down))))))
        let proj = MapProjection(camera: cam, viewport: viewport)
        // Ground points under the viewport corners (and edge midpoints, for pitch).
        var pts: [Mercator] = []
        for sx in [0.0, 0.5, 1.0] { for sy in [0.0, 0.5, 1.0] {
            if let p = proj.groundPoint(screen: SIMD2(sx * viewport.x, sy * viewport.y)) { pts.append(p) }
        } }
        guard !pts.isEmpty else { return [] }
        let n = Double(1 << z)
        let count = 1 << z
        let minX = cell(pts.map(\.x).min()! * n, count: count), maxX = cell(pts.map(\.x).max()! * n, count: count)
        let minY = cell(pts.map(\.y).min()! * n, count: count), maxY = cell(pts.map(\.y).max()! * n, count: count)
        guard minX <= maxX, minY <= maxY else { return [] }
        let cx = cam.center.x * n, cy = cam.center.y * n
        var out: [(TileID, Double)] = []
        out.reserveCapacity((maxX - minX + 1) * (maxY - minY + 1))
        for x in minX...maxX { for y in minY...maxY {
            let dx = Double(x) + 0.5 - cx, dy = Double(y) + 0.5 - cy
            out.append((TileID(z: z, x: x, y: y), dx * dx + dy * dy))
        } }
        return out.sorted { $0.1 < $1.1 }.prefix(max(0, limit)).map(\.0)
    }
}

/// Camera → screen projection. World units are Mercator 0…1 scaled so one 256-point tile at
/// integer zoom z covers 256 points: worldScale = 256 · 2^zoom points per world unit. The camera
/// looks at `center` from above, rotated by `bearing`, tilted by `pitch` with a fixed 36.87° field
/// of view (the conventional web-map value).
public struct MapProjection: Sendable {
    public let camera: MapCamera
    public let viewport: SIMD2<Double>          // points
    /// Points per world unit at the camera's zoom.
    public let worldScale: Double
    /// World (Mercator 0…1, metres-free) → clip space.
    public let viewProjection: simd_double4x4
    public let inverse: simd_double4x4

    public static let fovY = 36.8699 * Double.pi / 180

    public init(camera: MapCamera, viewport: SIMD2<Double>) {
        self.camera = camera
        self.viewport = SIMD2(max(1, viewport.x), max(1, viewport.y))
        worldScale = 256 * pow(2, camera.zoom)
        let w = self.viewport.x, h = self.viewport.y
        let pitch = max(0, min(MapCamera.maxPitch, camera.pitch)) * .pi / 180
        let bearing = camera.bearing * .pi / 180
        // Camera distance (in points) so the ground plane at the centre is at 1:1 scale.
        let dist = 0.5 * h / tan(Self.fovY / 2)
        let near = max(1, dist * 0.05)
        let far = dist / max(0.1, cos(pitch + Self.fovY / 2 + 0.01)) * 1.5 + dist
        let proj = Self.perspective(fovY: Self.fovY, aspect: w / h, near: near, far: far)
        // View: translate world so the centre is at the origin (in points), rotate by bearing,
        // tilt by pitch, push back by dist. Screen y grows downward, like world y.
        var m = matrix_identity_double4x4
        m = Self.translate(-camera.center.x * worldScale, -camera.center.y * worldScale, 0) * m
        m = Self.rotateZ(-bearing) * m
        m = Self.rotateX(pitch) * m
        m = Self.translate(0, 0, -dist) * m
        // Flip y so world-down is screen-down in a y-up clip space.
        m = Self.scale(1, -1, 1) * m
        let world = Self.scale(worldScale, worldScale, worldScale) // world units → points
        viewProjection = proj * m * world
        inverse = viewProjection.inverse
    }

    /// World (Mercator) + height in metres → screen points (top-left origin). nil when behind the camera.
    public func screen(_ p: Mercator, heightMeters: Double = 0) -> SIMD2<Double>? {
        let z = heightMeters * Self.worldUnitsPerMeter(y: p.y)
        let c = viewProjection * SIMD4(p.x, p.y, z, 1)
        guard c.w > 1e-9 else { return nil }
        let ndc = SIMD2(c.x / c.w, c.y / c.w)
        return SIMD2((ndc.x + 1) / 2 * viewport.x, (1 - ndc.y) / 2 * viewport.y)
    }

    /// The ground point (height 0) under a screen point; nil above the horizon.
    public func groundPoint(screen s: SIMD2<Double>) -> Mercator? {
        let ndc = SIMD2(s.x / viewport.x * 2 - 1, 1 - s.y / viewport.y * 2)
        let a = inverse * SIMD4(ndc.x, ndc.y, 0, 1), b = inverse * SIMD4(ndc.x, ndc.y, 1, 1)
        guard abs(a.w) > 1e-12, abs(b.w) > 1e-12 else { return nil }
        let p0 = SIMD3(a.x, a.y, a.z) / a.w, p1 = SIMD3(b.x, b.y, b.z) / b.w
        let dz = p1.z - p0.z
        guard abs(dz) > 1e-15 else { return nil }
        let t = -p0.z / dz
        guard t >= 0 else { return nil }
        let hit = p0 + (p1 - p0) * t
        return Mercator(x: hit.x, y: hit.y)
    }

    /// World units per metre at a Mercator y.
    public static func worldUnitsPerMeter(y: Double) -> Double {
        let lat = TileMath.unproject(Mercator(x: 0, y: y)).lat * .pi / 180
        return 1 / (40_075_016.686 * max(1e-6, cos(lat)))
    }

    /// Matrix placing a tile's local 0…1 coordinates in clip space (Float, for the GPU).
    /// Heights in the vertex shader are multiplied by `worldUnitsPerMeter` of the tile's centre.
    public func tileMatrix(_ t: TileID) -> simd_float4x4 {
        let (nw, se) = TileMath.bounds(t)
        let local = Self.translate(nw.x, nw.y, 0) * Self.scale(se.x - nw.x, se.y - nw.y, 1)
        let m = viewProjection * local
        return simd_float4x4(columns: (SIMD4<Float>(m.columns.0), SIMD4<Float>(m.columns.1),
                                       SIMD4<Float>(m.columns.2), SIMD4<Float>(m.columns.3)))
    }

    // MARK: Matrix helpers

    static func perspective(fovY: Double, aspect: Double, near: Double, far: Double) -> simd_double4x4 {
        let y = 1 / tan(fovY / 2), x = y / aspect, z = far / (near - far)
        return simd_double4x4(columns: (SIMD4(x, 0, 0, 0), SIMD4(0, y, 0, 0), SIMD4(0, 0, z, -1), SIMD4(0, 0, z * near, 0)))
    }
    static func translate(_ x: Double, _ y: Double, _ z: Double) -> simd_double4x4 {
        var m = matrix_identity_double4x4; m.columns.3 = SIMD4(x, y, z, 1); return m
    }
    static func scale(_ x: Double, _ y: Double, _ z: Double) -> simd_double4x4 {
        simd_double4x4(diagonal: SIMD4(x, y, z, 1))
    }
    static func rotateZ(_ a: Double) -> simd_double4x4 {
        let c = cos(a), s = sin(a)
        return simd_double4x4(columns: (SIMD4(c, s, 0, 0), SIMD4(-s, c, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, 0, 0, 1)))
    }
    static func rotateX(_ a: Double) -> simd_double4x4 {
        let c = cos(a), s = sin(a)
        return simd_double4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, c, s, 0), SIMD4(0, -s, c, 0), SIMD4(0, 0, 0, 1)))
    }
}
