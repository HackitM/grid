import XCTest
import simd
@testable import GridCore

final class MapsTerrainTests: XCTestCase {
    func testTerrariumDecode() throws {
        // 0 m = (128, 0, 0); 1000.5 m = 33768.5 → R 131 (33536) G 232 (232) B 128 (0.5).
        let px: [UInt8] = [128, 0, 0, 255, 131, 232, 128, 255]
        let h = try XCTUnwrap(Terrarium.decode(px, width: 2, height: 1, bytesPerPixel: 4))
        XCTAssertEqual(h[0], 0, accuracy: 1e-3)
        XCTAssertEqual(h[1], 1000.5, accuracy: 1e-3)
        XCTAssertNil(Terrarium.decode([1, 2], width: 2, height: 1, bytesPerPixel: 3))
        XCTAssertEqual(Terrarium.demTile(for: TileID(z: 14, x: 3406, y: 6202)), TileID(z: 12, x: 851, y: 1550))
        XCTAssertEqual(Terrarium.demTile(for: TileID(z: 9, x: 100, y: 200)), TileID(z: 9, x: 100, y: 200))
    }

    /// A DEM where elevation = x pixel index, to check cropping and shared edges.
    func ramp(_ size: Int) -> [Float] { (0..<size * size).map { Float($0 % size) } }

    func testGridCropsTheRightQuadrantAndNeighboursAgree() throws {
        let dem = TileID(z: 12, x: 10, y: 20)
        let heights = ramp(256)
        let left = try XCTUnwrap(Terrarium.grid(for: TileID(z: 13, x: 20, y: 40), dem: dem, heights: heights, demSize: 256))
        let right = try XCTUnwrap(Terrarium.grid(for: TileID(z: 13, x: 21, y: 40), dem: dem, heights: heights, demSize: 256))
        let n = TerrainGrid.size
        XCTAssertLessThan(left.heights[0], 1)                  // west edge of the DEM
        XCTAssertGreaterThan(right.heights[n - 1], 254)        // east edge
        for j in 0..<n { XCTAssertEqual(left.heights[j * n + n - 1], right.heights[j * n], accuracy: 1e-3) }   // shared edge
        XCTAssertNil(Terrarium.grid(for: TileID(z: 13, x: 30, y: 40), dem: dem, heights: heights, demSize: 256))
        XCTAssertEqual(left.height(u: 0.5, v: 0.5), Double(left.heights[(n / 2) * n + n / 2]), accuracy: 0.5)
    }

    func testContoursOfAConeAreClosedRings() {
        let n = TerrainGrid.size
        var h = [Float](repeating: 0, count: n * n)
        for j in 0..<n { for i in 0..<n {
            let dx = Float(i - n / 2), dy = Float(j - n / 2)
            h[j * n + i] = max(0, 1000 - 40 * (dx * dx + dy * dy).squareRoot())
        } }
        let grid = TerrainGrid(id: TileID(z: 13, x: 0, y: 0), heights: h)
        let lines = Contours.lines(grid, step: 100, indexStep: 500)
        XCTAssertEqual(lines.count, 9)                          // 100 … 900 m
        XCTAssertTrue(lines.allSatisfy(\.closed))
        XCTAssertEqual(lines.filter(\.isIndex).map(\.level), [500])
        // Each ring is at its level's radius: r = (1000 - level) / 40 cells.
        for l in lines {
            let r = (1000 - l.level) / 40 / Float(n - 1)
            for p in l.points { XCTAssertEqual(simd_length(p - SIMD2(0.5, 0.5)), r, accuracy: 0.02) }
        }
        let geo = Contours.geometry(grid, feet: false)
        XCTAssertEqual(Set(geo.lines.map(\.cls)), [.contour, .contourIndex])
        XCTAssertTrue(geo.labels.allSatisfy { $0.text.hasSuffix(" m") && simd_length($0.dir) > 0.99 })
        XCTAssertNil(Contours.interval(zoom: 6, feet: false))
        XCTAssertEqual(Contours.interval(zoom: 14, feet: true)?.minor, 40)
    }

    func testFlatAndNoisyGridsAreSafe() {
        let n = TerrainGrid.size
        XCTAssertTrue(Contours.lines(TerrainGrid(id: TileID(z: 12, x: 0, y: 0), heights: [Float](repeating: 300, count: n * n)), step: 50, indexStep: 250).isEmpty)
        var rng = SystemRandomNumberGenerator()
        let noisy = (0..<n * n).map { _ in Float.random(in: 0...2000, using: &rng) }
        // Huge relief at a fine step is capped instead of producing thousands of levels.
        XCTAssertTrue(Contours.lines(TerrainGrid(id: TileID(z: 14, x: 0, y: 0), heights: noisy), step: 1, indexStep: 5).isEmpty)
        _ = Contours.lines(TerrainGrid(id: TileID(z: 12, x: 0, y: 0), heights: noisy), step: 100, indexStep: 500)
    }
}

final class MapsTerrainLiftTests: XCTestCase {
    func testFlatAndRelative() {
        XCTAssertEqual(TerrainLift.flat.lift(4000), 0)
        let l = TerrainLift(scale: 1, base: 1600, ceiling: 0)
        XCTAssertEqual(l.lift(1600), 0, accuracy: 1e-9)
        XCTAssertEqual(l.lift(2600), 1000, accuracy: 1e-9)
        XCTAssertEqual(l.lift(600), -1000, accuracy: 1e-9)
    }

    func testSeaLevelClamp() {
        let l = TerrainLift(scale: 2, base: 0, ceiling: 0)
        XCTAssertEqual(l.lift(-4000), 0)
        XCTAssertEqual(l.lift(100), 200, accuracy: 1e-9)
    }

    func testCeilingIsSoftAndMonotonic() {
        let l = TerrainLift(scale: 1, base: 0, ceiling: 2000)
        var last = -1.0
        for h in stride(from: 0.0, through: 50_000, by: 250) {
            let v = l.lift(h)
            XCTAssertGreaterThan(v, last)
            XCTAssertLessThan(v, 2000)
            last = v
        }
        XCTAssertEqual(l.lift(10), 10, accuracy: 0.1)   // small rises are nearly true
    }
}
