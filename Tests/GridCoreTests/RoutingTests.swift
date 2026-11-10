import XCTest
@testable import GridCore

/// A made-up 4 × 4 street grid (≈ 111 m north–south, ≈ 93 m east–west per block).
private enum Town {
    static func id(_ r: Int, _ c: Int) -> Int64 { Int64(100 + r * 10 + c) }
    static func ll(_ r: Int, _ c: Int) -> LonLat { LonLat(lon: -86.8 + Double(c) * 0.001, lat: 33.5 + Double(r) * 0.001) }
    static var nodes: [PBFTestEncoder.Node] {
        var n: [PBFTestEncoder.Node] = []
        for r in 0..<4 { for c in 0..<4 { n.append(.init(id: id(r, c), lat: ll(r, c).lat, lon: ll(r, c).lon)) } }
        n.append(.init(id: 900, lat: 33.5005, lon: -86.7995))   // footway only
        return n
    }

    static func ways(restriction: Bool = false) -> ([PBFTestEncoder.Way], [PBFTestEncoder.Relation]) {
        var w: [PBFTestEncoder.Way] = []
        for r in 0..<4 {
            var tags = ["highway": "residential", "name": "Row \(r) Street"]
            if r == 1 { tags["oneway"] = "yes" }        // eastbound only
            w.append(.init(id: Int64(1000 + r), refs: (0..<4).map { id(r, $0) }, tags: tags))
        }
        for c in 0..<4 where c != 1 {
            w.append(.init(id: Int64(2000 + c), refs: (0..<4).map { id($0, c) }, tags: ["highway": "residential", "name": "Col \(c) Avenue"]))
        }
        // Column 1 in two ways meeting at row 1 (restrictions name whole ways that end at the via node).
        w.append(.init(id: 2101, refs: [id(0, 1), id(1, 1)], tags: ["highway": "residential", "name": "Col 1 Avenue"]))
        w.append(.init(id: 2102, refs: [id(1, 1), id(2, 1), id(3, 1)], tags: ["highway": "residential", "name": "Col 1 Avenue"]))
        w.append(.init(id: 3000, refs: [id(0, 0), 900, id(1, 1)], tags: ["highway": "footway"]))
        w.append(.init(id: 3001, refs: [id(2, 2), id(3, 3)], tags: ["highway": "service", "access": "private"]))
        var rel: [PBFTestEncoder.Relation] = []
        if restriction {
            rel.append(.init(id: 5000, members: [(1, 2101, "from"), (0, id(1, 1), "via"), (1, 2102, "to")],
                             tags: ["type": "restriction", "restriction": "no_straight_on"]))
        }
        return (w, rel)
    }

    static func graph(restriction: Bool = false, compress: Bool = true) throws -> RoadGraph {
        let (w, r) = ways(restriction: restriction)
        return try RoadGraphBuilder.build(pbf: PBFTestEncoder.encode(nodes: nodes, ways: w, relations: r, compress: compress)).0
    }
}

final class PBFReaderTests: XCTestCase {
    func testReadsNodesWaysAndRelations() throws {
        let (w, r) = Town.ways(restriction: true)
        for compress in [true, false] {
            let data = PBFTestEncoder.encode(nodes: Town.nodes, ways: w, relations: r, compress: compress)
            var nodes: [Int64: (Int32, Int32)] = [:]
            var ways: [OSMWay] = []
            var rels: [OSMRelation] = []
            var v = PBFReader.Visitor()
            v.node = { id, la, lo in nodes[id] = (la, lo) }
            v.way = { ways.append($0) }
            v.relationTypes = ["restriction"]
            v.relation = { rels.append($0) }
            try PBFReader(data: data).scan(v)
            XCTAssertEqual(nodes.count, 17)
            XCTAssertEqual(nodes[Town.id(2, 3)]?.0, 335_020_000)
            XCTAssertEqual(nodes[Town.id(2, 3)]?.1, -867_970_000)
            XCTAssertEqual(ways.count, w.count)
            XCTAssertEqual(ways.first { $0.id == 1001 }?.tags["oneway"], "yes")
            XCTAssertEqual(ways.first { $0.id == 2102 }?.refs, [Town.id(1, 1), Town.id(2, 1), Town.id(3, 1)])
            XCTAssertEqual(rels.count, 1)
            XCTAssertEqual(rels[0].members.map(\.role), ["from", "via", "to"])
            XCTAssertEqual(rels[0].members[1].type, .node)
        }
    }

    func testWayKeyFilter() throws {
        let (w, _) = Town.ways()
        var extra = w
        extra.append(.init(id: 4000, refs: [Town.id(0, 0), Town.id(0, 1)], tags: ["building": "yes"]))
        var seen: [Int64] = []
        var v = PBFReader.Visitor()
        v.wayKey = "highway"
        v.way = { seen.append($0.id) }
        try PBFReader(data: PBFTestEncoder.encode(nodes: Town.nodes, ways: extra)).scan(v)
        XCTAssertFalse(seen.contains(4000))
        XCTAssertEqual(seen.count, w.count)
    }

    func testRejectsBadInputWithoutTrapping() {
        let good = PBFTestEncoder.encode(nodes: Town.nodes, ways: Town.ways().0)
        var v = PBFReader.Visitor(); v.node = { _, _, _ in }
        // Every truncation throws (or reads cleanly up to a block boundary); none traps.
        for cut in stride(from: 1, to: good.count, by: max(1, good.count / 60)) {
            _ = try? PBFReader(data: good.prefix(cut)).scan(v)
        }
        XCTAssertThrowsError(try PBFReader(data: good.prefix(good.count - 3)).scan(v))
        XCTAssertThrowsError(try PBFReader(data: Data([0, 0, 0, 0])).scan(v))
        XCTAssertThrowsError(try PBFReader(data: Data(repeating: 0xFF, count: 64)).scan(v))
        let historical = PBFTestEncoder.encode(nodes: Town.nodes, ways: [], features: ["OsmSchema-V0.6", "HistoricalInformation"])
        XCTAssertThrowsError(try PBFReader(data: historical).scan(v)) { XCTAssertEqual($0 as? PBFError, .unsupported("HistoricalInformation")) }
        // Mutated bytes never trap.
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<300 {
            var m = [UInt8](good)
            for _ in 0..<4 { m[Int.random(in: 0..<m.count, using: &rng)] = UInt8.random(in: 0...255, using: &rng) }
            _ = try? PBFReader(data: Data(m)).scan(v)
        }
    }

    func testCancel() {
        let data = PBFTestEncoder.encode(nodes: Town.nodes, ways: Town.ways().0)
        XCTAssertThrowsError(try PBFReader(data: data).scan(.init(), cancelled: { true })) { XCTAssertEqual($0 as? PBFError, .cancelled) }
    }
}

final class RoadProfileTests: XCTestCase {
    func testAccessAndClasses() {
        XCTAssertNotNil(RoadProfile.attributes(["highway": "residential"]))
        XCTAssertNil(RoadProfile.attributes(["highway": "footway"]))
        XCTAssertNil(RoadProfile.attributes(["highway": "residential", "access": "private"]))
        XCTAssertNotNil(RoadProfile.attributes(["highway": "residential", "access": "private", "motor_vehicle": "yes"]))
        XCTAssertNil(RoadProfile.attributes(["highway": "residential", "access": "yes", "motorcar": "no"]))
        XCTAssertNotNil(RoadProfile.attributes(["highway": "residential", "access": "destination"]))
        XCTAssertNil(RoadProfile.attributes(["highway": "service", "area": "yes"]))
        XCTAssertNil(RoadProfile.attributes(["highway": "tertiary", "oneway": "reversible"]))
    }

    func testOnewayRules() {
        let yes = RoadProfile.attributes(["highway": "primary", "oneway": "yes"])!
        XCTAssertGreaterThan(yes.forwardKmh, 0); XCTAssertEqual(yes.backwardKmh, 0)
        let rev = RoadProfile.attributes(["highway": "primary", "oneway": "-1"])!
        XCTAssertEqual(rev.forwardKmh, 0); XCTAssertGreaterThan(rev.backwardKmh, 0)
        XCTAssertEqual(RoadProfile.attributes(["highway": "motorway"])!.backwardKmh, 0)
        XCTAssertGreaterThan(RoadProfile.attributes(["highway": "motorway", "oneway": "no"])!.backwardKmh, 0)
        let ring = RoadProfile.attributes(["highway": "tertiary", "junction": "roundabout"])!
        XCTAssertTrue(ring.roundabout); XCTAssertEqual(ring.backwardKmh, 0)
    }

    func testSpeedsAndNames() {
        XCTAssertEqual(RoadProfile.maxspeed("50"), 50)
        XCTAssertEqual(RoadProfile.maxspeed("30 mph")!, 48.28, accuracy: 0.01)
        XCTAssertEqual(RoadProfile.maxspeed("none"), 130)
        XCTAssertNil(RoadProfile.maxspeed("signals"))
        let slow = RoadProfile.attributes(["highway": "primary", "maxspeed": "25 mph"])!
        let fast = RoadProfile.attributes(["highway": "primary", "maxspeed": "55 mph"])!
        XCTAssertLessThan(slow.forwardKmh, fast.forwardKmh)
        XCTAssertEqual(RoadProfile.attributes(["highway": "motorway", "ref": "I 65", "name": "Red Mountain Expressway"])!.name,
                       "Red Mountain Expressway (I 65)")
        XCTAssertEqual(RoadProfile.attributes(["highway": "residential", "ref": "CR 12"])!.name, "CR 12")
        XCTAssertEqual(RoadProfile.attributes(["highway": "residential", "name": "Main\u{202E} St"])!.name, "Main St")
    }
}

final class RoadGraphTests: XCTestCase {
    func testBuildSplitsAtJunctionsAndSkipsUnroutable() throws {
        let (g, stats) = try RoadGraphBuilder.build(pbf: PBFTestEncoder.encode(nodes: Town.nodes, ways: Town.ways(restriction: true).0,
                                                                                relations: Town.ways(restriction: true).1))
        XCTAssertEqual(g.vertexCount, 16)
        // 4 rows × 3 blocks + 4 columns × 3 blocks.
        XCTAssertEqual(g.edgeCount, 24)
        XCTAssertEqual(stats.restrictions, 1)
        XCTAssertEqual(g.restrictions.first?.only, false)
        // Row 1 is one way: its edges allow forward only.
        let row1 = (0..<g.edgeCount).filter { g.roadName($0) == "Row 1 Street" }
        XCTAssertEqual(row1.count, 3)
        XCTAssertTrue(row1.allSatisfy { g.speedForward[$0] > 0 && g.speedBackward[$0] == 0 })
        XCTAssertEqual(Double(g.length[row1[0]]), 93, accuracy: 2)
    }

    func testMissingNodeCutsTheWay() throws {
        var nodes = Town.nodes
        nodes.removeAll { $0.id == Town.id(0, 2) }
        let (g, stats) = try RoadGraphBuilder.build(pbf: PBFTestEncoder.encode(nodes: nodes, ways: Town.ways().0))
        XCTAssertGreaterThan(stats.missingNodes, 0)
        XCTAssertFalse((0..<g.edgeCount).contains { e in
            [g.from[e], g.to[e]].contains { g.position($0) == Town.ll(0, 2) }
        })
    }

    func testFileRoundTripAndDamage() throws {
        let g = try Town.graph(restriction: true)
        let data = RoadGraphFile.encode(g)
        let back = try RoadGraphFile.decode(data)
        XCTAssertEqual(back.lat, g.lat); XCTAssertEqual(back.from, g.from); XCTAssertEqual(back.shape, g.shape)
        XCTAssertEqual(back.names, g.names); XCTAssertEqual(back.restrictions, g.restrictions); XCTAssertEqual(back.adj, g.adj)
        XCTAssertThrowsError(try RoadGraphFile.decode(Data("nope".utf8)))
        XCTAssertThrowsError(try RoadGraphFile.decode(data.prefix(data.count / 2)))
        // An edge pointing past the vertices is caught.
        var bad = g; bad.to[0] = Int32(g.vertexCount + 5)
        XCTAssertThrowsError(try RoadGraphFile.decode(RoadGraphFile.encode(bad)))
    }
}

final class RouterTests: XCTestCase {
    private func route(_ g: RoadGraph, _ a: LonLat, _ b: LonLat, penalty: [Float]? = nil) throws -> RoutePath {
        let e = RouteEngine(graph: g)
        let sa = try XCTUnwrap(e.snap(a)), sb = try XCTUnwrap(e.snap(b))
        return try XCTUnwrap(e.route(from: sa, to: sb, penalty: penalty))
    }

    func testShortestAcrossTown() throws {
        let p = try route(Town.graph(), Town.ll(0, 0), Town.ll(3, 3))
        XCTAssertEqual(p.distance, 3 * 111 + 3 * 93, accuracy: 15)
        XCTAssertEqual(p.points.first!.lat, 33.5, accuracy: 1e-6)
        XCTAssertEqual(p.points.last!.lon, -86.797, accuracy: 1e-6)
        XCTAssertEqual(p.steps.first?.kind, .depart)
        XCTAssertEqual(p.steps.last?.kind, .arrive)
        XCTAssertTrue(p.steps.contains { [.left, .right].contains($0.kind) })
        XCTAssertEqual(p.steps.dropLast().reduce(0) { $0 + $1.distance }, p.distance, accuracy: 1)
    }

    func testOneWayIsRespected() throws {
        // Westward along Row 1 isn't allowed: the route leaves it.
        let p = try route(Town.graph(), Town.ll(1, 3), Town.ll(1, 0))
        XCTAssertGreaterThan(p.distance, 3 * 93 + 2 * 100)
    }

    func testTurnRestrictionIsRespected() throws {
        let free = try route(Town.graph(), Town.ll(0, 1), Town.ll(2, 1))
        XCTAssertEqual(free.distance, 222, accuracy: 10)
        let limited = try route(Town.graph(restriction: true), Town.ll(0, 1), Town.ll(2, 1))
        XCTAssertGreaterThan(limited.distance, 350)
    }

    func testSameEdge() throws {
        let p = try route(Town.graph(), LonLat(lon: -86.8, lat: 33.5002), LonLat(lon: -86.8, lat: 33.5008))
        XCTAssertEqual(p.distance, 67, accuracy: 4)
        XCTAssertEqual(p.edges.count, 1)
    }

    func testCamerasAreAvoidedWhenAsked() throws {
        let g = try Town.graph()
        let cam = ALPRCamera(id: .node(1), coordinate: LonLat(lon: -86.8001, lat: 33.5015), directions: [], vendor: .flock,
                             operatorName: nil, mount: nil, zone: nil, lastEdited: nil)
        let normal = try route(g, Town.ll(0, 0), Town.ll(3, 0))
        XCTAssertEqual(normal.distance, 333, accuracy: 10)
        XCTAssertEqual(CameraExposure.hits(route: normal.points, candidates: [(0, cam)]).count, 1)
        let pen = RouteEngine(graph: g).cameraPenalties([cam], options: .init())
        XCTAssertGreaterThan(pen.filter { $0 > 0 }.count, 0)
        let avoid = try route(g, Town.ll(0, 0), Town.ll(3, 0), penalty: pen)
        XCTAssertGreaterThan(avoid.distance, 450)
        XCTAssertEqual(CameraExposure.hits(route: avoid.points, candidates: [(0, cam)]).count, 0)
    }

    func testUnreachable() throws {
        // Two separate roads far apart.
        let nodes: [PBFTestEncoder.Node] = [.init(id: 1, lat: 33.5, lon: -86.8), .init(id: 2, lat: 33.501, lon: -86.8),
                                            .init(id: 3, lat: 33.6, lon: -86.8), .init(id: 4, lat: 33.601, lon: -86.8)]
        let ways: [PBFTestEncoder.Way] = [.init(id: 1, refs: [1, 2], tags: ["highway": "residential"]),
                                          .init(id: 2, refs: [3, 4], tags: ["highway": "residential"])]
        let (g, _) = try RoadGraphBuilder.build(pbf: PBFTestEncoder.encode(nodes: nodes, ways: ways))
        let e = RouteEngine(graph: g)
        let a = try XCTUnwrap(e.snap(LonLat(lon: -86.8, lat: 33.5005)))
        let b = try XCTUnwrap(e.snap(LonLat(lon: -86.8, lat: 33.6005), maxMeters: 1500))
        XCTAssertNil(e.route(from: a, to: b))
        XCTAssertNil(e.snap(LonLat(lon: -80, lat: 30)))
    }
}

final class CameraExposureTests: XCTestCase {
    private func cam(_ dirs: [UInt16], lon: Double = -86.8, lat: Double = 33.5) -> ALPRCamera {
        ALPRCamera(id: .node(1), coordinate: LonLat(lon: lon, lat: lat), directions: dirs, vendor: .flock,
                   operatorName: nil, mount: nil, zone: nil, lastEdited: nil)
    }
    // A road 40 m east of the camera, running north.
    private let road = [LonLat(lon: -86.79957, lat: 33.499), LonLat(lon: -86.79957, lat: 33.501)]

    func testBufferAndUnknownFacing() {
        XCTAssertEqual(CameraExposure.hits(route: road, candidates: [(0, cam([]))]).count, 1)
        XCTAssertEqual(CameraExposure.hits(route: road, candidates: [(0, cam([]))], options: .init(buffer: 30)).count, 0)
    }

    func testCones() {
        XCTAssertEqual(CameraExposure.hits(route: road, candidates: [(0, cam([90]))]).count, 1)    // facing the road
        XCTAssertEqual(CameraExposure.hits(route: road, candidates: [(0, cam([270]))]).count, 0)   // facing away
        XCTAssertEqual(CameraExposure.hits(route: road, candidates: [(0, cam([270]))], options: .init(directional: false)).count, 1)
        // North-facing (0°) is a real direction: it sees the road to its north-east only within its cone.
        let north = [LonLat(lon: -86.8, lat: 33.5003), LonLat(lon: -86.7995, lat: 33.5003)]
        XCTAssertEqual(CameraExposure.hits(route: north, candidates: [(0, cam([0]))]).count, 1)
        XCTAssertEqual(CameraExposure.hits(route: north, candidates: [(0, cam([180]))]).count, 0)
        XCTAssertEqual(CameraExposure.hits(route: road, candidates: [(0, cam([45, 225]))]).count, 1)
    }

    func testOrderAlongRoute() {
        let long = [LonLat(lon: -86.79957, lat: 33.49), LonLat(lon: -86.79957, lat: 33.52)]
        let h = CameraExposure.hits(route: long, candidates: [(7, cam([], lat: 33.51)), (3, cam([], lat: 33.50))])
        XCTAssertEqual(h.map(\.camera), [3, 7])
        XCTAssertLessThan(h[0].along, h[1].along)
        XCTAssertEqual(ExposureLevel(count: 0), .low); XCTAssertEqual(ExposureLevel(count: 2), .medium)
        XCTAssertEqual(ExposureLevel(count: 5), .high); XCTAssertEqual(ExposureLevel(count: 6), .extreme)
    }
}

final class RouteExportTests: XCTestCase {
    private func path() throws -> RoutePath {
        let (w, _) = Town.ways()
        let (g, _) = try RoadGraphBuilder.build(pbf: PBFTestEncoder.encode(nodes: Town.nodes, ways: w))
        let e = RouteEngine(graph: g)
        return try XCTUnwrap(e.route(from: XCTUnwrap(e.snap(Town.ll(0, 0))), to: XCTUnwrap(e.snap(Town.ll(3, 3)))))
    }

    func testCueSheetRowsAndText() throws {
        let p = try path()
        let hit = CameraExposure.Hit(camera: 4, along: p.distance - 10, distance: 30)
        let sheet = CueSheet(path: p, hits: [hit])
        XCTAssertEqual(sheet.rows.count, p.steps.count)
        XCTAssertEqual(sheet.rows.first?.total, 0)
        XCTAssertEqual(sheet.rows.map(\.number), Array(1...p.steps.count))
        // The camera belongs to the step whose stretch contains it.
        XCTAssertEqual(sheet.rows.filter { !$0.cameras.isEmpty }.count, 1)
        XCTAssertEqual(sheet.rows.firstIndex { !$0.cameras.isEmpty }, sheet.rows.count - 2, "the last stretch before arriving")
        let t = sheet.text(title: "A to B", distance: { String(format: "%.0f m", $0) }, duration: { String(format: "%.0f s", $0) },
                           camera: { "camera \(Int($0.distance)) m away" })
        XCTAssertTrue(t.hasPrefix("A to B\n"))
        XCTAssertTrue(t.contains("01  Head"))
        XCTAssertTrue(t.contains("⌗ camera 30 m away"))
    }

    func testGPXDocument() throws {
        let p = try path()
        let doc = GPXWriter.document(name: "Home <to> \"Work\" & back", steps: p.steps, track: p.points,
                                     waypoints: [.init(at: Town.ll(0, 0), name: "A"), .init(at: Town.ll(1, 1), name: "ALPR camera", detail: "facing 90°")],
                                     created: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(doc.contains("<name>Home &lt;to&gt; &quot;Work&quot; &amp; back</name>"))
        XCTAssertTrue(doc.contains("<time>1970-01-01T00:00:00Z</time>"))
        XCTAssertEqual(doc.components(separatedBy: "<trkpt ").count - 1, p.points.count)
        XCTAssertEqual(doc.components(separatedBy: "<rtept ").count - 1, p.steps.count)
        XCTAssertEqual(doc.components(separatedBy: "<wpt ").count - 1, 2)
        XCTAssertTrue(doc.contains("lat=\"33.500000\" lon=\"-86.800000\""))
        // Well-formed XML.
        XCTAssertNoThrow(try XMLDocument(xmlString: doc, options: []))
    }

    func testEscapeDropsForbiddenCharacters() {
        XCTAssertEqual(GPXWriter.escape("a\u{0}b\u{1}c\td'"), "abc\td&apos;")
        XCTAssertEqual(GPXWriter.escape("Zürich 🚗"), "Zürich 🚗")
    }

    func testDecimalPointWhateverTheLocale() {
        XCTAssertEqual(GPXWriter.fixed(-86.8), "-86.800000")
        XCTAssertEqual(GPXWriter.fixed(.nan), "0")
    }
}
