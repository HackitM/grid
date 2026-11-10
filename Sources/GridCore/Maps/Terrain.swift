import Foundation
import simd

/// Elevation data: AWS Terrain Tiles in the "Terrarium" encoding (256 px PNG, RGB), decoded by the
/// app (ImageIO) and handed here as raw bytes. Pure math: decoding, per-tile grids, contours.
public enum Terrarium {
    /// The tile that holds elevation for a map tile: the same tile, or its z12 ancestor for deeper
    /// tiles (elevation sources are ~30 m; z12 is ~38 m per pixel at the equator).
    public static let maxDEMZoom = 12

    public static func demTile(for t: TileID) -> TileID {
        var d = t
        while Int(d.z) > maxDEMZoom, let p = TileMath.parent(d) { d = p }
        return d
    }

    /// Elevations in metres from Terrarium pixels: (R·256 + G + B/256) − 32768.
    /// `bytes` is `width × height` pixels of `bytesPerPixel` (3 or 4, RGB first), row-major.
    public static func decode(_ bytes: [UInt8], width: Int, height: Int, bytesPerPixel: Int, bytesPerRow: Int? = nil) -> [Float]? {
        guard width > 0, height > 0, width <= 1024, height <= 1024, bytesPerPixel >= 3 else { return nil }
        let row = bytesPerRow ?? width * bytesPerPixel
        guard row >= width * bytesPerPixel, bytes.count >= row * (height - 1) + width * bytesPerPixel else { return nil }
        var out = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let o = y * row + x * bytesPerPixel
                let v = Float(bytes[o]) * 256 + Float(bytes[o + 1]) + Float(bytes[o + 2]) / 256 - 32768
                out[y * width + x] = max(-11_000, min(9_000, v))
            }
        }
        return out
    }

    /// The `TerrainGrid` for map tile `t` from its DEM tile's elevations (`demSize²` samples).
    /// Samples sit at tile-local (i/(n−1), j/(n−1)), read bilinearly from the DEM.
    public static func grid(for t: TileID, dem: TileID, heights: [Float], demSize: Int) -> TerrainGrid? {
        guard demSize >= 2, heights.count == demSize * demSize, dem.z <= t.z else { return nil }
        let dz = Int(t.z) - Int(dem.z)
        let scale = Double(1 << dz)
        let ox = Double(t.x) - Double(dem.x) * scale, oy = Double(t.y) - Double(dem.y) * scale
        guard ox >= 0, oy >= 0, ox < scale, oy < scale else { return nil }
        let n = TerrainGrid.size
        var out = [Float](repeating: 0, count: n * n)
        let last = Double(demSize - 1)
        func sample(_ px: Double, _ py: Double) -> Float {
            let x = min(max(px, 0), last), y = min(max(py, 0), last)
            let x0 = min(Int(x), demSize - 2), y0 = min(Int(y), demSize - 2)
            let fx = Float(x - Double(x0)), fy = Float(y - Double(y0))
            let a = heights[y0 * demSize + x0], b = heights[y0 * demSize + x0 + 1]
            let c = heights[(y0 + 1) * demSize + x0], d = heights[(y0 + 1) * demSize + x0 + 1]
            return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy
        }
        for j in 0..<n {
            for i in 0..<n {
                // DEM-local 0…1, then pixel centres: pixel k covers [k, k+1) / demSize.
                let u = (ox + Double(i) / Double(n - 1)) / scale, v = (oy + Double(j) / Double(n - 1)) / scale
                out[j * n + i] = sample(u * Double(demSize) - 0.5, v * Double(demSize) - 0.5)
            }
        }
        return TerrainGrid(id: t, heights: out)
    }
}

/// Contour lines from a terrain grid (marching squares, joined into polylines).
public enum Contours {
    public struct Line: Sendable, Equatable {
        public var level: Float          // in display units (metres or feet)
        public var isIndex: Bool
        public var points: [SIMD2<Float>] // tile-local 0…1
        public var closed: Bool
    }

    /// Contour interval and index spacing for a map tile zoom, in display units; nil = no contours.
    public static func interval(zoom: Int, feet: Bool) -> (minor: Float, index: Float)? {
        switch (zoom, feet) {
        case (14..., false): (10, 50)
        case (13, false): (20, 100)
        case (12, false): (50, 250)
        case (11, false): (100, 500)
        case (10, false): (200, 1000)
        case (9, false): (250, 1250)
        case (14..., true): (40, 200)
        case (13, true): (80, 400)
        case (12, true): (200, 1000)
        case (11, true): (400, 2000)
        case (10, true): (800, 4000)
        case (9, true): (1000, 5000)
        default: nil
        }
    }

    /// Contours of `grid` every `step` (display units); `scale` converts metres to display units.
    public static func lines(_ grid: TerrainGrid, step: Float, indexStep: Float, scale: Float = 1, maxLevels: Int = 120) -> [Line] {
        let n = TerrainGrid.size
        guard grid.heights.count == n * n, step > 0 else { return [] }
        let h = grid.heights.map { $0 * scale }
        // Levels strictly inside (min, max): a level equal to the summit would be a dot.
        let lo = (grid.minHeight * scale / step).rounded(.down) + 1, hi = (grid.maxHeight * scale / step).rounded(.up) - 1
        guard hi >= lo, Int(hi - lo) < maxLevels else { return [] }
        var out: [Line] = []
        var level = lo
        while level <= hi {
            let z = level * step
            out.append(contentsOf: trace(h, n: n, level: z).map {
                Line(level: z, isIndex: abs(z / indexStep - (z / indexStep).rounded()) < 1e-4, points: $0.0, closed: $0.1)
            })
            level += 1
        }
        return out
    }

    /// Marching squares for one level, joined into polylines.
    static func trace(_ h: [Float], n: Int, level: Float) -> [([SIMD2<Float>], Bool)] {
        // Edge ids: horizontal edge (i,j)-(i+1,j) = j*(n-1)+i; vertical edge (i,j)-(i,j+1) = H + j*n+i.
        let H = n * (n - 1)
        func value(_ i: Int, _ j: Int) -> Float {
            let v = h[j * n + i]
            return v == level ? v + 1e-3 : v          // no sample exactly on the level
        }
        func point(_ e: Int) -> SIMD2<Float> {
            let inv = 1 / Float(n - 1)
            if e < H {
                let j = e / (n - 1), i = e % (n - 1)
                let a = value(i, j), b = value(i + 1, j)
                let t = (level - a) / (b - a)
                return SIMD2((Float(i) + t) * inv, Float(j) * inv)
            }
            let k = e - H, j = k / n, i = k % n
            let a = value(i, j), b = value(i, j + 1)
            let t = (level - a) / (b - a)
            return SIMD2(Float(i) * inv, (Float(j) + t) * inv)
        }
        var segs: [(Int, Int)] = []
        for j in 0..<(n - 1) {
            for i in 0..<(n - 1) {
                let tl = value(i, j), tr = value(i + 1, j), br = value(i + 1, j + 1), bl = value(i, j + 1)
                let c = (tl > level ? 8 : 0) | (tr > level ? 4 : 0) | (br > level ? 2 : 0) | (bl > level ? 1 : 0)
                if c == 0 || c == 15 { continue }
                let top = j * (n - 1) + i, bottom = (j + 1) * (n - 1) + i
                let left = H + j * n + i, right = H + j * n + i + 1
                switch c {
                case 1, 14: segs.append((left, bottom))
                case 2, 13: segs.append((bottom, right))
                case 3, 12: segs.append((left, right))
                case 4, 11: segs.append((top, right))
                case 6, 9: segs.append((top, bottom))
                case 7, 8: segs.append((left, top))
                case 5, 10:
                    // Saddle: decide by the cell centre.
                    let centre = (tl + tr + br + bl) / 4 > level
                    if (c == 5) == centre { segs.append((left, top)); segs.append((bottom, right)) }
                    else { segs.append((left, bottom)); segs.append((top, right)) }
                default: break
                }
            }
        }
        guard !segs.isEmpty else { return [] }
        // Join segments sharing edge points.
        var byEdge: [Int: [Int]] = [:]
        for (k, s) in segs.enumerated() { byEdge[s.0, default: []].append(k); byEdge[s.1, default: []].append(k) }
        var used = [Bool](repeating: false, count: segs.count)
        var out: [([SIMD2<Float>], Bool)] = []
        func next(from e: Int, excluding k: Int) -> Int? { byEdge[e]?.first { $0 != k && !used[$0] } }
        for start in segs.indices where !used[start] {
            used[start] = true
            var chain = [segs[start].0, segs[start].1]
            // Extend forward, then backward.
            var cur = start
            while let k = next(from: chain.last!, excluding: cur) {
                used[k] = true; cur = k
                let s = segs[k]
                chain.append(s.0 == chain.last! ? s.1 : s.0)
            }
            cur = start
            while let k = next(from: chain.first!, excluding: cur) {
                used[k] = true; cur = k
                let s = segs[k]
                chain.insert(s.0 == chain.first! ? s.1 : s.0, at: 0)
            }
            let closed = chain.count > 3 && chain.first == chain.last
            if closed { chain.removeLast() }
            out.append((chain.map(point), closed))
        }
        return out
    }

    /// Contour line batches and elevation labels for a map tile.
    public static func geometry(_ grid: TerrainGrid, feet: Bool) -> (lines: [LineBatch], labels: [LabelAnchor]) {
        guard let iv = interval(zoom: Int(grid.id.z), feet: feet) else { return ([], []) }
        let scale: Float = feet ? 3.28084 : 1
        let contours = lines(grid, step: iv.minor, indexStep: iv.index, scale: scale)
        var minorV: [LineVertex] = [], minorI: [UInt32] = [], indexV: [LineVertex] = [], indexI: [UInt32] = []
        var labels: [LabelAnchor] = []
        let fmt = NumberFormatter()
        fmt.numberStyle = .decimal
        fmt.maximumFractionDigits = 0
        for c in contours where c.points.count >= 2 {
            if c.isIndex {
                LineTessellator.append(c.points, closed: c.closed, cls: .contourIndex, flags: 0, vertices: &indexV, indices: &indexI)
                // One height label per long index line, on its middle segment, running along it.
                if c.points.count >= 12, labels.count < 24 {
                    let m = c.points.count / 2
                    let a = c.points[m - 1], b = c.points[m]
                    let d = b - a, len = simd_length(d)
                    if len > 0, a.x > 0.05, a.x < 0.95, a.y > 0.05, a.y < 0.95 {
                        let text = (fmt.string(from: NSNumber(value: c.level)) ?? "\(Int(c.level))") + (feet ? " ft" : " m")
                        labels.append(LabelAnchor(text: text, kind: .road, priority: 80, pos: (a + b) / 2,
                                                  minZoom: Float(grid.id.z), dir: d / len))
                    }
                }
            } else {
                LineTessellator.append(c.points, closed: c.closed, cls: .contour, flags: 0, vertices: &minorV, indices: &minorI)
            }
        }
        var batches: [LineBatch] = []
        if !minorV.isEmpty { batches.append(LineBatch(cls: .contour, vertices: minorV, indices: minorI)) }
        if !indexV.isEmpty { batches.append(LineBatch(cls: .contourIndex, vertices: indexV, indices: indexI)) }
        return (batches, labels)
    }
}

/// How elevation is drawn in the tilted 3D view, shared by the GPU (vertex displacement) and the
/// CPU (labels, markers) so both agree exactly.
/// - Heights below sea level draw at sea level (Terrarium holds ocean depths; water stays flat).
/// - Heights are relative to the terrain under the camera centre, so the camera's height above
///   the ground doesn't change as you fly over mountains.
/// - Rises ease toward `ceiling` (metres) instead of passing it, so a nearby peak never climbs
///   above the camera and cuts through the near plane.
public struct TerrainLift: Sendable, Equatable {
    /// Exaggeration × tilt ease; 0 draws the map flat.
    public var scale: Float
    /// Elevation under the camera centre (metres, ≥ 0).
    public var base: Float
    /// Soft upper bound for lifts (metres); 0 = none.
    public var ceiling: Float

    public static let flat = TerrainLift(scale: 0, base: 0, ceiling: 0)

    public init(scale: Float, base: Float, ceiling: Float) {
        self.scale = max(0, scale); self.base = max(0, base); self.ceiling = max(0, ceiling)
    }

    public var isFlat: Bool { scale <= 0 }

    /// Metres drawn above the ground plane for an elevation in metres.
    public func lift(_ h: Double) -> Double {
        guard scale > 0 else { return 0 }
        let r = (max(h, 0) - Double(base)) * Double(scale)
        guard r > 0, ceiling > 0 else { return r }
        return r * Double(ceiling) / (Double(ceiling) + r)
    }
}
