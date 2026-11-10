import Foundation

/// A drivable road network for one region, built from an OpenStreetMap extract on this Mac.
/// Vertices are junctions and dead ends; an edge is the road between two of them, with its shape.
/// Struct-of-arrays, indices are Int32. A directed edge is `edge * 2` (from → to) or `edge * 2 + 1`.
///
/// The arrays must agree with each other (as `RoadGraphBuilder` and `RoadGraphFile.decode` leave
/// them): the accessors and `RouteEngine` index them without re-checking.
public struct RoadGraph: Sendable {
    /// Vertex positions, degrees × 1e7.
    public var lat: [Int32] = [], lon: [Int32] = []
    public var from: [Int32] = [], to: [Int32] = []
    /// Metres.
    public var length: [Float] = []
    /// km/h each way; 0 = not allowed that way.
    public var speedForward: [UInt8] = [], speedBackward: [UInt8] = []
    public var roadClass: [UInt8] = []
    /// Bit 0 roundabout, bit 1 toll.
    public var flags: [UInt8] = []
    /// Index into `names`, or -1.
    public var name: [Int32] = []
    /// Shape points between the two vertices: `shape[shapeStart[e] ..< shapeStart[e+1]]` as lat, lon pairs (× 1e7).
    public var shapeStart: [Int32] = [0]
    public var shape: [Int32] = []
    public var names: [String] = []
    /// Outgoing directed edges per vertex: `adj[adjStart[v] ..< adjStart[v+1]]`.
    public var adjStart: [Int32] = [0]
    public var adj: [Int32] = []
    public var restrictions: [TurnRestriction] = []

    public init() {}

    public var vertexCount: Int { lat.count }
    public var edgeCount: Int { from.count }

    /// Directed edges are numbered `edge * 2 (+ 1)` in an Int32, which bounds the edge count.
    static let maxEdges = Int(Int32.max) / 2
    static let maxVertices = Int(Int32.max)

    public struct TurnRestriction: Sendable, Equatable {
        public var fromEdge: Int32, via: Int32, toEdge: Int32
        /// true: "only" (every other turn from `fromEdge` at `via` is forbidden); false: "no".
        public var only: Bool
    }

    public static let roundaboutFlag: UInt8 = 1, tollFlag: UInt8 = 2

    @inline(__always) public func speed(_ de: Int32) -> UInt8 {
        de & 1 == 0 ? speedForward[Int(de >> 1)] : speedBackward[Int(de >> 1)]
    }
    @inline(__always) public func tail(_ de: Int32) -> Int32 { de & 1 == 0 ? from[Int(de >> 1)] : to[Int(de >> 1)] }
    @inline(__always) public func head(_ de: Int32) -> Int32 { de & 1 == 0 ? to[Int(de >> 1)] : from[Int(de >> 1)] }

    public func position(_ v: Int32) -> LonLat { LonLat(lon: Double(lon[Int(v)]) / 1e7, lat: Double(lat[Int(v)]) / 1e7) }

    /// How many outgoing directed edges a car may take from `v`.
    @inline(__always) func outDegree(_ v: Int32) -> Int { Int(adjStart[Int(v) + 1] - adjStart[Int(v)]) }

    // MARK: Edge geometry

    /// Points on an edge's polyline: its two vertices and the shape points between them.
    @inline(__always) func pointCount(_ e: Int) -> Int { Int(shapeStart[e + 1] - shapeStart[e]) / 2 + 2 }

    /// Point `i` of edge `e`'s polyline (0 is `from`, `pointCount(e) - 1` is `to`). Reads the
    /// arrays in place: the hot paths (snapping, the spatial index, camera penalties) walk every
    /// edge's shape and must not build an array per edge.
    @inline(__always) func point(_ e: Int, _ i: Int) -> LonLat {
        if i == 0 { return position(from[e]) }
        let k = Int(shapeStart[e]) + 2 * (i - 1)
        if k + 1 >= Int(shapeStart[e + 1]) { return position(to[e]) }
        return LonLat(lon: Double(shape[k + 1]) / 1e7, lat: Double(shape[k]) / 1e7)
    }

    /// The full polyline of an edge, from → to.
    public func polyline(_ e: Int) -> [LonLat] {
        (0..<pointCount(e)).map { point(e, $0) }
    }

    /// The polyline of a directed edge, tail → head.
    public func polyline(directed de: Int32) -> [LonLat] {
        let p = polyline(Int(de >> 1))
        return de & 1 == 0 ? p : p.reversed()
    }

    public func roadName(_ e: Int) -> String? { name[e] >= 0 && Int(name[e]) < names.count ? names[Int(name[e])] : nil }
}

// MARK: - Building

public enum RoadGraphBuilder {
    public struct Stats: Sendable, Equatable { public var ways = 0, nodes = 0, vertices = 0, edges = 0, restrictions = 0, missingNodes = 0 }

    public enum Stage: Sendable { case ways, nodes, building }

    /// A node reference is kept as `nodeID << refPositionBits | position` (see `Roads.packedRefs`),
    /// which bounds both. OpenStreetMap node ids are around 2^34 in 2026, and 2^28 references is
    /// several times the largest extract GRID accepts (700 MB).
    static let refPositionBits: UInt64 = 28
    static let maxRefs = (1 << 28) - 1
    static let maxNodeID: Int64 = (1 << 36) - 1

    /// Builds the car graph from a PBF extract. Reads the file twice (ways and restrictions, then
    /// only the nodes those ways use). `progress(stage, fraction)` is called as it goes.
    public static func build(pbf data: Data, progress: ((Stage, Double) -> Void)? = nil,
                             cancelled: (() -> Bool)? = nil) throws -> (RoadGraph, Stats) {
        let reader = PBFReader(data: data)
        var stats = Stats()

        var (roads, blobContents) = try readRoads(reader, progress: { progress?(.ways, $0) }, cancelled: cancelled)
        stats.ways = roads.ways.count

        var nodes = NodeTable(roads: &roads)
        stats.nodes = try readPositions(reader, skipping: blobContents, into: &nodes,
                                        progress: { progress?(.nodes, $0) }, cancelled: cancelled)

        var (graph, vertexOfSlot, edgesOfRestrictedWays) = try makeEdges(roads, nodes, &stats, progress: { progress?(.building, $0) },
                                                                          cancelled: cancelled)
        graph.restrictions = resolve(roads.restrictions, nodes, vertexOfSlot, edgesOfRestrictedWays, in: graph)
        vertexOfSlot = []
        graph.buildAdjacency()

        stats.vertices = graph.vertexCount; stats.edges = graph.edgeCount; stats.restrictions = graph.restrictions.count
        progress?(.building, 1)
        return (graph, stats)
    }

    // MARK: Pass 1: ways and restrictions

    /// A turn restriction as mapped: OSM way and node ids.
    private struct RawRestriction { var fromWay: Int64; var via: Int64; var toWay: Int64; var only: Bool }

    /// The drivable ways of an extract. Compact on purpose: a state has a million of them.
    private struct Roads {
        struct Way {
            var id: Int64
            /// Index into `names`, or -1.
            var name: Int32
            var forwardKmh: UInt8, backwardKmh: UInt8, roadClass: UInt8, flags: UInt8
        }
        var ways: [Way] = []
        /// Way w's node references are positions `refStart[w] ..< refStart[w + 1]`.
        var refStart: [Int32] = [0]
        /// Every node reference of every way, in order, as `nodeID << refPositionBits | position`.
        /// Sorting this one array groups equal node ids together while remembering where each
        /// reference came from, which is all that's needed to number the nodes and find the
        /// junctions (no hash table, no search per reference).
        var packedRefs: [UInt64] = []
        var names: [String] = []
        var nameIndex: [String: Int32] = [:]
        var restrictions: [RawRestriction] = []
        /// Set when the extract can't be built (reported after the scan: visitors can't throw).
        var failure: PBFError?

        mutating func add(_ way: OSMWay, _ a: RoadAttributes) {
            guard failure == nil else { return }
            guard packedRefs.count + way.refs.count <= RoadGraphBuilder.maxRefs else {
                failure = .unsupported("too many road nodes"); return
            }
            for id in way.refs {
                guard id >= 0, id <= RoadGraphBuilder.maxNodeID else { failure = .unsupported("node id \(id)"); return }
                packedRefs.append(UInt64(id) << RoadGraphBuilder.refPositionBits | UInt64(packedRefs.count))
            }
            refStart.append(Int32(packedRefs.count))
            var name: Int32 = -1
            if let n = a.name {
                if let i = nameIndex[n] { name = i } else {
                    name = Int32(names.count); names.append(n); nameIndex[n] = name
                }
            }
            ways.append(Way(id: way.id, name: name, forwardKmh: a.forwardKmh, backwardKmh: a.backwardKmh, roadClass: a.roadClass.rawValue,
                            flags: (a.roundabout ? RoadGraph.roundaboutFlag : 0) | (a.toll ? RoadGraph.tollFlag : 0)))
        }
    }

    private static func readRoads(_ reader: PBFReader, progress: @escaping (Double) -> Void,
                                  cancelled: (() -> Bool)?) throws -> (Roads, [PBFReader.BlobContents]) {
        var roads = Roads()
        var v = PBFReader.Visitor()
        v.wayKey = "highway"
        v.wayTagKeys = RoadProfile.tagKeys
        v.way = { w in
            guard w.refs.count >= 2, let a = RoadProfile.attributes(w.tags), a.forwardKmh > 0 || a.backwardKmh > 0 else { return }
            roads.add(w, a)
        }
        v.relationTypes = ["restriction", "restriction:motorcar"]
        v.relation = { r in
            if let raw = restriction(r) { roads.restrictions.append(raw) }
        }
        let contents = try reader.scan(v, progress: progress, cancelled: cancelled)
        if let failure = roads.failure { throw failure }
        return (roads, contents)
    }

    /// A "no_…" or "only_…" restriction that applies to cars and turns at one node. Restrictions
    /// through a via way are rare and need a different model; they are left out.
    private static func restriction(_ r: OSMRelation) -> RawRestriction? {
        let kind = r.tags["restriction"] ?? r.tags["restriction:motorcar"] ?? ""
        let only = kind.hasPrefix("only_")
        guard only || kind.hasPrefix("no_") else { return nil }
        if let except = r.tags["except"], except.split(separator: ";").contains("motorcar") { return nil }
        let from = r.members.filter { $0.type == .way && $0.role == "from" }
        let to = r.members.filter { $0.type == .way && $0.role == "to" }
        let via = r.members.filter { $0.role == "via" }
        guard from.count == 1, to.count == 1, via.count == 1, via[0].type == .node else { return nil }
        return RawRestriction(fromWay: from[0].ref, via: via[0].ref, toWay: to[0].ref, only: only)
    }

    // MARK: Nodes

    /// The nodes the drivable ways use, numbered ("slots") in id order.
    private struct NodeTable {
        static let missing = Int32.min
        /// Node ids, ascending.
        var ids: [Int64] = []
        /// Positions (degrees × 1e7); `lat == missing` until the node is read from the file.
        var lat: [Int32] = [], lon: [Int32] = []
        /// A node becomes a graph vertex when ways meet or end there (or a restriction turns there).
        var isJunction: [Bool] = []
        /// The slot of each node reference, by position in the ways' reference list.
        var slotOfRef: [Int32] = []

        init() {}

        /// Numbers the nodes and finds the junctions. Takes the packed references out of `roads`
        /// (they are the largest thing in memory at this point).
        init(roads: inout Roads) {
            var refs = roads.packedRefs
            roads.packedRefs = []
            refs.sort()
            let positionMask = (UInt64(1) << RoadGraphBuilder.refPositionBits) - 1
            slotOfRef = [Int32](repeating: 0, count: refs.count)
            ids.reserveCapacity(refs.count / 2)
            isJunction.reserveCapacity(refs.count / 2)
            for packed in refs {
                let id = Int64(packed >> RoadGraphBuilder.refPositionBits)
                if ids.last == id {
                    isJunction[ids.count - 1] = true          // used more than once
                } else {
                    ids.append(id); isJunction.append(false)
                }
                slotOfRef[Int(packed & positionMask)] = Int32(ids.count - 1)
            }
            refs = []
            for w in roads.ways.indices {
                isJunction[Int(slotOfRef[Int(roads.refStart[w])])] = true
                isJunction[Int(slotOfRef[Int(roads.refStart[w + 1]) - 1])] = true
            }
            for r in roads.restrictions { if let s = slot(of: r.via) { isJunction[s] = true } }
            lat = [Int32](repeating: Self.missing, count: ids.count)
            lon = [Int32](repeating: 0, count: ids.count)
        }

        func slot(of id: Int64) -> Int? {
            var lo = 0, hi = ids.count
            while lo < hi { let mid = (lo + hi) / 2; if ids[mid] < id { lo = mid + 1 } else { hi = mid } }
            return lo < ids.count && ids[lo] == id ? lo : nil
        }
    }

    /// Pass 2: the positions of the nodes the ways use. Returns how many were found.
    private static func readPositions(_ reader: PBFReader, skipping contents: [PBFReader.BlobContents], into nodes: inout NodeTable,
                                      progress: @escaping (Double) -> Void, cancelled: (() -> Bool)?) throws -> Int {
        var found = 0
        var cursor = 0
        var table = nodes
        nodes = NodeTable()          // one owner while the visitor writes into the table
        defer { nodes = table }
        var v = PBFReader.Visitor()
        v.node = { id, lat, lon in
            // Files are sorted by id: walk forward; fall back to a search otherwise.
            var slot: Int?
            if cursor < table.ids.count, table.ids[cursor] == id { slot = cursor }
            else if cursor < table.ids.count, table.ids[cursor] < id {
                while cursor < table.ids.count, table.ids[cursor] < id { cursor += 1 }
                if cursor < table.ids.count, table.ids[cursor] == id { slot = cursor }
            } else { slot = table.slot(of: id) }
            guard let slot else { return }
            // A real latitude is never the marker (it is far outside ±90°).
            table.lat[slot] = lat == NodeTable.missing ? NodeTable.missing + 1 : lat
            table.lon[slot] = lon
            found += 1
        }
        try reader.scan(v, skipping: contents, progress: progress, cancelled: cancelled)
        return found
    }

    // MARK: Edges

    /// Cuts every way into edges at its junctions. Also returns each node slot's vertex (-1 when
    /// it isn't one) and the edges of the ways that turn restrictions name.
    private static func makeEdges(_ roads: Roads, _ nodes: NodeTable, _ stats: inout Stats, progress: (Double) -> Void,
                                  cancelled: (() -> Bool)?) throws -> (RoadGraph, vertexOfSlot: [Int32], edgesOfRestrictedWays: [Int64: [Int32]]) {
        var g = RoadGraph()
        var edgesOfRestrictedWays: [Int64: [Int32]] = [:]
        g.names = roads.names
        var vertexOfSlot = [Int32](repeating: -1, count: nodes.ids.count)
        func vertex(_ slot: Int) -> Int32 {
            if vertexOfSlot[slot] >= 0 { return vertexOfSlot[slot] }
            let v = Int32(g.lat.count)
            g.lat.append(nodes.lat[slot]); g.lon.append(nodes.lon[slot])
            vertexOfSlot[slot] = v
            return v
        }
        let restrictedWays = Set(roads.restrictions.flatMap { [$0.fromWay, $0.toWay] })

        for (w, way) in roads.ways.enumerated() {
            if w % 4096 == 0 {
                if cancelled?() == true { throw PBFError.cancelled }
                progress(Double(w) / Double(max(1, roads.ways.count)))
            }
            let isRestricted = restrictedWays.contains(way.id)
            let lastRef = Int(roads.refStart[w + 1]) - 1
            var start = -1                    // slot of the current edge's first vertex, or -1
            var previous = -1                 // slot of the last point taken
            var shapeBegin = g.shape.count    // where the current edge's shape points start
            var length = 0.0
            for k in Int(roads.refStart[w])...lastRef {
                let slot = Int(nodes.slotOfRef[k])
                guard nodes.lat[slot] != NodeTable.missing else {
                    // A node missing from the extract (clipped at its edge): cut the way here. It
                    // restarts at the next node, which becomes a vertex.
                    stats.missingNodes += 1
                    g.shape.removeSubrange(shapeBegin...)
                    start = -1; previous = -1
                    continue
                }
                if start < 0 {
                    start = slot; previous = slot; length = 0
                    continue
                }
                if slot == previous { continue }      // the same node twice in a row adds nothing
                length += meters((nodes.lat[previous], nodes.lon[previous]), (nodes.lat[slot], nodes.lon[slot]))
                previous = slot
                guard nodes.isJunction[slot] || k == lastRef else {
                    g.shape.append(nodes.lat[slot]); g.shape.append(nodes.lon[slot])
                    continue
                }
                let e = Int32(g.from.count)
                g.from.append(vertex(start)); g.to.append(vertex(slot))
                g.length.append(Float(max(0.1, length)))
                g.speedForward.append(way.forwardKmh); g.speedBackward.append(way.backwardKmh)
                g.roadClass.append(way.roadClass)
                g.flags.append(way.flags)
                g.name.append(way.name)
                g.shapeStart.append(Int32(g.shape.count))
                if isRestricted { edgesOfRestrictedWays[way.id, default: []].append(e) }
                start = slot; shapeBegin = g.shape.count; length = 0
            }
            g.shape.removeSubrange(shapeBegin...)     // points after the last vertex of a cut way
        }
        return (g, vertexOfSlot, edgesOfRestrictedWays)
    }

    /// Turn restrictions on the edges either side of their via vertex.
    private static func resolve(_ raw: [RawRestriction], _ nodes: NodeTable, _ vertexOfSlot: [Int32], _ edgesOfWay: [Int64: [Int32]],
                                in g: RoadGraph) -> [RoadGraph.TurnRestriction] {
        var out: [RoadGraph.TurnRestriction] = []
        for r in raw {
            guard let slot = nodes.slot(of: r.via), vertexOfSlot[slot] >= 0 else { continue }
            let via = vertexOfSlot[slot]
            func edge(of way: Int64) -> Int32? {
                edgesOfWay[way]?.first { g.from[Int($0)] == via || g.to[Int($0)] == via }
            }
            guard let fromEdge = edge(of: r.fromWay), let toEdge = edge(of: r.toWay) else { continue }
            out.append(.init(fromEdge: fromEdge, via: via, toEdge: toEdge, only: r.only))
        }
        return out
    }

    /// Ground distance in metres between two positions (degrees × 1e7).
    static func meters(_ a: (Int32, Int32), _ b: (Int32, Int32)) -> Double {
        let la1 = Double(a.0) / 1e7 * .pi / 180, la2 = Double(b.0) / 1e7 * .pi / 180
        let dla = la2 - la1, dlo = (Double(b.1) - Double(a.1)) / 1e7 * .pi / 180
        let h = sin(dla / 2) * sin(dla / 2) + cos(la1) * cos(la2) * sin(dlo / 2) * sin(dlo / 2)
        return 2 * 6_371_000 * asin(min(1, sqrt(h)))
    }
}

extension RoadGraph {
    /// Outgoing directed edges per vertex (only directions a car may use).
    mutating func buildAdjacency() {
        var count = [Int32](repeating: 0, count: vertexCount + 1)
        for e in 0..<edgeCount {
            if speedForward[e] > 0 { count[Int(from[e])] += 1 }
            if speedBackward[e] > 0 { count[Int(to[e])] += 1 }
        }
        adjStart = [Int32](repeating: 0, count: vertexCount + 1)
        for v in 0..<vertexCount { adjStart[v + 1] = adjStart[v] + count[v] }
        adj = [Int32](repeating: 0, count: Int(adjStart[vertexCount]))
        var fill = Array(adjStart.dropLast())
        for e in 0..<edgeCount {
            if speedForward[e] > 0 { adj[Int(fill[Int(from[e])])] = Int32(e * 2); fill[Int(from[e])] += 1 }
            if speedBackward[e] > 0 { adj[Int(fill[Int(to[e])])] = Int32(e * 2 + 1); fill[Int(to[e])] += 1 }
        }
    }
}

// MARK: - File format

/// GRID's road graph file: "GRDG", version, counts, then the arrays little-endian. Read back with
/// every index range-checked (the file is on disk and could be damaged).
public enum RoadGraphFile {
    static let magic: [UInt8] = Array("GRDG".utf8)
    static let version: UInt32 = 1

    public enum FileError: Error, Equatable { case notAGraph, version, damaged(String) }

    public static func encode(_ g: RoadGraph) -> Data {
        var d = Data()
        d.append(contentsOf: magic)
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func arr<T>(_ a: [T]) { u32(UInt32(a.count)); a.withUnsafeBytes { d.append(contentsOf: $0) } }
        u32(version)
        arr(g.lat); arr(g.lon)
        arr(g.from); arr(g.to); arr(g.length); arr(g.speedForward); arr(g.speedBackward)
        arr(g.roadClass); arr(g.flags); arr(g.name); arr(g.shapeStart); arr(g.shape)
        var rs: [Int32] = []
        for r in g.restrictions { rs += [r.fromEdge, r.via, r.toEdge, r.only ? 1 : 0] }
        arr(rs)
        let blob = Data(g.names.joined(separator: "\u{0}").utf8)
        u32(UInt32(blob.count)); d.append(blob)
        return d
    }

    public static func decode(_ data: Data) throws -> RoadGraph {
        // Read in place: the file is tens of megabytes and may be memory-mapped.
        var g = try data.withUnsafeBytes { try readArrays($0) }
        try validate(g)
        g.buildAdjacency()
        return g
    }

    /// The arrays as stored, sizes checked against the bytes present but contents not yet trusted.
    private static func readArrays(_ file: UnsafeRawBufferPointer) throws -> RoadGraph {
        guard file.count >= 8, file.prefix(4).elementsEqual(magic) else { throw FileError.notAGraph }
        var cursor = 4
        func u32() throws -> UInt32 {
            guard file.count - cursor >= 4 else { throw FileError.damaged("truncated") }
            defer { cursor += 4 }
            return UInt32(littleEndian: file.loadUnaligned(fromByteOffset: cursor, as: UInt32.self))
        }
        func array<T>(_: T.Type) throws -> [T] {
            let n = Int(try u32())
            // n < 2^32 and the element types are at most 4 bytes: no overflow.
            let byteCount = n * MemoryLayout<T>.stride
            guard file.count - cursor >= byteCount else { throw FileError.damaged("array") }
            let out = [T](unsafeUninitializedCapacity: n) { buffer, count in
                UnsafeMutableRawBufferPointer(buffer).copyMemory(from: UnsafeRawBufferPointer(rebasing: file[cursor ..< cursor + byteCount]))
                count = n
            }
            cursor += byteCount
            return out
        }
        guard try u32() == version else { throw FileError.version }
        var g = RoadGraph()
        g.lat = try array(Int32.self); g.lon = try array(Int32.self)
        g.from = try array(Int32.self); g.to = try array(Int32.self); g.length = try array(Float.self)
        g.speedForward = try array(UInt8.self); g.speedBackward = try array(UInt8.self)
        g.roadClass = try array(UInt8.self); g.flags = try array(UInt8.self); g.name = try array(Int32.self)
        g.shapeStart = try array(Int32.self); g.shape = try array(Int32.self)
        let restrictions = try array(Int32.self)
        guard restrictions.count % 4 == 0 else { throw FileError.damaged("counts") }
        var k = 0
        while k < restrictions.count {
            g.restrictions.append(.init(fromEdge: restrictions[k], via: restrictions[k + 1], toEdge: restrictions[k + 2],
                                        only: restrictions[k + 3] != 0))
            k += 4
        }
        let nameBytes = Int(try u32())
        guard file.count - cursor >= nameBytes else { throw FileError.damaged("names") }
        g.names = nameBytes == 0 ? []
            : String(decoding: UnsafeRawBufferPointer(rebasing: file[cursor ..< cursor + nameBytes]), as: UTF8.self).components(separatedBy: "\u{0}")
        return g
    }

    /// Checks everything an index points at, so nothing that uses the graph can read out of range.
    private static func validate(_ g: RoadGraph) throws {
        let V = g.lat.count, E = g.from.count
        guard V <= RoadGraph.maxVertices, E <= RoadGraph.maxEdges, g.lon.count == V,
              [g.to.count, g.length.count, g.speedForward.count, g.speedBackward.count,
               g.roadClass.count, g.flags.count, g.name.count].allSatisfy({ $0 == E }),
              g.shapeStart.count == E + 1, g.shapeStart.first == 0, Int(g.shapeStart.last ?? -1) == g.shape.count,
              g.shape.count % 2 == 0 else { throw FileError.damaged("counts") }
        for e in 0..<E {
            guard g.from[e] >= 0, g.from[e] < V, g.to[e] >= 0, g.to[e] < V, g.length[e].isFinite, g.length[e] >= 0,
                  g.shapeStart[e] <= g.shapeStart[e + 1], (g.shapeStart[e + 1] &- g.shapeStart[e]) % 2 == 0,
                  g.name[e] >= -1, Int(g.name[e]) < g.names.count, RoadClass(rawValue: g.roadClass[e]) != nil
            else { throw FileError.damaged("edge \(e)") }
        }
        for r in g.restrictions {
            guard r.fromEdge >= 0, r.fromEdge < E, r.toEdge >= 0, r.toEdge < E, r.via >= 0, r.via < V else {
                throw FileError.damaged("restriction")
            }
        }
    }
}
