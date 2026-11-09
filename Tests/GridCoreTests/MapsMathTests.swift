import XCTest
import simd
@testable import GridCore

final class MapsMathTests: XCTestCase {
    func testProjectRoundTrip() {
        for p in [LonLat(lon: 0, lat: 0), LonLat(lon: -122.4194, lat: 37.7749), LonLat(lon: 151.2, lat: -33.87), LonLat(lon: 179.9, lat: 84)] {
            let back = TileMath.unproject(TileMath.project(p))
            XCTAssertEqual(back.lon, p.lon, accuracy: 1e-9)
            XCTAssertEqual(back.lat, p.lat, accuracy: 1e-9)
        }
        let c = TileMath.project(LonLat(lon: 0, lat: 0))
        XCTAssertEqual(c.x, 0.5, accuracy: 1e-12); XCTAssertEqual(c.y, 0.5, accuracy: 1e-12)
    }

    func testTiles() {
        let sf = TileMath.project(LonLat(lon: -122.4194, lat: 37.7749))
        XCTAssertEqual(TileMath.tile(containing: sf, z: 14), TileID(z: 14, x: 2620, y: 6332))
        let t = TileID(z: 14, x: 2620, y: 6333)
        XCTAssertEqual(TileMath.parent(t), TileID(z: 13, x: 1310, y: 3166))
        XCTAssertEqual(TileMath.children(TileID(z: 1, x: 1, y: 0)).count, 4)
        XCTAssertTrue(TileMath.geoBounds(TileID(z: 0, x: 0, y: 0)).contains(LonLat(lon: 10, lat: 10)))
        XCTAssertFalse(TileID(z: 2, x: 4, y: 0).isValid)
    }

    func testProjectionCentreAndScale() {
        let cam = MapCamera(center: TileMath.project(LonLat(lon: -122.4194, lat: 37.7749)), zoom: 14)
        let proj = MapProjection(camera: cam, viewport: SIMD2(1280, 800))
        let s = try! XCTUnwrap(proj.screen(cam.center))
        XCTAssertEqual(s.x, 640, accuracy: 1e-6); XCTAssertEqual(s.y, 400, accuracy: 1e-6)
        // One tile width at z14 = 256 points.
        let east = Mercator(x: cam.center.x + 1.0 / Double(1 << 14), y: cam.center.y)
        let e = try! XCTUnwrap(proj.screen(east))
        XCTAssertEqual(e.x - 640, 256, accuracy: 1e-6)
        XCTAssertEqual(e.y, 400, accuracy: 1e-6)
        // North (smaller y) is up.
        let north = Mercator(x: cam.center.x, y: cam.center.y - 1.0 / Double(1 << 14))
        XCTAssertEqual(try XCTUnwrap(proj.screen(north)).y, 400 - 256, accuracy: 1e-6)
        // groundPoint inverts screen.
        let g = try! XCTUnwrap(proj.groundPoint(screen: SIMD2(900, 123)))
        let back = try! XCTUnwrap(proj.screen(g))
        XCTAssertEqual(back.x, 900, accuracy: 1e-6); XCTAssertEqual(back.y, 123, accuracy: 1e-6)
    }

    func testBearingAndPitch() {
        let c = TileMath.project(LonLat(lon: 0, lat: 0))
        let step = 1.0 / Double(1 << 10)
        // Bearing 90: facing east, so east is up.
        let east = Mercator(x: c.x + step, y: c.y)
        let rot = MapProjection(camera: MapCamera(center: c, zoom: 10, bearing: 90), viewport: SIMD2(1000, 1000))
        let e = try! XCTUnwrap(rot.screen(east))
        XCTAssertEqual(e.x, 500, accuracy: 1e-6); XCTAssertEqual(e.y, 500 - 256, accuracy: 1e-6)
        // Pitch: the centre stays put; northern ground rises toward the horizon and shrinks.
        let pitched = MapProjection(camera: MapCamera(center: c, zoom: 10, pitch: 45), viewport: SIMD2(1000, 1000))
        let ctr = try! XCTUnwrap(pitched.screen(c))
        XCTAssertEqual(ctr.y, 500, accuracy: 1e-6)
        let n = try! XCTUnwrap(pitched.screen(Mercator(x: c.x, y: c.y - step)))
        let s = try! XCTUnwrap(pitched.screen(Mercator(x: c.x, y: c.y + step)))
        XCTAssertLessThan(500 - n.y, s.y - 500)      // far side compressed
        // Heights go up the screen.
        let up = try! XCTUnwrap(pitched.screen(c, heightMeters: 500))
        XCTAssertLessThan(up.y, 500)
        let g = try! XCTUnwrap(pitched.groundPoint(screen: SIMD2(700, 200)))
        let back = try! XCTUnwrap(pitched.screen(g))
        XCTAssertEqual(back.x, 700, accuracy: 1e-4); XCTAssertEqual(back.y, 200, accuracy: 1e-4)
    }

    func testTileMatrixMatchesScreen() {
        let cam = MapCamera(center: TileMath.project(LonLat(lon: 2.35, lat: 48.85)), zoom: 13.4, bearing: 30, pitch: 30)
        let vp = SIMD2<Double>(1200, 700)
        let proj = MapProjection(camera: cam, viewport: vp)
        let t = TileMath.tile(containing: cam.center, z: 13)
        let m = proj.tileMatrix(t)
        let (nw, se) = TileMath.bounds(t)
        let local = SIMD2<Float>(0.25, 0.75)
        let world = Mercator(x: nw.x + 0.25 * (se.x - nw.x), y: nw.y + 0.75 * (se.y - nw.y))
        let c = m * SIMD4<Float>(local.x, local.y, 0, 1)
        let viaMatrix = SIMD2((Double(c.x / c.w) + 1) / 2 * vp.x, (1 - Double(c.y / c.w)) / 2 * vp.y)
        let viaScreen = try! XCTUnwrap(proj.screen(world))
        XCTAssertEqual(viaMatrix.x, viaScreen.x, accuracy: 0.05)
        XCTAssertEqual(viaMatrix.y, viaScreen.y, accuracy: 0.05)
    }

    func testCover() {
        let cam = MapCamera(center: TileMath.project(LonLat(lon: -122.4194, lat: 37.7749)), zoom: 14.2)
        let flat = TileMath.cover(cam, viewport: SIMD2(1280, 800), maxZoom: 14)
        XCTAssertTrue(flat.allSatisfy { $0.z == 14 })
        XCTAssertTrue((20...40).contains(flat.count), "\(flat.count)")
        XCTAssertEqual(flat.first, TileMath.tile(containing: cam.center, z: 14))
        // Overzoom reuses z14.
        var deep = cam; deep.zoom = 17
        XCTAssertTrue(TileMath.cover(deep, viewport: SIMD2(1280, 800), maxZoom: 14).allSatisfy { $0.z == 14 })
        // Pitch adds tiles but respects the limit.
        var tilted = cam; tilted.pitch = 45
        let t = TileMath.cover(tilted, viewport: SIMD2(1280, 800), maxZoom: 14, limit: 48)
        XCTAssertGreaterThan(t.count, flat.count)
        XCTAssertLessThanOrEqual(t.count, 48)
    }

    func testContractLayouts() {
        XCTAssertEqual(MemoryLayout<LineVertex>.stride, 32)
        XCTAssertEqual(MemoryLayout<LineVertex>.offset(of: \.normal), 8)
        XCTAssertEqual(MemoryLayout<LineVertex>.offset(of: \.side), 16)
        XCTAssertEqual(MemoryLayout<LineVertex>.offset(of: \.along), 20)
        XCTAssertEqual(MemoryLayout<LineVertex>.offset(of: \.cls), 24)
        XCTAssertEqual(MemoryLayout<ExtrusionVertex>.stride, 16)
        XCTAssertEqual(RegionDescriptor(id: "us/colorado", name: "Colorado", parent: nil, iso3166_1: [], iso3166_2: []).storageKey, "us--colorado")
        XCTAssertEqual(RegionDescriptor(id: "../../etc", name: "x", parent: nil, iso3166_1: [], iso3166_2: []).storageKey, "etc")
        XCTAssertEqual(RegionDescriptor(id: "///", name: "x", parent: nil, iso3166_1: [], iso3166_2: []).storageKey, "region")
        XCTAssertEqual(OSMElementID.node(42).webURL.absoluteString, "https://www.openstreetmap.org/node/42")
    }
}
