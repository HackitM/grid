import XCTest
@testable import GridCore

final class MapsDeFlockTests: XCTestCase {
    private let from = URL(string: "https://deflock.dontgetflocked.com/cameras-us-hourly.json")!

    private func tilejson(template: String = "https://deflock.dontgetflocked.com/cameras-us-hourly-7b4993d5a0e3/{z}/{x}/{y}.mvt",
                          index: String = "https://deflock.dontgetflocked.com/cameras-us-hourly-index-7b4993d5a0e3.bin",
                          build: String = "7b4993d5a0e3", bounds: String = "[-159.69,17.68,-64.59,61.61]",
                          maxzoom: String = "14") -> Data {
        Data("""
        {"tilejson":"3.0.0","tiles":["\(template)"],"build":"\(build)","bounds":\(bounds),"maxzoom":\(maxzoom),"index_bin":"\(index)"}
        """.utf8)
    }

    // MARK: build

    func testBuildParses() throws {
        let b = try DeFlockBuild.parse(tilejson(), from: from)
        XCTAssertEqual(b.build, "7b4993d5a0e3")
        XCTAssertEqual(b.maxZoom, 14)
        XCTAssertEqual(b.bounds, BBox(west: -159.69, south: 17.68, east: -64.59, north: 61.61))
        XCTAssertEqual(b.indexURL.host, "deflock.dontgetflocked.com")
        XCTAssertEqual(b.tileURL(TileID(z: 11, x: 603, y: 770))?.absoluteString,
                       "https://deflock.dontgetflocked.com/cameras-us-hourly-7b4993d5a0e3/11/603/770.mvt")
        XCTAssertNil(b.tileURL(TileID(z: 15, x: 0, y: 0)))       // above maxzoom
        XCTAssertNil(b.tileURL(TileID(z: 3, x: 9, y: 0)))        // invalid tile
    }

    func testBuildRejects() {
        func bad(_ d: Data, _ why: String, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertThrowsError(try DeFlockBuild.parse(d, from: from), why, file: file, line: line)
        }
        bad(tilejson(template: "http://deflock.dontgetflocked.com/x/{z}/{x}/{y}.mvt"), "http")
        bad(tilejson(template: "https://evil.example.com/x/{z}/{x}/{y}.mvt", index: "https://evil.example.com/i.bin"), "foreign host")
        bad(tilejson(template: "https://deflock.dontgetflocked.com.evil.com/{z}/{x}/{y}.mvt"), "suffix trick")
        bad(tilejson(template: "https://user:pw@deflock.dontgetflocked.com/{z}/{x}/{y}.mvt"), "userinfo")
        bad(tilejson(template: "https://deflock.dontgetflocked.com:8443/{z}/{x}/{y}.mvt"), "port")
        bad(tilejson(template: "https://deflock.dontgetflocked.com/{z}/{x}.mvt"), "missing y")
        bad(tilejson(template: "https://deflock.dontgetflocked.com/{s}/{z}/{x}/{y}.mvt"), "{s}")
        bad(tilejson(index: "https://tiles.dontgetflocked.com/i.bin"), "index on another host")
        bad(tilejson(index: "http://deflock.dontgetflocked.com/i.bin"), "index http")
        bad(tilejson(build: "../etc"), "build chars")
        bad(tilejson(build: "abc"), "build short")
        bad(tilejson(build: String(repeating: "a", count: 41)), "build long")
        bad(tilejson(build: "ABCDEF123456"), "build uppercase")
        bad(tilejson(bounds: "[1,2,3]"), "bounds count")
        bad(tilejson(bounds: "[10,0,-10,5]"), "bounds order")
        bad(Data("[]".utf8), "not object")
        bad(Data(count: 5000), "garbage")
        XCTAssertThrowsError(try DeFlockBuild.parse(tilejson(), from: from, maxBytes: 20)) { XCTAssertEqual($0 as? ALPRParseError, .tooLarge) }
        XCTAssertThrowsError(try DeFlockBuild.parse(tilejson(), from: URL(string: "https://example.com/a.json")!))
        XCTAssertThrowsError(try DeFlockBuild.parse(tilejson(), from: URL(string: "http://deflock.dontgetflocked.com/a.json")!))
    }

    // MARK: index

    private func indexData(_ pts: [(lat: Int32, lon: Int32, brand: UInt8)], version: UInt32 = 1, magic: String = "FHIX", count: UInt32? = nil,
                           reserved: Bool = false) -> Data {
        var d = Data(magic.utf8)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        u32(version); u32(count ?? UInt32(pts.count))
        if reserved { u32(0) }
        for p in pts { u32(UInt32(bitPattern: p.lat)) }
        for p in pts { u32(UInt32(bitPattern: p.lon)) }
        for p in pts { d.append(p.brand) }
        return d
    }
    private func pt(_ lon: Double, _ lat: Double) -> (lat: Int32, lon: Int32, brand: UInt8) { (Int32(lat * 1e6), Int32(lon * 1e6), 1) }

    func testIndexParsesAndCountsPerPolygon() throws {
        let pts = [pt(-71.4, 41.8), pt(-71.3, 41.9), pt(-105, 39.7), pt(-105.1, 39.8), pt(-105.2, 39.75), pt(-90, 30)]
        let idx = try DeFlockIndex(indexData(pts))
        XCTAssertEqual(idx.count, 6)
        let ri = GeoPolygon.rectangle(BBox(west: -72, south: 41, east: -71, north: 42.5))
        let co = GeoPolygon.rectangle(BBox(west: -109, south: 37, east: -102, north: 41))
        XCTAssertEqual(idx.count(in: ri), 2)
        XCTAssertEqual(idx.count(in: co), 3)
        XCTAssertEqual(idx.count(in: GeoPolygon(polygons: [])), 0)
        // Polygon containment, not bbox: a triangle excluding one of the Colorado points.
        let tri = GeoPolygon(polygons: [[[LonLat(lon: -109, lat: 37), LonLat(lon: -102, lat: 37), LonLat(lon: -109, lat: 41)]]])
        XCTAssertEqual(idx.count(in: tri), 0)    // all three CO points lie above the hypotenuse
        // Hole removes a point.
        let holed = GeoPolygon(polygons: [[
            [LonLat(lon: -109, lat: 37), LonLat(lon: -102, lat: 37), LonLat(lon: -102, lat: 41), LonLat(lon: -109, lat: 41)],
            [LonLat(lon: -105.15, lat: 39.7), LonLat(lon: -105.05, lat: 39.7), LonLat(lon: -105.05, lat: 39.9), LonLat(lon: -105.15, lat: 39.9)],
        ]])
        XCTAssertEqual(idx.count(in: holed), 2)
    }

    func testNonEmptyTilesUsePolygonContainment() throws {
        let pts = [pt(-71.4, 41.8), pt(-71.4001, 41.8001), pt(-71.0, 42.2), pt(-100, 40)]
        let idx = try DeFlockIndex(indexData(pts))
        let ri = GeoPolygon.rectangle(BBox(west: -72, south: 41, east: -70.5, north: 42.5))
        let tiles = idx.nonEmptyTiles(z: 11, in: ri)
        let t1 = TileMath.tile(containing: TileMath.project(LonLat(lon: -71.4, lat: 41.8)), z: 11)
        let t2 = TileMath.tile(containing: TileMath.project(LonLat(lon: -71.0, lat: 42.2)), z: 11)
        XCTAssertEqual(Set(tiles), Set([t1, t2]))
        XCTAssertEqual(tiles.count, 2)
        // A polygon that overlaps a tile's bbox but not its camera → the tile is absent.
        let tiny = GeoPolygon.rectangle(BBox(west: -71.5, south: 41.9, east: -71.45, north: 41.95))
        XCTAssertTrue(idx.nonEmptyTiles(z: 11, in: tiny).isEmpty)
        XCTAssertTrue(idx.nonEmptyTiles(z: 99, in: ri).isEmpty)
    }

    func testIndexLiveSixteenByteHeader() throws {
        // The live files carry a reserved u32 after the count (16-byte header).
        let pts = [pt(-71.4, 41.8), pt(-71.5, 41.7), pt(-100, 40)]
        let idx = try DeFlockIndex(indexData(pts, reserved: true))
        XCTAssertEqual(idx.count, 3)
        let ri = GeoPolygon.rectangle(BBox(west: -72, south: 41, east: -71, north: 42.1))
        XCTAssertEqual(idx.count(in: ri), 2)
        // One byte more or less than either layout is rejected.
        var d = indexData(pts, reserved: true); d.append(0)
        XCTAssertThrowsError(try DeFlockIndex(d))
    }

    func testIndexRejects() {
        let pts = [pt(-71.4, 41.8), pt(-71.3, 41.9)]
        func bad(_ d: Data, _ why: String) { XCTAssertThrowsError(try DeFlockIndex(d), why) }
        bad(indexData(pts, magic: "FHIY"), "magic")
        bad(indexData(pts, version: 2), "version")
        bad(indexData(pts, count: 3), "count > data")
        bad(indexData(pts, count: 1), "count < data")
        bad(indexData(pts, count: UInt32.max), "huge count")
        bad(Data(), "empty")
        bad(Data("FHIX".utf8), "short")
        var trailing = indexData(pts); trailing.append(0)
        bad(trailing, "trailing byte")
        bad(indexData([(lat: 91_000_000, lon: 0, brand: 0)]), "lat range")
        bad(indexData([(lat: 0, lon: -181_000_000, brand: 0)]), "lon range")
        XCTAssertEqual(try? DeFlockIndex(indexData([])).count, 0)
        for cut in 0..<indexData(pts).count { bad(indexData(pts).prefix(cut), "truncated \(cut)") }
    }

    func testIndexFuzzNeverTraps() throws {
        var rng = ALPRTestRNG(seed: 42)
        let pts = (0..<40).map { _ in pt(Double.random(in: -120 ... -70, using: &rng), Double.random(in: 25 ... 48, using: &rng)) }
        let base = [UInt8](indexData(pts))
        let poly = GeoPolygon.rectangle(BBox(west: -100, south: 30, east: -80, north: 45))
        var accepted = 0
        for i in 0..<3000 {
            var b = base
            switch i % 4 {
            case 0: b[Int(rng.next() % UInt64(b.count))] ^= UInt8(truncatingIfNeeded: rng.next() | 1)
            case 1: b = Array(b.prefix(Int(rng.next() % UInt64(b.count))))
            case 2: for _ in 0..<4 { b[Int(rng.next() % UInt64(b.count))] = UInt8(truncatingIfNeeded: rng.next()) }
            default: b.append(contentsOf: (0..<Int(rng.next() % 8) + 1).map { _ in UInt8(truncatingIfNeeded: rng.next()) })
            }
            if let idx = try? DeFlockIndex(Data(b)) {
                accepted += 1
                _ = idx.count(in: poly); _ = idx.nonEmptyTiles(z: 11, in: poly)
            }
        }
        XCTAssertGreaterThan(accepted, 0)   // brand-byte flips are still valid
    }

    // MARK: tile

    private func tile(_ features: [MVTFeature], extent: Int32 = 4096, name: String = "cameras") -> MVTTile {
        MVTTile(layers: [MVTLayer(name: name, extent: extent, features: features)])
    }

    func testTileMapsCamerasToLonLat() {
        let id = TileID(z: 11, x: 603, y: 770)
        let wanted = [LonLat(lon: -71.4123456, lat: 41.8123456), LonLat(lon: -71.4, lat: 41.75)]
        let (nw, se) = TileMath.bounds(id)
        func px(_ p: LonLat) -> SIMD2<Int32> {
            let m = TileMath.project(p)
            return SIMD2(Int32(((m.x - nw.x) / (se.x - nw.x) * 4096).rounded()), Int32(((m.y - nw.y) / (se.y - nw.y) * 4096).rounded()))
        }
        let f1 = MVTFeature(id: nil, tags: [
            "osmId": .int(123456), "osmType": .string("node"), "brand": .string("Flock Safety"), "direction": .int(90),
            "directions": .string("45;225"), "mountType": .string("pole"), "operator": .string("  Town PD "),
            "surveillanceZone": .string("traffic"), "osmTimestamp": .string("2026-10-01T00:00:00Z"),
        ], geometry: .points([px(wanted[0])]))
        let f2 = MVTFeature(id: nil, tags: ["osmId": .double(77), "osmType": .string("way"), "direction": .int(-90), "brand": .string("Rekor")],
                            geometry: .points([px(wanted[1])]))
        let cams = DeFlockTile.cameras(tile([f1, f2]), id: id)
        XCTAssertEqual(cams.count, 2)
        // One extent unit at z11 = 360/2048/4096 deg lon (~4.3e-5): positions are within half a unit.
        let tol = 360.0 / 2048 / 4096
        XCTAssertEqual(cams[0].coordinate.lon, wanted[0].lon, accuracy: tol)
        XCTAssertEqual(cams[0].coordinate.lat, wanted[0].lat, accuracy: tol)
        XCTAssertEqual(cams[0].id, .node(123456))
        XCTAssertEqual(cams[0].vendor, .flock)
        XCTAssertEqual(cams[0].directions, [45, 225], "directions string wins over direction")
        XCTAssertEqual(cams[0].mount, "pole")
        XCTAssertEqual(cams[0].operatorName, "Town PD")
        XCTAssertEqual(cams[0].zone, "traffic")
        XCTAssertEqual(cams[0].lastEdited, Date(timeIntervalSince1970: 1_790_812_800))
        XCTAssertEqual(cams[1].id, .way(77))
        XCTAssertEqual(cams[1].directions, [270])
        XCTAssertEqual(cams[1].vendor, .rekor)
        XCTAssertNil(cams[1].lastEdited)
    }

    func testTileExactCorners() {
        let id = TileID(z: 11, x: 603, y: 770)
        let gb = TileMath.geoBounds(id)
        let f = MVTFeature(id: nil, tags: ["osmId": .int(1)], geometry: .points([SIMD2(0, 0), SIMD2(4096, 4096)]))
        let cams = DeFlockTile.cameras(tile([f]), id: id)
        XCTAssertEqual(cams[0].coordinate.lon, gb.west, accuracy: 1e-9)
        XCTAssertEqual(cams[0].coordinate.lat, gb.north, accuracy: 1e-9)
        XCTAssertEqual(cams[1].coordinate.lon, gb.east, accuracy: 1e-9)
        XCTAssertEqual(cams[1].coordinate.lat, gb.south, accuracy: 1e-9)
    }

    func testTileSkipsBadFeatures() {
        let id = TileID(z: 11, x: 603, y: 770)
        let pts = MVTGeometry.points([SIMD2(100, 100)])
        let feats = [
            MVTFeature(id: nil, tags: [:], geometry: pts),                                                // no osmId
            MVTFeature(id: nil, tags: ["osmId": .string("5")], geometry: pts),                            // wrong type
            MVTFeature(id: nil, tags: ["osmId": .double(1.5)], geometry: pts),
            MVTFeature(id: nil, tags: ["osmId": .int(-3)], geometry: pts),
            MVTFeature(id: nil, tags: ["osmId": .int(9)], geometry: .lines([[SIMD2(0, 0), SIMD2(5, 5)]])),   // not a point
            MVTFeature(id: nil, tags: ["osmId": .int(10)], geometry: pts),                                // good
        ]
        XCTAssertEqual(DeFlockTile.cameras(tile(feats), id: id).map(\.id), [.node(10)])
        XCTAssertTrue(DeFlockTile.cameras(tile(feats, name: "other"), id: id).isEmpty)
        XCTAssertTrue(DeFlockTile.cameras(tile(feats, extent: 0), id: id).isEmpty)
        XCTAssertTrue(DeFlockTile.cameras(tile(feats), id: TileID(z: 3, x: 99, y: 0)).isEmpty)
    }

    func testTileDirectionFallbacks() {
        let id = TileID(z: 11, x: 603, y: 770)
        let pts = MVTGeometry.points([SIMD2(100, 100)])
        let feats = [
            MVTFeature(id: nil, tags: ["osmId": .int(1), "direction": .int(360)], geometry: pts),
            MVTFeature(id: nil, tags: ["osmId": .int(2), "directionCardinal": .string("SW")], geometry: pts),
            MVTFeature(id: nil, tags: ["osmId": .int(3), "directions": .string("junk"), "direction": .double(12.5)], geometry: pts),
            MVTFeature(id: nil, tags: ["osmId": .int(4), "direction": .double(.nan)], geometry: pts),
        ]
        XCTAssertEqual(DeFlockTile.cameras(tile(feats), id: id).map(\.directions), [[0], [225], [13], []])
    }
}
