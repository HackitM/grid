import Foundation

/// Spatial index of a road graph's edges: which edges pass through each 0.01° cell (about a
/// kilometre). Cells are kept as sorted keys with a run of edges per key, so the whole index is
/// three flat arrays.
struct EdgeGrid {
    static let cell = 0.01
    /// Cell columns and rows cover the whole globe (and a little more), offset to be non-negative.
    /// Positions outside it (possible only in a damaged graph file) land in the outermost cells.
    private static let columnOffset = 20_000, rowOffset = 10_000
    private static let maxColumn = 2 * columnOffset, maxRow = 2 * rowOffset
    /// A single segment spanning this many cells is not indexed (two degrees: not a real road).
    private static let maxSegmentSpan = 200

    /// Sorted cell keys; cell `k` holds `items[starts[k] ..< starts[k + 1]]`.
    private var keys: [UInt32] = []
    private var starts: [Int32] = []
    /// Edge ids, ascending within a cell.
    private var items: [Int32] = []

    @inline(__always) static func key(column: Int, row: Int) -> UInt32 { UInt32(column) << 16 | UInt32(row) }
    @inline(__always) static func column(ofKey k: UInt32) -> Int { Int(k >> 16) }
    @inline(__always) static func row(ofKey k: UInt32) -> Int { Int(k & 0xFFFF) }

    /// `floor(degrees / cell) + offset`, clamped to `0...limit`. Never traps, whatever the input.
    @inline(__always) private static func index(_ degrees: Double, offset: Int, limit: Int) -> Int {
        let v = (degrees / cell).rounded(.down) + Double(offset)
        guard v.isFinite else { return v == .infinity ? limit : 0 }
        return Int(max(0, min(Double(limit), v)))
    }
    @inline(__always) static func column(_ lon: Double) -> Int { index(lon, offset: columnOffset, limit: maxColumn) }
    @inline(__always) static func row(_ lat: Double) -> Int { index(lat, offset: rowOffset, limit: maxRow) }

    /// One (cell, edge) pair as a sortable integer.
    @inline(__always) static func pack(key: UInt32, edge: Int) -> UInt64 { UInt64(key) << 32 | UInt64(UInt32(truncatingIfNeeded: edge)) }

    init(_ g: RoadGraph) {
        var pairs: [UInt64] = []
        pairs.reserveCapacity(g.edgeCount * 2)
        for e in 0..<g.edgeCount {
            // Consecutive segments mostly fall in the same cell: skip those repeats here, and
            // the rest after sorting.
            var lastKey: UInt32?
            var a = g.point(e, 0)
            for i in 1..<g.pointCount(e) {
                let b = g.point(e, i)
                let x0 = Self.column(min(a.lon, b.lon)), x1 = Self.column(max(a.lon, b.lon))
                let y0 = Self.row(min(a.lat, b.lat)), y1 = Self.row(max(a.lat, b.lat))
                a = b
                guard x1 - x0 < Self.maxSegmentSpan, y1 - y0 < Self.maxSegmentSpan else { continue }
                for column in x0...x1 {
                    for row in y0...y1 {
                        let k = Self.key(column: column, row: row)
                        if k != lastKey { pairs.append(Self.pack(key: k, edge: e)); lastKey = k }
                    }
                }
            }
        }
        pairs.sort()
        var previous: UInt64?
        for pair in pairs where pair != previous {
            previous = pair
            let k = UInt32(pair >> 32)
            if keys.last != k { keys.append(k); starts.append(Int32(items.count)) }
            items.append(Int32(truncatingIfNeeded: pair))
        }
        starts.append(Int32(items.count))
    }

    /// First index in `keys` whose key is ≥ `k`.
    private func lowerBound(_ k: UInt32) -> Int {
        var lo = 0, hi = keys.count
        while lo < hi { let m = (lo + hi) / 2; if keys[m] < k { lo = m + 1 } else { hi = m } }
        return lo
    }

    /// Calls `body` with every edge in the cells within `r` degrees of `p`, column by column. An
    /// edge that crosses several of those cells is reported once per cell.
    func forEachEdge(near p: LonLat, radiusDegrees r: Double, _ body: (Int32) -> Void) {
        let r = r.isFinite ? max(0, r) : 360
        let x0 = Self.column(p.lon - r), x1 = Self.column(p.lon + r)
        let y0 = Self.row(p.lat - r), y1 = Self.row(p.lat + r)
        guard x0 <= x1, y0 <= y1 else { return }
        func visit(_ k: Int) { for i in Int(starts[k])..<Int(starts[k + 1]) { body(items[i]) } }

        let cellCount = (x1 - x0 + 1) * (y1 - y0 + 1)
        if cellCount <= keys.count / 8 + 64 {
            // A few cells: look each one up.
            for column in x0...x1 {
                for row in y0...y1 {
                    let key = Self.key(column: column, row: row)
                    let k = lowerBound(key)
                    if k < keys.count, keys[k] == key { visit(k) }
                }
            }
        } else {
            // A huge radius: walk the occupied cells instead (same order), so the work is bounded
            // by the size of the graph, not by the area asked for.
            var k = lowerBound(Self.key(column: x0, row: y0))
            let last = Self.key(column: x1, row: y1)
            while k < keys.count, keys[k] <= last {
                let row = Self.row(ofKey: keys[k])
                if row >= y0 && row <= y1 { visit(k) }
                k += 1
            }
        }
    }
}

/// A binary min-heap of (key, value) pairs for the route search.
struct MinHeap {
    private var entries: [(key: Float, value: Int32)] = []

    var isEmpty: Bool { entries.isEmpty }

    mutating func removeAll(keepingCapacity: Bool) { entries.removeAll(keepingCapacity: keepingCapacity) }

    mutating func push(_ key: Float, _ value: Int32) {
        entries.append((key, value))
        var i = entries.count - 1
        while i > 0 {
            let parent = (i - 1) / 2
            guard entries[parent].key > entries[i].key else { break }
            entries.swapAt(parent, i)
            i = parent
        }
    }

    mutating func pop() -> (Float, Int32)? {
        guard let top = entries.first else { return nil }
        let last = entries.removeLast()
        if !entries.isEmpty {
            entries[0] = last
            var i = 0
            while true {
                let left = 2 * i + 1, right = left + 1
                var smallest = i
                if left < entries.count && entries[left].key < entries[smallest].key { smallest = left }
                if right < entries.count && entries[right].key < entries[smallest].key { smallest = right }
                if smallest == i { break }
                entries.swapAt(smallest, i)
                i = smallest
            }
        }
        return (top.key, top.value)
    }
}
