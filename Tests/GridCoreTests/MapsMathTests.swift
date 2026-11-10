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
        // Tilted: the far edge is covered by coarser tiles (no gaps) within the limit.
        for pitch in [45.0, 60.0] {
            var tilted = cam; tilted.pitch = pitch
            let vp = SIMD2<Double>(1280, 800)
            let t = TileMath.cover(tilted, viewport: vp, maxZoom: 14, limit: 48)
            XCTAssertLessThanOrEqual(t.count, 48)
            if pitch >= 60 { XCTAssertTrue(t.contains { $0.z < 14 }, "pitch \(pitch): far tiles should be coarser") }
            let proj = MapProjection(camera: tilted, viewport: vp)
            for sx in stride(from: 0.0, through: 1.0, by: 0.25) {
                let far = try! XCTUnwrap(proj.groundPoint(screen: SIMD2(sx * vp.x, 2)))
                XCTAssertTrue(t.contains { id in
                    let (nw, se) = TileMath.bounds(id); return far.x >= nw.x && far.x <= se.x && far.y >= nw.y && far.y <= se.y
                }, "pitch \(pitch): top edge at \(sx) uncovered")
            }
        }
    }

    func testContractLayouts() {
        XCTAssertEqual(MemoryLayout<LineVertex>.stride, 32)
        XCTAssertEqual(MemoryLayout<LineVertex>.offset(of: \.normal), 8)
        XCTAssertEqual(MemoryLayout<LineVertex>.offset(of: \.side), 16)
        XCTAssertEqual(MemoryLayout<LineVertex>.offset(of: \.along), 20)
        XCTAssertEqual(MemoryLayout<LineVertex>.offset(of: \.cls), 24)
        XCTAssertEqual(MemoryLayout<ExtrusionVertex>.stride, 16)
        XCTAssertEqual(MemoryLayout<ExtrusionVertex>.offset(of: \.shade), 12)
        XCTAssertEqual(MemoryLayout<ExtrusionVertex>.offset(of: \.flags), 14)
        XCTAssertEqual(RegionDescriptor(id: "us/colorado", name: "Colorado", parent: nil, iso3166_1: [], iso3166_2: []).storageKey, "us--colorado")
        XCTAssertEqual(RegionDescriptor(id: "../../etc", name: "x", parent: nil, iso3166_1: [], iso3166_2: []).storageKey, "etc")
        XCTAssertEqual(RegionDescriptor(id: "///", name: "x", parent: nil, iso3166_1: [], iso3166_2: []).storageKey, "region")
        XCTAssertEqual(OSMElementID.node(42).webURL.absoluteString, "https://www.openstreetmap.org/node/42")
    }
}

final class MapsGlobeTests: XCTestCase {
    let vp = SIMD2<Double>(1200, 800)

    func testGlobeCentreAndScaleMatchFlat() throws {
        let cam = MapCamera(center: TileMath.project(LonLat(lon: -40, lat: 30)), zoom: 3.4)
        XCTAssertTrue(cam.isGlobe)
        let g = GlobeProjection(camera: cam, viewport: vp)
        let c = try XCTUnwrap(g.screen(cam.center))
        XCTAssertEqual(c.x, 600, accuracy: 1e-6); XCTAssertEqual(c.y, 400, accuracy: 1e-6)
        // Near the centre the globe has the flat map's scale; along a parallel a globe is cos(lat)
        // narrower than Mercator.
        let step = 0.0005
        let e = try XCTUnwrap(g.screen(Mercator(x: cam.center.x + step, y: cam.center.y)))
        XCTAssertEqual(e.x - 600, step * g.worldScale * cos(30 * Double.pi / 180), accuracy: step * g.worldScale * 0.05)
        XCTAssertEqual(e.y, 400, accuracy: 0.5)
        // North is up.
        let n = try XCTUnwrap(g.screen(Mercator(x: cam.center.x, y: cam.center.y - step)))
        XCTAssertLessThan(n.y, 400)
    }

    func testFarSideIsHiddenAndGroundPointInverts() throws {
        let cam = MapCamera(center: TileMath.project(LonLat(lon: 10, lat: 0)), zoom: 2)
        let g = GlobeProjection(camera: cam, viewport: vp)
        XCTAssertNil(g.screen(TileMath.project(LonLat(lon: -170, lat: 0))))      // antipode
        let s = try XCTUnwrap(g.screen(TileMath.project(LonLat(lon: 40, lat: 25))))
        let back = try XCTUnwrap(g.groundPoint(screen: s))
        let ll = TileMath.unproject(back)
        XCTAssertEqual(ll.lon, 40, accuracy: 1e-6); XCTAssertEqual(ll.lat, 25, accuracy: 1e-6)
        XCTAssertNil(g.groundPoint(screen: SIMD2(2, 2)))                          // off the globe
        // Bearing 90: east is up.
        let rot = GlobeProjection(camera: MapCamera(center: cam.center, zoom: 2, bearing: 90), viewport: vp)
        let east = try XCTUnwrap(rot.screen(TileMath.project(LonLat(lon: 20, lat: 0))))
        XCTAssertLessThan(east.y, 400); XCTAssertEqual(east.x, 600, accuracy: 0.5)
    }

    func testGlobeCoverAndGestures() {
        let cam = MapCamera(center: TileMath.project(LonLat(lon: -98, lat: 39)), zoom: 2.6)
        let tiles = TileMath.cover(cam, viewport: vp, maxZoom: 14)
        XCTAssertFalse(tiles.isEmpty)
        XCTAssertTrue(tiles.allSatisfy { $0.z == 3 })
        XCTAssertLessThan(tiles.count, 48)
        XCTAssertTrue(tiles.prefix(4).contains(TileMath.tile(containing: cam.center, z: 3)))
        // Dragging right spins the globe westward under the pointer (centre longitude decreases).
        let panned = MapGestureMath.pan(cam, by: SIMD2(100, 0), viewport: vp)
        XCTAssertLessThan(TileMath.unproject(panned.center).lon, -98)
        // Zoom on the globe keeps the centre; crossing into the flat map works.
        let z = MapGestureMath.zoom(cam, by: 2, around: SIMD2(100, 100), viewport: vp)
        XCTAssertEqual(z.center, cam.center); XCTAssertFalse(z.isGlobe)
        // Flat pan through the shared math matches the old model formula.
        let flat = MapCamera(center: TileMath.project(LonLat(lon: -71.4, lat: 41.8)), zoom: 13, bearing: 20, pitch: 30)
        let p = MapGestureMath.pan(flat, by: SIMD2(40, -25), viewport: vp)
        XCTAssertNotEqual(p.center, flat.center)
        XCTAssertEqual(MapGestureMath.rotate(flat, bearing: -30, pitch: 99).pitch, MapCamera.maxPitch)
        XCTAssertEqual(MapGestureMath.rotate(flat, bearing: -30, pitch: 0).bearing, 350, accuracy: 1e-9)
    }
}

final class MapsBlendTests: XCTestCase {
    let vp = SIMD2<Double>(1200, 800)

    func testBlendIsContinuousAcrossTheMorph() throws {
        let center = TileMath.project(LonLat(lon: -75, lat: 40))
        let probe = TileMath.project(LonLat(lon: -60, lat: 48))
        XCTAssertEqual(MapCamera(center: center, zoom: 2.9).flatness, 0)
        XCTAssertEqual(MapCamera(center: center, zoom: 4.0).flatness, 1)
        // The projection type follows the zoom.
        XCTAssertTrue(mapProjection(camera: MapCamera(center: center, zoom: 2.5), viewport: vp) is GlobeProjection)
        XCTAssertTrue(mapProjection(camera: MapCamera(center: center, zoom: 3.4), viewport: vp) is BlendedProjection)
        XCTAssertTrue(mapProjection(camera: MapCamera(center: center, zoom: 4.2), viewport: vp) is MapProjection)
        // A point moves smoothly: no step bigger than a few points between nearby zooms.
        var last: SIMD2<Double>?
        var z = 2.85
        while z <= 4.05 {
            let cam = MapCamera(center: center, zoom: z)
            let s = try XCTUnwrap(mapProjection(camera: cam, viewport: vp).screen(probe), "zoom \(z)")
            if let last { XCTAssertLessThan(simd_length(s - last), 12, "jump at zoom \(z)") }
            last = s
            // The centre stays put.
            let c = try XCTUnwrap(mapProjection(camera: cam, viewport: vp).screen(center))
            XCTAssertEqual(c.x, 600, accuracy: 1e-6); XCTAssertEqual(c.y, 400, accuracy: 1e-6)
            z += 0.01
        }
    }

    func testFarSideAppearsOnlyLateInTheMorph() {
        let center = TileMath.project(LonLat(lon: 0, lat: 0))
        let antipode = TileMath.project(LonLat(lon: 179, lat: 0))
        let early = BlendedProjection(camera: MapCamera(center: center, zoom: 3.1), viewport: vp)
        XCTAssertNil(early.screen(antipode))
        let late = BlendedProjection(camera: MapCamera(center: center, zoom: 3.98), viewport: vp)
        XCTAssertGreaterThan(late.visibility(antipode), 0)
    }
}
