import Foundation

/// A point snapped onto the road network: the edge, how far along it (0…1, from → to), the
/// position on the road and how far the original point was from it.
public struct RoadSnap: Sendable, Equatable {
    public var edge: Int32
    public var fraction: Double
    public var point: LonLat
    public var distance: Double
    /// Other roads almost as near (see `RouteEngine.snap`), nearest first. A route may start or
    /// end on one of these instead when that saves a detour.
    var alternatives: [Alternative] = []

    struct Alternative: Sendable, Equatable {
        var edge: Int32
        var fraction: Double
        var distance: Double
    }
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

/// Routes on one `RoadGraph` (which must be consistent: built by `RoadGraphBuilder` or read by
/// `RoadGraphFile.decode`). Not thread-safe: one call at a time (it reuses its buffers).
public final class RouteEngine {
    public let graph: RoadGraph
    private let grid: EdgeGrid
    private var restrictionsAt: [Int32: [RoadGraph.TurnRestriction]] = [:]
    /// Whether any turn restriction turns at a vertex (most have none: this spares the search a
    /// dictionary lookup per turn).
    private var hasRestriction: [Bool]
    /// Bearing (degrees) leaving `from` and arriving at `to`, per edge.
    private let startBearing: [Float], endBearing: [Float]
    /// The fastest any edge can be driven, m/s: what the search assumes for the road not yet seen.
    private let topSpeed: Double
    private var search = SearchBuffers()
    /// Marks edges already handed out by the current `candidates` call.
    private var candidateMark: [UInt32]
    private var candidateRound: UInt32 = 0

    public init(graph g: RoadGraph) {
        graph = g
        grid = EdgeGrid(g)
        hasRestriction = [Bool](repeating: false, count: g.vertexCount)
        for r in g.restrictions where r.via >= 0 && Int(r.via) < g.vertexCount {
            restrictionsAt[r.via, default: []].append(r)
            hasRestriction[Int(r.via)] = true
        }
        var first = [Float](repeating: 0, count: g.edgeCount), last = first
        for e in 0..<g.edgeCount {
            let n = g.pointCount(e)
            first[e] = Float(Self.bearing(g.point(e, 0), g.point(e, 1)))
            last[e] = Float(Self.bearing(g.point(e, n - 2), g.point(e, n - 1)))
        }
        startBearing = first; endBearing = last
        let fastest = max(g.speedForward.max() ?? 0, g.speedBackward.max() ?? 0)
        topSpeed = Double(max(1, fastest)) / 3.6
        search = SearchBuffers(directedEdges: g.edgeCount * 2)
        candidateMark = [UInt32](repeating: 0, count: g.edgeCount)
    }

    // MARK: Bearings and turns

    static func bearing(_ a: LonLat, _ b: LonLat) -> Double {
        let f = CameraExposure.Flat(lat: (a.lat + b.lat) / 2)
        return CameraExposure.bearing(f.xy(a), f.xy(b))
    }

    /// The opposite of a bearing in 0..<360.
    @inline(__always) private static func reversed(_ bearing: Double) -> Double { bearing >= 180 ? bearing - 180 : bearing + 180 }

    /// Departure / arrival bearing of a directed edge.
    func leaving(_ de: Int32) -> Double {
        de & 1 == 0 ? Double(startBearing[Int(de >> 1)]) : Self.reversed(Double(endBearing[Int(de >> 1)]))
    }
    func arriving(_ de: Int32) -> Double {
        de & 1 == 0 ? Double(endBearing[Int(de >> 1)]) : Self.reversed(Double(startBearing[Int(de >> 1)]))
    }

    /// Signed turn in degrees (right positive) between arriving on `a` and leaving on `b`.
    func turn(_ a: Int32, _ b: Int32) -> Double {
        var d = leaving(b) - arriving(a)
        if d > 180 { d -= 360 }
        if d <= -180 { d += 360 }
        return d
    }

    /// Seconds for a turn (right-hand traffic: lefts cost more), or nil when it isn't allowed.
    func turnCost(_ a: Int32, _ b: Int32, at v: Int32) -> Float? {
        if a >> 1 == b >> 1 {
            // U-turn: only at a dead end.
            return graph.outDegree(v) <= 1 ? 30 : nil
        }
        if hasRestriction[Int(v)], let restrictions = restrictionsAt[v] {
            let fromEdge = a >> 1, toEdge = b >> 1
            for r in restrictions where r.fromEdge == fromEdge {
                if r.only ? r.toEdge != toEdge : r.toEdge == toEdge { return nil }
            }
        }
        let t = turn(a, b)
        let sharpness = abs(t)
        // Crossing a junction off the motorway costs a little (stop signs, lights, traffic) even
        // straight on; turns cost more, lefts most (right-hand traffic).
        let cls = RoadClass(rawValue: graph.roadClass[Int(a >> 1)]) ?? .road
        let crossing: Float = cls.isHighway || cls == .motorwayLink || graph.outDegree(v) < 3 ? 0
            : (cls.rawValue <= RoadClass.secondary.rawValue ? 3 : 2)
        if sharpness < 30 { return crossing }
        if sharpness > 135 { return crossing + 20 }
        return crossing + (t > 0 ? 4 : 9)
    }

    /// Seconds to drive `fraction` of a directed edge.
    @inline(__always) private func travel(_ de: Int32, _ fraction: Double = 1) -> Float {
        let kmh = Double(graph.speed(de))
        guard kmh > 0 else { return .infinity }
        return Float(Double(graph.length[Int(de >> 1)]) * fraction / (kmh / 3.6))
    }

    // MARK: Snapping

    /// The edges in the grid cells within `radiusDegrees` of `p`, each once, in grid order.
    private func candidates(near p: LonLat, radiusDegrees: Double) -> [Int32] {
        candidateRound &+= 1
        if candidateRound == 0 {
            for i in candidateMark.indices { candidateMark[i] = 0 }
            candidateRound = 1
        }
        var out: [Int32] = []
        grid.forEachEdge(near: p, radiusDegrees: radiusDegrees) { e in
            if candidateMark[Int(e)] != candidateRound { candidateMark[Int(e)] = candidateRound; out.append(e) }
        }
        return out
    }

    /// Roads up to this much further away than the nearest are kept as alternatives, and using
    /// one costs the extra distance at walking pace. A looked-up place is usually a building's
    /// centre: the nearest road may be a back street, or the far side of a one-way pair, and
    /// insisting on it sends the route round the block when the front door is 20 m the other way.
    static let alternativeReach = 30.0
    static let maxAlternatives = 6
    static let walkingSpeed = 1.4

    /// The nearest drivable road to `p` within `maxMeters`.
    public func snap(_ p: LonLat, maxMeters: Double = 1500) -> RoadSnap? {
        guard p.isValid, maxMeters.isFinite, maxMeters >= 0 else { return nil }
        let flat = CameraExposure.Flat(lat: p.lat)
        let c = flat.xy(p)
        // The least ground a degree covers here (east–west, except near the poles).
        let metersPerDegree = max(1000, min(flat.kx, flat.ky))
        typealias Hit = (edge: Int32, segment: Int, t: Double, point: SIMD2<Double>, distance: Double)
        var hits: [Hit] = []          // the nearest point of each edge in reach
        var best: Hit?
        var radius = 0.004
        while radius <= maxMeters / 111_000 * 2 + 0.004 {
            hits.removeAll(keepingCapacity: true)
            best = nil
            for e in candidates(near: p, radiusDegrees: radius) {
                let ei = Int(e)
                guard graph.speedForward[ei] > 0 || graph.speedBackward[ei] > 0 else { continue }
                var nearest: Hit?
                var a = flat.xy(graph.point(ei, 0))
                for i in 1..<graph.pointCount(ei) {
                    let b = flat.xy(graph.point(ei, i))
                    defer { a = b }
                    if let n = nearest, CameraExposure.isOutOfReach(c, a, b, n.distance) { continue }
                    let (q, d, t) = CameraExposure.nearest(c, a, b)
                    if d <= maxMeters, nearest == nil || d < nearest!.distance { nearest = (e, i, t, q, d) }
                }
                guard let nearest else { continue }
                hits.append(nearest)
                if best == nil || nearest.distance < best!.distance { best = nearest }
            }
            // Edges come a grid cell at a time, so the nearest found can be further away than the
            // radius searched while a nearer one lies in a cell not yet looked at: keep widening
            // until the radius covers what was found (and the alternatives' reach beyond it).
            if let b = best, b.distance + Self.alternativeReach <= radius * metersPerDegree { break }
            radius *= 2.5
        }
        guard let best else { return nil }
        let alternatives = hits
            .filter { $0.edge != best.edge && $0.distance <= best.distance + Self.alternativeReach }
            .sorted { $0.distance < $1.distance }
            .prefix(Self.maxAlternatives)
            .map { RoadSnap.Alternative(edge: $0.edge, fraction: fraction(ofSegment: $0.segment, t: $0.t, on: Int($0.edge), flat), distance: $0.distance) }
        return RoadSnap(edge: best.edge, fraction: fraction(ofSegment: best.segment, t: best.t, on: Int(best.edge), flat),
                        point: LonLat(lon: best.point.x / flat.kx, lat: best.point.y / flat.ky), distance: best.distance,
                        alternatives: alternatives)
    }

    /// How far along edge `e` (0…1, by length) the point at `t` of its segment ending at point `segment` is.
    private func fraction(ofSegment segment: Int, t: Double, on e: Int, _ flat: CameraExposure.Flat) -> Double {
        var before = 0.0, total = 0.0, hit = 0.0
        var a = flat.xy(graph.point(e, 0))
        for i in 1..<graph.pointCount(e) {
            let b = flat.xy(graph.point(e, i))
            let length = ((b - a) * (b - a)).sum().squareRoot()
            if i < segment { before += length }
            if i == segment { hit = length * t }
            total += length
            a = b
        }
        return total > 0 ? min(1, max(0, (before + hit) / total)) : 0
    }

    // MARK: Route ends

    /// Where a route starts or ends: part-way along an edge, or at a junction.
    enum RouteEnd: Equatable {
        case along(edge: Int32, fraction: Double)
        case at(vertex: Int32)
    }

    /// A snapped point this close to an end of its edge is at that junction. A point beyond the
    /// end of a street, or at a corner, snaps to the junction itself; any of the roads meeting
    /// there may then have been picked as its edge, and which one must not matter. (It used to:
    /// a destination snapped to the far end of a one-way street could only be reached by driving
    /// down that street, so the route circled the block to arrive at a corner it had already
    /// passed.)
    static let junctionTolerance = 1.0

    /// nil when the edge doesn't belong to this graph.
    func routeEnd(edge: Int32, fraction: Double) -> RouteEnd? {
        guard edge >= 0, Int(edge) < graph.edgeCount, fraction.isFinite else { return nil }
        let e = Int(edge)
        let fraction = min(1, max(0, fraction))
        let fromStart = fraction * Double(graph.length[e]), toEnd = (1 - fraction) * Double(graph.length[e])
        if min(fromStart, toEnd) <= Self.junctionTolerance {
            return .at(vertex: fromStart <= toEnd ? graph.from[e] : graph.to[e])
        }
        return .along(edge: edge, fraction: fraction)
    }

    /// A place a route may start or end, and what choosing it costs (seconds: the walk beyond
    /// the nearest road).
    struct Option { var end: RouteEnd; var extra: Float }

    /// The snap's own road first, then its alternatives; each place once. Empty when the snap
    /// doesn't belong to this graph.
    func options(_ s: RoadSnap) -> [Option] {
        guard let nearest = routeEnd(edge: s.edge, fraction: s.fraction) else { return [] }
        var out = [Option(end: nearest, extra: 0)]
        for a in s.alternatives {
            guard let end = routeEnd(edge: a.edge, fraction: a.fraction), !out.contains(where: { $0.end == end }) else { continue }
            let walk = max(0, a.distance - s.distance)
            out.append(Option(end: end, extra: walk.isFinite ? Float(walk / Self.walkingSpeed) : 0))
        }
        return out
    }

    // MARK: Search

    /// Per directed edge: the best cost found to its far end, the edge before it on that path,
    /// and whether it belongs to the current search. Kept between searches (allocating them per
    /// route would cost more than a short search), with a round number instead of clearing.
    private struct SearchBuffers {
        var cost: [Float] = []
        var parent: [Int32] = []
        /// `round << 1` once reached in this search, `round << 1 | 1` once settled.
        var mark: [UInt32] = []
        var round: UInt32 = 0
        var heap = MinHeap()

        init() {}
        init(directedEdges n: Int) {
            cost = [Float](repeating: 0, count: n)
            parent = [Int32](repeating: -1, count: n)
            mark = [UInt32](repeating: 0, count: n)
        }

        /// Starts a search; returns the marks for "reached" and "settled".
        mutating func begin() -> (reached: UInt32, settled: UInt32) {
            round += 1
            if round >= 1 << 30 {
                for i in mark.indices { mark[i] = 0 }
                round = 1
            }
            heap.removeAll(keepingCapacity: true)
            return (round << 1, round << 1 | 1)
        }
    }

    /// A way of reaching the destination: the directed edge the route ends on and how far along
    /// it, the settled edge before it (-1 when the route is that one edge, or starts on it), and
    /// the total cost. `lastEdge` is -1 for "already there" (start and destination at one junction).
    private struct Arrival {
        var cost: Float
        var lastEdge: Int32
        var previous: Int32
        var endFraction: Double
    }

    /// The fastest route from `a` to `b`, adding `penalty[edge]` seconds for each edge driven
    /// (camera avoidance). nil when the two aren't connected, or when `cancelled` (polled every
    /// few thousand edges) says to stop.
    public func route(from a: RoadSnap, to b: RoadSnap, penalty: [Float]? = nil, maxSettled: Int = 6_000_000,
                      cancelled: (() -> Bool)? = nil) -> RoutePath? {
        let starts = options(a), ends = options(b)
        guard !starts.isEmpty, !ends.isEmpty else { return nil }

        // The buffers leave the engine for the search, so the loop works on a local value.
        var buffers = SearchBuffers()
        swap(&buffers, &search)
        defer { swap(&buffers, &search) }
        let goal = b.point.isValid ? b.point : graph.position(graph.from[Int(b.edge)])
        // No destination option is further than this from `goal` (they are all within reach of
        // the point that was snapped), which keeps the search's estimate a lower bound.
        let goalSlack = 2 * (max(0, b.distance) + Self.alternativeReach)
        var startFractions: [Int32: Double] = [:]
        guard let arrival = fastest(from: starts, to: ends, goal: goal, goalSlack: ends.count > 1 ? goalSlack : Self.junctionTolerance,
                                    penalty: penalty, maxSettled: maxSettled, cancelled: cancelled, &buffers, &startFractions) else { return nil }
        guard arrival.lastEdge >= 0 else { return stationaryRoute(at: a) }

        // Rebuild the directed edge sequence.
        var edges = [arrival.lastEdge]
        var current = arrival.previous
        while current >= 0, edges.count <= buffers.parent.count {
            edges.append(current)
            current = buffers.parent[Int(current)]
        }
        edges.reverse()
        return assemble(edges, startFraction: startFractions[edges[0]] ?? 0, endFraction: arrival.endFraction)
    }

    /// A route between two snaps at the same junction: no distance, on the start's edge.
    private func stationaryRoute(at a: RoadSnap) -> RoutePath {
        let f: Double = a.fraction < 0.5 ? 0 : 1
        return assemble([a.edge * 2], startFraction: f, endFraction: f)
    }

    /// A* over directed edges (so turn costs and restrictions apply between consecutive edges),
    /// from any of `starts` to any of `ends`. An edge's cost is the time to reach its far end;
    /// the estimate for the rest is the straight line at the graph's top speed, which never
    /// overestimates. `startFractions` gets, per edge a route may start on, how far along it
    /// the start is.
    private func fastest(from starts: [Option], to ends: [Option], goal: LonLat, goalSlack: Double, penalty: [Float]?, maxSettled: Int,
                         cancelled: (() -> Bool)?, _ s: inout SearchBuffers, _ startFractions: inout [Int32: Double]) -> Arrival? {
        let g = graph
        let (reached, settled) = s.begin()
        var best: Arrival?

        // Straight-line seconds from a vertex to the goal. The constants are below a degree's true
        // size (as the edge lengths measure it) and the narrower of the two latitudes scales the
        // east–west part, so this is a lower bound.
        let cosGoal = cos(goal.lat * .pi / 180)
        func estimate(_ v: Int32) -> Float {
            let lat = Double(g.lat[Int(v)]) / 1e7, lon = Double(g.lon[Int(v)]) / 1e7
            let dy = (lat - goal.lat) * 110_574
            let dx = (lon - goal.lon) * 111_000 * min(cosGoal, cos(lat * .pi / 180))
            return Float(max(0, (dx * dx + dy * dy).squareRoot() - goalSlack) / topSpeed)
        }
        // Penalties that are missing, negative or not numbers count as none.
        func penaltyFor(_ de: Int32) -> Float {
            guard let penalty, Int(de >> 1) < penalty.count else { return 0 }
            return max(0, penalty[Int(de >> 1)])
        }
        func offer(_ a: Arrival) {
            if best == nil || a.cost < best!.cost { best = a }
        }
        /// Offers every destination on directed edge `de` that lies at or beyond `done` of the
        /// way along it, for a route that has cost `cost` up to `de`'s start.
        func offerDestinations(on de: Int32, from done: Double, cost: Float, previous: Int32) {
            for option in ends {
                guard case .along(let edge, let f) = option.end, de >> 1 == edge else { continue }
                let fraction = de & 1 == 0 ? f : 1 - f
                guard fraction >= done else { continue }
                offer(Arrival(cost: cost + travel(de, fraction - done) + penaltyFor(de) + option.extra, lastEdge: de, previous: previous,
                              endFraction: fraction))
            }
        }
        /// Starts on `de`, already `done` of the way along it, having spent `extra`.
        func seed(_ de: Int32, done: Double, extra: Float) {
            guard g.speed(de) > 0 else { return }
            let c = extra + travel(de, 1 - done) + penaltyFor(de)
            if s.mark[Int(de)] != reached || c < s.cost[Int(de)] {
                s.mark[Int(de)] = reached; s.cost[Int(de)] = c; s.parent[Int(de)] = -1
                startFractions[de] = done
                s.heap.push(c + estimate(g.head(de)), de)
            }
            offerDestinations(on: de, from: done, cost: extra, previous: -1)
        }

        for start in starts {
            switch start.end {
            case .along(let edge, let f):
                // Either way along the start edge, from the snapped point.
                seed(edge * 2, done: f, extra: start.extra)
                seed(edge * 2 + 1, done: 1 - f, extra: start.extra)
            case .at(let v):
                for end in ends where end.end == start.end {
                    offer(Arrival(cost: start.extra + end.extra, lastEdge: -1, previous: -1, endFraction: 0))
                }
                for k in Int(g.adjStart[Int(v)])..<Int(g.adjStart[Int(v) + 1]) { seed(g.adj[k], done: 0, extra: start.extra) }
            }
        }
        // The junctions that are destinations (few: scanned per settled edge).
        let endVertices: [(vertex: Int32, extra: Float)] = ends.compactMap {
            if case .at(let v) = $0.end { return (v, $0.extra) } else { return nil }
        }
        let hasEndEdges = ends.contains { if case .along = $0.end { return true } else { return false } }

        var settledCount = 0
        while let (f, de) = s.heap.pop() {
            if let best, f >= best.cost { break }
            // An edge is pushed again whenever a cheaper way to it turns up; only the first
            // (cheapest) of those entries counts.
            guard s.mark[Int(de)] == reached else { continue }
            s.mark[Int(de)] = settled
            settledCount += 1
            if settledCount > maxSettled { break }
            if settledCount & 4095 == 0, cancelled?() == true { return nil }
            let cost = s.cost[Int(de)]
            let v = g.head(de)
            for end in endVertices where end.vertex == v {
                offer(Arrival(cost: cost + end.extra, lastEdge: de, previous: s.parent[Int(de)], endFraction: 1))
            }
            for k in Int(g.adjStart[Int(v)])..<Int(g.adjStart[Int(v) + 1]) {
                let next = g.adj[k]
                guard let turn = turnCost(de, next, at: v) else { continue }
                // Into a destination's edge, up to the snapped point.
                if hasEndEdges { offerDestinations(on: next, from: 0, cost: cost + turn, previous: de) }
                guard s.mark[Int(next)] != settled else { continue }
                let c = cost + turn + travel(next) + penaltyFor(next)
                if s.mark[Int(next)] != reached || c < s.cost[Int(next)] {
                    s.mark[Int(next)] = reached; s.cost[Int(next)] = c; s.parent[Int(next)] = de
                    s.heap.push(c + estimate(g.head(next)), next)
                }
            }
        }
        return best
    }

    // MARK: Cameras

    /// Seconds to add per edge so a search avoids roads that mapped cameras see.
    public func cameraPenalties(_ cameras: [ALPRCamera], options o: ExposureOptions) -> [Float] {
        var penalty = [Float](repeating: 0, count: graph.edgeCount)
        for camera in cameras where camera.coordinate.isValid {
            let flat = CameraExposure.Flat(lat: camera.coordinate.lat)
            let c = flat.xy(camera.coordinate)
            for e in candidates(near: camera.coordinate, radiusDegrees: o.buffer / 90_000 + 0.002) {
                let ei = Int(e)
                var nearest = Double.infinity
                var a = flat.xy(graph.point(ei, 0))
                for i in 1..<graph.pointCount(ei) {
                    let b = flat.xy(graph.point(ei, i))
                    defer { a = b }
                    // Most segments of a nearby edge are nowhere near the camera.
                    if CameraExposure.isOutOfReach(c, a, b, o.buffer) { continue }
                    if let (d, _) = CameraExposure.seen(c, camera.directions, a, b, o), d < nearest { nearest = d }
                }
                if nearest.isFinite { penalty[ei] += CameraExposure.penaltySeconds(distance: nearest, buffer: o.buffer) }
            }
        }
        return penalty
    }
}
