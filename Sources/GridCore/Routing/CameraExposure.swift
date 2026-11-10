import Foundation

/// Which mapped ALPR cameras can see a route. A camera sees a stretch of road when the road passes
/// within `buffer` metres and, if the camera's facing is known, the road lies inside one of its
/// view cones (`coneDegrees` wide, centred on each `direction`). Facing 0° is north, a real
/// direction, not "unknown" (an empty list is unknown, which sees all round).
public struct ExposureOptions: Sendable, Equatable {
    public var buffer: Double = 75
    public var directional = true
    public var coneDegrees: Double = 70
    public init(buffer: Double = 75, directional: Bool = true, coneDegrees: Double = 70) {
        self.buffer = min(150, max(10, buffer)); self.directional = directional; self.coneDegrees = coneDegrees
    }
}

public enum ExposureLevel: String, Sendable { case low, medium, high, extreme
    public init(count: Int) { self = count == 0 ? .low : count <= 2 ? .medium : count <= 5 ? .high : .extreme }
}

public enum CameraExposure {
    /// A camera that sees a route: its index (as given), how far along the route (metres) and
    /// how close the road passes.
    public struct Hit: Sendable, Equatable { public var camera: Int; public var along: Double; public var distance: Double }

    /// Local flat metres around a latitude (good to well under 1% within a few km).
    struct Flat {
        let kx: Double, ky: Double
        init(lat: Double) { ky = 110_574; kx = 111_320 * cos(lat * .pi / 180) }
        func xy(_ p: LonLat) -> SIMD2<Double> { SIMD2(p.lon * kx, p.lat * ky) }
    }

    /// Bearing in degrees clockwise from north, from `a` to `b` (flat metres).
    static func bearing(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
        let d = b - a
        let deg = atan2(d.x, d.y) * 180 / .pi
        return deg < 0 ? deg + 360 : deg
    }

    /// Whether a camera at `c` facing `directions` sees a point `p` at distance `dist`.
    static func sees(_ c: SIMD2<Double>, _ directions: [UInt16], _ p: SIMD2<Double>, dist: Double, _ o: ExposureOptions) -> Bool {
        guard dist <= o.buffer else { return false }
        guard o.directional, !directions.isEmpty else { return true }
        if dist < 8 { return true }     // right beside it: whichever way it faces
        let b = bearing(c, p)
        let half = o.coneDegrees / 2
        return directions.contains { d in
            var diff = abs(b - Double(d)).truncatingRemainder(dividingBy: 360)
            if diff > 180 { diff = 360 - diff }
            return diff <= half
        }
    }

    /// Nearest point of segment ab to c, its distance and the fraction along ab.
    static func nearest(_ c: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>) -> (SIMD2<Double>, Double, Double) {
        let ab = b - a
        let l2 = (ab * ab).sum()
        let t = l2 > 0 ? min(1, max(0, ((c - a) * ab).sum() / l2)) : 0
        let p = a + ab * t
        let d = c - p
        return (p, (d * d).sum().squareRoot(), t)
    }

    /// Whether `c` is further than `reach` from the box around segment ab (so certainly further
    /// than that from the segment): a cheap test before the exact one.
    @inline(__always)
    static func isOutOfReach(_ c: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>, _ reach: Double) -> Bool {
        c.x < min(a.x, b.x) - reach || c.x > max(a.x, b.x) + reach || c.y < min(a.y, b.y) - reach || c.y > max(a.y, b.y) + reach
    }

    /// The nearest point of segment ab (inside the buffer) that the camera sees: its distance and
    /// fraction along ab, or nil. The part of ab within the buffer is checked at ≤ 4 m steps, so a
    /// road that enters the cone further along counts even when its nearest point is outside it.
    static func seen(_ c: SIMD2<Double>, _ dirs: [UInt16], _ a: SIMD2<Double>, _ b: SIMD2<Double>, _ o: ExposureOptions) -> (Double, Double)? {
        let (p, d, t) = nearest(c, a, b)
        guard d <= o.buffer else { return nil }
        if sees(c, dirs, p, dist: d, o) { return (d, t) }
        guard o.directional, !dirs.isEmpty else { return nil }
        // The interval of ab inside the buffer circle.
        let ab = b - a, len = (ab * ab).sum().squareRoot()
        guard len > 0 else { return nil }
        let half = (o.buffer * o.buffer - d * d).squareRoot() / len
        let t0 = max(0, t - half), t1 = min(1, t + half)
        let n = min(80, max(2, Int(((t1 - t0) * len / 4).rounded(.up))))
        var best: (Double, Double)?
        for k in 0...n {
            let tk = t0 + (t1 - t0) * Double(k) / Double(n)
            let q = a + ab * tk
            let dq = ((c - q) * (c - q)).sum().squareRoot()
            if sees(c, dirs, q, dist: dq, o), best == nil || dq < best!.0 { best = (dq, tk) }
        }
        return best
    }

    /// Route segments are boxed in runs of this many, so a camera is tested against a run's box
    /// before any of its segments (a long route has tens of thousands of segments and most
    /// cameras are near none of them).
    private static let segmentsPerBox = 32

    /// The cameras (of `candidates`, index → camera) that see the polyline, nearest pass each, in
    /// order along the route. A camera is checked at every segment it is near, so a road passing
    /// first outside and then inside its cone counts.
    public static func hits(route: [LonLat], candidates: [(Int, ALPRCamera)], options o: ExposureOptions = .init()) -> [Hit] {
        guard route.count >= 2, !candidates.isEmpty else { return [] }
        let flat = Flat(lat: route[route.count / 2].lat)
        let pts = route.map(flat.xy)
        let segmentCount = pts.count - 1
        // Distance from the start to each point.
        var reach = [0.0]
        reach.reserveCapacity(pts.count)
        for i in 1..<pts.count { let d = pts[i] - pts[i - 1]; reach.append(reach[i - 1] + (d * d).sum().squareRoot()) }
        // The box around each run of segments.
        var boxes: [(lo: SIMD2<Double>, hi: SIMD2<Double>)] = []
        boxes.reserveCapacity(segmentCount / segmentsPerBox + 1)
        for first in stride(from: 0, to: segmentCount, by: segmentsPerBox) {
            var lo = pts[first], hi = pts[first]
            for i in (first + 1)...min(first + segmentsPerBox, segmentCount) {
                lo = lo.replacing(with: pts[i], where: pts[i] .< lo)
                hi = hi.replacing(with: pts[i], where: pts[i] .> hi)
            }
            boxes.append((lo, hi))
        }

        var out: [Hit] = []
        for (index, camera) in candidates {
            let c = flat.xy(camera.coordinate)
            var best: Hit?
            for (run, box) in boxes.enumerated() {
                if c.x < box.lo.x - o.buffer || c.x > box.hi.x + o.buffer || c.y < box.lo.y - o.buffer || c.y > box.hi.y + o.buffer { continue }
                let first = run * segmentsPerBox
                for i in first..<min(first + segmentsPerBox, segmentCount) {
                    let a = pts[i], b = pts[i + 1]
                    if isOutOfReach(c, a, b, o.buffer) { continue }
                    guard let (d, t) = seen(c, camera.directions, a, b, o) else { continue }
                    if best == nil || d < best!.distance {
                        best = Hit(camera: index, along: reach[i] + (reach[i + 1] - reach[i]) * t, distance: d)
                    }
                }
            }
            if let best { out.append(best) }
        }
        return out.sorted { $0.along < $1.along }
    }

    /// The cost of passing a camera in an avoiding search, in seconds: high enough that a route
    /// takes a long detour around it, higher the closer the road passes.
    public static func penaltySeconds(distance: Double, buffer: Double) -> Float {
        Float(600 + 900 * max(0, 1 - distance / max(1, buffer)))
    }
}
