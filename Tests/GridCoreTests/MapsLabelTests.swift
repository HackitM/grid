import XCTest
import simd
@testable import GridCore

final class MapsLabelTests: XCTestCase {
    private func c(_ text: String, _ prio: Int, _ x: Double, _ y: Double, w: Double = 60, h: Double = 12, kind: LabelKind = .place) -> LabelCandidate {
        LabelCandidate(text: text, kind: kind, priority: prio, center: SIMD2(x, y), size: SIMD2(w, h))
    }
    private let vp = SIMD2<Double>(800, 600)

    private func overlaps(_ a: LabelCandidate, _ b: LabelCandidate) -> Bool {
        abs(a.center.x - b.center.x) < (a.size.x + b.size.x) / 2 && abs(a.center.y - b.center.y) < (a.size.y + b.size.y) / 2
    }

    func testNoOverlapAndPriorityWins() {
        let placed = LabelPlacer.place([c("low", 5, 100, 100), c("high", 1, 120, 105), c("far", 9, 400, 300)], viewport: vp, keep: [])
        XCTAssertEqual(placed.map(\.text), ["high", "far"])
    }

    func testPaddingEnforcesClearance() {
        // Boxes 60 wide: centres 62 apart leave a 2 pt gap, less than the default padding of 4.
        XCTAssertEqual(LabelPlacer.place([c("a", 1, 100, 100), c("b", 2, 162, 100)], viewport: vp, keep: []).count, 1)
        XCTAssertEqual(LabelPlacer.place([c("a", 1, 100, 100), c("b", 2, 165, 100)], viewport: vp, keep: []).count, 2)
        XCTAssertEqual(LabelPlacer.place([c("a", 1, 100, 100), c("b", 2, 162, 100)], viewport: vp, keep: [], padding: 0).count, 2)
    }

    func testKeepIsPlacedFirst() {
        let cands = [c("new", 1, 100, 100), c("old", 50, 110, 100)]
        XCTAssertEqual(LabelPlacer.place(cands, viewport: vp, keep: ["old"]).map(\.text), ["old"])
        XCTAssertEqual(LabelPlacer.place(cands, viewport: vp, keep: []).map(\.text), ["new"])
        // Kept labels keep their own priority order among themselves.
        let both = LabelPlacer.place(cands, viewport: vp, keep: ["old", "new"])
        XCTAssertEqual(both.map(\.text), ["new"])
    }

    func testMaxHonoured() {
        let many = (0..<200).map { c("l\($0)", $0, Double($0 % 20) * 70 + 40, Double($0 / 20) * 30 + 20) }
        let placed = LabelPlacer.place(many, viewport: vp, keep: [], max: 40)
        XCTAssertEqual(placed.count, 40)
        XCTAssertEqual(LabelPlacer.place(many, viewport: vp, keep: [], max: 5).count, 5)
        XCTAssertEqual(LabelPlacer.place(many, viewport: vp, keep: [], max: 0).count, 0)
        // The best priorities win.
        XCTAssertEqual(placed.first?.text, "l0")
    }

    func testRandomFieldHasNoOverlaps() {
        var rng = SplitMix64(seed: 77)
        let cands = (0..<500).map { c("t\($0)", Int.random(in: 0..<100, using: &rng), Double.random(in: 0...800, using: &rng),
                                      Double.random(in: 0...600, using: &rng), w: Double.random(in: 20...120, using: &rng), h: 12) }
        let placed = LabelPlacer.place(cands, viewport: vp, keep: Set(["t3", "t9"]), max: 100, padding: 4)
        XCTAssertGreaterThan(placed.count, 10)
        for i in 0..<placed.count { for j in (i + 1)..<placed.count where overlaps(placed[i], placed[j]) { XCTFail("overlap \(placed[i].text) \(placed[j].text)") } }
    }

    func testOffscreenAndInvalidCandidatesRejected() {
        let placed = LabelPlacer.place([
            c("off", 1, -500, 100), c("edge", 2, 5, 100), c("nan", 3, .nan, 10), c("empty", 4, 300, 300) .withText(""),
            c("zero", 5, 200, 200, w: 0), c("inf", 6, 100, .infinity),
        ], viewport: vp, keep: [])
        XCTAssertEqual(placed.map(\.text), ["edge"], "partially visible labels are kept")
        XCTAssertTrue(LabelPlacer.place([c("a", 1, 10, 10)], viewport: SIMD2(0, 0), keep: []).isEmpty)
    }
}

private extension LabelCandidate {
    func withText(_ t: String) -> LabelCandidate { var c = self; c.text = t; return c }
}

final class MapsLabelBoxTests: XCTestCase {
    private let vp = SIMD2<Double>(800, 600)
    private func b(_ prio: Int, _ x: Double, _ y: Double, w: Double = 60, keep: Bool = false) -> LabelBox {
        LabelBox(center: SIMD2(x, y), size: SIMD2(w, 12), priority: prio, keep: keep)
    }

    func testIndicesInPlacementOrder() {
        // 1 beats 0 on priority and blocks it; 2 is clear of both.
        XCTAssertEqual(LabelPlacer.place(boxes: [b(5, 100, 100), b(1, 120, 105), b(9, 400, 300)], viewport: vp), [1, 2])
    }

    func testKeptBoxGoesFirstAndTiesKeepInputOrder() {
        XCTAssertEqual(LabelPlacer.place(boxes: [b(1, 100, 100), b(50, 110, 100, keep: true)], viewport: vp), [1])
        XCTAssertEqual(LabelPlacer.place(boxes: [b(3, 100, 100), b(3, 110, 100)], viewport: vp), [0])
    }

    func testInvalidOffscreenAndMax() {
        let boxes = [b(1, -500, 100), b(2, .nan, 10), b(3, 200, 200, w: 0), b(4, 5, 100), b(5, 300, 300), b(6, 500, 500)]
        XCTAssertEqual(LabelPlacer.place(boxes: boxes, viewport: vp), [3, 4, 5])
        XCTAssertEqual(LabelPlacer.place(boxes: boxes, viewport: vp, max: 2), [3, 4])
        XCTAssertTrue(LabelPlacer.place(boxes: boxes, viewport: vp, max: 0).isEmpty)
    }

    func testMatchesTheStringPlacement() {
        var rng = SplitMix64(seed: 5)
        let cands = (0..<300).map { i in
            LabelCandidate(text: "t\(i)", kind: .road, priority: Int.random(in: 0..<50, using: &rng),
                           center: SIMD2(Double.random(in: 0...800, using: &rng), Double.random(in: 0...600, using: &rng)),
                           size: SIMD2(Double.random(in: 20...120, using: &rng), 12))
        }
        let keep: Set<String> = ["t4", "t17", "t200"]
        let boxes = cands.map { LabelBox(center: $0.center, size: $0.size, priority: $0.priority, keep: keep.contains($0.text)) }
        XCTAssertEqual(LabelPlacer.place(boxes: boxes, viewport: vp, max: 60).map { cands[$0].text },
                       LabelPlacer.place(cands, viewport: vp, keep: keep, max: 60).map(\.text))
    }
}
