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

public enum LabelPlacer {
    /// Greedy collision in screen space. Candidates whose text is in `keep` (last frame's labels)
    /// are considered first (so labels do not flicker), then the rest by priority. A label is
    /// placed when its box, grown by `padding` points of clearance, overlaps no placed label and
    /// touches the viewport. At most `max` labels are returned, in placement order.
    public static func place(_ c: [LabelCandidate], viewport: SIMD2<Double>, keep: Set<String>, max maxCount: Int = 40, padding: Double = 4) -> [LabelCandidate] {
        guard maxCount > 0, viewport.x > 0, viewport.y > 0 else { return [] }
        var order: [(Int, Bool)] = []
        order.reserveCapacity(c.count)
        for (i, l) in c.enumerated() {
            guard !l.text.isEmpty, l.center.x.isFinite, l.center.y.isFinite, l.size.x.isFinite, l.size.y.isFinite,
                  l.size.x > 0, l.size.y > 0 else { continue }
            order.append((i, keep.contains(l.text)))
        }
        order.sort { a, b in
            if a.1 != b.1 { return a.1 }
            let pa = c[a.0].priority, pb = c[b.0].priority
            return pa != pb ? pa < pb : a.0 < b.0
        }
        var placed: [LabelCandidate] = []
        var boxes: [(lo: SIMD2<Double>, hi: SIMD2<Double>)] = []
        let pad = Swift.max(0, padding) / 2
        for (i, _) in order {
            if placed.count >= maxCount { break }
            let l = c[i]
            let half = l.size / 2
            let lo = l.center - half, hi = l.center + half
            if hi.x < 0 || hi.y < 0 || lo.x > viewport.x || lo.y > viewport.y { continue }
            let elo = lo - pad, ehi = hi + pad
            var clash = false
            for b in boxes where !(ehi.x <= b.lo.x - pad || elo.x >= b.hi.x + pad || ehi.y <= b.lo.y - pad || elo.y >= b.hi.y + pad) {
                clash = true; break
            }
            if clash { continue }
            boxes.append((lo, hi))
            placed.append(l)
        }
        return placed
    }
}
