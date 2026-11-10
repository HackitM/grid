import Foundation
import simd

/// A label to be placed on screen. `center` and `size` are in view points. Lower `priority` wins.
public struct LabelCandidate: Sendable {
    public var text: String
    public var kind: LabelKind
    public var priority: Int
    public var center: SIMD2<Double>
    public var size: SIMD2<Double>
    public init(text: String, kind: LabelKind, priority: Int, center: SIMD2<Double>, size: SIMD2<Double>) {
        self.text = text; self.kind = kind; self.priority = priority; self.center = center; self.size = size
    }
}

/// A label box for `LabelPlacer.place(boxes:…)`: screen centre and size in view points. Lower
/// `priority` wins; `keep` marks a label that was on screen in the last frame.
public struct LabelBox: Sendable {
    public var center: SIMD2<Double>
    public var size: SIMD2<Double>
    public var priority: Int
    public var keep: Bool
    public init(center: SIMD2<Double>, size: SIMD2<Double>, priority: Int, keep: Bool = false) {
        self.center = center; self.size = size; self.priority = priority; self.keep = keep
    }
}

public enum LabelPlacer {
    /// Greedy collision in screen space. Candidates whose text is in `keep` (last frame's labels)
    /// are considered first (so labels do not flicker), then the rest by priority. A label is
    /// placed when its box, grown by `padding` points of clearance, overlaps no placed label and
    /// touches the viewport. At most `max` labels are returned, in placement order.
    public static func place(_ c: [LabelCandidate], viewport: SIMD2<Double>, keep: Set<String>, max maxCount: Int = 40, padding: Double = 4) -> [LabelCandidate] {
        var boxes: [LabelBox] = []
        var source: [Int] = []
        boxes.reserveCapacity(c.count); source.reserveCapacity(c.count)
        for (i, l) in c.enumerated() where !l.text.isEmpty {
            boxes.append(LabelBox(center: l.center, size: l.size, priority: l.priority, keep: keep.contains(l.text)))
            source.append(i)
        }
        return place(boxes: boxes, viewport: viewport, max: maxCount, padding: padding).map { c[source[$0]] }
    }

    /// The same placement on bare boxes (no strings, for the per-frame label pass): returns the
    /// indices of the placed boxes in placement order. Boxes marked `keep` go first, then by
    /// priority, then by position in `boxes`.
    public static func place(boxes c: [LabelBox], viewport: SIMD2<Double>, max maxCount: Int = 40, padding: Double = 4) -> [Int] {
        guard maxCount > 0, viewport.x > 0, viewport.y > 0 else { return [] }
        var order: [Int] = []
        order.reserveCapacity(c.count)
        for (i, l) in c.enumerated() {
            guard l.center.x.isFinite, l.center.y.isFinite, l.size.x.isFinite, l.size.y.isFinite, l.size.x > 0, l.size.y > 0 else { continue }
            order.append(i)
        }
        order.sort { a, b in
            if c[a].keep != c[b].keep { return c[a].keep }
            let pa = c[a].priority, pb = c[b].priority
            return pa != pb ? pa < pb : a < b
        }
        var placed: [Int] = []
        var taken: [(lo: SIMD2<Double>, hi: SIMD2<Double>)] = []
        let pad = Swift.max(0, padding) / 2
        for i in order {
            if placed.count >= maxCount { break }
            let l = c[i]
            let half = l.size / 2
            let lo = l.center - half, hi = l.center + half
            if hi.x < 0 || hi.y < 0 || lo.x > viewport.x || lo.y > viewport.y { continue }
            let elo = lo - pad, ehi = hi + pad
            var clash = false
            for b in taken where !(ehi.x <= b.lo.x - pad || elo.x >= b.hi.x + pad || ehi.y <= b.lo.y - pad || elo.y >= b.hi.y + pad) {
                clash = true; break
            }
            if clash { continue }
            taken.append((lo, hi))
            placed.append(i)
        }
        return placed
    }
}
