import XCTest
import simd
@testable import GridCore

/// Small deterministic RNG so fuzz runs are reproducible.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

final class MapsMVTTests: XCTestCase {
    typealias P = SIMD2<Int32>
    private func pt(_ x: Int32, _ y: Int32) -> P { P(x, y) }

    private func decode(_ layers: [MVTTestEncoder.Layer], only: Set<String>? = nil, limits: MVTLimits = .init()) throws -> MVTTile {
        try MVTDecoder.decode(MVTTestEncoder.encode(layers), layers: only, limits: limits)
    }

    private let square: [P] = [P(100, 100), P(900, 100), P(900, 900), P(100, 900)]

    // MARK: Round trips

    func testPointLinePolygonRoundTrip() throws {
        let tile = try decode([
            .init(name: "place", features: [MVTTestEncoder.point([pt(10, 20), pt(30, 40)], tags: ["name": .string("A")], id: 7)]),
            .init(name: "transportation", features: [MVTTestEncoder.line([[pt(0, 0), pt(100, 0), pt(100, 100)], [pt(5, 5), pt(6, 6)]], tags: ["class": .string("minor")])]),
            .init(name: "water", extent: 8192, features: [MVTTestEncoder.polygon([[square]])]),
        ])
        XCTAssertEqual(tile.layers.map(\.name), ["place", "transportation", "water"])
        XCTAssertEqual(tile.layer("place")?.features[0].geometry, .points([pt(10, 20), pt(30, 40)]))
        XCTAssertEqual(tile.layer("place")?.features[0].id, 7)
        XCTAssertEqual(tile.layer("place")?.features[0].tags["name"], .string("A"))
        XCTAssertEqual(tile.layer("transportation")?.features[0].geometry,
                       .lines([[pt(0, 0), pt(100, 0), pt(100, 100)], [pt(5, 5), pt(6, 6)]]))
        XCTAssertEqual(tile.layer("water")?.extent, 8192)
        XCTAssertEqual(tile.layer("place")?.extent, 4096)
        guard case .polygons(let polys)? = tile.layer("water")?.features[0].geometry else { return XCTFail("polygon") }
        XCTAssertEqual(polys.count, 1)
        XCTAssertEqual(polys[0].count, 1)
        XCTAssertEqual(Set(polys[0][0]), Set(square))
        XCTAssertGreaterThan(MVTTestEncoder.shoelace(polys[0][0]), 0)
    }

    func testAllValueTypes() throws {
        var f = MVTTestEncoder.point([pt(1, 1)])
        f.tags = [("s", .string("héllo")), ("f", .float(1.5)), ("d", .double(-2.25)), ("i", .int(-5)), ("u", .uint(42)),
                  ("sn", .sint(-77)), ("bt", .bool(true)), ("bf", .bool(false)), ("big", .uint(UInt64.max))]
        let tags = try decode([.init(name: "x", features: [f])]).layers[0].features[0].tags
        XCTAssertEqual(tags["s"], .string("héllo"))
        XCTAssertEqual(tags["f"], .double(1.5))
        XCTAssertEqual(tags["d"], .double(-2.25))
        XCTAssertEqual(tags["i"], .int(-5))
        XCTAssertEqual(tags["u"], .int(42))
        XCTAssertEqual(tags["sn"], .int(-77))
        XCTAssertEqual(tags["bt"], .bool(true))
        XCTAssertEqual(tags["bf"], .bool(false))
        XCTAssertEqual(tags["big"], .double(Double(UInt64.max)))
    }

    // MARK: Polygons

    func testHoleBelongsToPrecedingExterior() throws {
        let hole: [P] = [P(300, 300), P(300, 400), P(400, 400), P(400, 300)]
        let second: [P] = [P(2000, 100), P(3000, 100), P(3000, 900), P(2000, 900)]
        let tile = try decode([.init(name: "w", features: [MVTTestEncoder.polygon([[square, hole], [second]])])])
        guard case .polygons(let polys) = tile.layers[0].features[0].geometry else { return XCTFail() }
        XCTAssertEqual(polys.count, 2)
        XCTAssertEqual(polys[0].count, 2)
        XCTAssertLessThan(MVTTestEncoder.shoelace(polys[0][1]), 0)
        XCTAssertEqual(polys[1].count, 1)
    }

    func testHoleBeforeExteriorIsDropped() throws {
        let hole: [P] = [P(300, 300), P(300, 400), P(400, 400), P(400, 300)]   // negative winding
        XCTAssertLessThan(MVTTestEncoder.shoelace(hole), 0)
        let f = MVTTestEncoder.polygon([[hole], [square]], autoWind: false)
        let tile = try decode([.init(name: "w", features: [f])])
        guard case .polygons(let polys) = tile.layers[0].features[0].geometry else { return XCTFail() }
        XCTAssertEqual(polys.count, 1)
        XCTAssertEqual(polys[0].count, 1)
        XCTAssertEqual(Set(polys[0][0]), Set(square))
    }

    func testDegenerateRingsDropped() throws {
        let two: [P] = [P(0, 0), P(10, 0)]
        let collinear: [P] = [P(0, 0), P(10, 0), P(20, 0)]
        let dup: [P] = [P(0, 0), P(0, 0), P(10, 0), P(10, 0), P(10, 10), P(0, 10), P(0, 10)]
        let tile = try decode([.init(name: "w", features: [
            MVTTestEncoder.polygon([[two]], autoWind: false),
            MVTTestEncoder.polygon([[collinear]], autoWind: false),
            MVTTestEncoder.polygon([[dup]]),
        ])])
        XCTAssertEqual(tile.layers[0].features.count, 1)
        guard case .polygons(let polys) = tile.layers[0].features[0].geometry else { return XCTFail() }
        XCTAssertEqual(polys[0][0].count, 4, "duplicate consecutive points removed")
    }

    func testLineDedupeAndShortLinesDropped() throws {
        let tile = try decode([.init(name: "t", features: [
            MVTTestEncoder.line([[pt(1, 1), pt(1, 1), pt(5, 5), pt(5, 5)], [pt(9, 9), pt(9, 9)]]),
        ])])
        XCTAssertEqual(tile.layers[0].features[0].geometry, .lines([[pt(1, 1), pt(5, 5)]]))
    }

    func testCoordinatesClampedToTwiceExtent() throws {
        let tile = try decode([.init(name: "t", features: [MVTTestEncoder.point([pt(1_000_000, -1_000_000), pt(5000, -3000)])])])
        XCTAssertEqual(tile.layers[0].features[0].geometry, .points([pt(8192, -8192), pt(5000, -3000)]))
    }

    // MARK: Layer selection and limits

    func testUnwantedLayersAreSkippedWithoutParsing() throws {
        // The unwanted layer has a corrupt feature; skipping it must not even look at that.
        var bad = MVTTestEncoder.Layer(name: "poi", features: [MVTTestEncoder.point([pt(1, 1)])])
        bad.features[0].geometry = [0xFFFF_FFFF, 3, 3]
        var data = MVTTestEncoder.encode([bad, .init(name: "water", features: [MVTTestEncoder.polygon([[square]])])])
        let tile = try MVTDecoder.decode(data, layers: ["water"])
        XCTAssertEqual(tile.layers.map(\.name), ["water"])
        // Same data, all layers wanted: the corrupt feature is dropped but nothing throws.
        let all = try MVTDecoder.decode(data)
        XCTAssertEqual(all.layers.count, 2)
        XCTAssertEqual(all.layer("poi")?.features.count, 0)
        data.removeAll()
    }

    func testExtentValidation() throws {
        let f = [MVTTestEncoder.point([pt(1, 1)])]
        XCTAssertEqual(try decode([.init(name: "a", extent: 0, features: f), .init(name: "b", features: f)]).layers.map(\.name), ["b"])
        XCTAssertEqual(try decode([.init(name: "a", extent: 70_000, features: f)]).layers.count, 0)
        XCTAssertEqual(try decode([.init(name: "a", extent: 65_536, features: f)]).layers.count, 1)
        var noExtent = MVTTestEncoder.Layer(name: "a", features: f)
        noExtent.writeExtent = false
        XCTAssertEqual(try decode([noExtent]).layers.first?.extent, 4096, "default extent")
    }

    func testLimits() throws {
        let f = MVTTestEncoder.point([pt(1, 1)])
        var l = MVTLimits()
        l.maxLayers = 2
        XCTAssertThrowsError(try decode([.init(name: "a", features: [f]), .init(name: "b", features: [f]), .init(name: "c", features: [f])], limits: l))
        l = MVTLimits(); l.maxBytes = 10
        XCTAssertThrowsError(try decode([.init(name: "a", features: [f])], limits: l)) { XCTAssertEqual($0 as? MVTError, .tooLarge) }
        l = MVTLimits(); l.maxFeaturesPerLayer = 2
        XCTAssertThrowsError(try decode([.init(name: "a", features: [f, f, f])], limits: l))
        l = MVTLimits(); l.maxGeometryInts = 5
        XCTAssertThrowsError(try decode([.init(name: "a", features: [MVTTestEncoder.line([[pt(0, 0), pt(1, 1), pt(2, 2), pt(3, 3)]])])], limits: l))
        l = MVTLimits(); l.maxKeysOrValuesPerLayer = 1
        var g = f; g.tags = [("a", .int(1)), ("b", .int(2))]
        XCTAssertThrowsError(try decode([.init(name: "a", features: [g])], limits: l))
        // maxVerticesPerFeature skips only the large feature.
        l = MVTLimits(); l.maxVerticesPerFeature = 3
        let tile = try decode([.init(name: "a", features: [MVTTestEncoder.line([[pt(0, 0), pt(1, 1), pt(2, 2), pt(3, 3)]]), f])], limits: l)
        XCTAssertEqual(tile.layers[0].features.count, 1)
        // maxStringBytes: an over-long value is dropped, the feature survives.
        l = MVTLimits(); l.maxStringBytes = 4
        var s = f; s.tags = [("k", .string("toolongvalue")), ("j", .string("ok"))]
        let t2 = try decode([.init(name: "a", features: [s])], limits: l)
        XCTAssertNil(t2.layers[0].features[0].tags["k"])
        XCTAssertEqual(t2.layers[0].features[0].tags["j"], .string("ok"))
        // A layer whose name is too long is skipped.
        XCTAssertEqual(try decode([.init(name: "abcdefgh", features: [f])], limits: l).layers.count, 0)
    }

    // MARK: Malformed

    func testMalformedFeaturesAreDropped() throws {
        var odd = MVTTestEncoder.point([pt(1, 1)]); odd.rawTagInts = [0]
        var oob = MVTTestEncoder.point([pt(1, 1)]); oob.rawTagInts = [5, 5]
        var overrun = MVTTestEncoder.point([pt(1, 1)]); overrun.geometry = [UInt32(1000 << 3 | 1), 2, 2]
        var badCmd = MVTTestEncoder.point([pt(1, 1)]); badCmd.geometry = [UInt32(3), 2, 2]
        var badType = MVTTestEncoder.point([pt(1, 1)]); badType.type = 9
        var lineNoMove = MVTTestEncoder.line([[pt(0, 0), pt(5, 5)]]); lineNoMove.geometry = [UInt32(2 << 3 | 2), 2, 2, 2, 2]
        let ok = MVTTestEncoder.point([pt(3, 3)])
        let tile = try decode([.init(name: "a", features: [odd, oob, overrun, badCmd, badType, lineNoMove, ok])])
        XCTAssertEqual(tile.layers[0].features.count, 1)
        XCTAssertEqual(tile.layers[0].features[0].geometry, .points([pt(3, 3)]))
    }

    func testTruncatedAndGarbageInputThrows() throws {
        let data = MVTTestEncoder.encode([.init(name: "water", features: [MVTTestEncoder.polygon([[square]], tags: ["class": .string("lake")])])])
        XCTAssertNoThrow(try MVTDecoder.decode(data))
        for cut in 1..<data.count where cut != data.count {
            // Must not trap; most cuts throw, a few land on a field boundary and decode.
            _ = try? MVTDecoder.decode(data.prefix(cut))
        }
        XCTAssertThrowsError(try MVTDecoder.decode(Data([0x1a])))                   // field 3, no length
        XCTAssertThrowsError(try MVTDecoder.decode(Data([0x1a, 0x05, 0x01])))       // length overruns
        XCTAssertThrowsError(try MVTDecoder.decode(Data(repeating: 0xff, count: 12))) // varint longer than 10 bytes
        XCTAssertThrowsError(try MVTDecoder.decode(Data([0x0b])))                   // wire type 3 (group) is rejected
        XCTAssertThrowsError(try MVTDecoder.decode(Data([0x00, 0x01])))             // field 0
        XCTAssertNoThrow(try MVTDecoder.decode(Data()))
        XCTAssertNoThrow(try MVTDecoder.decode(Data([0x08, 0x01])))                 // unknown varint field skipped
        XCTAssertNoThrow(try MVTDecoder.decode(Data([0x09] + [UInt8](repeating: 0, count: 8)))) // 64-bit field skipped
        XCTAssertNoThrow(try MVTDecoder.decode(Data([0x0d, 0, 0, 0, 0])))           // 32-bit field skipped
    }

    func testInvalidUTF8NameSkipsLayer() throws {
        var layer = Data()
        MVTTestEncoder.appendLen(&layer, field: 1, Data([0xff, 0xfe, 0x80]))
        var tile = Data()
        MVTTestEncoder.appendLen(&tile, field: 3, layer)
        XCTAssertEqual(try MVTDecoder.decode(tile).layers.count, 0)
    }

    func testBadStringValueDropsOnlyThatTag() throws {
        // Hand-build a layer with a value holding invalid UTF-8.
        var value = Data()
        MVTTestEncoder.appendLen(&value, field: 1, Data([0xc3, 0x28]))
        var feature = Data()
        MVTTestEncoder.appendLen(&feature, field: 2, MVTTestEncoder.packed([0, 0]))
        MVTTestEncoder.appendVarintField(&feature, field: 3, 1)
        MVTTestEncoder.appendLen(&feature, field: 4, MVTTestEncoder.packed([9, 2, 2]))
        var layer = Data()
        MVTTestEncoder.appendLen(&layer, field: 1, Data("a".utf8))
        MVTTestEncoder.appendLen(&layer, field: 2, feature)
        MVTTestEncoder.appendLen(&layer, field: 3, Data("k".utf8))
        MVTTestEncoder.appendLen(&layer, field: 4, value)
        var tile = Data()
        MVTTestEncoder.appendLen(&tile, field: 3, layer)
        let out = try MVTDecoder.decode(tile)
        XCTAssertEqual(out.layers[0].features.count, 1)
        XCTAssertTrue(out.layers[0].features[0].tags.isEmpty)
    }

    // MARK: Fuzz

    private func fuzzSeedTile() -> Data {
        var rng = SplitMix64(seed: 99)
        var feats: [MVTTestEncoder.Feature] = []
        for i in 0..<20 {
            let x = Int32.random(in: 0..<3000, using: &rng), y = Int32.random(in: 0..<3000, using: &rng)
            feats.append(MVTTestEncoder.polygon([[[P(x, y), P(x + 200, y), P(x + 200, y + 150), P(x, y + 150)], [P(x + 50, y + 50), P(x + 50, y + 80), P(x + 90, y + 80)]]],
                                                tags: ["render_height": .double(Double(i)), "class": .string("residential"), "n": .bool(true)], id: UInt64(i)))
        }
        let roads = (0..<20).map { i in
            MVTTestEncoder.line([[P(0, Int32(i) * 100), P(2000, Int32(i) * 100 + 30), P(4000, Int32(i) * 100)]],
                                tags: ["class": .string("primary"), "brunnel": .string("bridge")])
        }
        var places = MVTTestEncoder.point([P(500, 500)], tags: ["class": .string("city"), "name": .string("Testville"), "rank": .int(3)])
        places.tags += [("f", .float(1.5)), ("u", .uint(7)), ("s", .sint(-3))]
        return MVTTestEncoder.encode([
            .init(name: "building", features: feats), .init(name: "transportation", features: roads), .init(name: "place", features: [places]),
            .init(name: "poi", features: [places]),
        ])
    }

    func testFuzzMutationsNeverTrap() {
        let seed = fuzzSeedTile()
        var rng = SplitMix64(seed: 0xC0FFEE)
        var decoded = 0, thrown = 0
        var limits = MVTLimits()
        limits.maxBytes = 1 << 20
        let iterations = 6000
        for n in 0..<iterations {
            var d = [UInt8](seed)
            switch n % 5 {
            case 0:   // truncate
                d.removeLast(Int.random(in: 0..<d.count, using: &rng))
            case 1:   // flip random bytes
                for _ in 0..<Int.random(in: 1...8, using: &rng) { d[Int.random(in: 0..<d.count, using: &rng)] ^= UInt8.random(in: 1...255, using: &rng) }
            case 2:   // inflate: write 0xff / 0x7f into bytes (turns lengths and counts huge)
                for _ in 0..<Int.random(in: 1...4, using: &rng) { d[Int.random(in: 0..<d.count, using: &rng)] = Bool.random(using: &rng) ? 0xff : 0x7f }
            case 3:   // insert random bytes
                for _ in 0..<Int.random(in: 1...6, using: &rng) { d.insert(UInt8.random(in: 0...255, using: &rng), at: Int.random(in: 0...d.count, using: &rng)) }
            default:  // delete a span
                let a = Int.random(in: 0..<d.count, using: &rng)
                d.removeSubrange(a..<min(d.count, a + Int.random(in: 1...30, using: &rng)))
            }
            do {
                let tile = try MVTDecoder.decode(Data(d), limits: limits)
                decoded += 1
                // Whatever decoded must also survive the builder.
                _ = TileGeometryBuilder.build(tile, id: TileID(z: 14, x: 0, y: 0))
            } catch {
                thrown += 1
            }
        }
        XCTAssertEqual(decoded + thrown, iterations)
        XCTAssertGreaterThan(decoded, 100)
        XCTAssertGreaterThan(thrown, 100)
    }

    func testFuzzRandomBytesNeverTrap() {
        var rng = SplitMix64(seed: 7)
        for _ in 0..<1500 {
            let n = Int.random(in: 0..<400, using: &rng)
            let d = Data((0..<n).map { _ in UInt8.random(in: 0...255, using: &rng) })
            _ = try? MVTDecoder.decode(d)
        }
    }
}
