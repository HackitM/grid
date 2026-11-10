import XCTest
@testable import GridCore

/// Deterministic generator for the routing tests.
private struct TestRNG: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private func build(_ nodes: [PBFTestEncoder.Node], _ ways: [PBFTestEncoder.Way], _ relations: [PBFTestEncoder.Relation] = []) throws -> RoadGraph {
    try RoadGraphBuilder.build(pbf: PBFTestEncoder.encode(nodes: nodes, ways: ways, relations: relations)).0
}

// MARK: - Where routes start and end

final class RouteEndTests: XCTestCase {
    /// Two one-way streets 44 m apart (A eastbound in the south, B westbound in the north), joined
    /// by cross streets 560 m apart, with a feeder road arriving at A's west end.
    ///
    ///     b0 <------------------ B ------------------ b1
    ///     |                                            |
    ///     a0 ------------------- A -----------------> a1
    ///     |
    ///     s
    private func onewayPair() throws -> RoadGraph {
        let nodes: [PBFTestEncoder.Node] = [
            .init(id: 1, lat: 33.5000, lon: -86.800), .init(id: 2, lat: 33.5000, lon: -86.794),      // a0, a1
            .init(id: 3, lat: 33.5004, lon: -86.800), .init(id: 4, lat: 33.5004, lon: -86.794),      // b0, b1
            .init(id: 5, lat: 33.4990, lon: -86.800),                                               // s
        ]
        let ways: [PBFTestEncoder.Way] = [
            .init(id: 10, refs: [1, 2], tags: ["highway": "residential", "oneway": "yes", "name": "A Street"]),
            .init(id: 11, refs: [4, 3], tags: ["highway": "residential", "oneway": "yes", "name": "B Street"]),
            .init(id: 12, refs: [1, 3], tags: ["highway": "residential", "name": "West Cross"]),
            .init(id: 13, refs: [2, 4], tags: ["highway": "residential", "name": "East Cross"]),
            .init(id: 14, refs: [5, 1], tags: ["highway": "residential", "name": "Feeder"]),
        ]
        return try build(nodes, ways)
    }

    func testDestinationBetweenParallelOneWaysTakesTheNearSide() throws {
        let engine = RouteEngine(graph: try onewayPair())
        let start = try XCTUnwrap(engine.snap(LonLat(lon: -86.800, lat: 33.4995)))
        // A building between the two streets, 90 m along, a little nearer B (18 m) than A (26 m).
        let door = LonLat(lon: -86.799, lat: 33.50024)
        let end = try XCTUnwrap(engine.snap(door))
        XCTAssertEqual(engine.graph.roadName(Int(end.edge)), "B Street", "the nearest road is the far side of the pair")
        XCTAssertEqual(end.alternatives.map { engine.graph.roadName(Int($0.edge)) }, ["A Street"])
        let path = try XCTUnwrap(engine.route(from: start, to: end))
        // Up the feeder and 93 m along A; not right round the block to come back along B.
        XCTAssertEqual(path.distance, 55 + 93, accuracy: 10)
        XCTAssertEqual(engine.graph.roadName(Int(path.edges.last! >> 1)), "A Street")

        // The nearest road still wins when using it costs nothing extra.
        let nearB = try XCTUnwrap(engine.snap(LonLat(lon: -86.799, lat: 33.50038)))
        let fromEast = try XCTUnwrap(engine.snap(LonLat(lon: -86.794, lat: 33.5002)))
        let direct = try XCTUnwrap(engine.route(from: fromEast, to: nearB))
        XCTAssertEqual(engine.graph.roadName(Int(direct.edges.last! >> 1)), "B Street")
    }

    func testAlternativesAreOnlyRoadsAlmostAsNear() throws {
        let engine = RouteEngine(graph: try onewayPair())
        // 4 m from A, 40 m from B: B is more than the reach further away.
        let s = try XCTUnwrap(engine.snap(LonLat(lon: -86.797, lat: 33.50004)))
        XCTAssertEqual(engine.graph.roadName(Int(s.edge)), "A Street")
        XCTAssertTrue(s.alternatives.isEmpty)
    }

    /// The bug behind "the route loops round the block just before the destination": a point at a
    /// corner snaps to the end of whichever road was found first. When that was a one-way street
    /// ending there, the route had to drive down that street to arrive.
    func testDestinationAtTheEndOfAOneWayStreetIsTheJunction() throws {
        let g = try onewayPair()
        let engine = RouteEngine(graph: g)
        let aStreet = try XCTUnwrap((0..<g.edgeCount).first { g.roadName($0) == "A Street" })
        let eastCross = try XCTUnwrap((0..<g.edgeCount).first { g.roadName($0) == "East Cross" })
        XCTAssertEqual(g.speedBackward[aStreet], 0)
        // Start half-way up East Cross; the destination is the corner a1, as the end of A Street.
        let start = RoadSnap(edge: Int32(eastCross), fraction: 0.5, point: LonLat(lon: -86.794, lat: 33.5002), distance: 0)
        let corner = RoadSnap(edge: Int32(aStreet), fraction: 1, point: LonLat(lon: -86.794, lat: 33.5), distance: 0)
        let path = try XCTUnwrap(engine.route(from: start, to: corner))
        XCTAssertEqual(path.distance, 22, accuracy: 3, "straight down to the corner, not round by B, West Cross and A")
        XCTAssertEqual(path.edges.count, 1)

        // And a start at the beginning of a one-way street may leave by any road at that corner.
        let bStreet = try XCTUnwrap((0..<g.edgeCount).first { g.roadName($0) == "B Street" })
        let atB1 = RoadSnap(edge: Int32(bStreet), fraction: 0, point: LonLat(lon: -86.794, lat: 33.5004), distance: 0)
        let down = try XCTUnwrap(engine.route(from: atB1, to: corner))
        XCTAssertEqual(down.distance, 44, accuracy: 3)
    }

    func testSameJunctionIsAnEmptyRoute() throws {
        let g = try onewayPair()
        let engine = RouteEngine(graph: g)
        let a = try XCTUnwrap(engine.snap(LonLat(lon: -86.800, lat: 33.5)))
        let path = try XCTUnwrap(engine.route(from: a, to: a))
        XCTAssertEqual(path.distance, 0)
        XCTAssertEqual(path.duration, 0)
        XCTAssertEqual(path.steps.map(\.kind), [.depart, .arrive])
        XCTAssertGreaterThanOrEqual(path.points.count, 2)
    }

    func testSnapsFromElsewhereAndBadInputAreRefused() throws {
        let engine = RouteEngine(graph: try onewayPair())
        let good = try XCTUnwrap(engine.snap(LonLat(lon: -86.797, lat: 33.5)))
        let foreign = RoadSnap(edge: 9_999, fraction: 0.5, point: good.point, distance: 0)
        let negative = RoadSnap(edge: -3, fraction: 0.5, point: good.point, distance: 0)
        let notANumber = RoadSnap(edge: 0, fraction: .nan, point: LonLat(lon: .nan, lat: .nan), distance: .nan)
        for bad in [foreign, negative, notANumber] {
            XCTAssertNil(engine.route(from: bad, to: good))
            XCTAssertNil(engine.route(from: good, to: bad))
        }
        XCTAssertNil(engine.snap(LonLat(lon: .nan, lat: 33.5)))
        XCTAssertNil(engine.snap(LonLat(lon: -86.797, lat: .infinity)))
        XCTAssertNil(engine.snap(LonLat(lon: -86.797, lat: 33.5), maxMeters: .nan))
        // A huge radius is bounded by the graph, not by the area.
        XCTAssertNotNil(engine.snap(LonLat(lon: 100, lat: -40), maxMeters: 1e9))
    }

    func testPenaltiesOfTheWrongShapeAreHarmless() throws {
        let engine = RouteEngine(graph: try onewayPair())
        let a = try XCTUnwrap(engine.snap(LonLat(lon: -86.800, lat: 33.4995)))
        let b = try XCTUnwrap(engine.snap(LonLat(lon: -86.796, lat: 33.50001)))
        let plain = try XCTUnwrap(engine.route(from: a, to: b))
        XCTAssertEqual(engine.route(from: a, to: b, penalty: [])?.edges, plain.edges)
        XCTAssertEqual(engine.route(from: a, to: b, penalty: [.nan, -5])?.edges, plain.edges)
        XCTAssertEqual(engine.route(from: a, to: b, penalty: [Float](repeating: .nan, count: 99))?.edges, plain.edges)
    }

    func testASearchCanBeCancelled() throws {
        let g = RandomTown.graph(seed: 5, side: 80)       // 12 000 edges: far more than one poll interval
        let engine = RouteEngine(graph: g)
        let a = RoadSnap(edge: 0, fraction: 0.5, point: g.position(g.from[0]), distance: 0)
        let last = Int32(g.edgeCount - 1)
        let b = RoadSnap(edge: last, fraction: 0.5, point: g.position(g.to[Int(last)]), distance: 0)
        XCTAssertNotNil(engine.route(from: a, to: b))
        var polls = 0
        XCTAssertNil(engine.route(from: a, to: b, cancelled: { polls += 1; return true }))
        XCTAssertEqual(polls, 1)
        // The engine is usable afterwards.
        XCTAssertNotNil(engine.route(from: a, to: b, cancelled: { false }))
    }
}

// MARK: - Steps

final class RouteStepTests: XCTestCase {
    /// A four-arm roundabout (anticlockwise, one way) with two-way arms.
    private func roundabout() throws -> RoadGraph {
        let c = (lat: 33.5, lon: -86.8)
        let ring: [PBFTestEncoder.Node] = [
            .init(id: 1, lat: c.lat, lon: c.lon + 0.0002),      // east
            .init(id: 2, lat: c.lat + 0.0002, lon: c.lon),      // north
            .init(id: 3, lat: c.lat, lon: c.lon - 0.0002),      // west
            .init(id: 4, lat: c.lat - 0.0002, lon: c.lon),      // south
        ]
        let arms: [PBFTestEncoder.Node] = [
            .init(id: 11, lat: c.lat, lon: c.lon + 0.002), .init(id: 12, lat: c.lat + 0.002, lon: c.lon),
            .init(id: 13, lat: c.lat, lon: c.lon - 0.002), .init(id: 14, lat: c.lat - 0.002, lon: c.lon),
        ]
        let ways: [PBFTestEncoder.Way] = [
            .init(id: 100, refs: [1, 2, 3, 4, 1], tags: ["highway": "tertiary", "junction": "roundabout"]),
            .init(id: 101, refs: [1, 11], tags: ["highway": "tertiary", "name": "East Road"]),
            .init(id: 102, refs: [2, 12], tags: ["highway": "tertiary", "name": "North Road"]),
            .init(id: 103, refs: [3, 13], tags: ["highway": "tertiary", "name": "West Road"]),
            .init(id: 104, refs: [4, 14], tags: ["highway": "tertiary", "name": "South Road"]),
        ]
        return try build(ring + arms, ways)
    }

    func testARoundaboutIsOneStep() throws {
        let engine = RouteEngine(graph: try roundabout())
        let from = try XCTUnwrap(engine.snap(LonLat(lon: -86.8, lat: 33.499)))        // on South Road
        let to = try XCTUnwrap(engine.snap(LonLat(lon: -86.8, lat: 33.501)))          // on North Road
        let path = try XCTUnwrap(engine.route(from: from, to: to))
        // In at the south, past the east arm, out at the north: the second exit, said once (leaving
        // the roundabout used to add "Bear right onto North Road" as well).
        XCTAssertEqual(path.steps.map(\.kind), [.depart, .roundabout(exit: 2), .arrive])
        XCTAssertEqual(path.steps[1].text, "At the roundabout, take the 2nd exit onto North Road")
        XCTAssertEqual(path.steps.dropLast().reduce(0) { $0 + $1.distance }, path.distance, accuracy: 0.5)
    }

    func testOrdinals() {
        XCTAssertEqual([1, 2, 3, 4, 11, 12, 13, 21, 22, 23, 101, 111].map(RouteEngine.ordinal),
                       ["1st", "2nd", "3rd", "4th", "11th", "12th", "13th", "21st", "22nd", "23rd", "101st", "111th"])
    }

    func testCutKeepsTheEndsAndTheMiddle() {
        let line = [LonLat(lon: 0, lat: 0), LonLat(lon: 0.001, lat: 0), LonLat(lon: 0.002, lat: 0), LonLat(lon: 0.003, lat: 0)]
        let part = RouteEngine.cut(line, from: 0.25, to: 0.75)
        XCTAssertEqual(part.count, 4)
        XCTAssertEqual(part.first!.lon, 0.00075, accuracy: 1e-9)
        XCTAssertEqual(part.last!.lon, 0.00225, accuracy: 1e-9)
        XCTAssertEqual(RouteEngine.cut(line, from: 0.5, to: 0.5).count, 2)
        XCTAssertEqual(RouteEngine.cut([line[0]], from: 0, to: 1), [line[0]])
    }
}

// MARK: - The search against a plain reference

/// A square town with random one-way streets, gaps, speeds, classes and turn restrictions, built
/// straight into a `RoadGraph`.
enum RandomTown {
    static func graph(seed: UInt64, side: Int) -> RoadGraph {
        var rng = TestRNG(seed: seed)
        var g = RoadGraph()
        for r in 0..<side { for c in 0..<side {
            g.lat.append(Int32(335_000_000 + r * 9_000 + Int(rng.next() % 2_000)))
            g.lon.append(Int32(-868_000_000 + c * 11_000 + Int(rng.next() % 2_000)))
        } }
        func add(_ a: Int, _ b: Int) {
            guard rng.next() % 12 != 0 else { return }       // a gap in the grid
            let speeds: [UInt8] = [10, 30, 30, 45, 65, 105]
            let speed = speeds[Int(rng.next() % UInt64(speeds.count))]
            let direction = rng.next() % 6
            g.from.append(Int32(a)); g.to.append(Int32(b))
            g.length.append(Float(RoadGraphBuilder.meters((g.lat[a], g.lon[a]), (g.lat[b], g.lon[b]))))
            g.speedForward.append(direction == 0 ? 0 : speed)
            g.speedBackward.append(direction == 1 ? 0 : speed)
            g.roadClass.append(UInt8(rng.next() % UInt64(RoadClass.allCases.count)))
            g.flags.append(0)
            g.name.append(-1)
            g.shapeStart.append(Int32(g.shape.count))
        }
        for r in 0..<side { for c in 0..<side {
            if c + 1 < side { add(r * side + c, r * side + c + 1) }
            if r + 1 < side { add(r * side + c, (r + 1) * side + c) }
        } }
        // Restrictions between random pairs of edges that share a vertex.
        var edgesAt = [[Int32]](repeating: [], count: g.vertexCount)
        for e in 0..<g.edgeCount { edgesAt[Int(g.from[e])].append(Int32(e)); edgesAt[Int(g.to[e])].append(Int32(e)) }
        for v in 0..<g.vertexCount where edgesAt[v].count >= 3 && rng.next() % 5 == 0 {
            let a = edgesAt[v][Int(rng.next() % UInt64(edgesAt[v].count))], b = edgesAt[v][Int(rng.next() % UInt64(edgesAt[v].count))]
            if a != b { g.restrictions.append(.init(fromEdge: a, via: Int32(v), toEdge: b, only: rng.next() % 4 == 0)) }
        }
        g.buildAdjacency()
        return g
    }
}

final class RouteSearchReferenceTests: XCTestCase {
    /// Seconds of the fastest route by plain Dijkstra in Double, with no estimate, no reused
    /// buffers and the destinations written out longhand. nil when unreachable.
    private func reference(_ engine: RouteEngine, _ a: RoadSnap, _ b: RoadSnap, penalty: [Float]?) -> Double? {
        let g = engine.graph
        guard let start = engine.routeEnd(edge: a.edge, fraction: a.fraction), let end = engine.routeEnd(edge: b.edge, fraction: b.fraction) else { return nil }
        if case .at = start, start == end { return 0 }
        func time(_ de: Int32, _ fraction: Double) -> Double { Double(g.length[Int(de >> 1)]) * fraction / (Double(g.speed(de)) / 3.6) }
        func extra(_ de: Int32) -> Double { Double(penalty?[Int(de >> 1)] ?? 0) }
        var cost = [Double](repeating: .infinity, count: g.edgeCount * 2)
        var done = [Bool](repeating: false, count: g.edgeCount * 2)
        var best = Double.infinity
        func destination(on de: Int32) -> Double? {
            guard case .along(let edge, let f) = end, de >> 1 == edge else { return nil }
            return de & 1 == 0 ? f : 1 - f
        }
        func begin(_ de: Int32, _ doneFraction: Double) {
            guard g.speed(de) > 0 else { return }
            cost[Int(de)] = min(cost[Int(de)], time(de, 1 - doneFraction) + extra(de))
            if let f = destination(on: de), f >= doneFraction { best = min(best, time(de, f - doneFraction) + extra(de)) }
        }
        switch start {
        case .along(let edge, let f): begin(edge * 2, f); begin(edge * 2 + 1, 1 - f)
        case .at(let v): for k in Int(g.adjStart[Int(v)])..<Int(g.adjStart[Int(v) + 1]) { begin(g.adj[k], 0) }
        }
        while true {
            // The cheapest unfinished edge, by a full scan.
            var de = -1
            for i in cost.indices where !done[i] && cost[i] < (de < 0 ? .infinity : cost[de]) { de = i }
            guard de >= 0 else { break }
            done[de] = true
            let v = g.head(Int32(de))
            if end == .at(vertex: v) { best = min(best, cost[de]) }
            for k in Int(g.adjStart[Int(v)])..<Int(g.adjStart[Int(v) + 1]) {
                let next = g.adj[k]
                guard let turn = engine.turnCost(Int32(de), next, at: v) else { continue }
                if let f = destination(on: next) { best = min(best, cost[de] + Double(turn) + time(next, f) + extra(next)) }
                cost[Int(next)] = min(cost[Int(next)], cost[de] + Double(turn) + time(next, 1) + extra(next))
            }
        }
        return best.isFinite ? best : nil
    }

    /// What the engine's route costs under the same rules (its `duration` plus penalties).
    private func cost(of path: RoutePath, penalty: [Float]?) -> Double {
        guard let penalty, path.distance > 0 else { return path.duration }
        return path.duration + path.edges.reduce(0) { $0 + Double(penalty[Int($1 >> 1)]) }
    }

    func testFastestRouteMatchesPlainDijkstra() throws {
        var rng = TestRNG(seed: 2026)
        var compared = 0, unreachable = 0
        for town in 0..<12 {
            let g = RandomTown.graph(seed: UInt64(town) + 1, side: 9)
            let engine = RouteEngine(graph: g)
            let penalty: [Float]? = town % 3 == 2 ? (0..<g.edgeCount).map { _ in rng.next() % 5 == 0 ? Float(rng.next() % 900) : 0 } : nil
            for _ in 0..<60 {
                func snap() -> RoadSnap {
                    let e = Int32(rng.next() % UInt64(g.edgeCount))
                    // Ends of edges (junctions) as often as points along them.
                    let f = [0, 1, 0.5, Double(rng.next() % 1000) / 1000][Int(rng.next() % 4)]
                    // The town's edges are straight, so the point is a plain interpolation.
                    let from = g.position(g.from[Int(e)]), to = g.position(g.to[Int(e)])
                    let p = LonLat(lon: from.lon + (to.lon - from.lon) * f, lat: from.lat + (to.lat - from.lat) * f)
                    return RoadSnap(edge: e, fraction: f, point: p, distance: 0)
                }
                let a = snap(), b = snap()
                let expected = reference(engine, a, b, penalty: penalty)
                let path = engine.route(from: a, to: b, penalty: penalty)
                guard let expected, let path else {
                    XCTAssertNil(path, "town \(town): a route where the reference found none (\(a) → \(b))")
                    XCTAssertNil(expected, "town \(town): no route where the reference found one (\(a) → \(b))")
                    unreachable += 1
                    continue
                }
                compared += 1
                XCTAssertEqual(cost(of: path, penalty: penalty), expected, accuracy: 0.02 + expected * 1e-4, "town \(town): \(a) → \(b)")
                // The edges join up and each is driven the way it allows.
                for (x, y) in zip(path.edges, path.edges.dropFirst()) { XCTAssertEqual(g.head(x), g.tail(y)) }
                XCTAssertTrue(path.edges.allSatisfy { g.speed($0) > 0 } || path.distance == 0)
            }
        }
        XCTAssertGreaterThan(compared, 500)
        XCTAssertLessThan(unreachable, 100)
    }

    /// Costs beyond what a Float holds to the millisecond (long trips, stacked camera penalties)
    /// must not make the search drop its own heap entries.
    func testLargeCostsStillFindTheRoute() throws {
        let g = RandomTown.graph(seed: 77, side: 9)
        let engine = RouteEngine(graph: g)
        let penalty = [Float](repeating: 40_000, count: g.edgeCount)
        var rng = TestRNG(seed: 4)
        for _ in 0..<80 {
            let a = RoadSnap(edge: Int32(rng.next() % UInt64(g.edgeCount)), fraction: 0.4, point: g.position(0), distance: 0)
            let b = RoadSnap(edge: Int32(rng.next() % UInt64(g.edgeCount)), fraction: 0.6, point: g.position(Int32(g.vertexCount - 1)), distance: 0)
            XCTAssertEqual(engine.route(from: a, to: b) == nil, engine.route(from: a, to: b, penalty: penalty) == nil)
        }
    }
}

// MARK: - The spatial index

final class EdgeGridTests: XCTestCase {
    func testPairsKeepEdgeNumbersAboveSixteenMillion() {
        // Edge ids used to be cut to 24 bits here, sending snaps in a large region to the wrong road.
        let key = EdgeGrid.key(column: 40_000, row: 20_000)
        for edge in [0, 1, 16_777_215, 16_777_216, 20_000_000, RoadGraph.maxEdges] {
            let pair = EdgeGrid.pack(key: key, edge: edge)
            XCTAssertEqual(Int(Int32(truncatingIfNeeded: pair)), edge)
            XCTAssertEqual(UInt32(pair >> 32), key)
        }
        XCTAssertEqual(EdgeGrid.column(ofKey: key), 40_000)
        XCTAssertEqual(EdgeGrid.row(ofKey: key), 20_000)
        XCTAssertLessThan(EdgeGrid.pack(key: key - 1, edge: RoadGraph.maxEdges), EdgeGrid.pack(key: key, edge: 0))
    }

    func testCellsNeverTrap() {
        for v in [Double.nan, .infinity, -.infinity, 1e300, -1e300, 214.7, -214.7, 0] {
            XCTAssertTrue((0...40_000).contains(EdgeGrid.column(v)))
            XCTAssertTrue((0...20_000).contains(EdgeGrid.row(v)))
        }
    }

    func testQueriesMatchBruteForceWhateverTheRadius() {
        let g = RandomTown.graph(seed: 9, side: 12)
        let grid = EdgeGrid(g)
        let centre = g.position(Int32(g.vertexCount / 2))
        func found(_ r: Double) -> Set<Int32> {
            var s = Set<Int32>()
            grid.forEachEdge(near: centre, radiusDegrees: r) { s.insert($0) }
            return s
        }
        // Everything, by the per-cell path and by the walk over occupied cells.
        XCTAssertEqual(found(1).count, g.edgeCount)
        XCTAssertEqual(found(400).count, g.edgeCount)
        XCTAssertEqual(found(.infinity).count, g.edgeCount)
        XCTAssertEqual(found(.nan).count, g.edgeCount)
        // A small radius finds at least the edges with a vertex inside it.
        let r = 0.003
        let near = found(r)
        for e in 0..<g.edgeCount {
            let p = g.position(g.from[e])
            if abs(p.lon - centre.lon) < r && abs(p.lat - centre.lat) < r { XCTAssertTrue(near.contains(Int32(e))) }
        }
        XCTAssertLessThan(near.count, g.edgeCount)
    }

    func testSnapFindsTheNearestRoadNotJustTheNearestCell() throws {
        // A road 600 m north (in the cell searched first) and one 500 m east, across a cell border.
        let nodes: [PBFTestEncoder.Node] = [
            .init(id: 1, lat: 33.5054, lon: -86.8049), .init(id: 2, lat: 33.5054, lon: -86.8001),
            .init(id: 3, lat: 33.4990, lon: -86.7994), .init(id: 4, lat: 33.5010, lon: -86.7994),
        ]
        let g = try build(nodes, [.init(id: 1, refs: [1, 2], tags: ["highway": "residential", "name": "North"]),
                                  .init(id: 2, refs: [3, 4], tags: ["highway": "residential", "name": "East"])])
        let engine = RouteEngine(graph: g)
        let s = try XCTUnwrap(engine.snap(LonLat(lon: -86.8048, lat: 33.5)))
        XCTAssertEqual(g.roadName(Int(s.edge)), "East")
        XCTAssertEqual(s.distance, 500, accuracy: 15)
    }
}

// MARK: - Untrusted files

final class RoadGraphFileFuzzTests: XCTestCase {
    func testDamagedFilesNeverTrap() throws {
        let g = RandomTown.graph(seed: 3, side: 6)
        let good = [UInt8](RoadGraphFile.encode(g))
        XCTAssertNoThrow(try RoadGraphFile.decode(Data(good)))
        var rng = TestRNG(seed: 12)
        var accepted = 0
        for round in 0..<600 {
            var bytes = good
            if round % 5 == 0 {
                bytes.removeLast(Int(rng.next() % UInt64(bytes.count)))
            } else {
                for _ in 0..<(1 + Int(rng.next() % 4)) {
                    let i = Int(rng.next() % UInt64(bytes.count))
                    // Extreme values find more than random ones.
                    bytes[i] = [0x00, 0xFF, 0x7F, 0x80, UInt8(truncatingIfNeeded: rng.next())][Int(rng.next() % 5)]
                }
            }
            guard let damaged = try? RoadGraphFile.decode(Data(bytes)) else { continue }
            accepted += 1
            // Whatever is accepted can be used: the engine indexes it without further checks.
            let engine = RouteEngine(graph: damaged)
            guard damaged.edgeCount > 1 else { continue }
            let a = engine.snap(g.position(0)), b = engine.snap(g.position(Int32(g.vertexCount - 1)))
            if let a, let b { _ = engine.route(from: a, to: b) }
            let x = RoadSnap(edge: 0, fraction: 0.3, point: g.position(0), distance: 0)
            let y = RoadSnap(edge: Int32(damaged.edgeCount - 1), fraction: 0.7, point: g.position(1), distance: 0)
            _ = engine.route(from: x, to: y)
            _ = engine.cameraPenalties([ALPRCamera(id: .node(1), coordinate: g.position(3), directions: [90], vendor: .flock,
                                                   operatorName: nil, mount: nil, zone: nil, lastEdited: nil)], options: .init())
        }
        XCTAssertGreaterThan(accepted, 0)
    }

    func testHeaderOnlyAndOversizedCountsAreRejected() {
        XCTAssertThrowsError(try RoadGraphFile.decode(Data()))
        XCTAssertThrowsError(try RoadGraphFile.decode(Data("GRDG".utf8)))
        // A count far beyond the bytes present.
        var d = Data("GRDG".utf8)
        d.append(contentsOf: [1, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF])
        XCTAssertThrowsError(try RoadGraphFile.decode(d)) { XCTAssertEqual($0 as? RoadGraphFile.FileError, .damaged("array")) }
    }
}

final class PBFRobustnessTests: XCTestCase {
    private let nodes: [PBFTestEncoder.Node] = (0..<6).map { .init(id: Int64($0 + 1), lat: 33.5 + Double($0) * 0.001, lon: -86.8) }

    func testWayTagFilterKeepsOnlyTheKeysAskedFor() throws {
        let way = PBFTestEncoder.Way(id: 7, refs: [1, 2, 3], tags: ["highway": "residential", "name": "Elm", "tiger:cfcc": "A41", "surface": "asphalt"])
        var seen: [OSMWay] = []
        var v = PBFReader.Visitor()
        v.wayKey = "highway"
        v.wayTagKeys = ["highway", "name"]
        v.way = { seen.append($0) }
        try PBFReader(data: PBFTestEncoder.encode(nodes: nodes, ways: [way])).scan(v)
        XCTAssertEqual(seen.first?.tags, ["highway": "residential", "name": "Elm"])
        XCTAssertEqual(seen.first?.refs, [1, 2, 3])
    }

    func testASecondScanSkipsBlobsItHasNoUseFor() throws {
        let reader = PBFReader(data: PBFTestEncoder.encode(nodes: nodes, ways: [.init(id: 7, refs: [1, 2], tags: ["highway": "service"])]))
        var ways = PBFReader.Visitor()
        ways.way = { _ in }
        let contents = try reader.scan(ways)
        XCTAssertEqual(contents, [[.nodes, .ways]])
        var count = 0
        var nodeVisitor = PBFReader.Visitor()
        nodeVisitor.node = { _, _, _ in count += 1 }
        XCTAssertEqual(try reader.scan(nodeVisitor, skipping: contents), contents)
        XCTAssertEqual(count, 6)
        // Told the blob holds only ways, a node visitor leaves it alone.
        count = 0
        XCTAssertEqual(try reader.scan(nodeVisitor, skipping: [.ways]), [.ways])
        XCTAssertEqual(count, 0)
        // A list that is too short just means "unknown" for the rest.
        XCTAssertEqual(try reader.scan(nodeVisitor, skipping: []), contents)
    }

    func testBuilderRefusesNodeIdsItCannotNumber() {
        let odd: [PBFTestEncoder.Node] = [.init(id: 1, lat: 33.5, lon: -86.8), .init(id: 1 << 40, lat: 33.501, lon: -86.8)]
        let data = PBFTestEncoder.encode(nodes: odd, ways: [.init(id: 1, refs: [1, 1 << 40], tags: ["highway": "residential"])])
        XCTAssertThrowsError(try RoadGraphBuilder.build(pbf: data)) { XCTAssertEqual($0 as? PBFError, .unsupported("node id \(1 << 40)")) }
    }

    func testRepeatedNodesAndRingsBuildCleanly() throws {
        // A node listed twice in a row, and a way that closes on itself.
        let ways: [PBFTestEncoder.Way] = [
            .init(id: 1, refs: [1, 2, 2, 3], tags: ["highway": "residential"]),
            .init(id: 2, refs: [3, 4, 5, 3], tags: ["highway": "residential"]),
            .init(id: 3, refs: [6, 6], tags: ["highway": "residential"]),
        ]
        var bent = nodes
        bent[4] = .init(id: 5, lat: 33.5035, lon: -86.799)
        let (g, _) = try RoadGraphBuilder.build(pbf: PBFTestEncoder.encode(nodes: bent, ways: ways))
        // 1–2 and 2–3 (a node used twice is a junction, but not an edge to itself), and the ring.
        XCTAssertEqual(g.edgeCount, 3)
        XCTAssertEqual(Double(g.length[0]), 111, accuracy: 2)
        XCTAssertEqual(Double(g.length[1]), 111, accuracy: 2)
        XCTAssertNotEqual(g.from[0], g.to[0])
        XCTAssertNotEqual(g.from[1], g.to[1])
        XCTAssertEqual(g.from[2], g.to[2], "the ring is one edge back to its start")
        XCTAssertEqual(g.pointCount(2), 4)
        XCTAssertEqual(g.polyline(2).count, 4)
        XCTAssertEqual(g.vertexCount, 3, "the way from a node to itself adds nothing")
        XCTAssertNoThrow(try RoadGraphFile.decode(RoadGraphFile.encode(g)))
        _ = RouteEngine(graph: g)
    }

    func testBuilderSurvivesMutatedExtracts() {
        let (w, r) = (
            [PBFTestEncoder.Way(id: 1, refs: [1, 2, 3, 4], tags: ["highway": "residential", "name": "Elm"]),
             PBFTestEncoder.Way(id: 2, refs: [3, 5, 6], tags: ["highway": "primary", "oneway": "yes"])],
            [PBFTestEncoder.Relation(id: 9, members: [(1, 1, "from"), (0, 3, "via"), (1, 2, "to")], tags: ["type": "restriction", "restriction": "no_left_turn"])])
        // Uncompressed, so the mutations reach the parser instead of failing in zlib.
        let good = [UInt8](PBFTestEncoder.encode(nodes: nodes, ways: w, relations: r, compress: false))
        var rng = TestRNG(seed: 21)
        for _ in 0..<800 {
            var m = good
            for _ in 0..<(1 + Int(rng.next() % 3)) {
                m[Int(rng.next() % UInt64(m.count))] = [0x00, 0xFF, 0x7F, 0x80, UInt8(truncatingIfNeeded: rng.next())][Int(rng.next() % 5)]
            }
            if let (g, _) = try? RoadGraphBuilder.build(pbf: Data(m)) { _ = RouteEngine(graph: g) }
        }
    }
}

// MARK: - Camera exposure

final class CameraExposureEquivalenceTests: XCTestCase {
    /// `hits` boxes the route in runs of segments; the answer must be what testing every segment gives.
    func testHitsMatchTestingEverySegment() {
        var rng = TestRNG(seed: 8)
        func unit() -> Double { Double(rng.next() % 1_000_000) / 1_000_000 }
        // A wandering route of 700 points, about 30 m apart.
        var route = [LonLat(lon: -86.8, lat: 33.5)]
        var heading = 0.3
        for _ in 0..<700 {
            heading += (unit() - 0.5) * 0.9
            route.append(LonLat(lon: route.last!.lon + cos(heading) * 0.0003, lat: route.last!.lat + sin(heading) * 0.0003))
        }
        let cameras: [(Int, ALPRCamera)] = (0..<400).map { i in
            let near = route[Int(rng.next() % UInt64(route.count))]
            let p = LonLat(lon: near.lon + (unit() - 0.5) * 0.004, lat: near.lat + (unit() - 0.5) * 0.004)
            return (i, ALPRCamera(id: .node(Int64(i)), coordinate: p, directions: i % 3 == 0 ? [] : [UInt16(rng.next() % 360)],
                                  vendor: .flock, operatorName: nil, mount: nil, zone: nil, lastEdited: nil))
        }
        for options in [ExposureOptions(), ExposureOptions(buffer: 150, directional: false), ExposureOptions(buffer: 20)] {
            let flat = CameraExposure.Flat(lat: route[route.count / 2].lat)
            let pts = route.map(flat.xy)
            var reach = [0.0]
            for i in 1..<pts.count { let d = pts[i] - pts[i - 1]; reach.append(reach[i - 1] + (d * d).sum().squareRoot()) }
            var expected: [CameraExposure.Hit] = []
            for (index, camera) in cameras {
                var best: CameraExposure.Hit?
                for i in 0..<(pts.count - 1) {
                    guard let (d, t) = CameraExposure.seen(flat.xy(camera.coordinate), camera.directions, pts[i], pts[i + 1], options) else { continue }
                    if best == nil || d < best!.distance { best = .init(camera: index, along: reach[i] + (reach[i + 1] - reach[i]) * t, distance: d) }
                }
                if let best { expected.append(best) }
            }
            let got = CameraExposure.hits(route: route, candidates: cameras, options: options)
            XCTAssertEqual(got, expected.sorted { $0.along < $1.along })
            XCTAssertFalse(got.isEmpty)
        }
        // Routes shorter than one run of segments.
        XCTAssertEqual(CameraExposure.hits(route: Array(route.prefix(2)), candidates: cameras).count,
                       CameraExposure.hits(route: Array(route.prefix(2)), candidates: cameras, options: .init()).count)
        XCTAssertTrue(CameraExposure.hits(route: [route[0]], candidates: cameras).isEmpty)
    }
}
