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
        if cam.isGlobe { return GlobeProjection(camera: cam, viewport: viewport).cover(maxZoom: maxZoom, limit: limit) }
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
/// What the renderer, labels, overlays and gestures need from a projection: flat (MapProjection)
/// or globe (GlobeProjection). `screen` returns nil for points that can't be seen (behind the
/// camera, or on the far side of the globe).
public protocol MapScreenProjection: Sendable {
    var camera: MapCamera { get }
    var viewport: SIMD2<Double> { get }
    /// Points per world unit at the camera's zoom.
    var worldScale: Double { get }
    func screen(_ p: Mercator, heightMeters: Double) -> SIMD2<Double>?
    func groundPoint(screen s: SIMD2<Double>) -> Mercator?
}

public extension MapScreenProjection {
    func screen(_ p: Mercator) -> SIMD2<Double>? { screen(p, heightMeters: 0) }
}

/// The projection for a camera: the globe below `MapCamera.globeZoom`, the flat map above.
public func mapProjection(camera: MapCamera, viewport: SIMD2<Double>) -> any MapScreenProjection {
    camera.isGlobe ? GlobeProjection(camera: camera, viewport: viewport) : MapProjection(camera: camera, viewport: viewport)
}

public struct MapProjection: MapScreenProjection {
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

// MARK: - Globe

/// The world as a sphere, seen from a camera looking at `camera.center`, rotated by `bearing`
/// (pitch is ignored). The sphere's circumference equals the flat map's width at the same zoom
/// and the camera distance matches the flat projection, so the centre is drawn at the same scale
/// in both and switching at `MapCamera.globeZoom` keeps what's under the centre in place.
/// Frame: unit sphere, the view centre on +z (toward the camera), north up (+y), east right (+x).
public struct GlobeProjection: MapScreenProjection {
    public let camera: MapCamera
    public let viewport: SIMD2<Double>
    public let worldScale: Double
    /// Sphere radius in points.
    public let radius: Double
    /// Camera distance from the sphere's surface, in points.
    public let distance: Double
    public let lon0: Double, lat0: Double          // radians
    /// Rotated unit-sphere frame → clip (no rotation: apply `rotation` first).
    public let viewProjection: simd_double4x4
    /// Sphere frame relative to lon0 → clip (rotation included), for the GPU.
    public var shaderMatrix: simd_double4x4 { viewProjection * Self.embed(rotation) }
    public let inverse: simd_double4x4
    /// Rotated frame → sphere frame relative to lon0 (undoes bearing and latitude tilt).
    public let inverseRotation: simd_double3x3
    /// Sphere frame (relative to lon0) → rotated frame.
    public let rotation: simd_double3x3
    /// A rotated point is visible when its z exceeds this (the horizon seen from the camera).
    public var horizonZ: Double { radius / (radius + distance) }

    public init(camera: MapCamera, viewport: SIMD2<Double>) {
        self.camera = camera
        self.viewport = SIMD2(max(1, viewport.x), max(1, viewport.y))
        worldScale = 256 * pow(2, camera.zoom)
        radius = worldScale / (2 * .pi)
        let h = self.viewport.y, w = self.viewport.x
        distance = 0.5 * h / tan(MapProjection.fovY / 2)
        let c = TileMath.unproject(camera.center)
        lon0 = c.lon * .pi / 180
        lat0 = max(-89, min(89, c.lat)) * .pi / 180
        let near = max(1, distance * 0.05)
        let far = distance + 2 * radius + 10
        let proj = MapProjection.perspective(fovY: MapProjection.fovY, aspect: w / h, near: near, far: far)
        let b = camera.bearing * .pi / 180
        // Unit sphere: tilt so lat0 faces the camera, rotate by bearing, scale to points, push back.
        let rx = Self.rotX(lat0), rz = Self.rotZ(b)
        var m = simd_double4x4(diagonal: SIMD4(radius, radius, radius, 1))
        m = MapProjection.translate(0, 0, -(radius + distance)) * m
        viewProjection = proj * m
        inverse = viewProjection.inverse
        rotation = rz * rx
        inverseRotation = (rz * rx).inverse
    }

    /// Unit vector for a geographic point, relative to lon0 (before tilt and bearing).
    func unit(_ ll: LonLat) -> SIMD3<Double> {
        let lat = ll.lat * .pi / 180, dl = ll.lon * .pi / 180 - lon0
        return SIMD3(cos(lat) * sin(dl), sin(lat), cos(lat) * cos(dl))
    }

    /// The point in the rotated (camera-facing) frame.
    func rotated(_ p: Mercator) -> SIMD3<Double> {
        rotation * unit(TileMath.unproject(p))
    }

    public func screen(_ p: Mercator, heightMeters: Double = 0) -> SIMD2<Double>? {
        let v = rotated(p)
        guard v.z > horizonZ else { return nil }
        let c = viewProjection * SIMD4(v, 1)
        guard c.w > 1e-9 else { return nil }
        return SIMD2((c.x / c.w + 1) / 2 * viewport.x, (1 - c.y / c.w) / 2 * viewport.y)
    }

    /// The point on the sphere under a screen point (nearest intersection); nil off the globe.
    public func groundPoint(screen s: SIMD2<Double>) -> Mercator? {
        let ndc = SIMD2(s.x / viewport.x * 2 - 1, 1 - s.y / viewport.y * 2)
        let a = inverse * SIMD4(ndc.x, ndc.y, 0, 1), b = inverse * SIMD4(ndc.x, ndc.y, 1, 1)
        guard abs(a.w) > 1e-12, abs(b.w) > 1e-12 else { return nil }
        let p0 = SIMD3(a.x, a.y, a.z) / a.w, p1 = SIMD3(b.x, b.y, b.z) / b.w
        let d = simd_normalize(p1 - p0)
        // |p0 + t d| = 1
        let bq = simd_dot(p0, d), cq = simd_dot(p0, p0) - 1
        let disc = bq * bq - cq
        guard disc >= 0 else { return nil }
        let t = -bq - disc.squareRoot()
        guard t >= 0 else { return nil }
        let u = inverseRotation * (p0 + d * t)
        let lat = asin(max(-1, min(1, u.y))) * 180 / .pi
        var lon = (atan2(u.x, u.z) + lon0) * 180 / .pi
        lon = (lon + 540).truncatingRemainder(dividingBy: 360) - 180
        return TileMath.project(LonLat(lon: lon, lat: max(-TileMath.maxLatitude, min(TileMath.maxLatitude, lat))))
    }

    /// Tiles on the visible side of the globe at zoom 2 (zoomed far out) or 3, nearest first.
    public func cover(maxZoom: Int, limit: Int) -> [TileID] {
        let z = max(0, min(maxZoom, camera.zoom < 2 ? 2 : 3))
        let n = 1 << z
        var out: [(TileID, Double)] = []
        for x in 0..<n { for y in 0..<n {
            let t = TileID(z: z, x: x, y: y)
            let (nw, se) = TileMath.bounds(t)
            // A tile is wanted when any of its corners or its centre faces the camera.
            let probes = [nw, se, Mercator(x: nw.x, y: se.y), Mercator(x: se.x, y: nw.y), Mercator(x: (nw.x + se.x) / 2, y: (nw.y + se.y) / 2)]
            let best = probes.map { rotated($0).z }.max() ?? -1
            if best > horizonZ - 0.15 { out.append((t, -rotated(probes[4]).z)) }
        } }
        return out.sorted { $0.1 < $1.1 }.prefix(max(0, limit)).map(\.0)
    }

    static func rotX(_ a: Double) -> simd_double3x3 {
        let c = cos(a), s = sin(a)
        // y' = y c - z s, z' = y s + z c
        return simd_double3x3(columns: (SIMD3(1, 0, 0), SIMD3(0, c, s), SIMD3(0, -s, c)))
    }
    static func rotZ(_ a: Double) -> simd_double3x3 {
        let c = cos(a), s = sin(a)
        return simd_double3x3(columns: (SIMD3(c, s, 0), SIMD3(-s, c, 0), SIMD3(0, 0, 1)))
    }
    public static func embed(_ m: simd_double3x3) -> simd_double4x4 {
        simd_double4x4(columns: (SIMD4(m.columns.0, 0), SIMD4(m.columns.1, 0), SIMD4(m.columns.2, 0), SIMD4(0, 0, 0, 1)))
    }
}

// MARK: - Gestures

/// Camera changes for pan, zoom and rotate, shared by the model and the map view so both apply a
/// gesture identically (the view shows it at once; the model follows at ≤ 30 Hz).
public enum MapGestureMath {
    public static func clamp(_ c: MapCamera) -> MapCamera {
        var c = c
        c.center = Mercator(x: min(1, max(0, c.center.x)), y: min(1, max(0, c.center.y)))
        c.zoom = min(MapCamera.maxZoom, max(MapCamera.minZoom, c.zoom))
        c.pitch = min(MapCamera.maxPitch, max(0, c.pitch))
        return c
    }

    /// Content moved by `delta` points.
    public static func pan(_ cam: MapCamera, by delta: SIMD2<Double>, viewport: SIMD2<Double>) -> MapCamera {
        var c = cam
        if cam.isGlobe {
            // Spin the globe: a drag of one radius turns it by one radian (bearing-aware).
            let g = GlobeProjection(camera: cam, viewport: viewport)
            let b = cam.bearing * .pi / 180
            let dx = delta.x * cos(b) + delta.y * sin(b), dy = -delta.x * sin(b) + delta.y * cos(b)
            let ll = TileMath.unproject(cam.center)
            let lat = max(-80, min(80, ll.lat + dy / g.radius * 180 / .pi))
            var lon = ll.lon - dx / g.radius * 180 / .pi / max(0.2, cos(ll.lat * .pi / 180))
            lon = (lon + 540).truncatingRemainder(dividingBy: 360) - 180
            c.center = TileMath.project(LonLat(lon: lon, lat: lat))
            return clamp(c)
        }
        let proj = MapProjection(camera: cam, viewport: viewport)
        let mid = viewport / 2
        guard let a = proj.groundPoint(screen: mid), let b = proj.groundPoint(screen: mid - delta) else { return cam }
        c.center = Mercator(x: cam.center.x + (b.x - a.x), y: cam.center.y + (b.y - a.y))
        return clamp(c)
    }

    /// Zoom by `dz` levels keeping the point under `around` in place (globe: around the centre).
    public static func zoom(_ cam: MapCamera, by dz: Double, around: SIMD2<Double>, viewport: SIMD2<Double>) -> MapCamera {
        var c = cam
        c.zoom = min(MapCamera.maxZoom, max(MapCamera.minZoom, cam.zoom + dz))
        guard !cam.isGlobe, !c.isGlobe else { return clamp(c) }
        let before = MapProjection(camera: cam, viewport: viewport).groundPoint(screen: around)
        if let before, let after = MapProjection(camera: c, viewport: viewport).groundPoint(screen: around) {
            c.center = Mercator(x: c.center.x + before.x - after.x, y: c.center.y + before.y - after.y)
        }
        return clamp(c)
    }

    public static func rotate(_ cam: MapCamera, bearing db: Double, pitch dp: Double) -> MapCamera {
        var c = cam
        var b = (cam.bearing + db).truncatingRemainder(dividingBy: 360)
        if b < 0 { b += 360 }
        c.bearing = b
        c.pitch = cam.pitch + dp
        return clamp(c)
    }
}
