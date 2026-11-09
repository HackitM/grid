import XCTest
import simd
@testable import GridCore

final class MapsLineTests: XCTestCase {
    typealias V = SIMD2<Float>

    private func tess(_ pts: [V], closed: Bool = false, flags: UInt16 = 0, miter: Float = 2) -> ([LineVertex], [UInt32]) {
        var v: [LineVertex] = [], i: [UInt32] = []
        LineTessellator.append(pts, closed: closed, cls: .primary, flags: flags, miterLimit: miter, vertices: &v, indices: &i)
        return (v, i)
    }

    private func assertSane(_ v: [LineVertex], _ i: [UInt32], maxNormal: Float = 2.0001, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(i.count % 3, 0, file: file, line: line)
        XCTAssertTrue(i.allSatisfy { Int($0) < v.count }, "indices in range", file: file, line: line)
        for x in v {
            XCTAssertTrue(x.pos.x.isFinite && x.pos.y.isFinite && x.normal.x.isFinite && x.normal.y.isFinite && x.along.isFinite, "finite", file: file, line: line)
            XCTAssertLessThanOrEqual(simd_length(x.normal), maxNormal, file: file, line: line)
            XCTAssertTrue(x.side == -1 || x.side == 1, file: file, line: line)
        }
    }

    func testStraightSegment() {
        let (v, i) = tess([V(0.1, 0.5), V(0.6, 0.5)], flags: LineVertex.tunnel)
        XCTAssertEqual(v.count, 4)
        XCTAssertEqual(i.count, 6)
        assertSane(v, i)
        XCTAssertEqual(v.map(\.side), [-1, 1, -1, 1])
        XCTAssertEqual(v[0].normal, V(0, 1))        // left of +x in y-down math is +y
        XCTAssertEqual(v[0].along, 0)
        XCTAssertEqual(v[2].along, 0.5, accuracy: 1e-6)
        XCTAssertTrue(v.allSatisfy { $0.cls == RenderClass.primary.rawValue && $0.flags == LineVertex.tunnel })
        XCTAssertTrue(v.allSatisfy { abs(simd_length($0.normal) - 1) < 1e-6 })
    }

    func testRightAngleUsesMiter() {
        let (v, i) = tess([V(0, 0), V(0.5, 0), V(0.5, 0.5)])
        assertSane(v, i)
        XCTAssertEqual(v.count, 6, "one shared pair at the joint")
        XCTAssertEqual(i.count, 12)
        let joint = v[2]
        XCTAssertEqual(simd_length(joint.normal), Float(2).squareRoot(), accuracy: 1e-5)
    }

    func testSharpTurnBevels() {
        // About 170 degrees back on itself: a miter would be ~11x.
        let (v, i) = tess([V(0, 0), V(0.5, 0), V(0, 0.05)])
        assertSane(v, i)
        XCTAssertEqual(v.count, 8, "joint is split into two pairs")
        XCTAssertEqual(i.count, 2 * 6 + 3, "two quads and one bevel triangle")
    }

    func testMiterLimitRespected() {
        // 90 degree turn has scale sqrt(2) = 1.414: allowed at limit 2, bevelled at limit 1.2.
        let pts = [V(0, 0), V(0.5, 0), V(0.5, 0.5)]
        XCTAssertEqual(tess(pts, miter: 2).0.count, 6)
        XCTAssertEqual(tess(pts, miter: 1.2).0.count, 8)
    }

    func testExactReversalDoesNotProduceNaN() {
        let (v, i) = tess([V(0, 0), V(0.5, 0), V(0, 0)])
        assertSane(v, i)
        XCTAssertFalse(i.isEmpty)
    }

    func testZeroLengthSegmentsAndNonFinitePoints() {
        let (v, i) = tess([V(0.1, 0.1), V(0.1, 0.1), V(0.1, 0.1), V(0.4, 0.1), V(.nan, 0.2), V(0.4, 0.4), V(0.4, 0.4)])
        assertSane(v, i)
        XCTAssertEqual(v.count, 6)
        XCTAssertTrue(tess([V(0.2, 0.2), V(0.2, 0.2)]).0.isEmpty)
        XCTAssertTrue(tess([V(0.2, 0.2)]).0.isEmpty)
        XCTAssertTrue(tess([]).0.isEmpty)
    }

    func testAlongAccumulates() {
        let (v, _) = tess([V(0, 0), V(0.25, 0), V(0.25, 0.25), V(0.75, 0.25)])
        XCTAssertEqual(v.last!.along, 1.0, accuracy: 1e-6)
        XCTAssertEqual(v[2].along, 0.25, accuracy: 1e-6)
    }

    func testClosedRingJoinsEndToStart() {
        let sq: [V] = [V(0.1, 0.1), V(0.9, 0.1), V(0.9, 0.9), V(0.1, 0.9)]
        let (v, i) = tess(sq, closed: true)
        assertSane(v, i)
        XCTAssertEqual(i.count, 4 * 6, "four quads, no gap")
        // The closing quad reaches back to the first point.
        let used = Set(i.suffix(6).map { v[Int($0)].pos })
        XCTAssertTrue(used.contains(sq[3]) && used.contains(sq[0]))
        // An explicitly closed ring (first point repeated) is the same ring.
        XCTAssertEqual(tess(sq + [sq[0]], closed: true).1.count, 4 * 6)
        XCTAssertTrue(tess([V(0, 0), V(1, 1)], closed: true).0.isEmpty, "a closed line needs three points")
    }

    func testAppendsAfterExistingGeometryWithOffsetIndices() {
        var v: [LineVertex] = [], i: [UInt32] = []
        LineTessellator.append([V(0, 0), V(1, 0)], closed: false, cls: .minor, flags: 0, vertices: &v, indices: &i)
        LineTessellator.append([V(0, 1), V(1, 1)], closed: false, cls: .minor, flags: 0, vertices: &v, indices: &i)
        XCTAssertEqual(v.count, 8)
        XCTAssertEqual(Array(i[6...]).min(), 4)
        assertSane(v, i)
    }

    func testRandomPolylinesAreAlwaysFinite() {
        var rng = SplitMix64(seed: 5)
        for n in 0..<400 {
            let count = Int.random(in: 0...30, using: &rng)
            var pts = (0..<count).map { _ in V(Float.random(in: 0...1, using: &rng), Float.random(in: 0...1, using: &rng)) }
            if n % 3 == 0, pts.count > 2 { pts[1] = pts[0]; pts[pts.count - 1] = pts[pts.count - 2] }
            let (v, i) = tess(pts, closed: n % 2 == 0)
            assertSane(v, i)
        }
    }
}
