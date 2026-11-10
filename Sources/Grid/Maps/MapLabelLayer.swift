import AppKit
import CoreText
import GridCore
import QuartzCore

// Map labels: placed on the CPU each frame (anchors projected with the contract projection,
// measured with cached CTLine widths, collision-placed by GridCore's LabelPlacer) and drawn as pooled CATextLayers with
// implicit animations disabled. SF Mono 9.5 medium; places uppercase.

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

    /// Marks a cluster-count candidate so it can be told apart after placement.
    private static let countMark = "\u{1}"

    /// Places labels for the tiles on screen. Deepest tiles win duplicates (same text and kind).
    /// Cluster counts (left-anchored at their block) are placed first so names never cover them.
    func place(tiles: [TileGeometry], projection proj: any MapScreenProjection, counts: [MapCountLabel] = [],
               elevation: (Mercator) -> Double = { _ in 0 }) -> (labels: [PlacedMapLabel], counts: [MapCountLabel]) {
        var angles: [String: Double] = [:]
        let zoom = Float(proj.camera.zoom)
        var candidates: [LabelCandidate] = []
        var seen: Set<String> = []
        for c in counts where !c.text.isEmpty {
            let w = width(of: c.text) + 6
            candidates.append(LabelCandidate(text: Self.countMark + c.text, kind: .place, priority: Int.min / 2,
                                             center: SIMD2(c.center.x + w / 2, c.center.y), size: SIMD2(w, Self.labelHeight)))
        }
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
                let z = elevation(world)
                guard let s = proj.screen(world, heightMeters: z) else { continue }
                guard s.x > -200, s.y > -50, s.x < proj.viewport.x + 200, s.y < proj.viewport.y + 50 else { continue }
                seen.insert(key)
                let tw = width(of: text) + 8
                var size = SIMD2(tw, Self.labelHeight)
                var center = s + SIMD2(0, a.kind == .place ? 10 : 0)
                // Labels that belong to a line (road names, contour heights) run along it.
                if a.dir != .zero {
                    let ahead = Mercator(x: world.x + Double(a.dir.x) * w * 0.02, y: world.y + Double(a.dir.y) * h * 0.02)
                    if let s2 = proj.screen(ahead, heightMeters: z) {
                        var ang = atan2(s2.y - s.y, s2.x - s.x)
                        if ang > .pi / 2 { ang -= .pi } else if ang < -.pi / 2 { ang += .pi }   // keep it readable
                        angles[text] = ang
                        let c = abs(cos(ang)), sn = abs(sin(ang))
                        size = SIMD2(tw * c + Self.labelHeight * sn, tw * sn + Self.labelHeight * c)
                        center = s
                    }
                }
                candidates.append(LabelCandidate(text: text, kind: a.kind, priority: a.priority, center: center, size: size))
                if candidates.count >= 2000 { break }
            }
        }
        let placed = LabelPlacer.place(candidates, viewport: proj.viewport, keep: lastTexts, max: Self.maxLabels + counts.count, padding: 4)
        lastTexts = Set(placed.map(\.text))
        var labels: [PlacedMapLabel] = []
        var placedCounts: [MapCountLabel] = []
        for c in placed {
            if c.text.hasPrefix(Self.countMark) {
                placedCounts.append(MapCountLabel(text: String(c.text.dropFirst()), center: CGPoint(x: c.center.x - c.size.x / 2, y: c.center.y)))
            } else if labels.count < Self.maxLabels {
                labels.append(PlacedMapLabel(text: c.text, kind: c.kind, center: CGPoint(x: c.center.x, y: c.center.y), angle: angles[c.text] ?? 0))
            }
        }
        return (labels, placedCounts)
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
            t.setAffineTransform(l.angle == 0 ? .identity : CGAffineTransform(rotationAngle: CGFloat(l.angle)))
            t.isHidden = false
        }
        for c in counts {
            let t = layer(at: i); i += 1
            t.string = c.text
            t.font = MapLabelPlanner.countFont
            t.setAffineTransform(.identity)
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
