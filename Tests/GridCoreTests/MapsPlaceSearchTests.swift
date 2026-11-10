import XCTest
import simd
@testable import GridCore

final class MapsPOICatalogTests: XCTestCase {
    func testTileClassesMapToCategories() {
        XCTAssertEqual(POICatalog.category(class: "cafe", subclass: "cafe"), .food)
        XCTAssertEqual(POICatalog.category(class: "shop", subclass: "bakery"), .food)        // subclass wins
        XCTAssertEqual(POICatalog.category(class: "shop", subclass: "toys"), .shops)
        XCTAssertEqual(POICatalog.category(class: "railway", subclass: "station"), .transit)
        XCTAssertEqual(POICatalog.category(class: "fuel", subclass: nil), .fuel)
        XCTAssertEqual(POICatalog.category(class: "lodging", subclass: "hotel"), .lodging)
        XCTAssertEqual(POICatalog.category(class: "hospital", subclass: "clinic"), .health)
        XCTAssertEqual(POICatalog.category(class: "attraction", subclass: "viewpoint"), .culture)
        XCTAssertEqual(POICatalog.category(class: "something_new", subclass: "odd"), .other)
    }

    func testNoisyPointsAreSkipped() {
        XCTAssertNil(POICatalog.category(class: "entrance", subclass: "main"))
        XCTAssertNil(POICatalog.category(class: "amenity", subclass: "toilets"))
        XCTAssertNil(POICatalog.category(class: "", subclass: nil))
    }

    func testOSMTagsMapToCategories() {
        XCTAssertEqual(POICatalog.category(osmKey: "amenity", value: "restaurant"), .food)
        XCTAssertEqual(POICatalog.category(osmKey: "shop", value: "kitchen"), .shops)
        XCTAssertEqual(POICatalog.category(osmKey: "tourism", value: "hotel"), .lodging)
        XCTAssertEqual(POICatalog.category(osmKey: "tourism", value: "museum"), .culture)
        XCTAssertEqual(POICatalog.category(osmKey: "railway", value: "platform"), .transit)
        XCTAssertNil(POICatalog.category(osmKey: "place", value: "city"))
        XCTAssertNil(POICatalog.category(osmKey: "highway", value: "residential"))
        XCTAssertNil(POICatalog.category(osmKey: "amenity", value: "bench"))
    }

    func testRankSetsMinZoom() {
        XCTAssertLessThan(POICatalog.minZoom(rank: 1), POICatalog.minZoom(rank: 8))
        XCTAssertLessThan(POICatalog.minZoom(rank: 8), POICatalog.minZoom(rank: 40))
    }

    func testPOILayerBecomesAnchors() throws {
        typealias P = SIMD2<Int32>
        let layer = MVTTestEncoder.Layer(name: "poi", features: [
            MVTTestEncoder.point([P(1024, 2048)], tags: ["name": .string("Blue Door"), "class": .string("cafe"), "subclass": .string("cafe"), "rank": .int(2)]),
            MVTTestEncoder.point([P(100, 100)], tags: ["name": .string("Gate"), "class": .string("entrance")]),
            MVTTestEncoder.point([P(200, 200)], tags: ["class": .string("cafe")]),                       // no name
            MVTTestEncoder.point([P(9000, 200)], tags: ["name": .string("Outside"), "class": .string("cafe")]),  // buffer
            MVTTestEncoder.point([P(300, 300)], tags: ["name": .string("Late Bus"), "class": .string("bus"), "subclass": .string("bus_stop")]),
        ])
        let tile = try MVTDecoder.decode(MVTTestEncoder.encode([layer]), layers: OpenMapTilesSchema.layers)
        let g = TileGeometryBuilder.build(tile, id: TileID(z: 14, x: 1, y: 1))
        XCTAssertEqual(g.pois.map(\.name), ["Blue Door", "Late Bus"])
        XCTAssertEqual(g.pois[0].category, .food)
        XCTAssertEqual(g.pois[0].rank, 2)
        XCTAssertEqual(g.pois[0].pos.x, 0.25, accuracy: 1e-6)
        XCTAssertEqual(g.pois[0].pos.y, 0.5, accuracy: 1e-6)
        XCTAssertEqual(g.pois[1].detail, "bus stop")
        XCTAssertEqual(g.pois[1].category, .transit)
        XCTAssertTrue(g.labels.isEmpty, "POIs are not ordinary labels")
    }
}

final class MapsLocalSearchTests: XCTestCase {
    private let here = TileMath.project(LonLat(lon: 7.75, lat: 46.02))   // Zermatt

    private func entry(_ name: String, _ kind: PlaceResult.Kind, lon: Double, lat: Double, importance: Int = 50,
                       category: POICategory? = nil, detail: String = "") -> SearchEntry {
        SearchEntry(name: name, kind: kind, category: category, detail: detail, world: TileMath.project(LonLat(lon: lon, lat: lat)), importance: importance)
    }

    func testFoldIgnoresCaseAccentsAndSpacing() {
        XCTAssertEqual(LocalSearch.fold("Zürich  HB"), "zurich hb")
        XCTAssertEqual(LocalSearch.fold("  Täsch "), "tasch")
    }

    func testCleanDropsControlCharactersAndCaps() {
        XCTAssertEqual(LocalSearch.clean(" caf\u{0007}e\n"), "cafe")
        XCTAssertEqual(LocalSearch.clean(String(repeating: "a", count: 500)).count, 200)
    }

    func testAccentInsensitiveMatch() {
        let r = LocalSearch.search("tasch", in: [entry("Täsch", .place, lon: 7.78, lat: 46.07, importance: 57, detail: "village")], near: here)
        XCTAssertEqual(r.map(\.name), ["Täsch"])
        XCTAssertEqual(r[0].source, .local)
        XCTAssertNotNil(r[0].distance)
    }

    func testScatteredSubsequenceIsNotAMatch() {
        XCTAssertTrue(LocalSearch.search("zmt", in: [entry("Zermatt", .place, lon: 7.75, lat: 46.02)], near: here).isEmpty)
    }

    func testPrefixBeatsSubstringAndImportantPlacesRankHigher() {
        let entries = [
            entry("Old Bern Road", .road, lon: 7.75, lat: 46.02),
            entry("Bern", .place, lon: 7.44, lat: 46.95, importance: 30, detail: "city"),
            entry("Bernina Café", .poi, lon: 7.751, lat: 46.021, importance: 5, category: .food, detail: "cafe"),
        ]
        let r = LocalSearch.search("bern", in: entries, near: here)
        XCTAssertEqual(r.first?.name, "Bern")
        XCTAssertEqual(r.last?.name, "Old Bern Road")
    }

    func testStreetBeatsStopsNamedAfterIt() {
        let entries = [
            entry("Thayer before Meeting", .poi, lon: 7.751, lat: 46.021, importance: 1, category: .transit, detail: "bus stop"),
            entry("Thayer Street", .road, lon: 7.752, lat: 46.022),
        ]
        XCTAssertEqual(LocalSearch.search("thayer", in: entries, near: here).first?.name, "Thayer Street")
    }

    func testNearerWinsBetweenEqualMatches() {
        let entries = [
            entry("Bahnhofstrasse", .road, lon: 8.54, lat: 47.37),      // Zürich, far
            entry("Bahnhofstrasse", .road, lon: 7.748, lat: 46.021),    // here
        ]
        let r = LocalSearch.search("bahnhofstrasse", in: entries, near: here)
        XCTAssertEqual(r.count, 2, "far apart: two different streets")
        XCTAssertEqual(r[0].coordinate.lat, 46.021, accuracy: 1e-6)
    }

    func testDuplicatesCollapse() {
        // The same town in tiles of several zooms, and a road cut across tiles.
        let entries = [
            entry("Zermatt", .place, lon: 7.7491, lat: 46.0207, importance: 50, detail: "town"),
            entry("Zermatt", .place, lon: 7.7500, lat: 46.0210, importance: 50, detail: "town"),
            entry("Zermatt", .place, lon: 7.7600, lat: 46.0300, importance: 50, detail: "town"),
            entry("Hofmattstrasse", .road, lon: 7.748, lat: 46.021),
            entry("Hofmattstrasse", .road, lon: 7.752, lat: 46.022),
        ]
        XCTAssertEqual(LocalSearch.search("zermatt", in: entries, near: here).count, 1)
        XCTAssertEqual(LocalSearch.search("hofmatt", in: entries, near: here).count, 1)
    }

    func testEmptyQueryAndLimit() {
        let many = (0..<50).map { entry("Cafe \($0)", .poi, lon: 7.75 + Double($0) * 0.01, lat: 46.02, category: .food) }
        XCTAssertTrue(LocalSearch.search("  ", in: many, near: here).isEmpty)
        XCTAssertEqual(LocalSearch.search("cafe", in: many, near: here, limit: 7).count, 7)
    }

    func testEntriesFromTileSkipContourLabels() {
        let id = TileID(z: 14, x: 8529, y: 5803)
        let g = TileGeometry(id: id, fills: [], lines: [], extrusion: nil, labels: [
            LabelAnchor(text: "Zermatt", kind: .place, priority: 310, pos: SIMD2(0.5, 0.5), minZoom: 8),
            LabelAnchor(text: "Bahnhofstrasse", kind: .road, priority: 905, pos: SIMD2(0.2, 0.2), minZoom: 15),
            LabelAnchor(text: "5,000 ft", kind: .road, priority: 80, pos: SIMD2(0.3, 0.3), minZoom: 12),
        ], pois: [POIAnchor(name: "Gornergrat Bahn", category: .transit, detail: "station", rank: 3, pos: SIMD2(0.4, 0.4), minZoom: 14.5)],
                             byteCount: 0)
        let e = LocalSearch.entries(for: g)
        XCTAssertEqual(e.map(\.name), ["Zermatt", "Bahnhofstrasse", "Gornergrat Bahn"])
        XCTAssertEqual(e[0].detail, "town")
        XCTAssertEqual(e[2].category, .transit)
    }

    func testSuggestedZoomByKindAndBox() {
        let town = PlaceResult(id: "a", name: "T", kind: .place, category: nil, detail: "town", coordinate: LonLat(lon: 0, lat: 0), source: .local)
        let cafe = PlaceResult(id: "b", name: "C", kind: .poi, category: .food, detail: "cafe", coordinate: LonLat(lon: 0, lat: 0), source: .local)
        XCTAssertLessThan(town.suggestedZoom, cafe.suggestedZoom)
        var boxed = town
        boxed.bbox = BBox(west: 7, south: 45, east: 11, north: 48)
        XCTAssertLessThan(boxed.suggestedZoom, 8)
    }

    func testOSMURLOnlyFromTypeAndNumber() {
        var r = PlaceResult(id: "x", name: "X", kind: .poi, category: nil, detail: "", coordinate: LonLat(lon: 0, lat: 0), osmRef: "way/42", source: .online)
        XCTAssertEqual(r.osmURL?.absoluteString, "https://www.openstreetmap.org/way/42")
        r.osmRef = "way/42?x=1"
        XCTAssertNil(r.osmURL)
        r.osmRef = "changeset/1"
        XCTAssertNil(r.osmURL)
    }
}

final class MapsNominatimTests: XCTestCase {
    func testEndpointValidation() {
        XCTAssertEqual(Nominatim.endpoint("https://nominatim.openstreetmap.org/")?.absoluteString, "https://nominatim.openstreetmap.org")
        XCTAssertEqual(Nominatim.endpoint("https://geo.example.org/nominatim/search")?.absoluteString, "https://geo.example.org/nominatim")
        XCTAssertNil(Nominatim.endpoint("http://nominatim.openstreetmap.org"))
        XCTAssertNil(Nominatim.endpoint("https://user@geo.example.org"))
        XCTAssertNil(Nominatim.endpoint("https://geo.example.org:8080"))
        XCTAssertNil(Nominatim.endpoint("https://geo.example.org/?q=1"))
        XCTAssertNil(Nominatim.endpoint("not a url"))
    }

    func testSearchURL() throws {
        let ep = try XCTUnwrap(Nominatim.endpoint(Nominatim.defaultEndpoint))
        let u = try XCTUnwrap(Nominatim.searchURL(endpoint: ep, query: "  Café & Bar  ", viewbox: BBox(west: 7.7, south: 46.0, east: 7.8, north: 46.1), language: "en-GB"))
        let c = try XCTUnwrap(URLComponents(url: u, resolvingAgainstBaseURL: false))
        XCTAssertEqual(c.host, "nominatim.openstreetmap.org")
        XCTAssertEqual(c.path, "/search")
        let q = Dictionary(uniqueKeysWithValues: (c.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(q["q"], "Café & Bar")
        XCTAssertEqual(q["format"], "jsonv2")
        XCTAssertEqual(q["viewbox"], "7.7000,46.1000,7.8000,46.0000")
        XCTAssertEqual(q["accept-language"], "en-GB")
        XCTAssertNil(q["bounded"], "the view is a bias, not a limit")
        XCTAssertNil(Nominatim.searchURL(endpoint: ep, query: " \n ", viewbox: nil, language: nil))
    }

    func testParse() throws {
        let json = """
        [{"place_id":1,"osm_type":"node","osm_id":123,"lat":"46.0207","lon":"7.7491","category":"place","type":"town",
          "name":"Zermatt","display_name":"Zermatt, Visp, Valais, Switzerland","boundingbox":["45.9","46.1","7.6","7.9"]},
         {"osm_type":"way","osm_id":77,"lat":"46.02","lon":"7.75","category":"amenity","type":"cafe","name":"",
          "display_name":"Blue Door, Bahnhofstrasse, Zermatt"},
         {"osm_type":"relation","osm_id":5,"lat":"95","lon":"7","category":"place","type":"city","name":"Bad"},
         {"osm_type":"relation","osm_id":6,"lat":"46.1","lon":"7.8","category":"boundary","type":"administrative","addresstype":"village","name":"Täsch"},
         {"lat":"x","lon":"7","name":"Bad"},
         "junk",
         {"osm_type":"way","osm_id":8,"lat":"46.0","lon":"7.7","category":"highway","type":"residential","name":"Hofmatt\\u202Estrasse"}]
        """
        let r = try Nominatim.parse(Data(json.utf8), near: TileMath.project(LonLat(lon: 7.75, lat: 46.02)))
        XCTAssertEqual(r.map(\.name), ["Zermatt", "Blue Door", "Täsch", "Hofmattstrasse"])
        XCTAssertEqual(r[2].detail, "village")
        XCTAssertEqual(r[2].kind, .place)
        XCTAssertEqual(r[2].osmRef, "relation/6")
        XCTAssertEqual(r[0].kind, .place)
        XCTAssertEqual(r[0].detail, "town")
        XCTAssertEqual(r[0].osmRef, "node/123")
        XCTAssertEqual(r[0].bbox, BBox(west: 7.6, south: 45.9, east: 7.9, north: 46.1))
        XCTAssertEqual(r[0].source, .online)
        XCTAssertEqual(r[1].kind, .poi)
        XCTAssertEqual(r[1].category, .food)
        XCTAssertEqual(r[1].address, "Blue Door, Bahnhofstrasse, Zermatt")
        XCTAssertEqual(r[3].kind, .road)
        XCTAssertNotNil(r[0].distance)
    }

    func testParseRejectsJunk() {
        XCTAssertThrowsError(try Nominatim.parse(Data("{\"error\":1}".utf8)))
        XCTAssertThrowsError(try Nominatim.parse(Data("<html>".utf8)))
        XCTAssertThrowsError(try Nominatim.parse(Data(count: Nominatim.maxResponseBytes + 1)))
        XCTAssertEqual(try Nominatim.parse(Data("[]".utf8)), [])
    }

    func testParseCapsResults() throws {
        let one = #"{"osm_type":"node","osm_id":1,"lat":"1","lon":"1","category":"amenity","type":"cafe","name":"C"}"#
        let json = "[" + Array(repeating: one, count: 40).joined(separator: ",") + "]"
        XCTAssertEqual(try Nominatim.parse(Data(json.utf8)).count, Nominatim.maxResults)
    }

    func testRequestSpacer() {
        var s = RequestSpacer(interval: 1)
        let t0 = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(s.reserve(now: t0), 0)
        XCTAssertEqual(s.reserve(now: t0.addingTimeInterval(0.25)), 0.75, accuracy: 1e-9)
        XCTAssertEqual(s.reserve(now: t0.addingTimeInterval(0.5)), 1.5, accuracy: 1e-9)   // queued behind the second
        XCTAssertEqual(s.reserve(now: t0.addingTimeInterval(10)), 0)
    }

    func testExpiringCache() {
        var c = ExpiringCache<String, Int>(ttl: 100, capacity: 2)
        let t0 = Date(timeIntervalSince1970: 0)
        c.set("a", 1, now: t0)
        c.set("b", 2, now: t0.addingTimeInterval(1))
        XCTAssertEqual(c.value("a", now: t0.addingTimeInterval(50)), 1)
        XCTAssertNil(c.value("a", now: t0.addingTimeInterval(101)))
        c.set("c", 3, now: t0.addingTimeInterval(2))
        XCTAssertEqual(c.count, 2)
        XCTAssertNil(c.value("a", now: t0.addingTimeInterval(3)), "oldest dropped at capacity")
    }
}
