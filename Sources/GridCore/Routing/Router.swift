import Foundation

/// A point snapped onto the road network: the edge, how far along it (0…1, from → to), the
/// position on the road and how far the original point was from it.
public struct RoadSnap: Sendable, Equatable {
    public var edge: Int32
    public var fraction: Double
    public var point: LonLat
    public var distance: Double
}

public struct RouteStep: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case depart, arrive, straight, slightLeft, left, sharpLeft, slightRight, right, sharpRight, uTurn
        case roundabout(exit: Int), ramp(left: Bool), merge, keepLeft, keepRight
    }
    public var kind: Kind
    public var text: String
    public var road: String?
    /// Metres and seconds from this step to the next.
    public var distance: Double
    public var duration: Double
    public var location: LonLat
    /// Metres from the start of the route where this step begins.
    public var along: Double
}

public struct RoutePath: Sendable, Equatable {
    /// Directed edges, in order.
    public var edges: [Int32]
    public var points: [LonLat]
    public var distance: Double
    public var duration: Double
    public var steps: [RouteStep]
}

/// Routes on one `RoadGraph`. Not thread-safe: one search at a time (it reuses its buffers).
public final class RouteEngine {
    public let graph: RoadGraph
    private let grid: EdgeGrid
    private var restrictionsAt: [Int32: [RoadGraph.TurnRestriction]] = [:]
    /// Bearing (degrees) leaving `from` and arriving at `to`, per edge.
    private var startBearing: [Float], endBearing: [Float]
    // Search buffers, reused (a stamp marks which entries belong to the current search).
    private var cost: [Float], parent: [Int32], stamp: [UInt32], closed: [UInt32]
    private var search: UInt32 = 0

    public init(graph g: RoadGraph) {
        graph = g
        grid = EdgeGrid(g)
        for r in g.restrictions { restrictionsAt[r.via, default: []].append(r) }
        var sb = [Float](repeating: 0, count: g.edgeCount), eb = [Float](repeating: 0, count: g.edgeCount)
        for e in 0..<g.edgeCount {
            let p = g.polyline(e)
            sb[e] = Float(Self.bearing(p[0], p[1]))
            eb[e] = Float(Self.bearing(p[p.count - 2], p[p.count - 1]))
        }
        startBearing = sb; endBearing = eb
        let n = g.edgeCount * 2
        cost = [Float](repeating: 0, count: n); parent = [Int32](repeating: -1, count: n)
        stamp = [UInt32](repeating: 0, count: n); closed = [UInt32](repeating: 0, count: n)
    }

    static func bearing(_ a: LonLat, _ b: LonLat) -> Double {
        let f = CameraExposure.Flat(lat: (a.lat + b.lat) / 2)
        return CameraExposure.bearing(f.xy(a), f.xy(b))
    }

    /// Departure / arrival bearing of a directed edge.
    func leaving(_ de: Int32) -> Double { de & 1 == 0 ? Double(startBearing[Int(de >> 1)]) : (Double(endBearing[Int(de >> 1)]) + 180).truncatingRemainder(dividingBy: 360) }
    func arriving(_ de: Int32) -> Double { de & 1 == 0 ? Double(endBearing[Int(de >> 1)]) : (Double(startBearing[Int(de >> 1)]) + 180).truncatingRemainder(dividingBy: 360) }

    /// Signed turn in degrees (right positive) between arriving on `a` and leaving on `b`.
    func turn(_ a: Int32, _ b: Int32) -> Double {
        var d = leaving(b) - arriving(a)
        while d > 180 { d -= 360 }
        while d <= -180 { d += 360 }
        return d
    }

    // MARK: Snapping

    /// The nearest drivable road to `p` within `maxMeters`.
    public func snap(_ p: LonLat, maxMeters: Double = 1500) -> RoadSnap? {
        let flat = CameraExposure.Flat(lat: p.lat)
        let c = flat.xy(p)
        var best: RoadSnap?
        var radius = 0.004
        while radius <= maxMeters / 111_000 * 2 + 0.004 {
            for e in grid.edges(near: p, radiusDegrees: radius) {
                let ei = Int(e)
                guard graph.speedForward[ei] > 0 || graph.speedBackward[ei] > 0 else { continue }
                let poly = graph.polyline(ei).map(flat.xy)
                var along = 0.0, total = 0.0
                for i in 1..<poly.count { let d = poly[i] - poly[i - 1]; total += (d * d).sum().squareRoot() }
                for i in 1..<poly.count {
                    let a = poly[i - 1], b = poly[i]
                    let seg = ((b - a) * (b - a)).sum().squareRoot()
                    let (q, d, t) = CameraExposure.nearest(c, a, b)
                    if d <= maxMeters, best == nil || d < best!.distance {
                        let frac = total > 0 ? (along + seg * t) / total : 0
                        best = RoadSnap(edge: e, fraction: min(1, max(0, frac)),
                                        point: LonLat(lon: q.x / flat.kx, lat: q.y / flat.ky), distance: d)
                    }
                    along += seg
                }
            }
            if best != nil { break }
            radius *= 2.5
        }
        return best
    }

    // MARK: Search

    @inline(__always) private func travel(_ de: Int32, _ fraction: Double = 1) -> Float {
        let v = Double(graph.speed(de))
        guard v > 0 else { return .infinity }
        return Float(Double(graph.length[Int(de >> 1)]) * fraction / (v / 3.6))
    }

    /// Seconds for a turn (right-hand traffic: lefts cost more), or nil when it isn't allowed.
    private func turnCost(_ a: Int32, _ b: Int32, at v: Int32) -> Float? {
        if a >> 1 == b >> 1 {
            // U-turn: only at a dead end.
            return Int(graph.adjStart[Int(v) + 1] - graph.adjStart[Int(v)]) <= 1 ? 30 : nil
        }
        if let rs = restrictionsAt[v] {
            let fe = a >> 1, te = b >> 1
            for r in rs where r.fromEdge == fe {
                if r.only ? r.toEdge != te : r.toEdge == te { return nil }
            }
        }
        let t = turn(a, b)
        let m = abs(t)
        // Crossing a junction off the motorway costs a little (stop signs, lights, traffic) even
        // straight on; turns cost more, lefts most (right-hand traffic).
        let cls = RoadClass(rawValue: graph.roadClass[Int(a >> 1)]) ?? .road
        let degree = Int(graph.adjStart[Int(v) + 1] - graph.adjStart[Int(v)])
        let crossing: Float = cls.isHighway || cls == .motorwayLink || degree < 3 ? 0 : (cls.rawValue <= RoadClass.secondary.rawValue ? 3 : 2)
        if m < 30 { return crossing }
        if m > 135 { return crossing + 20 }
        return crossing + (t > 0 ? 4 : 9)
    }

    /// The fastest route from `a` to `b`, adding `penalty(edge)` seconds for each edge entered
    /// (camera avoidance). nil when the two aren't connected.
    public func route(from a: RoadSnap, to b: RoadSnap, penalty: [Float]? = nil, maxSettled: Int = 6_000_000) -> RoutePath? {
        search &+= 1
        if search == 0 { stamp = stamp.map { _ in 0 }; closed = closed.map { _ in 0 }; search = 1 }
        let s = search
        let target = graph.position(graph.from[Int(b.edge)])
        let tFlat = CameraExposure.Flat(lat: target.lat)
        let tXY = tFlat.xy(b.point)
        let maxSpeed = 130.0 / 3.6
        func h(_ v: Int32) -> Float {
            let d = tFlat.xy(graph.position(v)) - tXY
            return Float((d * d).sum().squareRoot() / maxSpeed)
        }
        func pen(_ de: Int32) -> Float { penalty.map { $0[Int(de >> 1)] } ?? 0 }

        var heap = MinHeap()
        // Total cost, the last directed edge (the target edge; `-2 - de` = straight along the start
        // edge `de`), and the settled edge before it.
        var best: (Float, Int32)? = nil
        var bestPrev: Int32 = -1
        // Start on both directions of the start edge, from the snapped point.
        for de in [a.edge * 2, a.edge * 2 + 1] where graph.speed(de) > 0 {
            let frac = de & 1 == 0 ? 1 - a.fraction : a.fraction
            let c = travel(de, frac) + pen(de)
            cost[Int(de)] = c; parent[Int(de)] = -1; stamp[Int(de)] = s
            heap.push(c + h(graph.head(de)), de)
            // The target on the same edge, ahead in this direction.
            if a.edge == b.edge {
                let ahead = de & 1 == 0 ? b.fraction >= a.fraction : b.fraction <= a.fraction
                if ahead {
                    let d = abs(b.fraction - a.fraction)
                    let total = travel(de, d)
                    if best == nil || total < best!.0 { best = (total, -2 - de) }   // encoded: direct on `de`
                }
            }
        }
        var settled = 0
        while let (f, de) = heap.pop() {
            if let bst = best, f >= bst.0 { break }
            guard stamp[Int(de)] == s, closed[Int(de)] != s, f - h(graph.head(de)) <= cost[Int(de)] + 0.001 else { continue }
            closed[Int(de)] = s
            settled += 1
            if settled > maxSettled { break }
            let g0 = cost[Int(de)]
            let v = graph.head(de)
            for k in Int(graph.adjStart[Int(v)])..<Int(graph.adjStart[Int(v) + 1]) {
                let nx = graph.adj[k]
                guard let tc = turnCost(de, nx, at: v) else { continue }
                if nx >> 1 == b.edge {
                    // Into the target edge, up to the snapped point.
                    let frac = nx & 1 == 0 ? b.fraction : 1 - b.fraction
                    let total = g0 + tc + travel(nx, frac) + pen(nx)
                    if best == nil || total < best!.0 { best = (total, nx); bestPrev = de }
                }
                guard closed[Int(nx)] != s else { continue }
                let ng = g0 + tc + travel(nx) + pen(nx)
                if stamp[Int(nx)] != s || ng < cost[Int(nx)] {
                    stamp[Int(nx)] = s; cost[Int(nx)] = ng; parent[Int(nx)] = de
                    heap.push(ng + h(graph.head(nx)), nx)
                }
            }
        }
        guard let (_, last) = best else { return nil }
        // Rebuild the directed edge sequence.
        var seq: [Int32]
        if last <= -2 {
            seq = [-2 - last]
        } else {
            seq = [last]
            var cur = bestPrev
            var guardCount = 0
            while cur >= 0, guardCount < 2_000_000 {
                seq.append(cur); cur = parent[Int(cur)]; guardCount += 1
            }
            seq.reverse()
        }
        return assemble(seq, from: a, to: b)
    }

    // MARK: Path

    /// Directed-edge polyline cut to [f0, f1] (fractions of its length, in its own direction).
    private func cut(_ de: Int32, _ f0: Double, _ f1: Double) -> [LonLat] {
        let p = graph.polyline(directed: de)
        guard p.count >= 2 else { return p }
        let flat = CameraExposure.Flat(lat: p[0].lat)
        let xy = p.map(flat.xy)
        var cum = [0.0]
        for i in 1..<xy.count { let d = xy[i] - xy[i - 1]; cum.append(cum[i - 1] + (d * d).sum().squareRoot()) }
        let total = cum.last!
        let d0 = total * f0, d1 = total * f1
        func at(_ d: Double) -> LonLat {
            var i = 1
            while i < cum.count - 1 && cum[i] < d { i += 1 }
            let seg = cum[i] - cum[i - 1]
            let t = seg > 0 ? (d - cum[i - 1]) / seg : 0
            let q = xy[i - 1] + (xy[i] - xy[i - 1]) * min(1, max(0, t))
            return LonLat(lon: q.x / flat.kx, lat: q.y / flat.ky)
        }
        var out = [at(d0)]
        for i in 1..<(cum.count - 1) where cum[i] > d0 && cum[i] < d1 { out.append(p[i]) }
        out.append(at(d1))
        return out
    }

    private func assemble(_ seq: [Int32], from a: RoadSnap, to b: RoadSnap) -> RoutePath {
        var points: [LonLat] = []
        var distance = 0.0, duration = 0.0
        // Per directed edge: the part used and where it starts along the route.
        var parts: [(de: Int32, f0: Double, f1: Double, along: Double)] = []
        for (i, de) in seq.enumerated() {
            let startF = i == 0 ? (de & 1 == 0 ? a.fraction : 1 - a.fraction) : 0
            let endF = i == seq.count - 1 ? (de & 1 == 0 ? b.fraction : 1 - b.fraction) : 1
            let f0 = min(startF, endF), f1 = max(startF, endF)
            parts.append((de, f0, f1, distance))
            let seg = cut(de, f0, f1)
            if points.isEmpty { points = seg } else { points.append(contentsOf: seg.dropFirst()) }
            let len = Double(graph.length[Int(de >> 1)]) * (f1 - f0)
            distance += len
            duration += len / (Double(graph.speed(de)) / 3.6)
            // Junctions and turns take time too (the same costs the search used).
            if i > 0, let tc = turnCost(seq[i - 1], de, at: graph.head(seq[i - 1])) { duration += Double(tc) }
        }
        return RoutePath(edges: seq, points: points, distance: distance, duration: duration,
                         steps: steps(parts, end: b.point, total: distance))
    }

    // MARK: Steps

    private func steps(_ parts: [(de: Int32, f0: Double, f1: Double, along: Double)], end: LonLat, total: Double) -> [RouteStep] {
        guard let first = parts.first else { return [] }
        func name(_ de: Int32) -> String? { graph.roadName(Int(de >> 1)) }
        func cls(_ de: Int32) -> RoadClass { RoadClass(rawValue: graph.roadClass[Int(de >> 1)]) ?? .road }
        func round(_ de: Int32) -> Bool { graph.flags[Int(de >> 1)] & RoadGraph.roundaboutFlag != 0 }
        func len(_ p: (de: Int32, f0: Double, f1: Double, along: Double)) -> Double { Double(graph.length[Int(p.de >> 1)]) * (p.f1 - p.f0) }
        func time(_ p: (de: Int32, f0: Double, f1: Double, along: Double)) -> Double { len(p) / (Double(graph.speed(p.de)) / 3.6) }
        func startPoint(_ p: (de: Int32, f0: Double, f1: Double, along: Double)) -> LonLat { cut(p.de, p.f0, p.f0)[0] }
        func options(at v: Int32, excluding back: Int32) -> Int {
            var n = 0
            for k in Int(graph.adjStart[Int(v)])..<Int(graph.adjStart[Int(v) + 1]) where graph.adj[k] >> 1 != back >> 1 { n += 1 }
            return n
        }

        var out: [RouteStep] = []
        let compass = ["north", "northeast", "east", "southeast", "south", "southwest", "west", "northwest"]
        let heading = compass[Int(((leaving(first.de) + 22.5) / 45).rounded(.down)) % 8]
        out.append(RouteStep(kind: .depart, text: name(first.de).map { "Head \(heading) on \($0)" } ?? "Head \(heading)",
                             road: name(first.de), distance: 0, duration: 0, location: startPoint(first), along: 0))
        var i = 0
        while i < parts.count {
            let p = parts[i]
            out[out.count - 1].distance += len(p); out[out.count - 1].duration += time(p)
            guard i + 1 < parts.count else { break }
            let q = parts[i + 1]
            let v = graph.head(p.de)
            if round(q.de) && !round(p.de) {
                // A roundabout: count the exits passed until leaving it.
                var j = i + 1, exits = 0
                while j < parts.count && round(parts[j].de) {
                    let at = graph.head(parts[j].de)
                    for k in Int(graph.adjStart[Int(at)])..<Int(graph.adjStart[Int(at) + 1]) where !round(graph.adj[k]) { exits += 1; break }
                    j += 1
                }
                let exitRoad = j < parts.count ? name(parts[j].de) : nil
                let ord = Self.ordinal(max(1, exits))
                out.append(RouteStep(kind: .roundabout(exit: max(1, exits)),
                                     text: "At the roundabout, take the \(ord) exit" + (exitRoad.map { " onto \($0)" } ?? ""),
                                     road: exitRoad, distance: 0, duration: 0, location: startPoint(q), along: q.along))
                i += 1
                continue
            }
            if round(p.de) && round(q.de) { i += 1; continue }
            let t = turn(p.de, q.de)
            let m = abs(t)
            let n1 = name(p.de), n2 = name(q.de)
            let opts = options(at: v, excluding: p.de)
            let renamed = n1 != n2 && n2 != nil
            let c1 = cls(p.de), c2 = cls(q.de)
            var kind: RouteStep.Kind?
            if c2.isLink && !c1.isLink && !(c1 == .motorwayLink) {
                kind = .ramp(left: t < 0)
            } else if c1.isLink && c2.isHighway {
                kind = .merge
            } else if renamed || (opts > 1 && m >= 35) {
                // A new road, or a real choice at a junction (a bend with no other way isn't a step).
                kind = m < 20 ? (c1.isHighway && opts > 1 && m >= 8 ? (t < 0 ? .keepLeft : .keepRight) : .straight)
                    : m < 60 ? (t < 0 ? .slightLeft : .slightRight)
                    : m < 135 ? (t < 0 ? .left : .right)
                    : m < 170 ? (t < 0 ? .sharpLeft : .sharpRight) : .uTurn
            }
            if let kind {
                out.append(RouteStep(kind: kind, text: Self.phrase(kind, n2), road: n2, distance: 0, duration: 0,
                                     location: startPoint(q), along: q.along))
            }
            i += 1
        }
        out.append(RouteStep(kind: .arrive, text: "Arrive at your destination", road: nil, distance: 0, duration: 0, location: end, along: total))
        return out
    }

    static func phrase(_ k: RouteStep.Kind, _ road: String?) -> String {
        let onto = road.map { " onto \($0)" } ?? ""
        switch k {
        case .straight: return road.map { "Continue onto \($0)" } ?? "Continue straight"
        case .slightLeft: return "Bear left" + onto
        case .slightRight: return "Bear right" + onto
        case .left: return "Turn left" + onto
        case .right: return "Turn right" + onto
        case .sharpLeft: return "Turn sharp left" + onto
        case .sharpRight: return "Turn sharp right" + onto
        case .uTurn: return "Make a U-turn" + onto
        case .ramp(let left): return "Take the ramp on the \(left ? "left" : "right")" + onto
        case .merge: return "Merge" + onto
        case .keepLeft: return "Keep left" + onto
        case .keepRight: return "Keep right" + onto
        case .depart, .arrive, .roundabout: return ""
        }
    }

    static func ordinal(_ n: Int) -> String {
        switch n { case 1: "1st"; case 2: "2nd"; case 3: "3rd"; default: "\(n)th" }
    }

    // MARK: Cameras

    /// Seconds to add per edge so a search avoids roads that mapped cameras see.
    public func cameraPenalties(_ cameras: [ALPRCamera], options o: ExposureOptions) -> [Float] {
        var pen = [Float](repeating: 0, count: graph.edgeCount)
        for cam in cameras {
            let flat = CameraExposure.Flat(lat: cam.coordinate.lat)
            let c = flat.xy(cam.coordinate)
            for e in grid.edges(near: cam.coordinate, radiusDegrees: o.buffer / 90_000 + 0.002) {
                let poly = graph.polyline(Int(e)).map(flat.xy)
                var bestD = Double.infinity
                for i in 1..<poly.count {
                    if let (d, _) = CameraExposure.seen(c, cam.directions, poly[i - 1], poly[i], o), d < bestD { bestD = d }
                }
                if bestD.isFinite { pen[Int(e)] += CameraExposure.penaltySeconds(distance: bestD, buffer: o.buffer) }
            }
        }
        return pen
    }
}

// MARK: - Spatial index of edges

/// Edges by 0.01° grid cell (each segment's box), sorted keys with an edge list per key.
struct EdgeGrid {
    static let cell = 0.01
    private var keys: [UInt64] = []
    private var starts: [Int32] = []
    private var items: [Int32] = []

    @inline(__always) static func key(_ cx: Int, _ cy: Int) -> UInt64 { UInt64(cx + 20_000) << 20 | UInt64(cy + 10_000) }

    init(_ g: RoadGraph) {
        var pairs: [UInt64] = []
        pairs.reserveCapacity(g.edgeCount * 3)
        var seen: [UInt64] = []
        for e in 0..<g.edgeCount {
            let p = g.polyline(e)
            seen.removeAll(keepingCapacity: true)
            for i in 1..<p.count {
                let x0 = Int((min(p[i - 1].lon, p[i].lon) / Self.cell).rounded(.down)), x1 = Int((max(p[i - 1].lon, p[i].lon) / Self.cell).rounded(.down))
                let y0 = Int((min(p[i - 1].lat, p[i].lat) / Self.cell).rounded(.down)), y1 = Int((max(p[i - 1].lat, p[i].lat) / Self.cell).rounded(.down))
                guard x1 - x0 < 200, y1 - y0 < 200 else { continue }
                for cx in x0...x1 { for cy in y0...y1 {
                    let k = Self.key(cx, cy)
                    if !seen.contains(k) { seen.append(k); pairs.append(k << 24 | UInt64(e & 0xFFFFFF)) }
                } }
            }
        }
        pairs.sort()
        for pr in pairs {
            let k = pr >> 24
            if keys.last != k { keys.append(k); starts.append(Int32(items.count)) }
            items.append(Int32(pr & 0xFFFFFF))
        }
        starts.append(Int32(items.count))
    }

    func edges(near p: LonLat, radiusDegrees r: Double) -> [Int32] {
        let x0 = Int(((p.lon - r) / Self.cell).rounded(.down)), x1 = Int(((p.lon + r) / Self.cell).rounded(.down))
        let y0 = Int(((p.lat - r) / Self.cell).rounded(.down)), y1 = Int(((p.lat + r) / Self.cell).rounded(.down))
        var out: [Int32] = []
        var seen = Set<Int32>()
        for cx in x0...x1 { for cy in y0...y1 {
            let k = Self.key(cx, cy)
            var lo = 0, hi = keys.count
            while lo < hi { let m = (lo + hi) / 2; if keys[m] < k { lo = m + 1 } else { hi = m } }
            guard lo < keys.count, keys[lo] == k else { continue }
            for i in Int(starts[lo])..<Int(starts[lo + 1]) where seen.insert(items[i]).inserted { out.append(items[i]) }
        } }
        return out
    }
}

// MARK: - Heap

struct MinHeap {
    private var keys: [Float] = []
    private var vals: [Int32] = []
    var isEmpty: Bool { keys.isEmpty }
    mutating func push(_ k: Float, _ v: Int32) {
        keys.append(k); vals.append(v)
        var i = keys.count - 1
        while i > 0 {
            let p = (i - 1) / 2
            guard keys[p] > keys[i] else { break }
            keys.swapAt(p, i); vals.swapAt(p, i); i = p
        }
    }
    mutating func pop() -> (Float, Int32)? {
        guard !keys.isEmpty else { return nil }
        let out = (keys[0], vals[0])
        let lk = keys.removeLast(), lv = vals.removeLast()
        if !keys.isEmpty {
            keys[0] = lk; vals[0] = lv
            var i = 0
            while true {
                let l = 2 * i + 1, r = l + 1
                var m = i
                if l < keys.count && keys[l] < keys[m] { m = l }
                if r < keys.count && keys[r] < keys[m] { m = r }
                if m == i { break }
                keys.swapAt(m, i); vals.swapAt(m, i); i = m
            }
        }
        return out
    }
}
