import Foundation
import simd

/// A cleaned, bbox-indexed copy of a `GeoPolygon` for bulk point tests (unclosed rings, no
/// duplicate or invalid points, degenerate rings dropped).
struct PreparedGeoPolygon {
    struct Ring {
        var pts: [SIMD2<Double>]
        var minX: Double, maxX: Double, minY: Double, maxY: Double
    }
    struct Poly {
        var rings: [Ring]          // [exterior, holes…]
        var bbox: BBox
    }
    var polys: [Poly] = []
    var bbox = BBox(west: 0, south: 0, east: 0, north: 0)

    static func cleanRing(_ ring: [LonLat]) -> Ring? {
        var pts: [SIMD2<Double>] = []
        pts.reserveCapacity(ring.count)
        for p in ring where p.isValid {
            let v = SIMD2(p.lon, p.lat)
            if let last = pts.last, last == v { continue }
            pts.append(v)
        }
        if pts.count > 1, pts.first! == pts.last! { pts.removeLast() }
        guard pts.count >= 3 else { return nil }
        var r = Ring(pts: pts, minX: .infinity, maxX: -.infinity, minY: .infinity, maxY: -.infinity)
        for p in pts { r.minX = min(r.minX, p.x); r.maxX = max(r.maxX, p.x); r.minY = min(r.minY, p.y); r.maxY = max(r.maxY, p.y) }
        return r
    }

    init(_ g: GeoPolygon) {
        var all = BBox(west: .infinity, south: .infinity, east: -.infinity, north: -.infinity)
        for poly in g.polygons {
            guard let first = poly.first, let ext = Self.cleanRing(first) else { continue }
            var rings = [ext]
            for h in poly.dropFirst() { if let r = Self.cleanRing(h) { rings.append(r) } }
            let b = BBox(west: ext.minX, south: ext.minY, east: ext.maxX, north: ext.maxY)
            polys.append(Poly(rings: rings, bbox: b))
            all.west = min(all.west, b.west); all.south = min(all.south, b.south)
            all.east = max(all.east, b.east); all.north = max(all.north, b.north)
        }
        if !polys.isEmpty { bbox = all }
    }

    @inline(__always)
    static func parity(_ r: Ring, _ x: Double, _ y: Double) -> Bool {
        guard x >= r.minX, x <= r.maxX, y >= r.minY, y <= r.maxY else { return false }
        var inside = false
        var j = r.pts.count - 1
        for i in 0..<r.pts.count {
            let a = r.pts[i], b = r.pts[j]
            if (a.y > y) != (b.y > y), x < (b.x - a.x) * (y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }

    func contains(lon x: Double, lat y: Double) -> Bool {
        for poly in polys {
            guard poly.bbox.west <= x, x <= poly.bbox.east, poly.bbox.south <= y, y <= poly.bbox.north else { continue }
            var inside = false
            for r in poly.rings where Self.parity(r, x, y) { inside.toggle() }
            if inside { return true }
        }
        return false
    }
}

extension GeoPolygon {
    /// Bounding box of every valid ring vertex; a zero box at (0, 0) when empty.
    public var bbox: BBox {
        var b = BBox(west: .infinity, south: .infinity, east: -.infinity, north: -.infinity)
        var any = false
        for poly in polygons { for ring in poly { for p in ring where p.isValid {
            any = true
            b.west = min(b.west, p.lon); b.east = max(b.east, p.lon)
            b.south = min(b.south, p.lat); b.north = max(b.north, p.lat)
        } } }
        return any ? b : BBox(west: 0, south: 0, east: 0, north: 0)
    }

    /// Even-odd containment within any polygon (holes honoured). Rings may be closed or unclosed;
    /// rings with fewer than 3 points are ignored. Points exactly on an edge are unspecified.
    public func contains(_ p: LonLat) -> Bool {
        guard p.isValid else { return false }
        for poly in polygons {
            var inside = false
            for ring in poly where ring.count >= 3 {
                var j = ring.count - 1
                var odd = false
                for i in 0..<ring.count {
                    let a = ring[i], b = ring[j]
                    if (a.lat > p.lat) != (b.lat > p.lat),
                       p.lon < (b.lon - a.lon) * (p.lat - a.lat) / (b.lat - a.lat) + a.lon { odd.toggle() }
                    j = i
                }
                if odd { inside.toggle() }
            }
            if inside { return true }
        }
        return false
    }

    /// Tiles at zoom `z` whose bounds intersect the polygon, row-major (north to south, west to
    /// east), at most `limit`. When the cover would exceed `limit`, the result is some
    /// `limit`-sized subset: `count == limit` means "possibly more exist".
    public func tileCover(z: Int, limit: Int) -> [TileID] {
        guard limit > 0, z >= 0, z <= 22 else { return [] }
        let prep = PreparedGeoPolygon(self)
        guard !prep.polys.isEmpty else { return [] }
        let n = 1 << z
        let nd = Double(n)
        let maxLat = TileMath.maxLatitude

        func col(_ lon: Double) -> Int { max(0, min(n - 1, Int(((lon + 180) / 360 * nd).rounded(.down)))) }
        func row(_ lat: Double) -> Int {
            let y = TileMath.project(LonLat(lon: 0, lat: lat)).y
            return max(0, min(n - 1, Int((y * nd).rounded(.down))))
        }
        func latAt(_ y: Double) -> Double { TileMath.unproject(Mercator(x: 0, y: y / nd)).lat }
        func key(_ r: Int, _ c: Int) -> UInt64 { UInt64(r) << 32 | UInt64(c) }

        // Edges as (lon0, lat0, lon1, lat1), latitudes clamped to the Mercator range for row maths.
        var edges: [SIMD4<Double>] = []
        for poly in prep.polys { for ring in poly.rings {
            var j = ring.pts.count - 1
            for i in 0..<ring.pts.count {
                let a = ring.pts[j], b = ring.pts[i]
                edges.append(SIMD4(a.x, max(-maxLat, min(maxLat, a.y)), b.x, max(-maxLat, min(maxLat, b.y))))
                j = i
            }
        } }

        // Pass 1: tiles touched by any edge (including vertices). Aborts once `limit` is reached.
        var boundary = Set<UInt64>()
        func finish(_ set: Set<UInt64>) -> [TileID] {
            set.sorted().prefix(limit).map { TileID(z: z, x: Int($0 & 0xFFFF_FFFF), y: Int($0 >> 32)) }
        }
        for e in edges {
            let lo = min(e.y, e.w), hi = max(e.y, e.w)
            let rTop = row(hi), rBot = row(lo)
            for r in rTop...rBot {
                var lonA = e.x, lonB = e.z
                if hi > lo {
                    let latHi = min(hi, latAt(Double(r))), latLo = max(lo, latAt(Double(r + 1)))
                    lonA = e.x + (latHi - e.y) * (e.z - e.x) / (e.w - e.y)
                    lonB = e.x + (latLo - e.y) * (e.z - e.x) / (e.w - e.y)
                }
                let c0 = col(min(lonA, lonB)), c1 = col(max(lonA, lonB))
                for c in c0...c1 {
                    boundary.insert(key(r, c))
                    if boundary.count >= limit { return finish(boundary) }
                }
            }
        }

        // Pass 2: interior tiles via per-row scanlines through the tile-row centres.
        var rMin = Int.max, rMax = Int.min
        for k in boundary { let r = Int(k >> 32); rMin = min(rMin, r); rMax = max(rMax, r) }
        guard rMin <= rMax else { return [] }
        let rows = rMax - rMin + 1
        var centre = [Double](repeating: 0, count: rows)
        for i in 0..<rows { centre[i] = latAt(Double(rMin + i) + 0.5) }
        var crossings = [[Double]](repeating: [], count: rows)
        for e in edges {
            let lo = min(e.y, e.w), hi = max(e.y, e.w)
            guard hi > lo else { continue }
            let r0 = max(rMin, row(hi)), r1 = min(rMax, row(lo))
            guard r0 <= r1 else { continue }
            for r in r0...r1 {
                let c = centre[r - rMin]
                if (e.y > c) != (e.w > c) { crossings[r - rMin].append(e.x + (c - e.y) * (e.z - e.x) / (e.w - e.y)) }
            }
        }
        var result = boundary
        outer: for i in 0..<rows {
            let xs = crossings[i].sorted()
            var k = 0
            while k + 1 < xs.count {
                let c0 = Int(((xs[k] + 180) / 360 * nd - 0.5).rounded(.up))
                let c1 = Int(((xs[k + 1] + 180) / 360 * nd - 0.5).rounded(.down))
                let a = max(0, c0), b = min(n - 1, c1)
                if a <= b {
                    for c in a...b {
                        result.insert(key(rMin + i, c))
                        if result.count >= limit * 2 { break outer }
                    }
                }
                k += 2
            }
        }
        return finish(result)
    }
}
