import Foundation
import simd

/// Turns polylines into triangle strips of `LineVertex` pairs. Positions are in whatever space the
/// caller supplies (the builder passes tile-local 0…1); the vertex shader expands each vertex by
/// `normal * side * halfWidthPx` in screen space, so geometry never depends on zoom.
public enum LineTessellator {
    /// Appends one polyline. Vertices come in pairs (side -1 then +1). Joins use a miter up to
    /// `miterLimit` (ratio of miter length to half width), beyond which they are bevelled. A closed
    /// polyline joins its last point to its first. Zero-length segments and non-finite points are
    /// dropped, so the output never contains NaN.
    public static func append(_ pts: [SIMD2<Float>], closed: Bool, cls: RenderClass, flags: UInt16,
                              miterLimit: Float = 2, vertices: inout [LineVertex], indices: inout [UInt32]) {
        // Clean: finite points, no consecutive duplicates (and no repeated closing point).
        var p: [SIMD2<Float>] = []
        p.reserveCapacity(pts.count)
        for q in pts where q.x.isFinite && q.y.isFinite {
            if let l = p.last, simd_length_squared(q - l) < 1e-14 { continue }
            p.append(q)
        }
        if closed, p.count > 1, simd_length_squared(p[0] - p[p.count - 1]) < 1e-14 { p.removeLast() }
        let n = p.count
        guard n >= 2, !(closed && n < 3) else { return }
        guard vertices.count + 2 * n + 4 * n < Int(UInt32.max) - 8 else { return }

        let segCount = closed ? n : n - 1
        var dir: [SIMD2<Float>] = []
        var alongAt: [Float] = [0]
        dir.reserveCapacity(segCount)
        alongAt.reserveCapacity(segCount + 1)
        var acc: Float = 0
        for k in 0..<segCount {
            let d = p[(k + 1) % n] - p[k]
            let len = simd_length(d)
            dir.append(len > 0 ? d / len : SIMD2<Float>(1, 0))
            acc += len
            alongAt.append(acc)
        }

        let cv = cls.rawValue
        func pair(_ pos: SIMD2<Float>, _ normal: SIMD2<Float>, _ along: Float) -> UInt32 {
            let base = UInt32(vertices.count)
            vertices.append(LineVertex(pos: pos, normal: normal, side: -1, along: along, cls: cv, flags: flags))
            vertices.append(LineVertex(pos: pos, normal: normal, side: 1, along: along, cls: cv, flags: flags))
            return base
        }
        func quad(_ a: UInt32, _ b: UInt32) {
            indices.append(contentsOf: [a, a + 1, b, a + 1, b + 1, b])
        }
        @inline(__always) func normalOf(_ d: SIMD2<Float>) -> SIMD2<Float> { SIMD2(-d.y, d.x) }

        /// Join at point `i` between segments `d0` (incoming) and `d1` (outgoing).
        /// Returns the (end pair of the incoming segment, start pair of the outgoing segment).
        func join(_ i: Int, _ d0: SIMD2<Float>, _ d1: SIMD2<Float>, along: Float) -> (UInt32, UInt32) {
            let n0 = normalOf(d0), n1 = normalOf(d1)
            let sum = n0 + n1
            let sl = simd_length(sum)
            if sl > 1e-4 {
                let m = sum / sl
                let cosHalf = simd_dot(m, n0)
                if cosHalf > 1e-4 {
                    let scale = 1 / cosHalf
                    if scale <= miterLimit {
                        let b = pair(p[i], m * scale, along)
                        return (b, b)
                    }
                }
            }
            let a = pair(p[i], n0, along)
            let b = pair(p[i], n1, along)
            // Fill the gap on the outer side of the turn with one triangle.
            let cross = d0.x * d1.y - d0.y * d1.x
            if cross > 0 {
                // Turning towards +normal side: the outer side is side -1.
                indices.append(contentsOf: [a, b, a + 1])
            } else {
                indices.append(contentsOf: [a + 1, b + 1, a])
            }
            return (a, b)
        }

        if !closed {
            var prev = pair(p[0], normalOf(dir[0]), 0)
            if n > 2 {
                for i in 1..<(n - 1) {
                    let (e, s) = join(i, dir[i - 1], dir[i], along: alongAt[i])
                    quad(prev, e)
                    prev = s
                }
            }
            let last = pair(p[n - 1], normalOf(dir[n - 2]), alongAt[n - 1])
            quad(prev, last)
        } else {
            let (closeEnd, first) = join(0, dir[n - 1], dir[0], along: 0)
            // The pair that closes the ring sits at the end of the last segment.
            var prev = first
            for i in 1..<n {
                let (e, s) = join(i, dir[i - 1], dir[i], along: alongAt[i])
                quad(prev, e)
                prev = s
            }
            // Last segment ends at point 0 with the incoming-side normal of the join there.
            let endPair: UInt32
            if closeEnd == first {
                // Mitered: duplicate the pair at the end with the full ring length as `along`.
                let v0 = vertices[Int(first)], v1 = vertices[Int(first) + 1]
                let base = UInt32(vertices.count)
                var a = v0, b = v1
                a.along = alongAt[n]; b.along = alongAt[n]
                vertices.append(a); vertices.append(b)
                endPair = base
            } else {
                let base = UInt32(vertices.count)
                let va = vertices[Int(closeEnd)], vb = vertices[Int(closeEnd) + 1]
                var a = va, b = vb
                a.along = alongAt[n]; b.along = alongAt[n]
                vertices.append(a); vertices.append(b)
                endPair = base
            }
            quad(prev, endPair)
        }
    }
}
