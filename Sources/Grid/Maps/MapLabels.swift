import AppKit
import CoreText
import GridCore
import Metal
import simd

// Map labels. Every frame the renderer asks the planner where labels go for the projection it is
// drawing with (anchors projected, collision-placed by GridCore's LabelPlacer), and draws them in
// the same render pass from an atlas of rasterised strings, so a label can never trail the map
// under it. SF Mono 9.5 medium; places uppercase; road and contour names run along their line.
// Work that comes in bursts (a new tile's anchors, strings to rasterise) is spread over frames.

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
/// Built to run every frame: each tile's anchors are prepared once per tile revision (a few
/// tiles per frame at most), and a frame only projects, culls and collides. A string is
/// interned and measured the first time one of its anchors comes into view, never for a whole
/// tile at once: a city tile carries thousands of names, and almost all of them stay off screen.
@MainActor
final class MapLabelPlanner {
    static let font = NSFont.monospacedSystemFont(ofSize: 9.5, weight: .medium)
    static let countFont = NSFont.monospacedSystemFont(ofSize: 9.5, weight: .semibold)
    static let labelHeight: Double = 12
    static let maxLabels = 40
    /// Points of interest are counted apart from names, so they never crowd out street names.
    static let maxPOIs = 28
    /// A POI's glyph: its box in points, and the gap before its name.
    static let iconSize: Double = 12, iconGap: Double = 3
    /// Boxes handed to the collision pass per frame.
    static let maxCandidates = 2000
    /// The string table starts over beyond this many strings.
    static let maxStrings = 12_000
    /// No label is wider than this (40 characters): anchors further than that from the view are
    /// dropped before their text is looked at.
    private static let widestLabel: Double = 800

    enum Style: UInt8 { case place, road, water, count, poi }

    /// The points of interest drawn in the last frame (glyph centre in view points, name): a click
    /// picks only what the user can see. One map view exists, so this is shared.
    private(set) static var drawnPOIs: [(center: SIMD2<Double>, name: String)] = []

    struct Placed {
        /// Index into the planner's string table (`text(of:)`), stable until `epoch` changes.
        var id: Int32
        var style: Style
        /// Centre of the text in view points.
        var center: SIMD2<Double>
        /// Radians, clockwise in screen space; 0 for level labels.
        var angle: Double
        /// A point of interest's category (`POICategory.rawValue`, 0: not a POI) and its glyph's centre.
        var icon: UInt8 = 0
        var iconCenter: SIMD2<Double> = .zero
    }

    // MARK: String table

    /// One id per (style, display text).
    private struct StringKey: Hashable { let style: Style; let text: String }
    private var ids: [StringKey: Int32] = [:]
    private var texts: [String] = []
    private var styles: [Style] = []
    /// Width in points; nan until the string is first needed on screen.
    private var widths: [Double] = []
    /// Frame number in which each id was last taken as a candidate / placed.
    private var seenIn: [UInt32] = []
    private var placedIn: [UInt32] = []
    private var frameNo: UInt32 = 1
    /// Bumped when the string table starts over (ids then mean different strings).
    private(set) var epoch = 0

    func text(of id: Int32) -> String { texts[Int(id)] }

    /// The string's width in points, measured the first time it is asked for.
    func width(of id: Int32) -> Double {
        let i = Int(id)
        if widths[i].isNaN { widths[i] = Self.measure(texts[i], bold: styles[i] == .count) }
        return widths[i]
    }

    /// The advance every printable ASCII glyph shares in the two (monospaced) label fonts.
    private static let asciiAdvance: (regular: Double, bold: Double) = (lineWidth("0", font), lineWidth("0", countFont))

    private static func lineWidth(_ text: String, _ font: NSFont) -> Double {
        CTLineGetTypographicBounds(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font])), nil, nil, nil)
    }

    /// A string's typographic width. Plain ASCII needs no layout: the fonts are monospaced, so
    /// it is the glyph advance times the length (the same number CoreText gives). Anything else
    /// (accents, other scripts, fallback fonts) is laid out.
    private static func measure(_ text: String, bold: Bool) -> Double {
        if text.utf8.allSatisfy({ $0 >= 0x20 && $0 <= 0x7E }) {
            return Double(text.utf8.count) * (bold ? asciiAdvance.bold : asciiAdvance.regular)
        }
        return lineWidth(text, bold ? countFont : font)
    }

    private func intern(_ text: String, _ style: Style) -> Int32 {
        let key = StringKey(style: style, text: text)
        if let id = ids[key] { return id }
        let id = Int32(texts.count)
        ids[key] = id
        texts.append(text); styles.append(style)
        widths.append(.nan)
        seenIn.append(0); placedIn.append(0)
        return id
    }

    private func startOver() {
        // Anchors notice through `epoch` and take new ids when they next come into view.
        ids = [:]; texts = []; styles = []; widths = []; seenIn = []; placedIn = []
        epoch += 1
    }

    /// A name as drawn: trimmed, at most 40 characters, places in capitals.
    static func display(_ text: String, kind: LabelKind) -> String {
        var t = text
        // Almost every name starts and ends on a visible ASCII character and needs no trimming.
        let visible: ClosedRange<UInt8> = 0x21...0x7E
        let startsAndEndsVisible = t.utf8.first.map(visible.contains) == true && t.utf8.last.map(visible.contains) == true
        if !startsAndEndsVisible { t = t.trimmingCharacters(in: .whitespacesAndNewlines) }
        // 40 bytes or fewer can't be more than 40 characters.
        let capped = t.utf8.count > 40 && t.count > 40 ? String(t.prefix(40)) : t
        return kind == .place ? capped.uppercased() : capped
    }

    // MARK: Tiles

    /// One anchor, ready to project: world position, the point a little further along its line
    /// (labels that follow a line), and the height scale at its latitude.
    private struct Anchor {
        var text: String
        var style: Style
        /// The text's id in the string table, valid while `idEpoch` is the planner's epoch.
        var id: Int32 = -1
        var idEpoch = -1
        var priority: Int
        var minZoom: Float
        var place: Bool
        var hasDir: Bool
        /// `POICategory.rawValue` for a point of interest, else 0.
        var icon: UInt8 = 0
        var x, y, ax, ay: Double
        var worldPerMeter: Double
        /// Elevation in metres from the frame's terrain (nan: none), valid while `rawEpoch` is
        /// the planner's terrain epoch.
        var raw: Double = .nan
        var rawEpoch = -1
    }

    private final class TileLabels {
        let revision: Int
        /// World bounds of the tile (its anchors all lie inside).
        let lo, hi: SIMD2<Double>
        var anchors: [Anchor]
        init(revision: Int, lo: SIMD2<Double>, hi: SIMD2<Double>, anchors: [Anchor]) {
            self.revision = revision; self.lo = lo; self.hi = hi; self.anchors = anchors
        }
    }
    private var tileCache: [TileID: TileLabels] = [:]

    /// A tile's anchors in world coordinates with their display text. No string is interned or
    /// measured here.
    private func prepare(_ t: TileGeometry) -> TileLabels {
        let (nw, se) = TileMath.bounds(t.id)
        let w = se.x - nw.x, h = se.y - nw.y
        var out: [Anchor] = []
        out.reserveCapacity(t.labels.count + t.pois.count)
        for a in t.labels where !a.text.isEmpty {
            let text = Self.display(a.text, kind: a.kind)
            guard !text.isEmpty else { continue }
            let style: Style = a.kind == .place ? .place : (a.kind == .road ? .road : .water)
            let x = nw.x + Double(a.pos.x) * w, y = nw.y + Double(a.pos.y) * h
            out.append(Anchor(text: text, style: style, priority: a.priority, minZoom: a.minZoom, place: a.kind == .place, hasDir: a.dir != .zero,
                              x: x, y: y, ax: x + Double(a.dir.x) * w * 0.02, ay: y + Double(a.dir.y) * h * 0.02,
                              worldPerMeter: MapProjection.worldUnitsPerMeter(y: y)))
        }
        for a in t.pois {
            let text = Self.display(a.name, kind: .road)
            guard !text.isEmpty else { continue }
            let x = nw.x + Double(a.pos.x) * w, y = nw.y + Double(a.pos.y) * h
            out.append(Anchor(text: text, style: .poi, priority: 920 + min(a.rank, 79), minZoom: a.minZoom, place: false, hasDir: false,
                              icon: a.category.rawValue, x: x, y: y, ax: x, ay: y, worldPerMeter: MapProjection.worldUnitsPerMeter(y: y)))
        }
        let c = TileLabels(revision: t.revision, lo: SIMD2(nw.x, nw.y), hi: SIMD2(se.x, se.y), anchors: out)
        tileCache[t.id] = c
        return c
    }

    // The frame's tiles with labels, deepest first, kept while the same frame is drawn again.
    private var orderStamp = Int.min
    private var wanted: [TileGeometry] = []
    /// The prepared tiles of `wanted`, in the same order.
    private var order: [TileLabels] = []
    /// Tiles of the frame still to be prepared (their labels join in one of the next frames).
    private(set) var hasUnpreparedTiles = false
    /// The frame's elevation grids; anchors look their elevation up again when these change.
    private var terrainIDs: [TileID] = []
    private var terrainEpoch = 0

    /// Brings `order` up to date with the frame, preparing new tiles for at most `budget` seconds
    /// (always at least one, so labels keep arriving).
    private func refreshTiles(_ frame: MapFrame, budget: CFTimeInterval) {
        if frame.stamp == 0 || frame.stamp != orderStamp {
            orderStamp = frame.stamp
            wanted = frame.tiles.filter { !$0.labels.isEmpty || !$0.pois.isEmpty }.sorted { $0.id.z > $1.id.z }
            hasUnpreparedTiles = true
            if tileCache.count > 2 * frame.tiles.count + 64 {
                let keep = Set(frame.tiles.map(\.id))
                tileCache = tileCache.filter { keep.contains($0.key) }
            }
            if !frame.terrain.map(\.id).elementsEqual(terrainIDs) {
                terrainIDs = frame.terrain.map(\.id)
                terrainEpoch += 1
            }
        }
        guard hasUnpreparedTiles else { return }
        let deadline = budget.isFinite ? CACurrentMediaTime() + budget : .infinity
        var preparedOne = false
        hasUnpreparedTiles = false
        order.removeAll(keepingCapacity: true)
        for t in wanted {
            if let c = tileCache[t.id], c.revision == t.revision {
                order.append(c)
            } else if !preparedOne || deadline == .infinity || CACurrentMediaTime() < deadline {
                order.append(prepare(t))
                preparedOne = true
            } else {
                hasUnpreparedTiles = true
                // The tile's earlier revision (before its contours arrived) serves meanwhile.
                if let stale = tileCache[t.id] { order.append(stale) }
            }
        }
    }

    // MARK: Placement

    private var boxes: [LabelBox] = []
    private var candidates: [Placed] = []

    /// Places labels for a frame as drawn by `proj`. Deepest tiles win duplicates (same text and
    /// kind). Cluster counts (`counts`: text and the left end of its box) go first so names never
    /// cover them. Labels on screen in the previous frame are placed before new ones.
    /// `prepareBudget`: seconds this call may spend preparing tiles it hasn't seen (see
    /// `hasUnpreparedTiles`).
    func place(frame: MapFrame, projection proj: any MapScreenProjection, counts: [(text: String, left: SIMD2<Double>)] = [],
               prepareBudget: CFTimeInterval = .infinity) -> [Placed] {
        if texts.count > Self.maxStrings { startOver() }
        refreshTiles(frame, budget: prepareBudget)
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
        let half = Self.labelHeight / 2
        /// Anchors further than this from the view can't put a label in it.
        let far = Self.widestLabel / 2 + half
        /// False when none of a tile's anchors can be near the view (the frame carries a ring of
        /// tiles around it). Raised terrain moves anchors off their place on the ground plane.
        func mayShow(_ tile: TileLabels) -> Bool {
            guard flat != nil else { return true }
            let margin = far + 10 + (lifted ? 0.3 * max(vp.x, vp.y) + 200 : 0)
            var lo = SIMD2<Double>(repeating: .infinity), hi = -lo
            for corner in 0..<4 {
                let c = m * SIMD4(corner & 1 == 0 ? tile.lo.x : tile.hi.x, corner & 2 == 0 ? tile.lo.y : tile.hi.y, 0, 1)
                guard c.w > 1e-9 else { return true }
                let s = SIMD2((c.x / c.w + 1) / 2 * vp.x, (1 - c.y / c.w) / 2 * vp.y)
                lo = simd_min(lo, s); hi = simd_max(hi, s)
            }
            return hi.x > -margin && hi.y > -margin && lo.x < vp.x + margin && lo.y < vp.y + margin
        }

        boxes.removeAll(keepingCapacity: true)
        candidates.removeAll(keepingCapacity: true)
        for c in counts where !c.text.isEmpty {
            let id = intern(c.text, .count)
            let w = width(of: id) + 6
            let center = SIMD2(c.left.x + w / 2, c.left.y)
            boxes.append(LabelBox(center: center, size: SIMD2(w, Self.labelHeight), priority: Int.min / 2, keep: placedIn[Int(id)] == frameNo - 1))
            candidates.append(Placed(id: id, style: .count, center: center, angle: 0))
        }
        let countBoxes = boxes.count
        for tile in order where mayShow(tile) {
            let full = tile.anchors.withUnsafeMutableBufferPointer { anchors -> Bool in
                for i in anchors.indices where anchors[i].minZoom <= zoom {
                    let icon = anchors[i].icon
                    // A name shows once per frame; points of interest repeat (two cafés of a chain),
                    // and the collision pass drops a copy in the same spot.
                    if icon != 0 {
                        guard frame.poiMask & (1 << UInt16(icon)) != 0 else { continue }
                    } else if anchors[i].idEpoch == epoch, seenIn[Int(anchors[i].id)] == frameNo { continue }
                    var z = 0.0
                    if lifted {
                        if anchors[i].rawEpoch != terrainEpoch {
                            anchors[i].raw = frame.rawElevation(at: Mercator(x: anchors[i].x, y: anchors[i].y)) ?? .nan
                            anchors[i].rawEpoch = terrainEpoch
                        }
                        if !anchors[i].raw.isNaN { z = frame.lift.lift(anchors[i].raw) }
                    }
                    guard let s = screen(anchors[i].x, anchors[i].y, z, anchors[i].worldPerMeter) else { continue }
                    // Too far for any label to reach the view: its text is never looked at.
                    guard s.x > -far, s.y > -far - 10, s.x < vp.x + far, s.y < vp.y + far else { continue }
                    let a = anchors[i]
                    let id: Int32
                    if a.idEpoch == epoch { id = a.id } else {
                        id = intern(a.text, a.style)
                        anchors[i].id = id; anchors[i].idEpoch = epoch
                        if icon == 0, seenIn[Int(id)] == frameNo { continue }
                    }
                    let textWidth = width(of: id)
                    let tw = textWidth + 8
                    // Nothing wider than this can reach the view from here.
                    let reach = tw / 2 + half
                    guard s.x > -reach, s.y > -reach - 10, s.x < vp.x + reach, s.y < vp.y + reach else { continue }
                    let keep = placedIn[Int(id)] == frameNo - 1
                    if icon != 0 {
                        // Glyph on the point, name to its right.
                        let left = s.x - Self.iconSize / 2 - 1
                        let wbox = Self.iconSize + Self.iconGap + textWidth + 4
                        let box = SIMD2(left + wbox / 2, s.y)
                        guard box.x + wbox / 2 > 0, box.y + half > 0, box.x - wbox / 2 < vp.x, box.y - half < vp.y else { continue }
                        seenIn[Int(id)] = frameNo
                        boxes.append(LabelBox(center: box, size: SIMD2(wbox, Self.labelHeight), priority: a.priority, keep: keep))
                        candidates.append(Placed(id: id, style: .poi, center: SIMD2(s.x + Self.iconSize / 2 + Self.iconGap + textWidth / 2, s.y),
                                                 angle: 0, icon: icon, iconCenter: s))
                        if boxes.count >= Self.maxCandidates { return true }
                        continue
                    }
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
                    seenIn[Int(id)] = frameNo
                    boxes.append(LabelBox(center: center, size: size, priority: a.priority, keep: keep))
                    candidates.append(Placed(id: id, style: a.style, center: center, angle: angle))
                    if boxes.count >= Self.maxCandidates { return true }
                }
                return false
            }
            if full { break }
        }
        var out: [Placed] = []
        out.reserveCapacity(Self.maxLabels + Self.maxPOIs + countBoxes)
        Self.drawnPOIs.removeAll(keepingCapacity: true)
        var names = 0, pois = 0
        for i in LabelPlacer.place(boxes: boxes, viewport: vp, max: Self.maxLabels + Self.maxPOIs + countBoxes, padding: 4) {
            let c = candidates[i]
            if c.style == .poi {
                guard pois < Self.maxPOIs else { continue }
                pois += 1
            } else if c.style != .count {
                guard names < Self.maxLabels else { continue }
                names += 1
            }
            placedIn[Int(c.id)] = frameNo
            out.append(c)
            if c.icon != 0 { Self.drawnPOIs.append((c.iconCenter, texts[Int(c.id)])) }
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

    /// Glyphs share the slot table with strings, under negative ids.
    private static func iconID(_ category: POICategory) -> Int32 { -Int32(category.rawValue) - 1 }

    /// The slot of a string that is already in the atlas (nothing is rasterised).
    func cachedSlot(_ id: Int32) -> Slot? { slots[id] }

    /// The slot of a glyph that is already in the atlas (nothing is rasterised).
    func cachedIconSlot(_ category: POICategory) -> Slot? { slots[Self.iconID(category)] }

    /// The slot holding a place category's glyph (an SF Symbol), rasterised on first use; nil
    /// when the atlas has no room left.
    func iconSlot(_ category: POICategory) -> Slot? {
        let id = Self.iconID(category)
        if let s = slots[id] { return s }
        guard let texture, let ctx = scratch else { return nil }
        let side = min(ctx.height, Int((CGFloat(MapLabelPlanner.iconSize) * scale).rounded(.up)) + 2)
        if penX + side > Self.width { penX = 0; penY += rowHeight }
        guard penY + side <= Self.height else { return nil }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        // Rasterised at the atlas scale and used as a coverage mask (drawing the image straight
        // into a one-channel bitmap paints nothing).
        let cfg = NSImage.SymbolConfiguration(pointSize: 8.5 * scale, weight: .semibold)
        if let img = NSImage(systemSymbolName: category.symbol, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
            var r = NSRect(origin: .zero, size: img.size)
            if let cg = img.cgImage(forProposedRect: &r, context: nil, hints: nil) {
                // Fit the symbol in the box, centred (symbols differ in width).
                let box = (CGFloat(MapLabelPlanner.iconSize) - 1) * scale
                let k = min(1, box / max(img.size.width, img.size.height, 1))
                let w = img.size.width * k, h = img.size.height * k
                ctx.saveGState()
                ctx.clip(to: CGRect(x: (CGFloat(side) - w) / 2, y: (CGFloat(side) - h) / 2, width: w, height: h), mask: cg)
                ctx.setFillColor(gray: 1, alpha: 1)
                ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
                ctx.restoreGState()
            }
        }
        guard let data = ctx.data else { return nil }
        let top = data.advanced(by: (ctx.height - side) * ctx.bytesPerRow)
        texture.replace(region: MTLRegionMake2D(penX, penY, side, side), mipmapLevel: 0, withBytes: top, bytesPerRow: ctx.bytesPerRow)
        let s = Slot(x: penX, y: penY, w: side, h: side)
        slots[id] = s
        penX += side + 1
        return s
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
