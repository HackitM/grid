import XCTest
@testable import GridCore

final class MapsPackageTests: XCTestCase {
    func testRoundTrip10k() throws {
        let cams = alprTestCameras(10_000, seed: 11)
        let data = RegionPackage.encode(cams)
        let back = try RegionPackage.decode(data)
        XCTAssertEqual(back.count, cams.count)
        for (a, b) in zip(back, cams) {
            XCTAssertEqual(a.coordinate.lon, b.coordinate.lon, accuracy: 1e-9)
            XCTAssertEqual(a.coordinate.lat, b.coordinate.lat, accuracy: 1e-9)
            XCTAssertEqual(a.id, b.id); XCTAssertEqual(a.directions, b.directions); XCTAssertEqual(a.vendor, b.vendor)
            XCTAssertEqual(a.operatorName, b.operatorName); XCTAssertEqual(a.mount, b.mount)
            XCTAssertEqual(a.zone, b.zone); XCTAssertEqual(a.lastEdited, b.lastEdited)
        }
    }

    func testEmptyAndEdgeValues() throws {
        XCTAssertEqual(try RegionPackage.decode(RegionPackage.encode([])), [])
        let edge = ALPRCamera(id: .way(Int64.max), coordinate: LonLat(lon: -180, lat: 90), directions: [0, 359, 1, 2, 3, 4, 5, 6, 7, 8],
                              vendor: .other("Ünïcode 🚗"), operatorName: "", mount: "m", zone: nil,
                              lastEdited: Date(timeIntervalSince1970: -86_400))
        let back = try RegionPackage.decode(RegionPackage.encode([edge]))
        XCTAssertEqual(back.count, 1)
        XCTAssertEqual(back[0].directions, [0, 359, 1, 2, 3, 4, 5, 6])   // capped at 8
        XCTAssertEqual(back[0].vendor, .other("Ünïcode 🚗"))
        XCTAssertEqual(back[0].operatorName, "")
        XCTAssertEqual(back[0].id, .way(Int64.max))
        XCTAssertEqual(back[0].coordinate, LonLat(lon: -180, lat: 90))
        XCTAssertEqual(back[0].lastEdited, Date(timeIntervalSince1970: -86_400))
    }

    func testHeaderLayout() {
        let d = [UInt8](RegionPackage.encode(alprTestCameras(3, seed: 5)))
        XCTAssertEqual(Array(d[0..<4]), Array("GALP".utf8))
        XCTAssertEqual(Array(d[4..<8]), [1, 0, 0, 0])
        XCTAssertEqual(Array(d[8..<12]), [3, 0, 0, 0])
    }

    func testRejectsEverySingleByteTruncation() {
        let data = RegionPackage.encode(alprTestCameras(40, seed: 12))
        XCTAssertGreaterThan(data.count, 500)
        for cut in 0..<data.count {
            XCTAssertThrowsError(try RegionPackage.decode(data.prefix(cut)), "cut at \(cut)")
        }
    }

    func testRejectsTrailingGarbage() {
        var data = RegionPackage.encode(alprTestCameras(10, seed: 13))
        data.append(0)
        XCTAssertThrowsError(try RegionPackage.decode(data))
    }

    func testRejectsBadHeaderAndCounts() {
        let good = [UInt8](RegionPackage.encode(alprTestCameras(5, seed: 14)))
        func mutated(_ f: (inout [UInt8]) -> Void) -> Data { var b = good; f(&b); return Data(b) }
        XCTAssertThrowsError(try RegionPackage.decode(mutated { $0[0] = 0x58 }))
        XCTAssertThrowsError(try RegionPackage.decode(mutated { $0[4] = 2 }))
        XCTAssertThrowsError(try RegionPackage.decode(mutated { $0[8] = 6 }))          // count too big
        XCTAssertThrowsError(try RegionPackage.decode(mutated { $0[8] = 4 }))          // count too small -> garbage/trailing
        XCTAssertThrowsError(try RegionPackage.decode(mutated { $0[11] = 0xFF }))      // huge count
        XCTAssertThrowsError(try RegionPackage.decode(Data(good), maxCount: 4)) { XCTAssertEqual($0 as? ALPRParseError, .tooLarge) }
        XCTAssertThrowsError(try RegionPackage.decode(Data()))
    }

    func testRejectsCorruptedIndicesAndFields() throws {
        // One camera with known strings so offsets are predictable.
        let cam = ALPRCamera(id: .node(5), coordinate: LonLat(lon: 1, lat: 2), directions: [90], vendor: .other("V"),
                             operatorName: "op", mount: nil, zone: nil, lastEdited: nil)
        let good = [UInt8](RegionPackage.encode([cam]))
        XCTAssertEqual(try RegionPackage.decode(Data(good)), [cam])
        // Layout: 12 header | lat4 lon4 type1 id8 vendor1 ndirs1 dir2 | op4 mount4 zone4 other4 | edited8 | table
        let fixed = 12 + 4 + 4 + 1 + 8 + 1 + 1 + 2
        let opIdx = fixed, otherIdx = fixed + 12, typeOff = 12 + 8, vendorOff = 12 + 8 + 1 + 8, ndirOff = vendorOff + 1, dirOff = ndirOff + 1
        func bad(_ off: Int, _ v: UInt8, _ why: String) {
            var b = good; b[off] = v
            XCTAssertThrowsError(try RegionPackage.decode(Data(b)), why)
        }
        bad(opIdx, 9, "string index out of range")
        bad(opIdx + 3, 0x7F, "huge string index")
        bad(otherIdx, 0xFF, "other vendor without string")     // 0x000000FF out of range
        bad(typeOff, 2, "osm type")
        bad(vendorOff, 10, "vendor code")
        bad(ndirOff, 9, "direction count")
        bad(ndirOff, 200, "direction count huge")
        bad(dirOff + 1, 0x7F, "direction >= 360")
        // Corrupt the string table's length field.
        var b = good
        let tableStart = fixed + 16 + 8
        b[tableStart + 4] = 0xFF; b[tableStart + 5] = 0xFF; b[tableStart + 6] = 0xFF; b[tableStart + 7] = 0x7F
        XCTAssertThrowsError(try RegionPackage.decode(Data(b)))
        // Invalid UTF-8 in a string.
        var u = good
        u[u.count - 1] = 0xFF
        XCTAssertThrowsError(try RegionPackage.decode(Data(u)))
        // Latitude out of range.
        var l = good
        l[12 + 3] = 0x7F
        XCTAssertThrowsError(try RegionPackage.decode(Data(l)))
    }

    func testFuzzNeverTraps() {
        let base = [UInt8](RegionPackage.encode(alprTestCameras(60, seed: 15)))
        var rng = ALPRTestRNG(seed: 2024)
        var accepted = 0
        for i in 0..<4000 {
            var b = base
            switch i % 5 {
            case 0: b[Int(rng.next() % UInt64(b.count))] ^= UInt8(truncatingIfNeeded: rng.next() | 1)
            case 1: b = Array(b.prefix(Int(rng.next() % UInt64(b.count))))
            case 2: for _ in 0..<6 { b[Int(rng.next() % UInt64(b.count))] = UInt8(truncatingIfNeeded: rng.next()) }
            case 3: b.append(contentsOf: (0..<Int(rng.next() % 12) + 1).map { _ in UInt8(truncatingIfNeeded: rng.next()) })
            default:
                // Inflate a 32-bit field (counts and lengths) near the start or at a random place.
                let o = i % 10 == 4 ? 8 : Int(rng.next() % UInt64(b.count - 4))
                for k in 0..<4 { b[o + k] = 0xFF }
            }
            if (try? RegionPackage.decode(Data(b))) != nil { accepted += 1 }
        }
        XCTAssertLessThan(accepted, 4000)
        // Pure random bytes of assorted sizes.
        for n in [0, 1, 11, 12, 13, 64, 1000] {
            _ = try? RegionPackage.decode(Data((0..<n).map { _ in UInt8(truncatingIfNeeded: rng.next()) }))
        }
    }

    func testEncodeDecodePerformance() {
        let cams = alprTestCameras(50_000, seed: 16)
        let data = RegionPackage.encode(cams)
        measure { _ = try? RegionPackage.decode(data) }
        let t0 = Date()
        _ = RegionPackage.encode(cams)
        print("RegionPackage encode 50k: \(String(format: "%.3f", Date().timeIntervalSince(t0))) s")
    }
}
