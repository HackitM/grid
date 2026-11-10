import Foundation
import simd

// Polygon triangulation: a Swift port of mapbox/earcut (https://github.com/mapbox/earcut),
// Copyright (c) 2016, Mapbox, ISC License:
//
//   Permission to use, copy, modify, and/or distribute this software for any purpose with or
//   without fee is hereby granted, provided that the above copyright notice and this permission
//   notice appear in all copies.
//
//   THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH REGARD TO THIS
//   SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL
//   THE AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY
//   DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF
//   CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE
//   OR PERFORMANCE OF THIS SOFTWARE.
//
// The linked lists are index-based (no class allocations). Differences from the original: input
// with non-finite coordinates yields no triangles, and the work is bounded. Ear clipping is fast on
// real map polygons but quadratic or worse on ones built to defeat it (combs, self-intersecting
// scribbles), and tiles are untrusted, so every loop draws on one budget of steps, counted where
// the time actually goes (the scans inside the ear, diagonal and hole tests). When it runs out the
// triangles found so far are returned. The budget is far above what real polygons use.

public enum Earcut {
    /// Node indices are Int32 and each split adds two nodes: far more points than any tile holds.
    static let maxPoints = 1 << 24
    /// Steps one polygon may take: generous for real data (a 50 000 point coastline with
    /// hundreds of islands uses a few million; a hostile one is cut off after roughly 0.1 s).
    static func stepBudget(points: Int) -> Int { 10_000_000 + 1_000 * points }
    /// Nested polygon splits allowed. Each level is a few stack frames, and tiles are decoded on
    /// threads with small stacks.
    static let maxSplitDepth = 64

    /// rings[0] exterior, rest holes; returns triangle indices into the rings flattened in order.
    public static func triangulate(_ rings: [[SIMD2<Float>]]) -> [UInt32] {
        var steps = Int.max
        return triangulate(rings, steps: &steps)
    }

    /// The same, drawing on a caller's step budget as well (a tile's, shared by all its
    /// polygons); what was used is taken off `steps`.
    static func triangulate(_ rings: [[SIMD2<Float>]], steps: inout Int) -> [UInt32] {
        guard let outer = rings.first, outer.count >= 3, steps > 0 else { return [] }
        var total = 0
        for r in rings {
            total += r.count
            for p in r where !(p.x.isFinite && p.y.isFinite) { return [] }
        }
        guard total <= maxPoints else { return [] }
        var e = Triangulator(capacity: total + rings.count * 2)
        let allowed = min(steps, stepBudget(points: total))
        e.budget = allowed
        let triangles = e.run(rings, total: total)
        steps -= allowed - max(0, e.budget)
        return triangles
    }

    private struct Node {
        var i: Int32
        var x: Double
        var y: Double
        var prev: Int32 = -1
        var next: Int32 = -1
        var z: Int32 = 0
        var prevZ: Int32 = -1
        var nextZ: Int32 = -1
        var steiner = false
    }

    private struct Triangulator {
        var n: [Node] = []
        var tris: [UInt32] = []
        var budget = 0
        var minX = 0.0, minY = 0.0, invSize = 0.0
        var depth = 0

        init(capacity: Int) { n.reserveCapacity(capacity) }

        mutating func run(_ rings: [[SIMD2<Float>]], total: Int) -> [UInt32] {
            tris.reserveCapacity(total * 3)
            var start = 0
            guard var outer = linkedList(rings[0], start: start, clockwise: true), n[Int(outer)].next != n[Int(outer)].prev else { return [] }
            start += rings[0].count
            if rings.count > 1 {
                var queue: [Int32] = []
                for hi in 1..<rings.count {
                    let ring = rings[hi]
                    if ring.count >= 3, let list = linkedList(ring, start: start, clockwise: false) {
                        if n[Int(list)].next == list { n[Int(list)].steiner = true }
                        queue.append(leftmost(list))
                    }
                    start += ring.count
                }
                queue.sort { n[Int($0)].x < n[Int($1)].x }
                for h in queue { outer = eliminateHole(h, outer) }
            }
            if total > 80 {
                var mnx = Double.infinity, mny = Double.infinity, mxx = -Double.infinity, mxy = -Double.infinity
                for p in rings[0] {
                    let x = Double(p.x), y = Double(p.y)
                    mnx = min(mnx, x); mny = min(mny, y); mxx = max(mxx, x); mxy = max(mxy, y)
                }
                minX = mnx; minY = mny
                let size = max(mxx - mnx, mxy - mny)
                invSize = size > 1e-30 ? 32767 / size : 0
            }
            earcutLinked(outer, pass: 0)
            return tris
        }

        // MARK: Linked list

        @inline(__always) func nx(_ p: Int32) -> Int32 { n[Int(p)].next }
        @inline(__always) func pv(_ p: Int32) -> Int32 { n[Int(p)].prev }

        mutating func linkedList(_ ring: [SIMD2<Float>], start: Int, clockwise: Bool) -> Int32? {
            guard !ring.isEmpty else { return nil }
            var sum = 0.0
            var j = ring.count - 1
            for i in 0..<ring.count {
                sum += (Double(ring[j].x) - Double(ring[i].x)) * (Double(ring[i].y) + Double(ring[j].y))
                j = i
            }
            var last: Int32 = -1
            if clockwise == (sum > 0) {
                for i in 0..<ring.count { last = insertNode(Int32(start + i), ring[i], last) }
            } else {
                for i in stride(from: ring.count - 1, through: 0, by: -1) { last = insertNode(Int32(start + i), ring[i], last) }
            }
            if last >= 0, equals(last, nx(last)) {
                removeNode(last)
                last = nx(last)
            }
            return last >= 0 ? last : nil
        }

        mutating func insertNode(_ i: Int32, _ p: SIMD2<Float>, _ last: Int32) -> Int32 {
            let id = Int32(n.count)
            var node = Node(i: i, x: Double(p.x), y: Double(p.y))
            if last < 0 {
                node.prev = id; node.next = id
                n.append(node)
            } else {
                node.next = n[Int(last)].next
                node.prev = last
                n.append(node)
                n[Int(n[Int(last)].next)].prev = id
                n[Int(last)].next = id
            }
            return id
        }

        mutating func removeNode(_ p: Int32) {
            let node = n[Int(p)]
            n[Int(node.next)].prev = node.prev
            n[Int(node.prev)].next = node.next
            if node.prevZ >= 0 { n[Int(node.prevZ)].nextZ = node.nextZ }
            if node.nextZ >= 0 { n[Int(node.nextZ)].prevZ = node.prevZ }
        }

        @inline(__always) func equals(_ a: Int32, _ b: Int32) -> Bool {
            n[Int(a)].x == n[Int(b)].x && n[Int(a)].y == n[Int(b)].y
        }

        @inline(__always) func area(_ p: Int32, _ q: Int32, _ r: Int32) -> Double {
            let P = n[Int(p)], Q = n[Int(q)], R = n[Int(r)]
            return (Q.y - P.y) * (R.x - Q.x) - (Q.x - P.x) * (R.y - Q.y)
        }

        mutating func filterPoints(_ start: Int32, _ endIn: Int32 = -1) -> Int32 {
            var end = endIn < 0 ? start : endIn
            var p = start
            var again = false
            var guardSteps = n.count * 4 + 16
            repeat {
                again = false
                guardSteps -= 1
                budget -= 1
                if guardSteps < 0 || budget < 0 { break }
                let node = n[Int(p)]
                if !node.steiner && (equals(p, node.next) || area(node.prev, p, node.next) == 0) {
                    removeNode(p)
                    p = node.prev
                    end = p
                    if p == n[Int(p)].next { break }
                    again = true
                } else {
                    p = node.next
                }
            } while again || p != end
            return end
        }

        // MARK: Main loop

        mutating func earcutLinked(_ earIn: Int32, pass: Int) {
            guard earIn >= 0 else { return }
            var ear = earIn
            if pass == 0 && invSize != 0 { indexCurve(ear) }
            var stop = ear
            while pv(ear) != nx(ear) {
                budget -= 1
                if budget < 0 { return }
                let prev = pv(ear), next = nx(ear)
                if invSize != 0 ? isEarHashed(ear) : isEar(ear) {
                    tris.append(UInt32(n[Int(prev)].i))
                    tris.append(UInt32(n[Int(ear)].i))
                    tris.append(UInt32(n[Int(next)].i))
                    removeNode(ear)
                    ear = nx(next)
                    stop = nx(next)
                    continue
                }
                ear = next
                if ear == stop {
                    if pass == 0 {
                        earcutLinked(filterPoints(ear), pass: 1)
                    } else if pass == 1 {
                        let e2 = cureLocalIntersections(filterPoints(ear))
                        earcutLinked(e2, pass: 2)
                    } else if pass == 2 {
                        splitEarcut(ear)
                    }
                    break
                }
            }
        }

        mutating func isEar(_ ear: Int32) -> Bool {
            let a = pv(ear), c = nx(ear)
            if area(a, ear, c) >= 0 { return false }
            let A = n[Int(a)], B = n[Int(ear)], C = n[Int(c)]
            let x0 = min(A.x, B.x, C.x), y0 = min(A.y, B.y, C.y), x1 = max(A.x, B.x, C.x), y1 = max(A.y, B.y, C.y)
            var p = nx(c)
            while p != a {
                budget -= 1
                if budget < 0 { return false }
                let P = n[Int(p)]
                if P.x >= x0 && P.x <= x1 && P.y >= y0 && P.y <= y1
                    && pointInTriangleExceptFirst(A.x, A.y, B.x, B.y, C.x, C.y, P.x, P.y)
                    && area(P.prev, p, P.next) >= 0 { return false }
                p = P.next
            }
            return true
        }

        mutating func isEarHashed(_ ear: Int32) -> Bool {
            let a = pv(ear), c = nx(ear)
            if area(a, ear, c) >= 0 { return false }
            let A = n[Int(a)], B = n[Int(ear)], C = n[Int(c)]
            let x0 = min(A.x, B.x, C.x), y0 = min(A.y, B.y, C.y), x1 = max(A.x, B.x, C.x), y1 = max(A.y, B.y, C.y)
            let minZ = zOrder(x0, y0), maxZ = zOrder(x1, y1)
            var p = B.prevZ, q = B.nextZ
            @inline(__always) func hit(_ id: Int32) -> Bool {
                let P = n[Int(id)]
                return P.x >= x0 && P.x <= x1 && P.y >= y0 && P.y <= y1 && id != a && id != c
                    && pointInTriangleExceptFirst(A.x, A.y, B.x, B.y, C.x, C.y, P.x, P.y)
                    && area(P.prev, id, P.next) >= 0
            }
            while p >= 0 && n[Int(p)].z >= minZ && q >= 0 && n[Int(q)].z <= maxZ {
                budget -= 2
                if budget < 0 { return false }
                if hit(p) { return false }
                p = n[Int(p)].prevZ
                if hit(q) { return false }
                q = n[Int(q)].nextZ
            }
            while p >= 0 && n[Int(p)].z >= minZ {
                budget -= 1
                if budget < 0 { return false }
                if hit(p) { return false }
                p = n[Int(p)].prevZ
            }
            while q >= 0 && n[Int(q)].z <= maxZ {
                budget -= 1
                if budget < 0 { return false }
                if hit(q) { return false }
                q = n[Int(q)].nextZ
            }
            return true
        }

        mutating func cureLocalIntersections(_ startIn: Int32) -> Int32 {
            var start = startIn
            var p = start
            var steps = n.count * 4 + 16
            repeat {
                steps -= 1
                if steps < 0 { break }
                let a = pv(p), b = nx(nx(p))
                if !equals(a, b) && intersects(a, p, nx(p), b) && locallyInside(a, b) && locallyInside(b, a) {
                    tris.append(UInt32(n[Int(a)].i))
                    tris.append(UInt32(n[Int(p)].i))
                    tris.append(UInt32(n[Int(b)].i))
                    removeNode(p)
                    removeNode(nx(p))
                    start = b
                    p = b
                }
                p = nx(p)
            } while p != start
            return filterPoints(p)
        }

        mutating func splitEarcut(_ start: Int32) {
            var a = start
            repeat {
                var b = nx(nx(a))
                while b != pv(a) {
                    budget -= 1
                    if budget < 0 { return }
                    if n[Int(a)].i != n[Int(b)].i && isValidDiagonal(a, b) {
                        var c = splitPolygon(a, b)
                        a = filterPoints(a, nx(a))
                        c = filterPoints(c, nx(c))
                        depth += 1
                        if depth < Earcut.maxSplitDepth {
                            earcutLinked(a, pass: 0)
                            earcutLinked(c, pass: 0)
                        }
                        depth -= 1
                        return
                    }
                    b = nx(b)
                }
                a = nx(a)
            } while a != start
        }

        // MARK: Holes

        mutating func eliminateHole(_ hole: Int32, _ outer: Int32) -> Int32 {
            guard let bridge = findHoleBridge(hole, outer) else { return outer }
            let bridgeReverse = splitPolygon(bridge, hole)
            _ = filterPoints(bridgeReverse, nx(bridgeReverse))
            return filterPoints(bridge, nx(bridge))
        }

        mutating func findHoleBridge(_ hole: Int32, _ outer: Int32) -> Int32? {
            var p = outer
            let hx = n[Int(hole)].x, hy = n[Int(hole)].y
            var qx = -Double.infinity
            var m: Int32 = -1
            var steps = n.count + 4
            repeat {
                steps -= 1
                budget -= 1
                if steps < 0 || budget < 0 { return nil }
                let P = n[Int(p)], N = n[Int(P.next)]
                if equals(hole, p) { return p }
                if hy <= P.y && hy >= N.y && N.y != P.y {
                    let x = P.x + (hy - P.y) * (N.x - P.x) / (N.y - P.y)
                    if x <= hx && x > qx {
                        qx = x
                        m = P.x < N.x ? p : P.next
                        if x == hx { return m }
                    }
                }
                p = P.next
            } while p != outer
            if m < 0 { return nil }

            let stop = m
            let mx = n[Int(m)].x, my = n[Int(m)].y
            var tanMin = Double.infinity
            p = m
            steps = n.count + 4
            repeat {
                steps -= 1
                budget -= 1
                if steps < 0 || budget < 0 { break }
                let P = n[Int(p)]
                if hx >= P.x && P.x >= mx && hx != P.x
                    && pointInTriangle(hy < my ? hx : qx, hy, mx, my, hy < my ? qx : hx, hy, P.x, P.y) {
                    let t = abs(hy - P.y) / (hx - P.x)
                    if locallyInside(p, hole)
                        && (t < tanMin || (t == tanMin && (P.x > n[Int(m)].x || (P.x == n[Int(m)].x && sectorContainsSector(m, p))))) {
                        m = p
                        tanMin = t
                    }
                }
                p = P.next
            } while p != stop
            return m
        }

        func sectorContainsSector(_ m: Int32, _ p: Int32) -> Bool {
            area(pv(m), m, pv(p)) < 0 && area(nx(p), m, nx(m)) < 0
        }

        func leftmost(_ start: Int32) -> Int32 {
            var p = start, lm = start
            var steps = n.count + 4
            repeat {
                steps -= 1
                if steps < 0 { break }
                let P = n[Int(p)], L = n[Int(lm)]
                if P.x < L.x || (P.x == L.x && P.y < L.y) { lm = p }
                p = P.next
            } while p != start
            return lm
        }

        // MARK: z-order curve

        mutating func indexCurve(_ start: Int32) {
            var p = start
            var steps = n.count + 4
            repeat {
                steps -= 1
                if steps < 0 { break }
                if n[Int(p)].z == 0 { n[Int(p)].z = zOrder(n[Int(p)].x, n[Int(p)].y) }
                n[Int(p)].prevZ = n[Int(p)].prev
                n[Int(p)].nextZ = n[Int(p)].next
                p = n[Int(p)].next
            } while p != start
            let pz = n[Int(p)].prevZ
            if pz >= 0 { n[Int(pz)].nextZ = -1 }
            n[Int(p)].prevZ = -1
            sortLinked(p)
        }

        mutating func sortLinked(_ listIn: Int32) {
            var list = listIn
            var inSize = 1
            var numMerges = 0
            repeat {
                var p = list
                list = -1
                var tail: Int32 = -1
                numMerges = 0
                while p >= 0 {
                    numMerges += 1
                    var q = p
                    var pSize = 0
                    for _ in 0..<inSize {
                        pSize += 1
                        q = n[Int(q)].nextZ
                        if q < 0 { break }
                    }
                    var qSize = inSize
                    while pSize > 0 || (qSize > 0 && q >= 0) {
                        let e: Int32
                        if pSize != 0 && (qSize == 0 || q < 0 || n[Int(p)].z <= n[Int(q)].z) {
                            e = p; p = n[Int(p)].nextZ; pSize -= 1
                        } else {
                            e = q; q = n[Int(q)].nextZ; qSize -= 1
                        }
                        if tail >= 0 { n[Int(tail)].nextZ = e } else { list = e }
                        n[Int(e)].prevZ = tail
                        tail = e
                    }
                    p = q
                }
                if tail >= 0 { n[Int(tail)].nextZ = -1 }
                inSize *= 2
            } while numMerges > 1 && inSize < (1 << 30)
        }

        func zOrder(_ xIn: Double, _ yIn: Double) -> Int32 {
            var x = Int32(max(0, min(32767, ((xIn - minX) * invSize).rounded(.towardZero))))
            var y = Int32(max(0, min(32767, ((yIn - minY) * invSize).rounded(.towardZero))))
            x = (x | (x << 8)) & 0x00FF00FF
            x = (x | (x << 4)) & 0x0F0F0F0F
            x = (x | (x << 2)) & 0x33333333
            x = (x | (x << 1)) & 0x55555555
            y = (y | (y << 8)) & 0x00FF00FF
            y = (y | (y << 4)) & 0x0F0F0F0F
            y = (y | (y << 2)) & 0x33333333
            y = (y | (y << 1)) & 0x55555555
            return x | (y << 1)
        }

        // MARK: Geometry predicates

        @inline(__always) func pointInTriangle(_ ax: Double, _ ay: Double, _ bx: Double, _ by: Double,
                                               _ cx: Double, _ cy: Double, _ px: Double, _ py: Double) -> Bool {
            (cx - px) * (ay - py) >= (ax - px) * (cy - py)
                && (ax - px) * (by - py) >= (bx - px) * (ay - py)
                && (bx - px) * (cy - py) >= (cx - px) * (by - py)
        }

        @inline(__always) func pointInTriangleExceptFirst(_ ax: Double, _ ay: Double, _ bx: Double, _ by: Double,
                                                          _ cx: Double, _ cy: Double, _ px: Double, _ py: Double) -> Bool {
            !(ax == px && ay == py) && pointInTriangle(ax, ay, bx, by, cx, cy, px, py)
        }

        mutating func isValidDiagonal(_ a: Int32, _ b: Int32) -> Bool {
            let A = n[Int(a)], B = n[Int(b)]
            if n[Int(A.next)].i == B.i || n[Int(A.prev)].i == B.i { return false }
            if intersectsPolygon(a, b) { return false }
            if locallyInside(a, b) && locallyInside(b, a) && middleInside(a, b)
                && (area(A.prev, a, B.prev) != 0 || area(a, B.prev, b) != 0) { return true }
            return equals(a, b) && area(A.prev, a, A.next) > 0 && area(B.prev, b, B.next) > 0
        }

        @inline(__always) func sign(_ v: Double) -> Int { v > 0 ? 1 : (v < 0 ? -1 : 0) }

        func onSegment(_ p: Int32, _ q: Int32, _ r: Int32) -> Bool {
            let P = n[Int(p)], Q = n[Int(q)], R = n[Int(r)]
            return Q.x <= max(P.x, R.x) && Q.x >= min(P.x, R.x) && Q.y <= max(P.y, R.y) && Q.y >= min(P.y, R.y)
        }

        func intersects(_ p1: Int32, _ q1: Int32, _ p2: Int32, _ q2: Int32) -> Bool {
            let o1 = sign(area(p1, q1, p2)), o2 = sign(area(p1, q1, q2))
            let o3 = sign(area(p2, q2, p1)), o4 = sign(area(p2, q2, q1))
            if o1 != o2 && o3 != o4 { return true }
            if o1 == 0 && onSegment(p1, p2, q1) { return true }
            if o2 == 0 && onSegment(p1, q2, q1) { return true }
            if o3 == 0 && onSegment(p2, p1, q2) { return true }
            if o4 == 0 && onSegment(p2, q1, q2) { return true }
            return false
        }

        mutating func intersectsPolygon(_ a: Int32, _ b: Int32) -> Bool {
            var p = a
            let ai = n[Int(a)].i, bi = n[Int(b)].i
            var steps = n.count + 4
            repeat {
                steps -= 1
                budget -= 1
                if steps < 0 || budget < 0 { return true }
                let P = n[Int(p)]
                let pn = n[Int(P.next)].i
                if P.i != ai && pn != ai && P.i != bi && pn != bi && intersects(p, P.next, a, b) { return true }
                p = P.next
            } while p != a
            return false
        }

        func locallyInside(_ a: Int32, _ b: Int32) -> Bool {
            let A = n[Int(a)]
            return area(A.prev, a, A.next) < 0
                ? area(a, b, A.next) >= 0 && area(a, A.prev, b) >= 0
                : area(a, b, A.prev) < 0 || area(a, A.next, b) < 0
        }

        mutating func middleInside(_ a: Int32, _ b: Int32) -> Bool {
            var p = a
            var inside = false
            let px = (n[Int(a)].x + n[Int(b)].x) / 2, py = (n[Int(a)].y + n[Int(b)].y) / 2
            var steps = n.count + 4
            repeat {
                steps -= 1
                budget -= 1
                if steps < 0 || budget < 0 { return false }
                let P = n[Int(p)], N = n[Int(P.next)]
                if (P.y > py) != (N.y > py) && N.y != P.y && px < (N.x - P.x) * (py - P.y) / (N.y - P.y) + P.x { inside.toggle() }
                p = P.next
            } while p != a
            return inside
        }

        mutating func splitPolygon(_ a: Int32, _ b: Int32) -> Int32 {
            let a2 = Int32(n.count), b2 = a2 + 1
            n.append(Node(i: n[Int(a)].i, x: n[Int(a)].x, y: n[Int(a)].y))
            n.append(Node(i: n[Int(b)].i, x: n[Int(b)].x, y: n[Int(b)].y))
            let an = n[Int(a)].next, bp = n[Int(b)].prev
            n[Int(a)].next = b; n[Int(b)].prev = a
            n[Int(a2)].next = an; n[Int(an)].prev = a2
            n[Int(b2)].next = a2; n[Int(a2)].prev = b2
            n[Int(bp)].next = b2; n[Int(b2)].prev = bp
            return b2
        }
    }
}
