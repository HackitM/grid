import AppKit
import CoreText
import GridCore
import QuartzCore

// Map labels: placed on the CPU each frame (anchors projected with the contract projection,
// measured with cached CTLine widths, collision-placed) and drawn as pooled CATextLayers with
// implicit animations disabled. SF Mono 9.5 medium; places uppercase.

// MARK: - Stand-in for GridCore's LabelPlacer (workstream A)
//
// Worker A ships `LabelCandidate` and `LabelPlacer.place(_:viewport:keep:max:padding:)` in
// GridCore (IMPLEMENTATION.md §3.3 A). Until that merges, these two aliases point at a private
// stand-in with the same shape. To swap: set the aliases to `LabelCandidate` / `LabelPlacer` and
// delete `_StandInLabelCandidate` and `_StandInLabelPlacer` below.
fileprivate typealias PlacerCandidate = _StandInLabelCandidate
fileprivate typealias Placer = _StandInLabelPlacer

fileprivate struct _StandInLabelCandidate: Sendable {
    var text: String
    var kind: LabelKind
    var priority: Int
    var center: SIMD2<Double>
    var size: SIMD2<Double>
    init(text: String, kind: LabelKind, priority: Int, center: SIMD2<Double>, size: SIMD2<Double>) {
        self.text = text; self.kind = kind; self.priority = priority; self.center = center; self.size = size
    }
}

fileprivate enum _StandInLabelPlacer {
    /// Greedy collision in screen space; candidates in `keep` (last frame's texts) are placed first.
    static func place(_ c: [PlacerCandidate], viewport: SIMD2<Double>, keep: Set<String>, max: Int = 40, padding: Double = 4) -> [PlacerCandidate] {
        guard max > 0, !c.isEmpty else { return [] }
        let ordered = c.enumerated().sorted { a, b in
            let ka = keep.contains(a.element.text), kb = keep.contains(b.element.text)
            if ka != kb { return ka }
            if a.element.priority != b.element.priority { return a.element.priority < b.element.priority }
            return a.offset < b.offset
        }.map(\.element)
        var out: [PlacerCandidate] = []
        var boxes: [(SIMD2<Double>, SIMD2<Double>)] = []   // min, max with padding
        out.reserveCapacity(min(max, ordered.count))
        for cand in ordered {
            let half = cand.size / 2
            let lo = cand.center - half, hi = cand.center + half
            // Entirely inside the viewport.
            guard lo.x >= 0, lo.y >= 0, hi.x <= viewport.x, hi.y <= viewport.y else { continue }
            let plo = lo - SIMD2(repeating: padding), phi = hi + SIMD2(repeating: padding)
            var collides = false
            for (blo, bhi) in boxes where !(phi.x <= blo.x || plo.x >= bhi.x || phi.y <= blo.y || plo.y >= bhi.y) { collides = true; break }
            if collides { continue }
            boxes.append((plo, phi))
            out.append(cand)
            if out.count >= max { break }
        }
        return out
    }
}

// MARK: - Planner

/// A cluster count drawn beside its block.
struct MapCountLabel: Equatable {
    var text: String
    var center: CGPoint
}

/// Turns the frame's label anchors into placed labels. Owned by the view; main thread only.
@MainActor
final class MapLabelPlanner {
    static let font = NSFont.monospacedSystemFont(ofSize: 9.5, weight: .medium)
    static let countFont = NSFont.monospacedSystemFont(ofSize: 9.5, weight: .semibold)
    static let labelHeight: Double = 12
    static let maxLabels = 40
    private var widthCache: [String: Double] = [:]
    private var lastTexts: Set<String> = []

    /// Width in points of `text` in the label font (cached; the cache is cleared past 4k entries).
    func width(of text: String) -> Double {
        if let w = widthCache[text] { return w }
        if widthCache.count > 4096 { widthCache.removeAll(keepingCapacity: true) }
        let attr = NSAttributedString(string: text, attributes: [.font: Self.font])
        let line = CTLineCreateWithAttributedString(attr)
        let w = CTLineGetTypographicBounds(line, nil, nil, nil)
        widthCache[text] = w
        return w
    }

    static func display(_ text: String, kind: LabelKind) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let capped = t.count > 40 ? String(t.prefix(40)) : t
        return kind == .place ? capped.uppercased() : capped
    }

    /// Places labels for the tiles on screen. Deepest tiles win duplicates (same text and kind).
    func place(tiles: [TileGeometry], projection proj: MapProjection) -> [PlacedMapLabel] {
        let zoom = Float(proj.camera.zoom)
        var candidates: [PlacerCandidate] = []
        var seen: Set<String> = []
        for t in tiles.sorted(by: { $0.id.z > $1.id.z }) {
            guard !t.labels.isEmpty else { continue }
            let (nw, se) = TileMath.bounds(t.id)
            let w = se.x - nw.x, h = se.y - nw.y
            for a in t.labels where a.minZoom <= zoom && !a.text.isEmpty {
                let text = Self.display(a.text, kind: a.kind)
                guard !text.isEmpty else { continue }
                let key = "\(a.kind.rawValue)|\(text)"
                guard !seen.contains(key) else { continue }
                let world = Mercator(x: nw.x + Double(a.pos.x) * w, y: nw.y + Double(a.pos.y) * h)
                guard let s = proj.screen(world) else { continue }
                guard s.x > -200, s.y > -50, s.x < proj.viewport.x + 200, s.y < proj.viewport.y + 50 else { continue }
                seen.insert(key)
                let tw = width(of: text)
                candidates.append(PlacerCandidate(text: text, kind: a.kind, priority: a.priority, center: s + SIMD2(0, 10),
                                                  size: SIMD2(tw + 8, Self.labelHeight)))
                if candidates.count >= 2000 { break }
            }
        }
        let placed = Placer.place(candidates, viewport: proj.viewport, keep: lastTexts, max: Self.maxLabels, padding: 4)
        lastTexts = Set(placed.map(\.text))
        return placed.map { PlacedMapLabel(text: $0.text, kind: $0.kind, center: CGPoint(x: $0.center.x, y: $0.center.y)) }
    }
}

// MARK: - Layer

/// Draws placed labels and cluster counts with pooled CATextLayers; never animates.
final class MapLabelLayer: NSView {
    private var pool: [CATextLayer] = []
    private var used = 0
    private var colors: (place: CGColor, road: CGColor, water: CGColor, count: CGColor) =
        (NSColor.white.cgColor, NSColor.gray.cgColor, NSColor.gray.cgColor, NSColor.white.cgColor)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidChangeBackingProperties() {
        let s = window?.backingScaleFactor ?? 2
        pool.forEach { $0.contentsScale = s }
    }

    func setPalette(_ p: MapPalette) {
        func c(_ v: SIMD4<Float>, _ alpha: CGFloat = 1) -> CGColor {
            CGColor(srgbRed: CGFloat(v.x), green: CGFloat(v.y), blue: CGFloat(v.z), alpha: CGFloat(v.w) * alpha)
        }
        colors = (c(p.text), c(p.textDim), c(p.accent, 0.8), c(p.text))
    }

    private func layer(at i: Int) -> CATextLayer {
        if i < pool.count { return pool[i] }
        let t = CATextLayer()
        t.font = MapLabelPlanner.font
        t.fontSize = 9.5
        t.alignmentMode = .center
        t.truncationMode = .end
        t.contentsScale = window?.backingScaleFactor ?? 2
        t.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        t.isHidden = true
        layer?.addSublayer(t)
        pool.append(t)
        return t
    }

    /// Shows exactly these labels; the rest of the pool is hidden (never freed below 64 layers).
    func apply(_ labels: [PlacedMapLabel], counts: [MapCountLabel], widthOf: (String) -> Double) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var i = 0
        for l in labels {
            let t = layer(at: i); i += 1
            t.string = l.text
            t.font = MapLabelPlanner.font
            t.foregroundColor = l.kind == .place ? colors.place : (l.kind == .road ? colors.road : colors.water)
            let w = widthOf(l.text) + 8
            t.bounds = CGRect(x: 0, y: 0, width: w, height: MapLabelPlanner.labelHeight)
            t.position = l.center
            t.isHidden = false
        }
        for c in counts {
            let t = layer(at: i); i += 1
            t.string = c.text
            t.font = MapLabelPlanner.countFont
            t.foregroundColor = colors.count
            let w = widthOf(c.text) + 6
            t.bounds = CGRect(x: 0, y: 0, width: w, height: MapLabelPlanner.labelHeight)
            t.position = CGPoint(x: c.center.x + w / 2, y: c.center.y)
            t.isHidden = false
        }
        if i < used { for k in i..<used { pool[k].isHidden = true } }
        used = i
        if pool.count > 64, used < pool.count / 2 {
            for t in pool[max(64, used)...] { t.removeFromSuperlayer() }
            pool.removeSubrange(max(64, used)...)
        }
        CATransaction.commit()
    }
}
