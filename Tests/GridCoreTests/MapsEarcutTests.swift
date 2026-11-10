import XCTest
import simd
@testable import GridCore

final class MapsEarcutTests: XCTestCase {
    typealias V = SIMD2<Float>

    static func ringArea(_ r: [V]) -> Double {
        var a = 0.0
        for i in 0..<r.count {
            let p = r[i], q = r[(i + 1) % r.count]
            a += Double(p.x) * Double(q.y) - Double(q.x) * Double(p.y)
        }
        return abs(a) / 2
    }

    static func triangleArea(_ rings: [[V]], _ idx: [UInt32]) -> Double {
        let flat = rings.flatMap { $0 }
        var a = 0.0
        for t in stride(from: 0, to: idx.count, by: 3) {
            let p = flat[Int(idx[t])], q = flat[Int(idx[t + 1])], r = flat[Int(idx[t + 2])]
            a += abs((Double(q.x) - Double(p.x)) * (Double(r.y) - Double(p.y)) - (Double(r.x) - Double(p.x)) * (Double(q.y) - Double(p.y))) / 2
        }
        return a
    }

    static func expectedArea(_ rings: [[V]]) -> Double {
        ringArea(rings[0]) - rings.dropFirst().reduce(0) { $0 + ringArea($1) }
    }

    private func assertArea(_ rings: [[V]], tolerance: Double = 0.001, file: StaticString = #filePath, line: UInt = #line) {
        let idx = Earcut.triangulate(rings)
        let total = rings.reduce(0) { $0 + $1.count }
        XCTAssertEqual(idx.count % 3, 0, file: file, line: line)
        XCTAssertTrue(idx.allSatisfy { Int($0) < total }, "indices in range", file: file, line: line)
        let want = Self.expectedArea(rings), got = Self.triangleArea(rings, idx)
        XCTAssertEqual(got, want, accuracy: want * tolerance, file: file, line: line)
    }

    func testTriangleAndSquare() {
        XCTAssertEqual(Earcut.triangulate([[V(0, 0), V(1, 0), V(0, 1)]]).count, 3)
        let sq: [V] = [V(0, 0), V(10, 0), V(10, 10), V(0, 10)]
        XCTAssertEqual(Earcut.triangulate([sq]).count, 6)
        assertArea([sq])
        assertArea([sq.reversed()])   // winding of the input does not matter
    }

    func testSquareWithHole() {
        let outer: [V] = [V(0, 0), V(100, 0), V(100, 100), V(0, 100)]
        let hole: [V] = [V(30, 30), V(30, 70), V(70, 70), V(70, 30)]
        assertArea([outer, hole])
        assertArea([outer, hole.reversed()])
        XCTAssertEqual(Earcut.triangulate([outer, hole]).count, 24, "8 vertices, one hole: 8 triangles")
    }

    func testConcaveComb() {
        var comb: [V] = [V(0, 0)]
        let teeth = 12
        for i in 0..<teeth {
            let x = Float(i) * 10
            comb += [V(x + 2, 0), V(x + 2, 40), V(x + 8, 40), V(x + 8, 0)]
        }
        comb += [V(Float(teeth) * 10, 0), V(Float(teeth) * 10, -10), V(0, -10)]
        assertArea([comb])
    }

    func testLShapeStarAndCircle() {
        assertArea([[V(0, 0), V(10, 0), V(10, 4), V(4, 4), V(4, 10), V(0, 10)]])
        var star: [V] = []
        for i in 0..<20 {
            let a = Float(i) * .pi / 10, r: Float = i % 2 == 0 ? 50 : 20
            star.append(V(cos(a) * r, sin(a) * r))
        }
        assertArea([star])
        let circle = (0..<500).map { V(cos(Float($0) * 2 * .pi / 500) * 100, sin(Float($0) * 2 * .pi / 500) * 100) }
        assertArea([circle])   // exercises the z-order hash (> 80 vertices)
    }

    func testMultipleHoles() {
        let outer: [V] = [V(0, 0), V(100, 0), V(100, 100), V(0, 100)]
        var rings = [outer]
        for gx in 0..<4 { for gy in 0..<4 {
            let x = Float(gx) * 22 + 8, y = Float(gy) * 22 + 8
            rings.append([V(x, y), V(x, y + 10), V(x + 10, y + 10), V(x + 10, y)])
        } }
        assertArea(rings)
    }

    func testLargeBlockWithHolesAbout13kVertices() {
        let (rings, count) = Self.syntheticBlock()
        XCTAssertGreaterThan(count, 12_000)
        XCTAssertLessThan(count, 14_500)
        let start = Date()
        let idx = Earcut.triangulate(rings)
        let elapsed = Date().timeIntervalSince(start)
        let want = Self.expectedArea(rings), got = Self.triangleArea(rings, idx)
        XCTAssertEqual(got, want, accuracy: want * 0.001)
        XCTAssertLessThan(elapsed, 5, "must not hang")
        print("earcut \(count) vertices with holes: \(Int(elapsed * 1000)) ms")
    }

    /// A wobbly 4000-vertex outline with ~100 circular courtyards of 90 vertices each.
    static func syntheticBlock() -> ([[V]], Int) {
        var rings: [[V]] = []
        rings.append((0..<4000).map { i in
            let a = Double(i) * 2 * .pi / 4000, r = 100 + 2 * sin(a * 17)
            return V(Float(cos(a) * r), Float(sin(a) * r))
        })
        var x = -80.0
        while x <= 80 {
            var y = -80.0
            while y <= 80 {
                if x * x + y * y < 82 * 82 {
                    rings.append((0..<90).map { i in
                        let a = Double(i) * 2 * .pi / 90
                        return V(Float(x + cos(a) * 4), Float(y + sin(a) * 4))
                    })
                }
                y += 15
            }
            x += 15
        }
        return (rings, rings.reduce(0) { $0 + $1.count })
    }

    func testDegenerateInputsReturnAndDoNotHang() {
        XCTAssertEqual(Earcut.triangulate([]), [])
        XCTAssertEqual(Earcut.triangulate([[]]), [])
        XCTAssertEqual(Earcut.triangulate([[V(0, 0), V(1, 1)]]), [])
        // Collinear points: no area, no (or zero-area) triangles, but it returns.
        let line = (0..<50).map { V(Float($0), Float($0)) }
        let t = Earcut.triangulate([line])
        XCTAssertEqual(Self.triangleArea([line], t), 0, accuracy: 1e-6)
        // All points identical.
        _ = Earcut.triangulate([[V](repeating: V(3, 3), count: 200)])
        // Duplicated vertices around a square.
        let dup: [V] = [V(0, 0), V(0, 0), V(10, 0), V(10, 0), V(10, 10), V(10, 10), V(0, 10), V(0, 10)]
        XCTAssertEqual(Self.triangleArea([dup], Earcut.triangulate([dup])), 100, accuracy: 0.1)
        // Bow-tie (self-intersecting) and a hole outside the exterior: must return something finite.
        _ = Earcut.triangulate([[V(0, 0), V(10, 10), V(10, 0), V(0, 10)]])
        _ = Earcut.triangulate([[V(0, 0), V(10, 0), V(10, 10), V(0, 10)], [V(50, 50), V(50, 60), V(60, 60), V(60, 50)]])
        // Non-finite coordinates are rejected.
        XCTAssertEqual(Earcut.triangulate([[V(0, 0), V(.nan, 1), V(1, 0)]]), [])
        XCTAssertEqual(Earcut.triangulate([[V(0, 0), V(.infinity, 1), V(1, 0)]]), [])
    }

    func testRandomPolygonsNeverHang() {
        var rng = SplitMix64(seed: 123)
        for _ in 0..<300 {
            let n = Int.random(in: 3...150, using: &rng)
            let ring = (0..<n).map { _ in V(Float.random(in: -100...100, using: &rng), Float.random(in: -100...100, using: &rng)) }
            let hole = (0..<Int.random(in: 3...20, using: &rng)).map { _ in V(Float.random(in: -50...50, using: &rng), Float.random(in: -50...50, using: &rng)) }
            let t = Earcut.triangulate([ring, hole])
            XCTAssertEqual(t.count % 3, 0)
            XCTAssertTrue(t.allSatisfy { Int($0) < n + hole.count })
        }
    }
}
