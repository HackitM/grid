#if DEBUG
import Foundation
import GridCore
import simd

// Synthetic map geometry for checking the renderer before real tiles exist (Brief C step 6).
// Deterministic per TileID: a road lattice graded by class, a river, a lake with a shoreline,
// a park, a landuse block, extruded buildings and a few labels. Debug builds only; the QA page
// wires `frame(...)` through a `--qa` hook.

enum MapDebugGeometry {
    /// A frame covering the camera's view with synthetic tiles (≤ `maxTiles`) and overlay samples.
    @MainActor
    static func frame(camera: MapCamera, viewport: SIMD2<Double>, palette: MapPalette, glow: Bool = true, buildings: Bool = true,
                      maxTiles: Int = 48, overlays: Bool = true) -> MapFrame {
        let ids = TileMath.cover(camera, viewport: viewport, maxZoom: 14, limit: maxTiles)
        let tiles = ids.map { tile($0) }
        var f = MapFrame(camera: camera, tileGeneration: 0, tiles: tiles, palette: palette, glow: glow, buildings: buildings)
        guard overlays else { return f }
        let c = camera.center
        let span = viewport.x * 0.3 / (256 * pow(2, camera.zoom))   // about a third of the viewport width in world units
        var cams: [CameraMarker] = []
        for i in 0..<14 {
            let a = Double(i) / 14 * 2 * .pi
            let r = span * (0.35 + 0.5 * Double(i % 3) / 2)
            cams.append(CameraMarker(world: Mercator(x: c.x + cos(a) * r, y: c.y + sin(a) * r * 0.7),
                                     directions: i % 4 == 0 ? [] : [UInt16((i * 47) % 360), UInt16((i * 47 + 180) % 360)].prefix(i % 3 == 1 ? 2 : 1).map { $0 },
                                     isFlock: i % 2 == 0, selected: i == 3, index: i))
        }
        f.cameras = cams
        f.clusters = [ClusterMarker(world: Mercator(x: c.x - span * 1.2, y: c.y - span * 0.9), count: 7),
                      ClusterMarker(world: Mercator(x: c.x + span * 1.3, y: c.y + span * 0.8), count: 1284)]
        f.location = LocationMarker(world: Mercator(x: c.x + span * 0.15, y: c.y + span * 0.55), accuracyMeters: 65)
        let rw = span * 1.6, rh = span * 1.0
        f.regions = [RegionOutline(rings: [[Mercator(x: c.x - rw, y: c.y - rh), Mercator(x: c.x + rw, y: c.y - rh),
                                            Mercator(x: c.x + rw, y: c.y + rh), Mercator(x: c.x - rw, y: c.y + rh)]], highlighted: false)]
        return f
    }

    /// Synthetic geometry for one tile, in tile-local 0…1.
    static func tile(_ id: TileID) -> TileGeometry {
        var rng = SplitMix(seed: UInt64(id.z) << 56 | UInt64(id.x) << 28 | UInt64(id.y))
        var fills: [FillBatch] = []
        var lines: [LineBatch] = []
        var labels: [LabelAnchor] = []

        // Landuse block and a park (convex quads).
        fills.append(fan(.landuse, [SIMD2(0.08, 0.55), SIMD2(0.42, 0.55), SIMD2(0.42, 0.92), SIMD2(0.08, 0.92)]))
        fills.append(fan(.park, [SIMD2(0.58, 0.08), SIMD2(0.9, 0.1), SIMD2(0.92, 0.4), SIMD2(0.6, 0.42)]))

        // Lake: a wobbly blob (fill + shoreline line batch of class .water).
        var lake: [SIMD2<Float>] = []
        for i in 0..<24 {
            let a = Float(i) / 24 * 2 * .pi
            let r: Float = 0.13 + 0.03 * sin(a * 3 + Float(rng.next() % 100) / 100)
            lake.append(SIMD2(0.72 + cos(a) * r, 0.72 + sin(a) * r * 0.8))
        }
        fills.append(fan(.water, lake))
        var sv: [LineVertex] = [], si: [UInt32] = []
        strip(lake, closed: true, cls: .water, flags: 0, vertices: &sv, indices: &si)
        lines.append(LineBatch(cls: .water, vertices: sv, indices: si))

        // River: a sine through the tile.
        var river: [SIMD2<Float>] = []
        for i in 0...16 { let t = Float(i) / 16; river.append(SIMD2(t, 0.3 + 0.08 * sin(t * 6))) }
        var rv: [LineVertex] = [], ri: [UInt32] = []
        strip(river, closed: false, cls: .waterway, flags: 0, vertices: &rv, indices: &ri)
        lines.append(LineBatch(cls: .waterway, vertices: rv, indices: ri))

        // Road lattice graded by class: a motorway on the diagonal, primaries at thirds, minors in between.
        func road(_ pts: [SIMD2<Float>], _ cls: RenderClass, flags: UInt16 = 0) {
            var v: [LineVertex] = [], ix: [UInt32] = []
            strip(pts, closed: false, cls: cls, flags: flags, vertices: &v, indices: &ix)
            if let k = lines.firstIndex(where: { $0.cls == cls }) {
                let base = UInt32(lines[k].vertices.count)
                lines[k].vertices += v; lines[k].indices += ix.map { $0 + base }
            } else { lines.append(LineBatch(cls: cls, vertices: v, indices: ix)) }
        }
        road([SIMD2(0, 1), SIMD2(0.3, 0.72), SIMD2(0.7, 0.28), SIMD2(1, 0)], .motorway)
        road([SIMD2(0, 0.5), SIMD2(1, 0.5)], .primary)
        road([SIMD2(0.5, 0), SIMD2(0.5, 1)], .primary)
        road([SIMD2(0, 0.25), SIMD2(1, 0.25)], .secondary)
        road([SIMD2(0.25, 0), SIMD2(0.25, 1)], .tertiary, flags: LineVertex.tunnel)
        road([SIMD2(0.75, 0), SIMD2(0.75, 1)], .secondary)
        for i in 1..<8 where i % 2 == 1 {
            let t = Float(i) / 8
            road([SIMD2(0, t), SIMD2(1, t)], .minor)
            road([SIMD2(t, 0), SIMD2(t, 1)], .minor)
        }
        road([SIMD2(0.05, 0.05), SIMD2(0.2, 0.15), SIMD2(0.4, 0.12)], .service)
        road([SIMD2(0, 0.9), SIMD2(1, 0.95)], .rail)
        road([SIMD2(0.1, 0.6), SIMD2(0.3, 0.85)], .path)
        road([SIMD2(0, 0.02), SIMD2(1, 0.02)], .boundary)

        // Buildings: a block of boxes with roofs (flag 1) and walls (top vertices flag 2).
        var ev: [ExtrusionVertex] = [], ei: [UInt32] = []
        for bx in 0..<4 { for by in 0..<3 {
            let x0 = 0.53 + Float(bx) * 0.11 + 0.01, y0 = 0.52 + Float(by) * 0.13 + 0.01
            let w: Float = 0.07 + Float(rng.next() % 20) / 1000, h: Float = 0.08
            let height = Float(12 + rng.next() % 70)
            box([SIMD2(x0, y0), SIMD2(x0 + w, y0), SIMD2(x0 + w, y0 + h), SIMD2(x0, y0 + h)], height: height, vertices: &ev, indices: &ei)
        } }
        let extrusion = ExtrusionBatch(vertices: ev, indices: ei)

        labels.append(LabelAnchor(text: "Sector \(id.x % 97)-\(id.y % 89)", kind: .place, priority: 2, pos: SIMD2(0.5, 0.48), minZoom: 0))
        labels.append(LabelAnchor(text: "Grid Lake", kind: .water, priority: 5, pos: SIMD2(0.72, 0.72), minZoom: 10))
        labels.append(LabelAnchor(text: "Encom Avenue", kind: .road, priority: 8, pos: SIMD2(0.3, 0.5), minZoom: 13))
        labels.append(LabelAnchor(text: "Light Cycle Way", kind: .road, priority: 9, pos: SIMD2(0.5, 0.75), minZoom: 13))

        let bytes = fills.reduce(0) { $0 + $1.positions.count * 8 + $1.indices.count * 4 }
            + lines.reduce(0) { $0 + $1.vertices.count * 32 + $1.indices.count * 4 } + ev.count * 16 + ei.count * 4
        return TileGeometry(id: id, fills: fills, lines: lines, extrusion: extrusion, labels: labels, byteCount: bytes)
    }

    // MARK: Helpers (debug quality: fan triangulation of convex rings, per-segment quads)

    private static func fan(_ cls: RenderClass, _ ring: [SIMD2<Float>]) -> FillBatch {
        var idx: [UInt32] = []
        for i in 1..<(ring.count - 1) { idx += [0, UInt32(i), UInt32(i + 1)] }
        return FillBatch(cls: cls, positions: ring, indices: idx)
    }

    /// Per-segment quads with averaged normals at interior joins (no miter clamp needed here).
    private static func strip(_ pts: [SIMD2<Float>], closed: Bool, cls: RenderClass, flags: UInt16,
                              vertices: inout [LineVertex], indices: inout [UInt32]) {
        let n = pts.count
        guard n >= 2 else { return }
        let count = closed ? n + 1 : n
        var along: Float = 0
        let base = UInt32(vertices.count)
        for i in 0..<count {
            let p = pts[i % n]
            let prev = pts[(i - 1 + n) % n], next = pts[(i + 1) % n]
            var dir: SIMD2<Float>
            if closed { dir = simd_normalize(simd_normalize(next - p) + simd_normalize(p - prev)) }
            else if i == 0 { dir = simd_normalize(next - p) }
            else if i == n - 1 { dir = simd_normalize(p - prev) }
            else { dir = simd_normalize(simd_normalize(next - p) + simd_normalize(p - prev)) }
            if !(dir.x.isFinite && dir.y.isFinite) { dir = SIMD2(1, 0) }
            let normal = SIMD2(-dir.y, dir.x)
            if i > 0 { along += simd_length(p - pts[(i - 1) % n]) }
            vertices.append(LineVertex(pos: p, normal: normal, side: -1, along: along, cls: cls.rawValue, flags: flags))
            vertices.append(LineVertex(pos: p, normal: normal, side: 1, along: along, cls: cls.rawValue, flags: flags))
            if i > 0 {
                let a = base + UInt32((i - 1) * 2)
                indices += [a, a + 1, a + 2, a + 1, a + 3, a + 2]
            }
        }
    }

    /// Roof (fan, flag roof) and walls (two triangles per edge; top vertices flag wallTop).
    private static func box(_ ring: [SIMD2<Float>], height: Float, vertices: inout [ExtrusionVertex], indices: inout [UInt32]) {
        let base = UInt32(vertices.count)
        for p in ring { vertices.append(ExtrusionVertex(pos: p, height: height, shade: 65535, flags: ExtrusionVertex.roof)) }
        for i in 1..<(ring.count - 1) { indices += [base, base + UInt32(i), base + UInt32(i + 1)] }
        let n = ring.count
        for i in 0..<n {
            let a = ring[i], b = ring[(i + 1) % n]
            let d = simd_normalize(b - a)
            // Light from the north-west: faces whose outward normal points that way are brighter.
            let normal = SIMD2(d.y, -d.x)
            let light = simd_normalize(SIMD2<Float>(-0.6, -0.8))
            let shade = UInt16(max(0, min(65535, Int((0.35 + 0.65 * max(0, simd_dot(normal, light))) * 65535))))
            let w = UInt32(vertices.count)
            vertices.append(ExtrusionVertex(pos: a, height: 0, shade: shade, flags: 0))
            vertices.append(ExtrusionVertex(pos: b, height: 0, shade: shade, flags: 0))
            vertices.append(ExtrusionVertex(pos: b, height: height, shade: shade, flags: ExtrusionVertex.wallTop))
            vertices.append(ExtrusionVertex(pos: a, height: height, shade: shade, flags: ExtrusionVertex.wallTop))
            indices += [w, w + 1, w + 2, w, w + 2, w + 3]
        }
    }

    struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }
}
#endif
