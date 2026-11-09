import XCTest
@testable import GridCore

final class MapsTileSourceTests: XCTestCase {
    private let planet = URL(string: "https://tiles.openfreemap.org/planet")!

    /// The shape OpenFreeMap serves (a literal; no network in tests).
    private let openFreeMap = """
    {"tilejson":"3.0.0","tiles":["https://tiles.openfreemap.org/planet/20261101_080013_pt/{z}/{x}/{y}.pbf"],"minzoom":0,"maxzoom":14,"attribution":"<a href=\\"https://openfreemap.org\\">OpenFreeMap</a> <a href=\\"https://www.openmaptiles.org/\\">© OpenMapTiles</a> Data from <a href=\\"https://www.openstreetmap.org/copyright\\">OpenStreetMap</a>","bounds":[-180,-85.0511,180,85.0511],"center":[0,0,0],"name":"OpenFreeMap","description":"Free and open vector tiles","format":"pbf","vector_layers":[{"id":"water","fields":{"class":"String"}}]}
    """

    private func parse(_ json: String, from url: URL? = nil, maxBytes: Int = 1 << 20) throws -> TileSource {
        try TileSource.parse(Data(json.utf8), from: url ?? planet, maxBytes: maxBytes)
    }
    private func doc(tiles: String, extra: String = "") -> String { "{\"tilejson\":\"3.0.0\",\"tiles\":[\(tiles)]\(extra)}" }

    func testAcceptsOpenFreeMapShape() throws {
        let s = try parse(openFreeMap)
        XCTAssertEqual(s.host, "tiles.openfreemap.org")
        XCTAssertEqual(s.version, "20261101_080013_pt")
        XCTAssertEqual(s.minZoom, 0)
        XCTAssertEqual(s.maxZoom, 14)
        XCTAssertEqual(s.template, "https://tiles.openfreemap.org/planet/20261101_080013_pt/{z}/{x}/{y}.pbf")
        XCTAssertEqual(s.tileJSONURL, planet)
        XCTAssertEqual(s.attribution, "OpenFreeMap © OpenMapTiles Data from OpenStreetMap")
        XCTAssertEqual(s.url(for: TileID(z: 5, x: 17, y: 11))?.absoluteString,
                       "https://tiles.openfreemap.org/planet/20261101_080013_pt/5/17/11.pbf")
        XCTAssertEqual(s, try parse(openFreeMap))
    }

    func testURLForRespectsZoomRangeAndValidity() throws {
        let s = try parse(openFreeMap)
        XCTAssertNotNil(s.url(for: TileID(z: 0, x: 0, y: 0)))
        XCTAssertNotNil(s.url(for: TileID(z: 14, x: 16383, y: 16383)))
        XCTAssertNil(s.url(for: TileID(z: 15, x: 0, y: 0)), "above maxzoom: the caller overzooms")
        XCTAssertNil(s.url(for: TileID(z: 3, x: 8, y: 0)), "x out of range")
        XCTAssertNil(s.url(for: TileID(z: 3, x: 0, y: 8)))
    }

    func testRejectsInsecureAndMalformedTemplates() {
        let ok = "https://tiles.openfreemap.org/p/{z}/{x}/{y}.pbf"
        func bad(_ tile: String, _ why: String, line: UInt = #line) {
            XCTAssertThrowsError(try parse(doc(tiles: "\"\(tile)\"")), why, line: line)
        }
        XCTAssertNoThrow(try parse(doc(tiles: "\"\(ok)\"")))
        bad("http://tiles.openfreemap.org/p/{z}/{x}/{y}.pbf", "http")
        bad("//tiles.openfreemap.org/p/{z}/{x}/{y}.pbf", "scheme-relative")
        bad("https://user:pw@tiles.openfreemap.org/p/{z}/{x}/{y}.pbf", "userinfo")
        bad("https://user@tiles.openfreemap.org/p/{z}/{x}/{y}.pbf", "userinfo, no password")
        bad("https://tiles.openfreemap.org:8443/p/{z}/{x}/{y}.pbf", "port")
        bad("https://evil.example.com/p/{z}/{x}/{y}.pbf", "foreign host")
        bad("https://tiles.openfreemap.org.evil.com/p/{z}/{x}/{y}.pbf", "suffix host")
        bad("https://evil.com\\\\@tiles.openfreemap.org/p/{z}/{x}/{y}.pbf", "backslash trick")
        bad("https://tiles.openfreemap.org/p/{x}/{y}.pbf", "missing {z}")
        bad("https://tiles.openfreemap.org/p/{z}/{y}.pbf", "missing {x}")
        bad("https://tiles.openfreemap.org/p/{z}/{x}.pbf", "missing {y}")
        bad("https://{s}.openfreemap.org/p/{z}/{x}/{y}.pbf", "{s} subdomain")
        bad("https://tiles.openfreemap.org/{s}/{z}/{x}/{y}.pbf", "{s} path")
        bad("https://tiles.openfreemap.org/p/{z}/{x}/{y}{r}.pbf", "unknown placeholder")
        bad("https://tiles.openfreemap.org/p/{z}/{x}/{y.pbf", "unbalanced")
        bad("https://tiles.openfreemap.org/p/ {z}/{x}/{y}.pbf", "space")
        bad("https://tiles.openfreemap.org/p/{z}/{x}/{y}.pbf#frag", "fragment")
        bad("file:///etc/passwd", "file")
        bad("", "empty")
        bad("https://" + String(repeating: "a", count: 3000) + "/{z}/{x}/{y}", "too long")
    }

    func testRejectsBadDocumentsAndOrigins() {
        XCTAssertThrowsError(try parse("not json"))
        XCTAssertThrowsError(try parse("[1,2]"))
        XCTAssertThrowsError(try parse("{\"tilejson\":\"3.0.0\"}"))
        XCTAssertThrowsError(try parse("{\"tilejson\":\"3.0.0\",\"tiles\":[]}"))
        XCTAssertThrowsError(try parse("{\"tilejson\":\"3.0.0\",\"tiles\":[5]}"))
        XCTAssertThrowsError(try parse("{\"tilejson\":\"1.0.0\",\"tiles\":[\"https://tiles.openfreemap.org/{z}/{x}/{y}\"]}"))
        XCTAssertThrowsError(try parse(doc(tiles: "\"https://tiles.openfreemap.org/{z}/{x}/{y}\"", extra: ",\"scheme\":\"tms\"")))
        // The TileJSON must itself come from https without userinfo or port.
        XCTAssertThrowsError(try parse(openFreeMap, from: URL(string: "http://tiles.openfreemap.org/planet")!))
        XCTAssertThrowsError(try parse(openFreeMap, from: URL(string: "https://u:p@tiles.openfreemap.org/planet")!))
        XCTAssertThrowsError(try parse(openFreeMap, from: URL(string: "https://tiles.openfreemap.org:444/planet")!))
        // A template on a different host than the TileJSON is rejected even if it is https.
        XCTAssertThrowsError(try parse(openFreeMap, from: URL(string: "https://other.example.com/planet")!)) { XCTAssertEqual($0 as? TileSourceError, .foreignHost) }
    }

    func testRejectsOversizeInput() {
        XCTAssertThrowsError(try parse(openFreeMap, maxBytes: 100)) { XCTAssertEqual($0 as? TileSourceError, .tooLarge) }
        let big = doc(tiles: "\"https://tiles.openfreemap.org/{z}/{x}/{y}\"", extra: ",\"description\":\"\(String(repeating: "x", count: 2 << 20))\"")
        XCTAssertThrowsError(try parse(big)) { XCTAssertEqual($0 as? TileSourceError, .tooLarge) }
    }

    func testZoomClampAndDefaults() throws {
        let t = "\"https://tiles.openfreemap.org/{z}/{x}/{y}.pbf\""
        let a = try parse(doc(tiles: t, extra: ",\"minzoom\":-5,\"maxzoom\":99"))
        XCTAssertEqual(a.minZoom, 0); XCTAssertEqual(a.maxZoom, 22)
        let b = try parse(doc(tiles: t))
        XCTAssertEqual(b.minZoom, 0); XCTAssertEqual(b.maxZoom, 22)
        let c = try parse(doc(tiles: t, extra: ",\"minzoom\":\"x\",\"maxzoom\":true"))
        XCTAssertEqual(c.maxZoom, 22)
        let d = try parse(doc(tiles: t, extra: ",\"minzoom\":10,\"maxzoom\":4"))
        XCTAssertEqual(d.minZoom, 4); XCTAssertEqual(d.maxZoom, 10)
        XCTAssertNil(b.version, "no path segment before {z}")
        XCTAssertEqual(b.attribution, "")
    }

    func testVersionExtraction() throws {
        XCTAssertEqual(try parse(doc(tiles: "\"https://tiles.openfreemap.org/planet/v2/{z}/{x}/{y}.pbf\"")).version, "v2")
        XCTAssertNil(try parse(doc(tiles: "\"https://tiles.openfreemap.org/{z}/{x}/{y}.pbf\"")).version)
        XCTAssertNil(try parse(doc(tiles: "\"https://tiles.openfreemap.org/a%20b/{z}/{x}/{y}.pbf\"")).version, "odd characters are not a version")
    }

    func testAttributionSanitising() throws {
        let t = "\"https://tiles.openfreemap.org/{z}/{x}/{y}.pbf\""
        let s = try parse(doc(tiles: t, extra: ",\"attribution\":\"<script>alert(1)</script>&copy; A &amp; B\\n\\t<b>bold</b>\""))
        XCTAssertFalse(s.attribution.contains("<"))
        XCTAssertTrue(s.attribution.contains("© A & B bold"))
        let long = try parse(doc(tiles: t, extra: ",\"attribution\":\"\(String(repeating: "word ", count: 500))\""))
        XCTAssertLessThanOrEqual(long.attribution.count, 400)
    }
}
