import XCTest
@testable import GridCore

/// Deterministic generator shared by the ALPR tests.
struct ALPRTestRNG: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

func alprTestCameras(_ n: Int, seed: UInt64, lon: ClosedRange<Double> = -125 ... -66, lat: ClosedRange<Double> = 25 ... 49) -> [ALPRCamera] {
    var rng = ALPRTestRNG(seed: seed)
    let vendors: [ALPRVendor] = [.flock, .motorola, .genetec, .axis, .leonardo, .rekor, .axon, .neology, .unknown, .other("Acme Optics")]
    return (0..<n).map { i in
        let ndirs = Int(rng.next() % 4)
        // Quantised to the package's 1e-7 resolution so round trips are exact.
        let la = (Double.random(in: lat, using: &rng) * 1e7).rounded() / 1e7
        let lo = (Double.random(in: lon, using: &rng) * 1e7).rounded() / 1e7
        return ALPRCamera(
            id: rng.next() % 5 == 0 ? .way(Int64(i) + 1_000_000_000) : .node(Int64(i) + 1),
            coordinate: LonLat(lon: lo, lat: la),
            directions: (0..<ndirs).map { _ in UInt16(rng.next() % 360) },
            vendor: vendors[Int(rng.next() % UInt64(vendors.count))],
            operatorName: rng.next() % 3 == 0 ? "Operator \(rng.next() % 50)" : nil,
            mount: rng.next() % 3 == 0 ? ["pole", "wall", "traffic signal"][Int(rng.next() % 3)] : nil,
            zone: rng.next() % 4 == 0 ? "traffic" : nil,
            lastEdited: rng.next() % 2 == 0 ? Date(timeIntervalSince1970: Double(1_500_000_000 + Int(rng.next() % 300_000_000))) : nil)
    }
}

final class MapsCameraIndexTests: XCTestCase {
    func testQueryMatchesBruteForce() {
        let cams = alprTestCameras(20_000, seed: 1)
        let index = CameraIndex(cams)
        XCTAssertEqual(index.cameras.count, 20_000)
        var rng = ALPRTestRNG(seed: 99)
        for _ in 0..<60 {
            let w = Double.random(in: -126 ... -66, using: &rng), s = Double.random(in: 24 ... 49, using: &rng)
            let box = BBox(west: w, south: s, east: w + Double.random(in: 0.01 ... 25, using: &rng), north: s + Double.random(in: 0.01 ... 12, using: &rng))
            let brute = cams.indices.filter { box.contains(cams[$0].coordinate) }
            XCTAssertEqual(index.query(box), brute)
            XCTAssertEqual(index.count(in: box), brute.count)
        }
        // Whole world, empty and invalid boxes.
        XCTAssertEqual(index.query(BBox(west: -180, south: -90, east: 180, north: 90)).count, 20_000)
        XCTAssertTrue(index.query(BBox(west: 10, south: 10, east: 11, north: 11)).isEmpty)
        XCTAssertTrue(index.query(BBox(west: 5, south: 0, east: 1, north: 1)).isEmpty)
        XCTAssertTrue(CameraIndex([]).query(BBox(west: -1, south: -1, east: 1, north: 1)).isEmpty)
        XCTAssertEqual(index.count(in: BBox(west: -180, south: -90, east: 180, north: 90)), 20_000)
        XCTAssertEqual(index.count(in: BBox(west: 5, south: 0, east: 1, north: 1)), 0)
        XCTAssertEqual(CameraIndex([]).count(in: BBox(west: -1, south: -1, east: 1, north: 1)), 0)
    }

    func testCameraWithoutAPositionNeverTraps() {
        let bad = ALPRCamera(id: .node(1), coordinate: LonLat(lon: .nan, lat: .infinity), directions: [], vendor: .unknown,
                             operatorName: nil, mount: nil, zone: nil, lastEdited: nil)
        let index = CameraIndex([bad] + alprTestCameras(50, seed: 3))
        let world = BBox(west: -180, south: -90, east: 180, north: 90)
        XCTAssertEqual(index.query(world).count, 50)
        XCTAssertEqual(index.clusters(world, cellWorld: 0.01).reduce(0) { $0 + $1.count }, 50)
        XCTAssertNotNil(index.nearest(to: LonLat(lon: -100, lat: 40), maxWorldDistance: 1))
    }

    func testNearestMatchesBruteForce() {
        let cams = alprTestCameras(20_000, seed: 2)
        let index = CameraIndex(cams)
        let merc = cams.map { TileMath.project($0.coordinate) }
        var rng = ALPRTestRNG(seed: 7)
        var hits = 0
        for _ in 0..<400 {
            let p = LonLat(lon: Double.random(in: -126 ... -65, using: &rng), lat: Double.random(in: 24 ... 50, using: &rng))
            let maxD = [0.0002, 0.001, 0.01, 0.05][Int(rng.next() % 4)]
            let m = TileMath.project(p)
            var best: Int?, bd = Double.infinity
            for i in cams.indices {
                let d = ((merc[i].x - m.x) * (merc[i].x - m.x) + (merc[i].y - m.y) * (merc[i].y - m.y)).squareRoot()
                if d <= maxD, d < bd { bd = d; best = i }
            }
            let got = index.nearest(to: p, maxWorldDistance: maxD)
            XCTAssertEqual(got, best)
            if got != nil { hits += 1 }
        }
        XCTAssertGreaterThan(hits, 20)
        XCTAssertNil(index.nearest(to: LonLat(lon: 0, lat: 0), maxWorldDistance: 0.001))
        XCTAssertNil(index.nearest(to: LonLat(lon: .nan, lat: 0), maxWorldDistance: 1))
        XCTAssertNil(CameraIndex([]).nearest(to: LonLat(lon: 0, lat: 0), maxWorldDistance: 1))
        // Exact hit with zero distance.
        XCTAssertEqual(index.nearest(to: cams[5].coordinate, maxWorldDistance: 0), 5)
    }

    func testClusters() {
        func cam(_ id: Int64, _ lon: Double, _ lat: Double) -> ALPRCamera {
            ALPRCamera(id: .node(id), coordinate: LonLat(lon: lon, lat: lat), directions: [], vendor: .flock, operatorName: nil, mount: nil, zone: nil, lastEdited: nil)
        }
        // Three cameras within ~10 m, one far away.
        let cams = [cam(1, -71.4000, 41.8000), cam(2, -71.4001, 41.8001), cam(3, -71.4002, 41.8000), cam(4, -71.0, 42.5)]
        let index = CameraIndex(cams)
        let world = BBox(west: -180, south: -85, east: 180, north: 85)
        let coarse = index.clusters(world, cellWorld: 1.0 / 256)     // ~z8 cells: first three merge
        XCTAssertEqual(coarse.map(\.count).sorted(), [1, 3])
        let big = coarse.first { $0.count == 3 }!
        XCTAssertEqual(big.representative, 0)
        XCTAssertEqual(big.center.lon, -71.4001, accuracy: 1e-4)
        XCTAssertEqual(big.center.lat, 41.8000333, accuracy: 1e-4)
        let single = coarse.first { $0.count == 1 }!
        XCTAssertEqual(single.representative, 3)
        XCTAssertEqual(single.center, cams[3].coordinate)
        // Tiny cells separate everything; degenerate cell sizes never trap.
        XCTAssertEqual(index.clusters(world, cellWorld: 1e-7).count, 4)
        XCTAssertEqual(index.clusters(world, cellWorld: 0).count, 4)
        XCTAssertEqual(index.clusters(world, cellWorld: .nan).count, 4)
        // Total count is conserved on a larger random set, and the box restricts membership.
        let many = CameraIndex(alprTestCameras(5_000, seed: 3))
        XCTAssertEqual(many.clusters(world, cellWorld: 0.01).map(\.count).reduce(0, +), 5_000)
        let box = BBox(west: -100, south: 30, east: -90, north: 40)
        XCTAssertEqual(many.clusters(box, cellWorld: 0.01).map(\.count).reduce(0, +), many.query(box).count)
    }

    func testBuildPerformance150k() {
        let cams = alprTestCameras(150_000, seed: 4)
        var built = 0
        measure {
            built = CameraIndex(cams).cameras.count
        }
        XCTAssertEqual(built, 150_000)
        let t0 = Date()
        _ = CameraIndex(cams)
        let dt = Date().timeIntervalSince(t0)
        print("CameraIndex build 150k: \(String(format: "%.3f", dt)) s")
        XCTAssertLessThan(dt, 3.0)    // target < 1 s on release; debug builds are slower
    }
}
