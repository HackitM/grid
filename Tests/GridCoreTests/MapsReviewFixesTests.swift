import XCTest
@testable import GridCore

/// Regression tests for the integrated review of Maps v1.
final class MapsReviewFixesTests: XCTestCase {
    func testTileSourceZoomZeroAndOneAreNumbers() throws {
        let json = #"{"tilejson":"3.0.0","tiles":["https://t.example.org/v1/{z}/{x}/{y}.pbf"],"minzoom":1,"maxzoom":1}"#
        let s = try TileSource.parse(Data(json.utf8), from: URL(string: "https://t.example.org/tiles.json")!)
        XCTAssertEqual(s.minZoom, 1)
        XCTAssertEqual(s.maxZoom, 1)
        let b = #"{"tilejson":"3.0.0","tiles":["https://t.example.org/v1/{z}/{x}/{y}.pbf"],"maxzoom":true}"#
        XCTAssertEqual(try TileSource.parse(Data(b.utf8), from: URL(string: "https://t.example.org/tiles.json")!).maxZoom, 22)
    }

    func testDeFlockHostsAreExact() {
        func tj(_ host: String) -> Data {
            Data(#"{"build":"abcdef12","tiles":["https://\#(host)/c-abcdef12/{z}/{x}/{y}.mvt"],"index_bin":"https://\#(host)/i.bin","bounds":[-160,17,-64,62]}"#.utf8)
        }
        let src = URL(string: "https://deflock.dontgetflocked.com/cameras-us-hourly.json")!
        XCTAssertNoThrow(try DeFlockBuild.parse(tj("deflock.dontgetflocked.com"), from: src))
        XCTAssertNoThrow(try DeFlockBuild.parse(tj("tiles.dontgetflocked.com"), from: src))
        XCTAssertThrowsError(try DeFlockBuild.parse(tj("evil.dontgetflocked.com"), from: src))
        XCTAssertThrowsError(try DeFlockBuild.parse(tj("{z}.dontgetflocked.com"), from: src))
    }

    func testIndicesNeverTrapOnExtremeInput() {
        let cams = (0..<50).map { i in
            ALPRCamera(id: .node(Int64(i + 1)), coordinate: LonLat(lon: -71 + Double(i) * 0.001, lat: 41.8), directions: [], vendor: .flock,
                       operatorName: nil, mount: nil, zone: nil, lastEdited: nil)
        }
        let idx = CameraIndex(cams)
        XCTAssertNotNil(idx.nearest(to: LonLat(lon: -71, lat: 41.8), maxWorldDistance: 1e300))
        _ = idx.nearest(to: LonLat(lon: .nan, lat: .infinity), maxWorldDistance: .infinity)
        _ = idx.query(BBox(west: -1e300, south: -1e300, east: 1e300, north: 1e300))
        XCTAssertEqual(TileMath.tile(containing: Mercator(x: .infinity, y: -.infinity), z: 99).z, 24)
        XCTAssertTrue(TileMath.cover(MapCamera(center: Mercator(x: .nan, y: 0.5), zoom: 10), viewport: SIMD2(800, 600), maxZoom: 14).isEmpty)
        let poly = GeoPolygon.rectangle(BBox(west: -71.5, south: 41.5, east: -71.0, north: 42.0))
        XCTAssertFalse(poly.tileCover(z: 11, limit: Int.max).isEmpty)
    }

    func testPackageSkipsInvalidCamerasAndCapsStrings() throws {
        let good = ALPRCamera(id: .node(1), coordinate: LonLat(lon: -71, lat: 41), directions: [90], vendor: .flock,
                              operatorName: "Town", mount: nil, zone: nil, lastEdited: nil)
        let nan = ALPRCamera(id: .node(2), coordinate: LonLat(lon: .nan, lat: 41), directions: [], vendor: .unknown,
                             operatorName: nil, mount: nil, zone: nil, lastEdited: nil)
        let back = try RegionPackage.decode(RegionPackage.encode([good, nan]))
        XCTAssertEqual(back.map(\.id), [.node(1)])
        let huge = ALPRCamera(id: .node(3), coordinate: LonLat(lon: -71, lat: 41), directions: [], vendor: .unknown,
                              operatorName: String(repeating: "x", count: 4000), mount: nil, zone: nil, lastEdited: nil)
        XCTAssertThrowsError(try RegionPackage.decode(RegionPackage.encode([huge])))
    }

    func testDirectionsRejectExponentsAndHex() {
        XCTAssertEqual(OSMSurveillance.directions("1e5"), [])
        XCTAssertEqual(OSMSurveillance.directions("0x10"), [])
        XCTAssertEqual(OSMSurveillance.directions("90;1e2;NE"), [90, 45])
    }

    func testCatalogueClampsSlightlyOutOfRangeLongitudes() throws {
        let json = #"""
        {"type":"FeatureCollection","features":[{"type":"Feature","properties":{"id":"us/alaska","parent":"north-america","name":"us/alaska","iso3166-2":["US-AK"]},
         "geometry":{"type":"Polygon","coordinates":[[[-179.5,51],[180.6,52],[-130,55],[-141,70],[-179.5,51]]]}}]}
        """#
        let cat = try RegionCatalog.parse(Data(json.utf8))
        XCTAssertEqual(cat.regions.first?.name, "Alaska")
        XCTAssertNotNil(cat.polygon("us/alaska"))
    }

    func testInteriorShorelineIsClosed() {
        let lake: [SIMD2<Float>] = [SIMD2(0.3, 0.3), SIMD2(0.6, 0.3), SIMD2(0.6, 0.6), SIMD2(0.3, 0.6)]
        var closed: [LineVertex] = [], ci: [UInt32] = []
        TileGeometryBuilder.appendShoreline([lake], vertices: &closed, indices: &ci)
        var open: [LineVertex] = [], oi: [UInt32] = []
        LineTessellator.append(lake, closed: true, cls: .water, flags: 0, vertices: &open, indices: &oi)
        XCTAssertEqual(closed.count, open.count)     // same as one closed ring, no notch
        XCTAssertEqual(ci, oi)
    }

    func testLabelsDropBidiControls() {
        let tags: [String: MVTValue] = ["class": .string("city"), "name": .string("Evil\u{202E}txt.exe")]
        let label = OpenMapTilesSchema.label(layer: "place", tags: tags)
        XCTAssertEqual(label?.text.contains("\u{202E}"), false)
    }
}
