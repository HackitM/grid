import XCTest
@testable import GridCore

final class MapsALPRTests: XCTestCase {
    // MARK: directions

    func testDirectionTable() {
        let table: [(String, [UInt16])] = [
            ("0", [0]), ("360", [0]), ("-45", [315]), ("12.5", [13]), ("NE;SW", [45, 225]),
            ("north", [0]), ("North", [0]), ("SOUTHWEST", [225]), ("NNE", [23]), ("north-northeast", [23]),
            ("45;225", [45, 225]), ("45-90", [68]), ("350-10", [0]), ("", []), ("abc", []), ("nan", []),
            ("inf", []), ("45;;45;45", [45]), ("90; garbage ;180", [90, 180]), ("725", [5]), ("1e400", []),
            ("-", []), ("--5", []), ("w", [270]), ("E", [90]),
        ]
        for (raw, want) in table { XCTAssertEqual(OSMSurveillance.directions(raw), want, "input \(raw)") }
    }

    func testDirectionsCappedAtEightAndDeduplicated() {
        let raw = (0..<20).map { String($0 * 10) }.joined(separator: ";")
        XCTAssertEqual(OSMSurveillance.directions(raw), [0, 10, 20, 30, 40, 50, 60, 70])
        XCTAssertTrue(OSMSurveillance.directions(String(repeating: "x;", count: 100_000)).isEmpty)
    }

    // MARK: isALPR

    func testALPRMatching() {
        XCTAssertTrue(OSMSurveillance.isALPR(["man_made": "surveillance", "surveillance:type": "ALPR"]))
        XCTAssertTrue(OSMSurveillance.isALPR(["man_made": "surveillance", "surveillance:type": "camera; alpr "]))
        XCTAssertFalse(OSMSurveillance.isALPR(["man_made": "surveillance", "surveillance:type": "alprx"]))
        XCTAssertFalse(OSMSurveillance.isALPR(["man_made": "surveillance", "surveillance:type": "camera"]))
        XCTAssertFalse(OSMSurveillance.isALPR(["surveillance:type": "ALPR"]))
        XCTAssertFalse(OSMSurveillance.isALPR(["man_made": "tower", "surveillance:type": "ALPR"]))
        XCTAssertFalse(OSMSurveillance.isALPR([:]))
    }

    // MARK: vendor

    func testVendorTable() {
        XCTAssertEqual(OSMSurveillance.vendor(["manufacturer:wikidata": "Q108485435"]), .flock)
        XCTAssertEqual(OSMSurveillance.vendor(["manufacturer:wikidata": "q634815"]), .motorola)
        XCTAssertEqual(OSMSurveillance.vendor(["manufacturer:wikidata": "Q30295174"]), .genetec)
        XCTAssertEqual(OSMSurveillance.vendor(["manufacturer:wikidata": "Q910379"]), .leonardo)
        XCTAssertEqual(OSMSurveillance.vendor(["manufacturer:wikidata": "Q2347731"]), .axis)
        XCTAssertEqual(OSMSurveillance.vendor(["manufacturer": "Flock Safety"]), .flock)
        XCTAssertEqual(OSMSurveillance.vendor(["brand": "FLOCK"]), .flock)
        XCTAssertEqual(OSMSurveillance.vendor(["brand": "Rekor Systems"]), .rekor)
        XCTAssertEqual(OSMSurveillance.vendor(["manufacturer": "Axon"]), .axon)
        XCTAssertEqual(OSMSurveillance.vendor(["manufacturer": "Neology Inc."]), .neology)
        XCTAssertEqual(OSMSurveillance.vendor(["manufacturer": "Axis Communications"]), .axis)
        XCTAssertEqual(OSMSurveillance.vendor(["manufacturer": "Taxonomy Corp"]), .other("Taxonomy Corp"))
        XCTAssertEqual(OSMSurveillance.vendor(["manufacturer": "  Acme  "]), .other("Acme"))
        XCTAssertEqual(OSMSurveillance.vendor(["manufacturer": "  ", "brand": ""]), .unknown)
        XCTAssertEqual(OSMSurveillance.vendor([:]), .unknown)
        // A known brand beats an unknown manufacturer string; wikidata beats names.
        XCTAssertEqual(OSMSurveillance.vendor(["manufacturer": "Acme", "brand": "Flock Safety"]), .flock)
        XCTAssertEqual(OSMSurveillance.vendor(["manufacturer:wikidata": "Q634815", "manufacturer": "Flock"]), .motorola)
        XCTAssertEqual(OSMSurveillance.vendor(brand: nil), .unknown)
        XCTAssertEqual(OSMSurveillance.vendor(brand: String(repeating: "z", count: 200)), .other(String(repeating: "z", count: 60)))
    }

    // MARK: camera

    func testCameraBuilding() {
        let tags = ["man_made": "surveillance", "surveillance:type": "ALPR", "direction": "NE;180", "directions-x": "1",
                    "manufacturer": "Flock Safety", "operator": "  Town PD  ", "camera:mount": "pole",
                    "surveillance:zone": "traffic"]
        let d = Date(timeIntervalSince1970: 1_700_000_000)
        let c = OSMSurveillance.camera(id: .node(7), at: LonLat(lon: -71.4, lat: 41.8), tags: tags, edited: d)
        XCTAssertEqual(c?.directions, [45, 180])
        XCTAssertEqual(c?.vendor, .flock)
        XCTAssertEqual(c?.operatorName, "Town PD")
        XCTAssertEqual(c?.mount, "pole")
        XCTAssertEqual(c?.zone, "traffic")
        XCTAssertEqual(c?.lastEdited, d)
        XCTAssertEqual(c?.id, .node(7))
    }

    func testCameraRejectsBadInput() {
        let ok = ["man_made": "surveillance", "surveillance:type": "alpr"]
        XCTAssertNil(OSMSurveillance.camera(id: .node(1), at: LonLat(lon: .nan, lat: 0), tags: ok, edited: nil))
        XCTAssertNil(OSMSurveillance.camera(id: .node(1), at: LonLat(lon: 0, lat: 91), tags: ok, edited: nil))
        XCTAssertNil(OSMSurveillance.camera(id: .node(1), at: LonLat(lon: 200, lat: 0), tags: ok, edited: nil))
        XCTAssertNil(OSMSurveillance.camera(id: .node(1), at: LonLat(lon: 0, lat: 0), tags: ["man_made": "surveillance"], edited: nil))
    }

    func testStringCaps() {
        var tags = ["man_made": "surveillance", "surveillance:type": "alpr"]
        tags["operator"] = String(repeating: "o", count: 500)
        tags["camera:mount"] = "  " + String(repeating: "m", count: 500)
        tags["surveillance:zone"] = "   "
        let c = OSMSurveillance.camera(id: .way(2), at: LonLat(lon: 1, lat: 1), tags: tags, edited: nil)
        XCTAssertEqual(c?.operatorName?.count, 120)
        XCTAssertEqual(c?.mount?.count, 120)
        XCTAssertNil(c?.zone)
    }

    // MARK: ISO 8601

    func testISO8601() {
        XCTAssertEqual(OSMSurveillance.parseISO8601("1970-01-01T00:00:00Z")?.timeIntervalSince1970, 0)
        XCTAssertEqual(OSMSurveillance.parseISO8601("2023-11-14T22:13:20Z")?.timeIntervalSince1970, 1_700_000_000)
        XCTAssertEqual(OSMSurveillance.parseISO8601("2023-11-14T22:13:20.500Z")?.timeIntervalSince1970, 1_700_000_000.5)
        XCTAssertEqual(OSMSurveillance.parseISO8601("2023-11-15T00:13:20+02:00")?.timeIntervalSince1970, 1_700_000_000)
        XCTAssertEqual(OSMSurveillance.parseISO8601("2024-02-29T12:00:00Z")?.timeIntervalSince1970, 1_709_208_000)
        for bad in ["", "garbage", "2023-13-14T22:13:20Z", "2023-11-14T25:13:20Z", "2023-11-14", "2023-11-14T22:13:20Zjunk", "99999-11-14T22:13:20Z"] {
            XCTAssertNil(OSMSurveillance.parseISO8601(bad), bad)
        }
    }

    // MARK: FetchPolicy

    func testBackoffDoublesAndResets() {
        var p = FetchPolicy(base: 30, max: 100, dailyBudget: 60)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertTrue(p.canRequest(now: t0))
        p.failed(status: 429, now: t0)
        XCTAssertEqual(p.retryAt, t0.addingTimeInterval(30))
        XCTAssertFalse(p.canRequest(now: t0.addingTimeInterval(29)))
        XCTAssertTrue(p.canRequest(now: t0.addingTimeInterval(30)))
        p.failed(status: 504, now: t0.addingTimeInterval(30))
        XCTAssertEqual(p.retryAt, t0.addingTimeInterval(30 + 60))
        p.failed(status: 406, now: t0.addingTimeInterval(100))
        XCTAssertEqual(p.retryAt, t0.addingTimeInterval(200))     // capped at 100
        p.failed(status: 429, now: t0.addingTimeInterval(200))
        XCTAssertEqual(p.retryAt, t0.addingTimeInterval(300))
        p.succeeded(now: t0.addingTimeInterval(300))
        XCTAssertNil(p.retryAt)
        p.failed(status: 429, now: t0.addingTimeInterval(301))
        XCTAssertEqual(p.retryAt, t0.addingTimeInterval(331))     // back to base
    }

    func testOtherFailuresCountOnceWithoutBackoff() {
        var p = FetchPolicy(base: 30, max: 600, dailyBudget: 3)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        p.failed(status: 500, now: t0)
        XCTAssertNil(p.retryAt)
        XCTAssertEqual(p.usedToday(now: t0), 1)
        p.failed(status: 400, now: t0)
        p.succeeded(now: t0)
        XCTAssertFalse(p.canRequest(now: t0))
    }

    func testBudgetResetsOnUTCDay() {
        var p = FetchPolicy(base: 30, max: 600, dailyBudget: 2)
        let dayStart = Date(timeIntervalSince1970: 19_700 * 86_400)
        p.succeeded(now: dayStart.addingTimeInterval(86_390 - 10))
        p.succeeded(now: dayStart.addingTimeInterval(86_390))
        XCTAssertFalse(p.canRequest(now: dayStart.addingTimeInterval(86_399)))
        XCTAssertTrue(p.canRequest(now: dayStart.addingTimeInterval(86_400)))
        p.succeeded(now: dayStart.addingTimeInterval(86_400))
        XCTAssertEqual(p.usedToday(now: dayStart.addingTimeInterval(86_400)), 1)
    }

    func testFetchPolicyCodableRoundTrip() throws {
        var p = FetchPolicy()
        p.failed(status: 429, now: Date(timeIntervalSince1970: 1_700_000_000))
        let d = try JSONEncoder().encode(p)
        XCTAssertEqual(try JSONDecoder().decode(FetchPolicy.self, from: d), p)
    }
}
