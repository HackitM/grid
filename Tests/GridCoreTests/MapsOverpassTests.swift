import XCTest
@testable import GridCore

final class MapsOverpassTests: XCTestCase {
    func testQueryShape() {
        let q = OverpassQuery.alpr(BBox(west: -71.5, south: 41.1, east: -71.1, north: 42.0), timeout: 90)
        XCTAssertTrue(q.hasPrefix("[out:json][timeout:90];"))
        XCTAssertTrue(q.contains("(41.100000,-71.500000,42.000000,-71.100000)"))
        XCTAssertTrue(q.contains("node[\"man_made\"=\"surveillance\"]"))
        XCTAssertTrue(q.contains("way[\"man_made\"=\"surveillance\"]"))
        XCTAssertTrue(q.contains("alpr"))
        XCTAssertTrue(q.contains("out meta center"))
        XCTAssertTrue(OverpassQuery.alpr(BBox(west: 0, south: 0, east: 1, north: 1), timeout: 100_000).contains("[timeout:300]"))
        XCTAssertTrue(OverpassQuery.alpr(BBox(west: .nan, south: 0, east: 1, north: 1)).contains("0.000000"))
    }

    func testChunks() {
        let b = BBox(west: -71.5, south: 41.1, east: -71.1, north: 42.0)
        let chunks = OverpassQuery.chunks(.rectangle(b), z: 7, limit: 60)
        XCTAssertFalse(chunks.isEmpty)
        for c in chunks {
            XCTAssertTrue(c.isValid)
            XCTAssertGreaterThanOrEqual(c.west, b.west); XCTAssertLessThanOrEqual(c.east, b.east)
            XCTAssertGreaterThanOrEqual(c.south, b.south); XCTAssertLessThanOrEqual(c.north, b.north)
        }
        // Union covers the whole box (compare areas).
        let area = chunks.reduce(0.0) { $0 + ($1.east - $1.west) * ($1.north - $1.south) }
        XCTAssertEqual(area, (b.east - b.west) * (b.north - b.south), accuracy: 1e-6)
        let big = GeoPolygon.rectangle(BBox(west: -120, south: 25, east: -70, north: 50))
        XCTAssertEqual(OverpassQuery.chunks(big, z: 7, limit: 60).count, 60)
    }

    private let sample = """
    {"version":0.6,"generator":"Overpass API","osm3s":{"timestamp_osm_base":"2026-11-01T10:20:30Z"},
    "elements":[
    {"type":"node","id":101,"lat":41.8,"lon":-71.4,"timestamp":"2026-10-01T00:00:00Z","tags":{"man_made":"surveillance","surveillance:type":"ALPR","direction":"90","manufacturer":"Flock Safety","operator":"RIPD"}},
    {"type":"way","id":202,"center":{"lat":41.9,"lon":-71.3},"tags":{"man_made":"surveillance","surveillance:type":"alpr;camera","camera:direction":"north"}},
    {"type":"node","id":103,"lat":41.7,"lon":-71.2,"tags":{"man_made":"surveillance","surveillance:type":"camera"}},
    {"type":"node","id":104,"tags":{"man_made":"surveillance","surveillance:type":"alpr"}},
    {"type":"way","id":205,"tags":{"man_made":"surveillance","surveillance:type":"alpr"}},
    {"type":"node","id":106,"lat":123,"lon":-71.2,"tags":{"man_made":"surveillance","surveillance:type":"alpr"}},
    {"type":"relation","id":207,"center":{"lat":1,"lon":1},"tags":{"man_made":"surveillance","surveillance:type":"alpr"}},
    {"type":"node","id":108,"lat":41.6,"lon":-71.1,"tags":{"man_made":"surveillance","surveillance:type":"alpr","brand":5}},
    {"id":"x"}, 7, null
    ]}
    """

    func testParseNodesWaysAndSkips() throws {
        let r = try OverpassQuery.parse(Data(sample.utf8))
        XCTAssertEqual(r.cameras.map(\.id), [.node(101), .way(202), .node(108)])
        XCTAssertEqual(r.cameras[0].directions, [90])
        XCTAssertEqual(r.cameras[0].vendor, .flock)
        XCTAssertEqual(r.cameras[0].operatorName, "RIPD")
        XCTAssertEqual(r.cameras[0].lastEdited, Date(timeIntervalSince1970: 1_790_812_800))
        XCTAssertEqual(r.cameras[1].coordinate, LonLat(lon: -71.3, lat: 41.9))
        XCTAssertEqual(r.cameras[1].directions, [0])
        XCTAssertEqual(r.cameras[2].vendor, .unknown)
        XCTAssertEqual(r.osmBase, OSMSurveillance.parseISO8601("2026-11-01T10:20:30Z"))
        XCTAssertNil(r.remark)
    }

    func testRuntimeErrorRemarkThrows() {
        let j = "{\"osm3s\":{},\"remark\":\"runtime error: Query timed out in \\\"query\\\" at line 3 after 91 seconds.\",\"elements\":[]}"
        XCTAssertThrowsError(try OverpassQuery.parse(Data(j.utf8))) {
            guard case .serverRemark(let m)? = $0 as? ALPRParseError else { return XCTFail("\($0)") }
            XCTAssertTrue(m.contains("timed out"))
        }
    }

    func testOtherRemarkIsReturned() throws {
        let j = "{\"remark\":\"something informational\",\"elements\":[]}"
        let r = try OverpassQuery.parse(Data(j.utf8))
        XCTAssertEqual(r.remark, "something informational")
        XCTAssertTrue(r.cameras.isEmpty)
    }

    func testCapsAndGarbage() {
        XCTAssertThrowsError(try OverpassQuery.parse(Data(sample.utf8), maxElements: 3)) { XCTAssertEqual($0 as? ALPRParseError, .tooLarge) }
        XCTAssertThrowsError(try OverpassQuery.parse(Data("nope".utf8)))
        XCTAssertThrowsError(try OverpassQuery.parse(Data("{}".utf8)))
        XCTAssertThrowsError(try OverpassQuery.parse(Data("[1,2]".utf8)))
    }

    func testBadTimestampsAreNil() throws {
        let j = "{\"osm3s\":{\"timestamp_osm_base\":\"yesterday\"},\"elements\":[{\"type\":\"node\",\"id\":1,\"lat\":1,\"lon\":1,\"timestamp\":\"x\",\"tags\":{\"man_made\":\"surveillance\",\"surveillance:type\":\"alpr\"}}]}"
        let r = try OverpassQuery.parse(Data(j.utf8))
        XCTAssertNil(r.osmBase)
        XCTAssertNil(r.cameras.first?.lastEdited)
        XCTAssertEqual(r.cameras.count, 1)
    }
}
