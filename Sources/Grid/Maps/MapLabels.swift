import AppKit
import CoreText
import GridCore
import Metal
import simd

// Map labels. Every frame the renderer asks the planner where labels go for the projection it is
// drawing with (anchors projected, collision-placed by GridCore's LabelPlacer), and draws them in
// the same render pass from an atlas of rasterised strings, so a label can never trail the map
// under it. SF Mono 9.5 medium; places uppercase; road and contour names run along their line.

/// One label quad (`LabelInst` in the shader). Pixels, top-left origin.
struct MapLabelInstance {
    var center: SIMD2<Float>
    var half: SIMD2<Float>
    /// Atlas texture coordinates of the quad: u0, v0, u1, v1.
    var uv: SIMD4<Float>
    var color: SIMD4<Float>
    /// Cosine and sine of the label's angle (clockwise, screen space).
    var rot: SIMD2<Float>
    var pad: SIMD2<Float> = .zero
}

// MARK: - Planner

/// Turns the frame's label anchors into placed labels. Owned by the renderer; main thread only.
/// Built to run every frame: strings are interned to integers once, each tile's anchors are
/// prepared once per tile revision, and a frame only projects, culls and collides.
@MainActor
final class MapLabelPlanner {
    static let font = NSFont.monospacedSystemFont(ofSize: 9.5, weight: .medium)
    static let countFont = NSFont.monospacedSystemFont(ofSize: 9.5, weight: .semibold)
    static let labelHeight: Double = 12
    static let maxLabels = 40

    enum Style: UInt8 { case place, road, water, count }

    struct Placed {
        /// Index into the planner's string table (`text(of:)`), stable until `epoch` changes.
        var id: Int32
        var style: Style
        /// Centre of the text in view points.
        var center: SIMD2<Double>
        /// Radians, clockwise in screen space; 0 for level labels.
        var angle: Double
    }

    // Interned strings: one id per (style, display text).
    private var ids: [String: Int32] = [:]
    private var texts: [String] = []
    private var styles: [Style] = []
    private var widths: [Double] = []
    /// Frame number in which each id was last taken as a candidate / placed.
    private var seenIn: [UInt32] = []
    private var placedIn: [UInt32] = []
    private var frameNo: UInt32 = 1
    /// Bumped when the string table starts over (ids then mean different strings).
    private(set) var epoch = 0

    func text(of id: Int32) -> String { texts[Int(id)] }
    func width(of id: Int32) -> Double { widths[Int(id)] }

    private func measure(_ text: String, _ font: NSFont) -> Double {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        return CTLineGetTypographicBounds(line, nil, nil, nil)
    }

    private func intern(_ text: String, _ style: Style) -> Int32 {
        let key = "\(style.rawValue)|\(text)"
        if let id = ids[key] { return id }
        let id = Int32(texts.count)
        ids[key] = id
        texts.append(text); styles.append(style)
        widths.append(measure(text, style == .count ? Self.countFont : Self.font))
        seenIn.append(0); placedIn.append(0)
        return id
    }

    static func display(_ text: String, kind: LabelKind) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let capped = t.count > 40 ? String(t.prefix(40)) : t
        return kind == .place ? capped.uppercased() : capped
    }

    /// One anchor, ready to project: world position, the point a little further along its line
    /// (labels that follow a line), and the height scale at its latitude.
    private struct Anchor {
        var id: Int32
        var priority: Int
        var minZoom: Float
        var place: Bool
        var hasDir: Bool
        var x, y, ax, ay: Double
        var worldPerMeter: Double
        /// Elevation in metres from the frame's terrain (nan: none), refreshed per frame build.
        var raw: Double = .nan
    }
    private final class TileLabels {
        let revision: Int
        var anchors: [Anchor]
        var rawStamp = Int.min
        init(revision: Int, anchors: [Anchor]) { self.revision = revision; self.anchors = anchors }
    }
    private var tileCache: [TileID: TileLabels] = [:]

    private func prepared(_ t: TileGeometry) -> TileLabels {
        if let c = tileCache[t.id], c.revision == t.revision { return c }
        let (nw, se) = TileMath.bounds(t.id)
        let w = se.x - nw.x, h = se.y - nw.y
        var out: [Anchor] = []
        out.reserveCapacity(t.labels.count)
        for a in t.labels where !a.text.isEmpty {
            let text = Self.display(a.text, kind: a.kind)
            guard !text.isEmpty else { continue }
            let style: Style = a.kind == .place ? .place : (a.kind == .road ? .road : .water)
            let x = nw.x + Double(a.pos.x) * w, y = nw.y + Double(a.pos.y) * h
            let hasDir = a.dir != .zero
            out.append(Anchor(id: intern(text, style), priority: a.priority, minZoom: a.minZoom, place: a.kind == .place, hasDir: hasDir,
                              x: x, y: y, ax: x + Double(a.dir.x) * w * 0.02, ay: y + Double(a.dir.y) * h * 0.02,
                              worldPerMeter: MapProjection.worldUnitsPerMeter(y: y)))
        }
        let c = TileLabels(revision: t.revision, anchors: out)
        tileCache[t.id] = c
        return c
    }

    // The frame's tiles, deepest first, kept while the same frame is drawn again.
    private var orderStamp = Int.min
    private var order: [TileLabels] = []
    private var boxes: [LabelBox] = []
    private var candidates: [Placed] = []

    private func startOver() {
        ids = [:]; texts = []; styles = []; widths = []; seenIn = []; placedIn = []
        tileCache = [:]; orderStamp = Int.min; order = []
        epoch += 1
    }

    /// Places labels for a frame as drawn by `proj`. Deepest tiles win duplicates (same text and
    /// kind). Cluster counts (`counts`: text and the left end of its box) go first so names never
    /// cover them. Labels on screen in the previous frame are placed before new ones.
    func place(frame: MapFrame, projection proj: any MapScreenProjection, counts: [(text: String, left: SIMD2<Double>)] = []) -> [Placed] {
        if texts.count > 12_000 { startOver() }
        if frame.stamp == 0 || frame.stamp != orderStamp {
            orderStamp = frame.stamp
            order = frame.tiles.filter { !$0.labels.isEmpty }.sorted { $0.id.z > $1.id.z }.map(prepared)
            if tileCache.count > 2 * frame.tiles.count + 64 {
                let keep = Set(frame.tiles.map(\.id))
                tileCache = tileCache.filter { keep.contains($0.key) }
            }
        }
        frameNo &+= 1
        if frameNo < 2 { frameNo = 2; for i in seenIn.indices { seenIn[i] = 0; placedIn[i] = 0 } }
        let vp = proj.viewport
        let zoom = Float(proj.camera.zoom)
        let lifted = !frame.lift.isFlat
        let flat = proj as? MapProjection
        let m = flat?.viewProjection ?? matrix_identity_double4x4
        @inline(__always) func screen(_ x: Double, _ y: Double, _ z: Double, _ wpm: Double) -> SIMD2<Double>? {
            guard flat != nil else { return proj.screen(Mercator(x: x, y: y), heightMeters: z) }
            let c = m * SIMD4(x, y, z * wpm, 1)
            guard c.w > 1e-9 else { return nil }
            return SIMD2((c.x / c.w + 1) / 2 * vp.x, (1 - c.y / c.w) / 2 * vp.y)
        }

        boxes.removeAll(keepingCapacity: true)
        candidates.removeAll(keepingCapacity: true)
        for c in counts where !c.text.isEmpty {
            let id = intern(c.text, .count)
            let w = widths[Int(id)] + 6
            let center = SIMD2(c.left.x + w / 2, c.left.y)
            boxes.append(LabelBox(center: center, size: SIMD2(w, Self.labelHeight), priority: Int.min / 2, keep: placedIn[Int(id)] == frameNo - 1))
            candidates.append(Placed(id: id, style: .count, center: center, angle: 0))
        }
        let countBoxes = boxes.count
        let half = Self.labelHeight / 2
        outer: for tile in order {
            if lifted, frame.stamp == 0 || tile.rawStamp != frame.stamp {
                tile.rawStamp = frame.stamp
                for i in tile.anchors.indices {
                    tile.anchors[i].raw = frame.rawElevation(at: Mercator(x: tile.anchors[i].x, y: tile.anchors[i].y)) ?? .nan
                }
            }
            for a in tile.anchors where a.minZoom <= zoom && seenIn[Int(a.id)] != frameNo {
                let z = lifted && !a.raw.isNaN ? frame.lift.lift(a.raw) : 0
                guard let s = screen(a.x, a.y, z, a.worldPerMeter) else { continue }
                let tw = widths[Int(a.id)] + 8
                // Nothing wider than this can reach the view from here.
                let reach = tw / 2 + half
                guard s.x > -reach, s.y > -reach - 10, s.x < vp.x + reach, s.y < vp.y + reach else { continue }
                var size = SIMD2(tw, Self.labelHeight)
                var center = s + SIMD2(0, a.place ? 10 : 0)
                var angle = 0.0
                // Labels that belong to a line (road names, contour heights) run along it.
                if a.hasDir, let s2 = screen(a.ax, a.ay, z, a.worldPerMeter) {
                    angle = atan2(s2.y - s.y, s2.x - s.x)
                    if angle > .pi / 2 { angle -= .pi } else if angle < -.pi / 2 { angle += .pi }   // keep it readable
                    let c = abs(cos(angle)), sn = abs(sin(angle))
                    size = SIMD2(tw * c + Self.labelHeight * sn, tw * sn + Self.labelHeight * c)
                    center = s
                }
                // Only a label that touches the view takes its name (another anchor of the same
                // name further in may still show).
                guard center.x + size.x / 2 > 0, center.y + size.y / 2 > 0, center.x - size.x / 2 < vp.x, center.y - size.y / 2 < vp.y else { continue }
                seenIn[Int(a.id)] = frameNo
                boxes.append(LabelBox(center: center, size: size, priority: a.priority, keep: placedIn[Int(a.id)] == frameNo - 1))
                candidates.append(Placed(id: a.id, style: styles[Int(a.id)], center: center, angle: angle))
                if boxes.count >= 2000 { break outer }
            }
        }
        var out: [Placed] = []
        var names = 0
        for i in LabelPlacer.place(boxes: boxes, viewport: vp, max: Self.maxLabels + countBoxes, padding: 4) {
            let c = candidates[i]
            if c.style != .count {
                guard names < Self.maxLabels else { continue }
                names += 1
            }
            placedIn[Int(c.id)] = frameNo
            out.append(c)
        }
        return out
    }
}

// MARK: - Atlas

/// Label strings rasterised once into a single-channel texture (coverage), packed in rows. When
/// it fills up it starts over with a fresh texture; the labels on screen are drawn again then.
@MainActor
final class MapLabelAtlas {
    struct Slot { var x, y, w, h: Int }

    static let width = 2048, height = 2048
    /// Points of clear space around the text inside its slot (keeps rotated edges soft).
    static let margin: CGFloat = 2
    /// The slot is this tall in points: the 12-point label box plus a point above and below.
    static let slotHeight: CGFloat = 14

    private let device: MTLDevice
    private(set) var texture: MTLTexture?
    private(set) var scale: CGFloat = 0
    /// Bumped whenever the atlas starts over (slots handed out before are void).
    private(set) var generation = 0
    private var slots: [Int32: Slot] = [:]
    private var penX = 0, penY = 0
    private var scratch: CGContext?

    init(device: MTLDevice) { self.device = device }

    private var rowHeight: Int { Int((Self.slotHeight * scale).rounded(.up)) + 1 }

    /// Starts over (new backing scale, new string table, or full).
    func reset(scale s: CGFloat) {
        scale = max(1, s)
        slots.removeAll(keepingCapacity: true)
        penX = 0; penY = 0
        generation += 1
        // A new texture each time: frames still on their way to the GPU keep the old one.
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: Self.width, height: Self.height, mipmapped: false)
        d.usage = [.shaderRead]
        d.storageMode = device.hasUnifiedMemory ? .shared : .managed
        texture = device.makeTexture(descriptor: d)
        if let t = texture {
            let zeros = [UInt8](repeating: 0, count: Self.width * Self.height)
            t.replace(region: MTLRegionMake2D(0, 0, Self.width, Self.height), mipmapLevel: 0, withBytes: zeros, bytesPerRow: Self.width)
        }
        if scratch == nil {
            scratch = CGContext(data: nil, width: Self.width, height: 64, bitsPerComponent: 8, bytesPerRow: Self.width,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            scratch?.setShouldAntialias(true)
            scratch?.setShouldSmoothFonts(false)
            scratch?.setAllowsFontSubpixelPositioning(true)
            scratch?.setShouldSubpixelPositionFonts(true)
        }
    }

    /// The slot holding `text`, rasterising it on first use; nil when the atlas has no room left
    /// (the caller starts it over and asks again).
    func slot(_ id: Int32, text: String, bold: Bool, width: Double) -> Slot? {
        if let s = slots[id] { return s }
        guard let texture, let ctx = scratch else { return nil }
        let w = min(Self.width, Int(((CGFloat(width) + 2 * Self.margin) * scale).rounded(.up)))
        let h = min(ctx.height, Int((Self.slotHeight * scale).rounded(.up)))
        if penX + w > Self.width { penX = 0; penY += rowHeight }
        guard penY + h <= Self.height else { return nil }
        let font = bold ? MapLabelPlanner.countFont : MapLabelPlanner.font
        // White on black in a grey bitmap: the value is the glyph coverage.
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.saveGState()
        ctx.scaleBy(x: scale, y: scale)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            .font: font, NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]))
        ctx.setFillColor(gray: 1, alpha: 1)
        // The first baseline sits one ascent below the top of the 12-point box, as a text layer lays it out.
        ctx.textPosition = CGPoint(x: Self.margin, y: Self.slotHeight - 1 - CTFontGetAscent(font))
        CTLineDraw(line, ctx)
        ctx.restoreGState()
        guard let data = ctx.data else { return nil }
        // The bitmap's memory starts at its top row; the label was drawn in the bottom `h` rows.
        let top = data.advanced(by: (ctx.height - h) * ctx.bytesPerRow)
        texture.replace(region: MTLRegionMake2D(penX, penY, w, h), mipmapLevel: 0, withBytes: top, bytesPerRow: ctx.bytesPerRow)
        let s = Slot(x: penX, y: penY, w: w, h: h)
        slots[id] = s
        penX += w + 1
        return s
    }
}
