import Foundation
import simd

/// Spatial index over a camera set: cameras are bucketed by z12 tile (contiguous storage sorted by
/// tile key), so box queries and nearest-neighbour lookups only touch nearby buckets.
public struct CameraIndex: Sendable {
    public let cameras: [ALPRCamera]
    private let mercator: [SIMD2<Double>]            // by camera index
    private let order: [Int32]                       // camera indices grouped by bucket
    private let buckets: [UInt32: Range<Int32>]      // z12 tile key → range in `order`

    private static let z = 12
    private static let side = 1 << 12

    private static func key(_ x: Int, _ y: Int) -> UInt32 { UInt32(x * side + y) }
    private static func tileXY(_ m: Mercator) -> (Int, Int) {
        let n = Double(side)
        return (TileMath.cell(m.x * n, count: side), TileMath.cell(m.y * n, count: side))
    }

    public init(_ cameras: [ALPRCamera]) {
        self.cameras = cameras
        var merc = [SIMD2<Double>](repeating: .zero, count: cameras.count)
        var keys = [UInt32](repeating: 0, count: cameras.count)
        for (i, c) in cameras.enumerated() {
            let m = TileMath.project(c.coordinate)
            merc[i] = SIMD2(m.x, m.y)
            let (tx, ty) = Self.tileXY(m)
            keys[i] = Self.key(tx, ty)
        }
        let ord = (0..<cameras.count).sorted { keys[$0] != keys[$1] ? keys[$0] < keys[$1] : $0 < $1 }
        var buckets: [UInt32: Range<Int32>] = [:]
        var start = 0
        while start < ord.count {
            let k = keys[ord[start]]
            var end = start + 1
            while end < ord.count, keys[ord[end]] == k { end += 1 }
            buckets[k] = Int32(start)..<Int32(end)
            start = end
        }
        mercator = merc
        order = ord.map { Int32($0) }
        self.buckets = buckets
    }

    /// Calls `body` for every camera index in the buckets overlapping the Mercator rectangle.
    private func forEachCandidate(minX: Double, minY: Double, maxX: Double, maxY: Double, _ body: (Int) -> Void) {
        let (x0, y0) = Self.tileXY(Mercator(x: minX, y: minY)), (x1, y1) = Self.tileXY(Mercator(x: maxX, y: maxY))
        let tiles = (x1 - x0 + 1) * (y1 - y0 + 1)
        if tiles <= buckets.count {
            for x in x0...x1 { for y in y0...y1 {
                if let r = buckets[Self.key(x, y)] { for k in r { body(Int(order[Int(k)])) } }
            } }
        } else {
            for (k, r) in buckets {
                let x = Int(k) / Self.side, y = Int(k) % Self.side
                if x >= x0, x <= x1, y >= y0, y <= y1 { for i in r { body(Int(order[Int(i)])) } }
            }
        }
    }

    /// Indices (ascending) of cameras inside the box.
    public func query(_ box: BBox) -> [Int] {
        guard box.isValid, !cameras.isEmpty else { return [] }
        let a = TileMath.project(LonLat(lon: box.west, lat: box.north)), b = TileMath.project(LonLat(lon: box.east, lat: box.south))
        var out: [Int] = []
        forEachCandidate(minX: a.x, minY: a.y, maxX: b.x, maxY: b.y) { i in
            if box.contains(cameras[i].coordinate) { out.append(i) }
        }
        out.sort()
        return out
    }

    /// Grid clusters (cells of `cellWorld` Mercator units) of the cameras in the box. A cell with
    /// one camera is that camera. Sorted by representative index.
    public func clusters(_ box: BBox, cellWorld: Double) -> [CameraCluster] {
        let idx = query(box)
        guard cellWorld.isFinite, cellWorld > 1e-9 else {
            return idx.map { CameraCluster(count: 1, center: cameras[$0].coordinate, representative: $0) }
        }
        struct Cell: Hashable { var x: Int64; var y: Int64 }
        struct Acc { var count = 0; var sum = SIMD2<Double>.zero; var rep = 0 }
        var cells: [Cell: Acc] = [:]
        for i in idx {   // ascending, so the first camera seen is the lowest index
            let m = mercator[i]
            let c = Cell(x: Int64((m.x / cellWorld).rounded(.down)), y: Int64((m.y / cellWorld).rounded(.down)))
            var acc = cells[c] ?? Acc(count: 0, sum: .zero, rep: i)
            acc.count += 1; acc.sum += m
            cells[c] = acc
        }
        return cells.values.map { a in
            let center: LonLat
            if a.count == 1 { center = cameras[a.rep].coordinate }
            else { center = TileMath.unproject(Mercator(x: a.sum.x / Double(a.count), y: a.sum.y / Double(a.count))) }
            return CameraCluster(count: a.count, center: center, representative: a.rep)
        }.sorted { $0.representative < $1.representative }
    }

    /// The nearest camera (Mercator distance) within `maxWorldDistance`; ties go to the lower index.
    public func nearest(to p: LonLat, maxWorldDistance: Double) -> Int? {
        guard p.isValid, maxWorldDistance.isFinite, maxWorldDistance >= 0, !cameras.isEmpty else { return nil }
        let m = TileMath.project(p)
        var best: Int?
        var bestD = Double.infinity
        let limit2 = maxWorldDistance * maxWorldDistance
        forEachCandidate(minX: m.x - maxWorldDistance, minY: m.y - maxWorldDistance,
                         maxX: m.x + maxWorldDistance, maxY: m.y + maxWorldDistance) { i in
            let dx = mercator[i].x - m.x, dy = mercator[i].y - m.y
            let d = dx * dx + dy * dy
            if d <= limit2, d < bestD || (d == bestD && i < (best ?? Int.max)) { best = i; bestD = d }
        }
        return best
    }
}
