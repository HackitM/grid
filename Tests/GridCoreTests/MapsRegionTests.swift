import XCTest
@testable import GridCore

final class MapsRegionTests: XCTestCase {
    private func ll(_ lon: Double, _ lat: Double) -> LonLat { LonLat(lon: lon, lat: lat) }
    private func square(_ w: Double, _ s: Double, _ e: Double, _ n: Double) -> [LonLat] { [ll(w, s), ll(e, s), ll(e, n), ll(w, n)] }

    // MARK: polygon math

    func testSquareContainsAndBBox() {
        let g = GeoPolygon(polygons: [[square(-10, -10, 10, 10)]])
        XCTAssertTrue(g.contains(ll(0, 0)))
        XCTAssertTrue(g.contains(ll(9.9, -9.9)))
        XCTAssertFalse(g.contains(ll(10.1, 0)))
        XCTAssertFalse(g.contains(ll(0, -10.1)))
        XCTAssertEqual(g.bbox, BBox(west: -10, south: -10, east: 10, north: 10))
        XCTAssertFalse(g.contains(ll(.nan, 0)))
    }

    func testClosedRingsAreTolerated() {
        var r = square(0, 0, 10, 10); r.append(r[0])
        let g = GeoPolygon(polygons: [[r]])
        XCTAssertTrue(g.contains(ll(5, 5)))
        XCTAssertFalse(g.contains(ll(15, 5)))
    }

    func testHoleIsExcluded() {
        let g = GeoPolygon(polygons: [[square(0, 0, 10, 10), square(4, 4, 6, 6)]])
        XCTAssertTrue(g.contains(ll(2, 2)))
        XCTAssertFalse(g.contains(ll(5, 5)))
        XCTAssertTrue(g.contains(ll(8, 5)))
    }

    func testMultiPolygon() {
        let g = GeoPolygon(polygons: [[square(0, 0, 1, 1)], [square(10, 10, 11, 11)]])
        XCTAssertTrue(g.contains(ll(0.5, 0.5)))
        XCTAssertTrue(g.contains(ll(10.5, 10.5)))
        XCTAssertFalse(g.contains(ll(5, 5)))
        XCTAssertEqual(g.bbox, BBox(west: 0, south: 0, east: 11, north: 11))
    }

    func testConcaveL() {
        // L shape: the notch (upper right) is empty.
        let l = [ll(0, 0), ll(10, 0), ll(10, 4), ll(4, 4), ll(4, 10), ll(0, 10)]
        let g = GeoPolygon(polygons: [[l]])
        XCTAssertTrue(g.contains(ll(2, 8)))
        XCTAssertTrue(g.contains(ll(8, 2)))
        XCTAssertFalse(g.contains(ll(8, 8)))
        XCTAssertFalse(g.contains(ll(5, 5)))
    }

    func testDegenerateRingsIgnored() {
        let g = GeoPolygon(polygons: [[[ll(0, 0), ll(1, 1)]], [], [[ll(5, 5), ll(5, 5), ll(5, 5)]]])
        XCTAssertFalse(g.contains(ll(0.5, 0.5)))
        XCTAssertEqual(g.bbox.west, 0)
        XCTAssertTrue(GeoPolygon(polygons: []).tileCover(z: 5, limit: 100).isEmpty)
    }

    // MARK: tileCover

    func testTileCoverOfSmallRectangleMatchesTileMath() {
        // Corners well inside their tiles (not on tile boundaries).
        let b = BBox(west: -71.52, south: 41.61, east: -71.18, north: 41.93)
        let z = 11
        let got = Set(GeoPolygon.rectangle(b).tileCover(z: z, limit: 1000))
        let a = TileMath.tile(containing: TileMath.project(ll(b.west, b.north)), z: z)
        let c = TileMath.tile(containing: TileMath.project(ll(b.east, b.south)), z: z)
        var want = Set<TileID>()
        for x in Int(a.x)...Int(c.x) { for y in Int(a.y)...Int(c.y) { want.insert(TileID(z: z, x: x, y: y)) } }
        XCTAssertEqual(got, want)
        XCTAssertGreaterThan(want.count, 4)
    }

    func testTileCoverLimitAndOrder() {
        let g = GeoPolygon.rectangle(BBox(west: -80, south: 30, east: -70, north: 40))
        let all = g.tileCover(z: 8, limit: 100_000)
        XCTAssertGreaterThan(all.count, 50)
        let capped = g.tileCover(z: 8, limit: 10)
        XCTAssertEqual(capped.count, 10)
        XCTAssertTrue(Set(capped).isSubset(of: Set(all)))
        XCTAssertEqual(all, all.sorted { ($0.y, $0.x) < ($1.y, $1.x) })
        XCTAssertTrue(g.tileCover(z: 7, limit: 0).isEmpty)
        XCTAssertTrue(g.tileCover(z: 40, limit: 10).isEmpty)
    }

    func testTileCoverPolygonInsideOneTile() {
        let t = TileID(z: 8, x: 77, y: 95)
        let gb = TileMath.geoBounds(t)
        let cx = (gb.west + gb.east) / 2, cy = (gb.south + gb.north) / 2
        let g = GeoPolygon(polygons: [[square(cx - 0.001, cy - 0.001, cx + 0.001, cy + 0.001)]])
        XCTAssertEqual(g.tileCover(z: 8, limit: 50), [t])
    }

    func testTileCoverConcaveSkipsTheNotch() {
        // L shape ~ 8x8 tiles at z8 (1 tile = 1.40625 deg of lon).
        let l = [ll(0, 40), ll(16, 40), ll(16, 44), ll(8, 44), ll(8, 52), ll(0, 52)]
        let g = GeoPolygon(polygons: [[l]])
        let cover = Set(g.tileCover(z: 8, limit: 100_000))
        func tile(_ lon: Double, _ lat: Double) -> TileID { TileMath.tile(containing: TileMath.project(ll(lon, lat)), z: 8) }
        XCTAssertTrue(cover.contains(tile(2, 50)))
        XCTAssertTrue(cover.contains(tile(14, 42)))
        XCTAssertFalse(cover.contains(tile(13, 49)))
        // Every cover tile must intersect the polygon: its centre or a corner is inside, or the polygon crosses it.
        for t in cover {
            let gb = TileMath.geoBounds(t)
            XCTAssertTrue(gb.intersects(g.bbox))
        }
        // Interior tiles (centre inside the polygon) are all covered.
        for x in 0..<256 { for y in 80...100 {
            let t = TileID(z: 8, x: x, y: y)
            let gb = TileMath.geoBounds(t)
            if g.contains(ll((gb.west + gb.east) / 2, (gb.south + gb.north) / 2)) { XCTAssertTrue(cover.contains(t), "\(t)") }
        } }
    }

    func testTileCoverHoleLeavesInteriorTilesOut() {
        let outer = square(0, 40, 20, 56), hole = square(5, 44, 15, 52)
        let g = GeoPolygon(polygons: [[outer, hole]])
        let cover = Set(g.tileCover(z: 8, limit: 100_000))
        let centre = TileMath.tile(containing: TileMath.project(ll(10, 48)), z: 8)
        XCTAssertFalse(cover.contains(centre))
        XCTAssertTrue(cover.contains(TileMath.tile(containing: TileMath.project(ll(2, 48)), z: 8)))
    }

    func testTileCoverDiagonalEdgeCrossingWithoutVertices() {
        // A thin diagonal sliver crossing many tiles with no vertex in most of them.
        let g = GeoPolygon(polygons: [[[ll(0, 0.01), ll(20, 20), ll(20, 20.05), ll(0, 0.06)]]])
        let cover = g.tileCover(z: 8, limit: 100_000)
        let rows = Set(cover.map(\.y))
        XCTAssertGreaterThan(rows.count, 12)
        // Contiguous rows: no gaps along the diagonal.
        XCTAssertEqual(Int(rows.max()! - rows.min()!) + 1, rows.count)
    }

    // MARK: catalogue

    private func feature(_ id: String, name: String, parent: String?, iso1: [String] = [], iso2: [String] = [], geometry: String) -> String {
        let p = parent.map { "\"\($0)\"" } ?? "null"
        let i1 = iso1.map { "\"\($0)\"" }.joined(separator: ","), i2 = iso2.map { "\"\($0)\"" }.joined(separator: ",")
        return """
        {"type":"Feature","properties":{"id":"\(id)","parent":\(p),"name":"\(name)","iso3166-1:alpha2":[\(i1)],"iso3166-2":[\(i2)],"urls":{"pbf":"https://download.geofabrik.de/x.osm.pbf"}},"geometry":\(geometry)}
        """
    }
    private let poly = """
    {"type":"Polygon","coordinates":[[[-109,37],[-102,37],[-102,41],[-109,41],[-109,37]]]}
    """
    private let multi = """
    {"type":"MultiPolygon","coordinates":[[[[-80,40],[-79,40],[-79,41],[-80,41],[-80,40]]],[[[-70,40],[-69,40],[-69,41],[-70,41],[-70,40]],[[-69.8,40.2],[-69.2,40.2],[-69.2,40.8],[-69.8,40.8],[-69.8,40.2]]]]}
    """

    func testCatalogParse() throws {
        let json = """
        {"type":"FeatureCollection","features":[
        \(feature("north-america", name: "North America", parent: nil, geometry: poly)),
        \(feature("us", name: "US", parent: "north-america", iso1: ["US"], geometry: poly)),
        \(feature("us/colorado", name: "Colorado", parent: "north-america", iso2: ["US-CO"], geometry: poly)),
        \(feature("us/california/norcal", name: "Northern California", parent: "us/california", geometry: multi)),
        \(feature("canada/ontario", name: "Ontario", parent: "canada", iso2: ["CA-ON"], geometry: poly)),
        \(feature("bad-geo", name: "Broken", parent: "north-america", geometry: "{\"type\":\"Point\",\"coordinates\":[1,2]}")),
        \(feature("../evil", name: "Evil", parent: nil, geometry: poly))
        ]}
        """
        let cat = try RegionCatalog.parse(Data(json.utf8))
        XCTAssertEqual(cat.regions.map(\.id), ["north-america", "us", "us/colorado", "us/california/norcal", "canada/ontario", "bad-geo"])
        XCTAssertEqual(cat.children(of: nil).map(\.id), ["north-america"])
        XCTAssertEqual(cat.children(of: "north-america").map(\.id), ["bad-geo", "us/colorado", "us"])
        let co = cat.regions.first { $0.id == "us/colorado" }
        XCTAssertEqual(co?.iso3166_2, ["US-CO"])
        XCTAssertEqual(co?.parent, "north-america")
        XCTAssertNotNil(cat.polygon("us/colorado"))
        XCTAssertNil(cat.polygon("bad-geo"))
        let nc = try XCTUnwrap(cat.polygon("us/california/norcal"))
        XCTAssertEqual(nc.polygons.count, 2)
        XCTAssertEqual(nc.polygons[1].count, 2)             // exterior + hole, closing points dropped
        XCTAssertEqual(nc.polygons[0][0].count, 4)
        XCTAssertTrue(nc.contains(ll(-79.5, 40.5)))
        XCTAssertFalse(nc.contains(ll(-69.5, 40.5)))        // inside the hole
        XCTAssertTrue(nc.contains(ll(-69.9, 40.1)))
    }

    func testCatalogRejectsOversizeAndGarbage() {
        XCTAssertThrowsError(try RegionCatalog.parse(Data(count: 2000), maxBytes: 1000)) { XCTAssertEqual($0 as? ALPRParseError, .tooLarge) }
        XCTAssertThrowsError(try RegionCatalog.parse(Data("not json".utf8)))
        XCTAssertThrowsError(try RegionCatalog.parse(Data("{\"features\":5}".utf8)))
        XCTAssertThrowsError(try RegionCatalog.parse(Data("[]".utf8)))
    }

    func testCatalogSkipsBadCoordinates() throws {
        let bad = "{\"type\":\"Polygon\",\"coordinates\":[[[0,0],[1,95],[1,1],[0,0]]]}"
        let cat = try RegionCatalog.parse(Data("{\"features\":[\(feature("x", name: "X", parent: nil, geometry: bad))]}".utf8))
        XCTAssertEqual(cat.regions.count, 1)
        XCTAssertNil(cat.polygon("x"))
    }

    // MARK: planner

    func testPlannerForCatalogRegions() {
        let g = GeoPolygon.rectangle(BBox(west: 0, south: 0, east: 1, north: 1))
        let us = BBox(west: -160, south: 17, east: -64, north: 62), ca = BBox(west: -141, south: 41, east: -52, north: 84)
        func r(_ id: String, parent: String?, _ i2: [String]) -> RegionDescriptor {
            RegionDescriptor(id: id, name: id, parent: parent, iso3166_1: [], iso3166_2: i2)
        }
        XCTAssertEqual(ALPRSourcePlanner.sources(for: r("us/colorado", parent: "north-america", ["US-CO"]), polygon: g, us: us, ca: ca), [.deflockUS])
        XCTAssertEqual(ALPRSourcePlanner.sources(for: r("us/california/norcal", parent: "us/california", []), polygon: g, us: us, ca: ca), [.deflockUS])
        XCTAssertEqual(ALPRSourcePlanner.sources(for: r("canada/ontario", parent: "canada", ["CA-ON"]), polygon: g, us: us, ca: ca), [.deflockCA])
        XCTAssertEqual(ALPRSourcePlanner.sources(for: r("canada/quebec", parent: "canada", []), polygon: g, us: us, ca: ca), [.deflockCA])
        XCTAssertEqual(ALPRSourcePlanner.sources(for: r("europe/france", parent: "europe", []), polygon: g, us: us, ca: ca), [.overpass])
        XCTAssertEqual(ALPRSourcePlanner.sources(for: r("georgia", parent: "europe", ["GE-AB"]), polygon: g, us: us, ca: ca), [.overpass])
    }

    func testPlannerForRectangles() {
        let us = BBox(west: -160, south: 17, east: -64, north: 62), ca = BBox(west: -141, south: 41, east: -52, north: 84)
        func rect(_ b: BBox) -> GeoPolygon { .rectangle(b) }
        // Entirely in the US-only area.
        XCTAssertEqual(ALPRSourcePlanner.sources(for: nil, polygon: rect(BBox(west: -105, south: 35, east: -100, north: 38)), us: us, ca: ca), [.deflockUS])
        // Entirely in the CA-only area.
        XCTAssertEqual(ALPRSourcePlanner.sources(for: nil, polygon: rect(BBox(west: -100, south: 70, east: -90, north: 75)), us: us, ca: ca), [.deflockCA])
        // Across the border (both builds).
        XCTAssertEqual(ALPRSourcePlanner.sources(for: nil, polygon: rect(BBox(west: -100, south: 48, east: -95, north: 52)), us: us, ca: ca), [.deflockUS, .deflockCA])
        // Reaching beyond both: also Overpass.
        XCTAssertEqual(ALPRSourcePlanner.sources(for: nil, polygon: rect(BBox(west: -70, south: 40, east: -20, north: 45)), us: us, ca: ca), [.deflockUS, .deflockCA, .overpass])
        // Outside both.
        XCTAssertEqual(ALPRSourcePlanner.sources(for: nil, polygon: rect(BBox(west: 2, south: 48, east: 3, north: 49)), us: us, ca: ca), [.overpass])
        // A rect- descriptor behaves like nil.
        let d = RegionDescriptor(id: "rect-abc", name: "Rect", parent: nil, iso3166_1: [], iso3166_2: [])
        XCTAssertEqual(ALPRSourcePlanner.sources(for: d, polygon: rect(BBox(west: 2, south: 48, east: 3, north: 49)), us: us, ca: ca), [.overpass])
        // Unknown bounds: Overpass.
        XCTAssertEqual(ALPRSourcePlanner.sources(for: nil, polygon: rect(BBox(west: -105, south: 35, east: -100, north: 38)), us: nil, ca: nil), [.overpass])
    }
}
