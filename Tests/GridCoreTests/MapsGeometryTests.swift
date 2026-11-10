import XCTest
import simd
@testable import GridCore

final class MapsGeometryTests: XCTestCase {
    typealias P = SIMD2<Int32>
    private let tid = TileID(z: 14, x: 3, y: 5)

    private func build(_ layers: [MVTTestEncoder.Layer]) throws -> TileGeometry {
        let data = MVTTestEncoder.encode(layers)
        let tile = try MVTDecoder.decode(data, layers: OpenMapTilesSchema.layers)
        return TileGeometryBuilder.build(tile, id: tid)
    }

    private func rect(_ x: Int32, _ y: Int32, _ w: Int32, _ h: Int32) -> [P] { [P(x, y), P(x + w, y), P(x + w, y + h), P(x, y + h)] }

    // MARK: Fills

    func testWaterPolygonWithHoleIsNormalisedAndTriangulated() throws {
        let hole = rect(1024, 1024, 1024, 1024)
        let g = try build([.init(name: "water", features: [MVTTestEncoder.polygon([[rect(0, 0, 4096, 4096), hole]], tags: ["class": .string("lake")])])])
        XCTAssertEqual(g.id, tid)
        XCTAssertEqual(g.fills.count, 1)
        let f = g.fills[0]
        XCTAssertEqual(f.cls, .water)
        // Subdivided (edges ≤ 1/16 tile) so it can follow the terrain; the shape is unchanged.
        XCTAssertGreaterThanOrEqual(f.positions.count, 8)
        XCTAssertTrue(f.positions.allSatisfy { $0.x >= 0 && $0.x <= 1 && $0.y >= 0 && $0.y <= 1 })
        XCTAssertTrue(f.positions.contains(SIMD2<Float>(0.25, 0.25)))
        // Full tile minus a hole that spans a quarter of the width and height.
        XCTAssertEqual(MapsEarcutTests.triangleArea([f.positions], f.indices), 1 - 0.25 * 0.25, accuracy: 1e-4)
        // Only the island (hole) gets a shoreline; the outer ring runs along the tile border.
        XCTAssertEqual(g.lines.map(\.cls), [.water])
        XCTAssertTrue(g.lines[0].vertices.allSatisfy { $0.pos.x >= 0.24 && $0.pos.x <= 0.51 && $0.pos.y >= 0.24 && $0.pos.y <= 0.51 })
        XCTAssertNil(g.extrusion)
    }

    func testExtentIsUsedForNormalisation() throws {
        let g = try build([.init(name: "water", extent: 8192, features: [MVTTestEncoder.polygon([[rect(0, 0, 8192, 4096)]])])])
        XCTAssertEqual(g.fills[0].positions.map(\.y).max(), 0.5)
    }

    func testFillBatchesGroupByClassInRenderOrder() throws {
        let g = try build([
            .init(name: "park", features: [MVTTestEncoder.polygon([[rect(0, 0, 100, 100)]])]),
            .init(name: "water", features: [MVTTestEncoder.polygon([[rect(0, 0, 100, 100)]]), MVTTestEncoder.polygon([[rect(200, 0, 100, 100)]])]),
            .init(name: "landuse", features: [MVTTestEncoder.polygon([[rect(0, 0, 100, 100)]], tags: ["class": .string("industrial")])]),
        ])
        XCTAssertEqual(g.fills.map(\.cls), [.water, .landuse, .park])
        XCTAssertEqual(g.fills[0].positions.count, 8)
        XCTAssertEqual(g.fills[0].indices.count, 12)
        XCTAssertTrue(g.fills[0].indices.allSatisfy { $0 < 8 })
    }

    func testTransportationPolygonsAreDropped() throws {
        let g = try build([.init(name: "transportation", features: [MVTTestEncoder.polygon([[rect(0, 0, 100, 100)]], tags: ["class": .string("pedestrian")])])])
        XCTAssertTrue(g.fills.isEmpty)
        XCTAssertTrue(g.lines.isEmpty)
    }

    func testOversizedPolygonFeatureIsDropped() throws {
        let n = 100_100
        let ring = (0..<n).map { i -> P in
            let a = Double(i) * 2 * .pi / Double(n)
            return P(Int32(2048 + cos(a) * 2000), Int32(2048 + sin(a) * 2000))
        }
        // The decoder already refuses > maxVerticesPerFeature; the builder must cope with what it gets.
        let tile = MVTTile(layers: [MVTLayer(name: "water", extent: 4096, features: [MVTFeature(id: nil, tags: [:], geometry: .polygons([[ring]]))])])
        let g = TileGeometryBuilder.build(tile, id: tid)
        XCTAssertTrue(g.fills.isEmpty)
    }

    // MARK: Lines

    func testRoadsByClassWithTunnelAndBridgeFlags() throws {
        let l = [[P(0, 2048), P(4096, 2048)]]
        let g = try build([.init(name: "transportation", features: [
            MVTTestEncoder.line(l, tags: ["class": .string("motorway")]),
            MVTTestEncoder.line(l, tags: ["class": .string("minor"), "brunnel": .string("tunnel")]),
            MVTTestEncoder.line(l, tags: ["class": .string("minor"), "brunnel": .string("bridge")]),
            MVTTestEncoder.line(l, tags: ["class": .string("track")]),
            MVTTestEncoder.line(l, tags: ["class": .string("ferry")]),      // skipped in v1
            MVTTestEncoder.line(l, tags: ["class": .string("transit")]),    // skipped in v1
            MVTTestEncoder.line(l, tags: ["class": .string("nonsense")]),
            MVTTestEncoder.line(l, tags: [:]),
        ])])
        XCTAssertEqual(g.lines.map(\.cls), [.path, .minor, .motorway])
        let minor = g.lines.first { $0.cls == .minor }!
        // Two lines, each split into ≤ 1/32-tile segments (4 vertices per segment).
        XCTAssertEqual(minor.vertices.count % 4, 0)
        XCTAssertGreaterThanOrEqual(minor.vertices.count, 8)
        XCTAssertEqual(Set(minor.vertices.map(\.flags)), [LineVertex.tunnel, LineVertex.bridge])
        XCTAssertTrue(minor.vertices.allSatisfy { $0.cls == RenderClass.minor.rawValue })
        XCTAssertTrue(minor.vertices.allSatisfy { $0.pos.y == 0.5 && $0.pos.x >= 0 && $0.pos.x <= 1 })
        XCTAssertEqual(g.lines.first { $0.cls == .motorway }!.vertices.last!.along, 1, accuracy: 1e-6)
    }

    func testWaterwayBoundaryAndAeroway() throws {
        let l = [[P(0, 100), P(4096, 100)]]
        let g = try build([
            .init(name: "waterway", features: [MVTTestEncoder.line(l, tags: ["class": .string("river")]), MVTTestEncoder.line(l, tags: ["class": .string("dam")])]),
            .init(name: "boundary", features: [
                MVTTestEncoder.line(l, tags: ["admin_level": .int(2)]),
                MVTTestEncoder.line(l, tags: ["admin_level": .int(4)]),
                MVTTestEncoder.line(l, tags: ["admin_level": .int(6)]),                       // too fine
                MVTTestEncoder.line(l, tags: ["admin_level": .int(2), "maritime": .int(1)]),  // at sea
                MVTTestEncoder.line(l, tags: [:]),
            ]),
            .init(name: "aeroway", features: [
                MVTTestEncoder.line(l, tags: ["class": .string("runway")]),
                MVTTestEncoder.line(l, tags: ["class": .string("taxiway")]),
                MVTTestEncoder.line(l, tags: ["class": .string("gate")]),
                MVTTestEncoder.polygon([[rect(0, 0, 50, 50)]], tags: ["class": .string("runway")]),
                MVTTestEncoder.polygon([[rect(0, 0, 50, 50)]], tags: ["class": .string("apron")]),
            ]),
        ])
        XCTAssertEqual(g.lines.map(\.cls), [.waterway, .boundary, .aeroway])
        // Counts scale with segment splitting; the boundary keeps exactly two lines' worth (levels 2 and 4).
        XCTAssertEqual(g.lines[1].vertices.count, 2 * g.lines[0].vertices.count, "admin levels 2 and 4 only")
        XCTAssertEqual(g.lines[2].vertices.count, 2 * g.lines[0].vertices.count)
        XCTAssertEqual(g.fills.map(\.cls), [.aeroway])
    }

    // MARK: Buildings

    func testBuildingExtrusion() throws {
        let g = try build([.init(name: "building", features: [
            MVTTestEncoder.polygon([[rect(1000, 1000, 400, 400)]], tags: ["render_height": .double(30), "render_min_height": .double(5)]),
        ])])
        XCTAssertTrue(g.fills.isEmpty, "buildings are drawn as extrusions only")
        let e = try XCTUnwrap(g.extrusion)
        // 4 roof + 4 walls x 4 vertices; 2 roof triangles + 4 walls x 2 triangles.
        XCTAssertEqual(e.vertices.count, 4 + 16)
        XCTAssertEqual(e.indices.count, 3 * (2 + 8))
        XCTAssertTrue(e.indices.allSatisfy { Int($0) < e.vertices.count })
        let roofs = e.vertices.filter { $0.flags == ExtrusionVertex.roof }
        XCTAssertEqual(roofs.count, 4)
        XCTAssertTrue(roofs.allSatisfy { $0.height == 30 && $0.shade == 65535 })
        let tops = e.vertices.filter { $0.flags == ExtrusionVertex.wallTop }
        XCTAssertEqual(tops.count, 8)
        XCTAssertTrue(tops.allSatisfy { $0.height == 30 })
        let bottoms = e.vertices.filter { $0.flags == 0 }
        XCTAssertEqual(bottoms.count, 8)
        XCTAssertTrue(bottoms.allSatisfy { $0.height == 5 })
        XCTAssertTrue(e.vertices.allSatisfy { $0.pos.x >= 0 && $0.pos.x <= 1 })
        // Walls facing the light are brighter than walls facing away.
        let wallShades = Set(e.vertices.filter { $0.flags != ExtrusionVertex.roof }.map(\.shade))
        XCTAssertEqual(wallShades.count, 4)
        XCTAssertTrue(wallShades.allSatisfy { $0 < 65535 && $0 > 0 })
    }

    func testBuildingHeightRules() {
        XCTAssertEqual(OpenMapTilesSchema.buildingHeight([:]), 10)
        XCTAssertEqual(OpenMapTilesSchema.buildingHeight(["render_height": .int(25)]), 25)
        XCTAssertEqual(OpenMapTilesSchema.buildingHeight(["render_height": .double(1e6)]), 500)
        XCTAssertEqual(OpenMapTilesSchema.buildingHeight(["render_height": .int(-5)]), 0)
        XCTAssertEqual(OpenMapTilesSchema.buildingHeight(["render_height": .string("tall")]), 10)
        XCTAssertEqual(OpenMapTilesSchema.buildingHeight(["render_height": .double(.nan)]), 10)
    }

    func testBuildingWithCourtyardGetsInnerWalls() throws {
        let g = try build([.init(name: "building", features: [
            MVTTestEncoder.polygon([[rect(0, 0, 1000, 1000), rect(300, 300, 400, 400)]], tags: ["render_height": .int(12)]),
        ])])
        let e = try XCTUnwrap(g.extrusion)
        XCTAssertEqual(e.vertices.count, 8 + 8 * 4)
        XCTAssertEqual(e.vertices.filter { $0.flags == ExtrusionVertex.wallTop }.count, 16)
    }

    // MARK: Labels

    func testPlaceLabels() throws {
        func place(_ cls: String, _ name: String, rank: Int64 = 1) -> MVTTestEncoder.Feature {
            MVTTestEncoder.point([P(2048, 1024)], tags: ["class": .string(cls), "name": .string(name), "rank": .int(rank)])
        }
        let g = try build([.init(name: "place", features: [
            place("country", "Country"), place("state", "State"), place("city", "City", rank: 3), place("town", "Town"),
            place("village", "Village"), place("suburb", "Suburb"), place("neighbourhood", "Hood"),
            place("hamlet", "Hamlet"), place("island", "Island"), place("city", ""),
            MVTTestEncoder.point([P(100, 100)], tags: ["class": .string("city")]),                     // no name
            MVTTestEncoder.point([P(-100, 100)], tags: ["class": .string("city"), "name": .string("Buffer")]), // outside the tile
        ])])
        let byText = Dictionary(uniqueKeysWithValues: g.labels.map { ($0.text, $0) })
        XCTAssertEqual(Set(byText.keys), ["Country", "State", "City", "Town", "Village", "Suburb", "Hood"])
        XCTAssertEqual(byText["Country"]?.minZoom, 2)
        XCTAssertEqual(byText["State"]?.minZoom, 5)
        XCTAssertEqual(byText["City"]?.minZoom, 4)
        XCTAssertEqual(byText["Town"]?.minZoom, 8)
        XCTAssertEqual(byText["Village"]?.minZoom, 11)
        XCTAssertEqual(byText["Suburb"]?.minZoom, 13)
        XCTAssertEqual(byText["Hood"]?.minZoom, 13)
        XCTAssertTrue(byText.values.allSatisfy { $0.kind == .place })
        XCTAssertEqual(byText["City"]?.pos, SIMD2<Float>(0.5, 0.25))
        XCTAssertLessThan(byText["Country"]!.priority, byText["City"]!.priority)
        XCTAssertLessThan(byText["City"]!.priority, byText["Town"]!.priority)
    }

    func testNamePreferenceAndCleaning() {
        let schema = OpenMapTilesSchema.self
        XCTAssertEqual(schema.label(layer: "place", tags: ["class": .string("city"), "name": .string("Köln"), "name_en": .string("Cologne")])?.text, "Cologne")
        XCTAssertEqual(schema.label(layer: "place", tags: ["class": .string("city"), "name": .string("東京"), "name:latin": .string("Tokyo")])?.text, "Tokyo")
        XCTAssertEqual(schema.label(layer: "place", tags: ["class": .string("city"), "name": .string("  Paris\n ")])?.text, "Paris")
        XCTAssertEqual(schema.label(layer: "place", tags: ["class": .string("city"), "name": .string(String(repeating: "x", count: 200))])?.text.count, 64)
        XCTAssertNil(schema.label(layer: "place", tags: ["class": .string("city"), "name": .string("  ")]))
        XCTAssertNil(schema.label(layer: "poi", tags: ["class": .string("city"), "name": .string("x")]))
    }

    func testWaterAndRoadLabels() throws {
        let g = try build([
            .init(name: "water_name", features: [MVTTestEncoder.point([P(1024, 1024)], tags: ["class": .string("lake"), "name": .string("Lake Test")])]),
            .init(name: "transportation_name", features: [
                MVTTestEncoder.line([[P(0, 0), P(100, 0), P(100, 1000), P(900, 1000)]], tags: ["class": .string("primary"), "name": .string("Main St")]),
                MVTTestEncoder.line([[P(0, 0), P(10, 0)]], tags: ["class": .string("rail"), "name": .string("Rail Line")]),
            ]),
        ])
        let water = try XCTUnwrap(g.labels.first { $0.kind == .water })
        XCTAssertEqual(water.text, "Lake Test")
        XCTAssertEqual(water.pos, SIMD2<Float>(0.25, 0.25))
        let road = try XCTUnwrap(g.labels.first { $0.kind == .road })
        XCTAssertEqual(road.text, "Main St")
        XCTAssertEqual(road.minZoom, 15)
        // Longest segment is (100,0) to (100,1000): midpoint (100, 500).
        XCTAssertEqual(road.pos.x, 100.0 / 4096, accuracy: 1e-6)
        XCTAssertEqual(road.pos.y, 500.0 / 4096, accuracy: 1e-6)
        XCTAssertEqual(g.labels.count, 2)
    }

    // MARK: Misc

    func testUnknownLayersAreIgnoredAndEmptyTile() throws {
        let g = try build([.init(name: "poi", features: [MVTTestEncoder.point([P(1, 1)], tags: ["class": .string("cafe"), "name": .string("Cafe")])])])
        XCTAssertTrue(g.fills.isEmpty && g.lines.isEmpty && g.labels.isEmpty)
        XCTAssertNil(g.extrusion)
        XCTAssertEqual(g.byteCount, 0)
        let empty = TileGeometryBuilder.build(MVTTile(layers: []), id: tid)
        XCTAssertEqual(empty.byteCount, 0)
    }

    func testByteCountIsSumOfArraySizes() throws {
        let g = try build([
            .init(name: "water", features: [MVTTestEncoder.polygon([[rect(0, 0, 100, 100)]])]),
            .init(name: "transportation", features: [MVTTestEncoder.line([[P(0, 0), P(100, 100)]], tags: ["class": .string("minor")])]),
            .init(name: "building", features: [MVTTestEncoder.polygon([[rect(0, 0, 100, 100)]])]),
            .init(name: "place", features: [MVTTestEncoder.point([P(5, 5)], tags: ["class": .string("city"), "name": .string("C")])]),
        ])
        var want = 0
        for f in g.fills { want += f.positions.count * MemoryLayout<SIMD2<Float>>.stride + f.indices.count * 4 }
        for l in g.lines { want += l.vertices.count * MemoryLayout<LineVertex>.stride + l.indices.count * 4 }
        if let e = g.extrusion { want += e.vertices.count * MemoryLayout<ExtrusionVertex>.stride + e.indices.count * 4 }
        want += g.labels.count * MemoryLayout<LabelAnchor>.stride
        XCTAssertEqual(g.byteCount, want)
        XCTAssertGreaterThan(want, 0)
        XCTAssertEqual(MemoryLayout<LineVertex>.stride, 32)
        XCTAssertEqual(MemoryLayout<ExtrusionVertex>.stride, 16)
    }

    func testSchemaLayerSet() {
        for l in ["water", "waterway", "landuse", "landcover", "park", "building", "transportation", "transportation_name", "place", "water_name", "boundary", "aeroway"] {
            XCTAssertTrue(OpenMapTilesSchema.layers.contains(l), l)
        }
        XCTAssertFalse(OpenMapTilesSchema.layers.contains("poi"))
        XCTAssertEqual(OpenMapTilesSchema.fillClass(layer: "landcover", tags: ["class": .string("wood")]), .park)
        XCTAssertNil(OpenMapTilesSchema.fillClass(layer: "landcover", tags: ["class": .string("farmland")]))
        XCTAssertEqual(OpenMapTilesSchema.fillClass(layer: "landuse", tags: ["class": .string("residential")]), .landuse)
        XCTAssertEqual(OpenMapTilesSchema.fillClass(layer: "landuse", tags: ["class": .string("cemetery")]), .park)
        XCTAssertNil(OpenMapTilesSchema.fillClass(layer: "transportation", tags: ["class": .string("minor")]))
        XCTAssertTrue(RenderClass.allCases.count <= 24)
    }

    // MARK: Performance

    /// A dense z14-like tile: 600 buildings (some with courtyards), 400 road polylines, one
    /// 12k-vertex block with holes, labels. Reports decode+build time; does not gate.
    func testMeasureDenseTileBuild() throws {
        var rng = SplitMix64(seed: 42)
        var buildings: [MVTTestEncoder.Feature] = []
        for i in 0..<600 {
            let x = Int32.random(in: 0..<3800, using: &rng), y = Int32.random(in: 0..<3800, using: &rng)
            let w = Int32.random(in: 20..<120, using: &rng), h = Int32.random(in: 20..<120, using: &rng)
            var rings = [rect(x, y, w, h)]
            if i % 10 == 0 { rings.append(rect(x + w / 3, y + h / 3, w / 3, h / 3)) }
            buildings.append(MVTTestEncoder.polygon([rings], tags: ["render_height": .double(Double(5 + i % 60))]))
        }
        var roads: [MVTTestEncoder.Feature] = []
        let classes = ["motorway", "primary", "secondary", "tertiary", "minor", "service", "path"]
        for i in 0..<400 {
            var pts: [P] = []
            var x = Int32.random(in: 0..<4096, using: &rng), y = Int32.random(in: 0..<4096, using: &rng)
            for _ in 0..<Int.random(in: 4...40, using: &rng) {
                pts.append(P(x, y))
                x = max(-200, min(4300, x + Int32.random(in: -150...150, using: &rng)))
                y = max(-200, min(4300, y + Int32.random(in: -150...150, using: &rng)))
            }
            roads.append(MVTTestEncoder.line([pts], tags: ["class": .string(classes[i % classes.count])]))
        }
        // The 12k-vertex block, expressed in tile units.
        let (rings, _) = MapsEarcutTests.syntheticBlock()
        let intRings: [[P]] = rings.map { $0.map { P(Int32(2048 + $0.x * 18), Int32(2048 + $0.y * 18)) } }
        let names = (0..<150).map { i in
            MVTTestEncoder.line([[P(Int32(i * 20), 100), P(Int32(i * 20) + 300, 400)]], tags: ["class": .string("minor"), "name": .string("Street \(i)")])
        }
        let data = MVTTestEncoder.encode([
            .init(name: "building", features: buildings), .init(name: "transportation", features: roads),
            .init(name: "landuse", features: [MVTTestEncoder.polygon([intRings], tags: ["class": .string("residential")])]),
            .init(name: "transportation_name", features: names),
        ])
        XCTAssertNotNil(try? MVTDecoder.decode(data))

        var built: TileGeometry?
        measure {
            let tile = try! MVTDecoder.decode(data, layers: OpenMapTilesSchema.layers)
            built = TileGeometryBuilder.build(tile, id: tid)
        }
        let g = try XCTUnwrap(built)
        XCTAssertEqual(g.fills.map(\.cls), [.landuse])
        XCTAssertFalse(g.lines.isEmpty)
        XCTAssertNotNil(g.extrusion)
        XCTAssertEqual(g.labels.count, 150)

        let t0 = Date()
        for _ in 0..<5 {
            let tile = try MVTDecoder.decode(data, layers: OpenMapTilesSchema.layers)
            _ = TileGeometryBuilder.build(tile, id: tid)
        }
        let ms = Date().timeIntervalSince(t0) / 5 * 1000
        print("dense tile (\(data.count / 1024) KB, \(g.byteCount / 1024) KB geometry): decode+build \(String(format: "%.1f", ms)) ms avg")
    }
}

final class MapsShorelineTests: XCTestCase {
    func testShorelineSkipsTileEdges() {
        // A lake touching the tile's left edge: the edge segment is a seam, the rest is shore.
        let ring: [SIMD2<Float>] = [SIMD2(0, 0.2), SIMD2(0.5, 0.2), SIMD2(0.5, 0.6), SIMD2(0, 0.6)]
        var v: [LineVertex] = [], i: [UInt32] = []
        TileGeometryBuilder.appendShoreline([ring], vertices: &v, indices: &i)
        XCTAssertFalse(v.isEmpty)
        XCTAssertTrue(v.allSatisfy { $0.cls == RenderClass.water.rawValue })
        // No vertex sits on the seam's interior (x == 0 between y 0.2 and 0.6) except the run ends.
        let onSeam = v.filter { $0.pos.x == 0 && $0.pos.y > 0.21 && $0.pos.y < 0.59 }
        XCTAssertTrue(onSeam.isEmpty)
        // A polygon entirely along the border yields nothing.
        var v2: [LineVertex] = [], i2: [UInt32] = []
        TileGeometryBuilder.appendShoreline([[SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)]], vertices: &v2, indices: &i2)
        XCTAssertTrue(v2.isEmpty)
    }
}

final class MapsSubdivisionTests: XCTestCase {
    func testSubdivisionKeepsAreaAndIsWatertight() {
        let square: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)]
        let tris = Earcut.triangulate([square])
        let (pos, idx) = TileGeometryBuilder.subdivide(square, tris, maxEdge: 1.0 / 16)
        XCTAssertEqual(MapsEarcutTests.triangleArea([pos], idx), 1, accuracy: 1e-5)
        var maxEdge: Float = 0
        var i = 0
        while i < idx.count {
            let a = pos[Int(idx[i])], b = pos[Int(idx[i + 1])], c = pos[Int(idx[i + 2])]
            maxEdge = max(maxEdge, simd_length(a - b), simd_length(b - c), simd_length(c - a))
            i += 3
        }
        XCTAssertLessThanOrEqual(maxEdge, 1.0 / 16 + 1e-5)
        // Watertight: no duplicate positions (shared midpoints are reused).
        XCTAssertEqual(Set(pos.map { "\($0.x),\($0.y)" }).count, pos.count)
    }
}
