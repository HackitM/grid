import Foundation

/// A drivable road network for one region, built from an OpenStreetMap extract on this Mac.
/// Vertices are junctions and dead ends; an edge is the road between two of them, with its shape.
/// Struct-of-arrays, indices are Int32. A directed edge is `edge * 2` (from → to) or `edge * 2 + 1`.
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

    /// The full polyline of an edge, from → to.
    public func polyline(_ e: Int) -> [LonLat] {
        var out = [position(from[e])]
        var i = Int(shapeStart[e])
        while i + 1 < Int(shapeStart[e + 1]) {
            out.append(LonLat(lon: Double(shape[i + 1]) / 1e7, lat: Double(shape[i]) / 1e7))
            i += 2
        }
        out.append(position(to[e]))
        return out
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

    /// Builds the car graph from a PBF extract. Reads the file twice (ways and restrictions, then
    /// only the nodes those ways use). `progress(stage, fraction)` is called as it goes.
    public static func build(pbf data: Data, progress: ((Stage, Double) -> Void)? = nil,
                             cancelled: (() -> Bool)? = nil) throws -> (RoadGraph, Stats) {
        let reader = PBFReader(data: data)
        var stats = Stats()

        // Pass 1: drivable ways and turn restrictions.
        var wayIDs: [Int64] = []
        var wayAttr: [RoadAttributes] = []
        var refStart: [Int] = [0]
        var refs: [Int64] = []
        struct RawRestriction { var fromWay: Int64; var via: Int64; var toWay: Int64; var only: Bool }
        var rawRestrictions: [RawRestriction] = []
        var v1 = PBFReader.Visitor()
        v1.wayKey = "highway"
        v1.way = { w in
            guard w.refs.count >= 2, let a = RoadProfile.attributes(w.tags), a.forwardKmh > 0 || a.backwardKmh > 0 else { return }
            wayIDs.append(w.id); wayAttr.append(a)
            refs.append(contentsOf: w.refs); refStart.append(refs.count)
        }
        v1.relationTypes = ["restriction", "restriction:motorcar"]
        v1.relation = { r in
            let kind = r.tags["restriction"] ?? r.tags["restriction:motorcar"] ?? ""
            let only = kind.hasPrefix("only_")
            guard only || kind.hasPrefix("no_") else { return }
            if let except = r.tags["except"], except.split(separator: ";").contains("motorcar") { return }
            let fromW = r.members.filter { $0.type == .way && $0.role == "from" }
            let toW = r.members.filter { $0.type == .way && $0.role == "to" }
            let via = r.members.filter { $0.role == "via" }
            // Node-via restrictions only (way-via ones are rare and need a different model).
            guard fromW.count == 1, toW.count == 1, via.count == 1, via[0].type == .node else { return }
            rawRestrictions.append(RawRestriction(fromWay: fromW[0].ref, via: via[0].ref, toWay: toW[0].ref, only: only))
        }
        try reader.scan(v1, progress: { progress?(.ways, $0) }, cancelled: cancelled)
        stats.ways = wayIDs.count

        // Node ids used, how often (≥ 2 or an end makes a junction).
        var sorted = refs
        sorted.sort()
        var ids: [Int64] = []
        var uses: [UInt8] = []
        ids.reserveCapacity(sorted.count / 2)
        for id in sorted {
            if let last = ids.last, last == id { uses[uses.count - 1] &+= uses[uses.count - 1] < 250 ? 1 : 0 }
            else { ids.append(id); uses.append(1) }
        }
        sorted = []
        func slot(_ id: Int64) -> Int? {
            var lo = 0, hi = ids.count
            while lo < hi { let mid = (lo + hi) / 2; if ids[mid] < id { lo = mid + 1 } else { hi = mid } }
            return lo < ids.count && ids[lo] == id ? lo : nil
        }
        var junction = uses.map { $0 >= 2 }
        uses = []
        for w in wayIDs.indices {
            if let a = slot(refs[refStart[w]]) { junction[a] = true }
            if let b = slot(refs[refStart[w + 1] - 1]) { junction[b] = true }
        }
        for r in rawRestrictions { if let s = slot(r.via) { junction[s] = true } }

        // Pass 2: positions of the nodes the ways use.
        var nlat = [Int32](repeating: 0, count: ids.count), nlon = [Int32](repeating: 0, count: ids.count)
        var found = [Bool](repeating: false, count: ids.count)
        var cursor = 0
        var v2 = PBFReader.Visitor()
        v2.node = { id, la, lo in
            // Files are sorted by id: walk forward; fall back to a search otherwise.
            var s: Int?
            if cursor < ids.count, ids[cursor] == id { s = cursor }
            else if cursor < ids.count, ids[cursor] < id {
                while cursor < ids.count, ids[cursor] < id { cursor += 1 }
                if cursor < ids.count, ids[cursor] == id { s = cursor }
            } else { s = slot(id) }
            guard let s else { return }
            nlat[s] = la; nlon[s] = lo; found[s] = true
            stats.nodes += 1
        }
        try reader.scan(v2, progress: { progress?(.nodes, $0) }, cancelled: cancelled)

        // Vertices and edges.
        var g = RoadGraph()
        var vertexOf = [Int32](repeating: -1, count: ids.count)
        func vertex(_ s: Int) -> Int32 {
            if vertexOf[s] >= 0 { return vertexOf[s] }
            let v = Int32(g.lat.count)
            g.lat.append(nlat[s]); g.lon.append(nlon[s])
            vertexOf[s] = v
            return v
        }
        var nameIndex: [String: Int32] = [:]
        let restrictedWays = Set(rawRestrictions.flatMap { [$0.fromWay, $0.toWay] })
        var edgesOfWay: [Int64: [Int32]] = [:]
        for w in wayIDs.indices {
            if w % 4096 == 0 {
                if cancelled?() == true { throw PBFError.cancelled }
                progress?(.building, Double(w) / Double(max(1, wayIDs.count)))
            }
            let a = wayAttr[w]
            let nm: Int32 = a.name.map { n in
                if let i = nameIndex[n] { return i }
                let i = Int32(g.names.count); g.names.append(n); nameIndex[n] = i; return i
            } ?? -1
            var start: Int?          // slot of the current edge's first vertex
            var pts: [(Int32, Int32)] = []
            var len = 0.0
            var prev: (Int32, Int32)?
            for k in refStart[w]..<refStart[w + 1] {
                guard let s = slot(refs[k]), found[s] else {
                    // A node missing from the extract (clipped at its edge): cut the way here.
                    stats.missingNodes += 1
                    start = nil; pts = []; len = 0; prev = nil
                    continue
                }
                let p = (nlat[s], nlon[s])
                if let q = prev { len += meters(q, p) }
                prev = p
                if start == nil {
                    // A way cut by a missing node restarts at the next node (making it a vertex).
                    start = s; pts = []; len = 0
                    continue
                }
                if junction[s] || k == refStart[w + 1] - 1 {
                    let e = Int32(g.from.count)
                    g.from.append(vertex(start!)); g.to.append(vertex(s))
                    g.length.append(Float(max(0.1, len)))
                    g.speedForward.append(a.forwardKmh); g.speedBackward.append(a.backwardKmh)
                    g.roadClass.append(a.roadClass.rawValue)
                    g.flags.append((a.roundabout ? RoadGraph.roundaboutFlag : 0) | (a.toll ? RoadGraph.tollFlag : 0))
                    g.name.append(nm)
                    for (la, lo) in pts { g.shape.append(la); g.shape.append(lo) }
                    g.shapeStart.append(Int32(g.shape.count))
                    if restrictedWays.contains(wayIDs[w]) { edgesOfWay[wayIDs[w], default: []].append(e) }
                    start = s; pts = []; len = 0
                } else {
                    pts.append(p)
                }
            }
        }
        refs = []

        // Turn restrictions on the edges either side of their via vertex.
        for r in rawRestrictions {
            guard let vs = slot(r.via), vertexOf[vs] >= 0 else { continue }
            let via = vertexOf[vs]
            let fromE = (edgesOfWay[r.fromWay] ?? []).first { g.from[Int($0)] == via || g.to[Int($0)] == via }
            let toE = (edgesOfWay[r.toWay] ?? []).first { g.from[Int($0)] == via || g.to[Int($0)] == via }
            guard let fromE, let toE else { continue }
            g.restrictions.append(.init(fromEdge: fromE, via: via, toEdge: toE, only: r.only))
        }

        g.buildAdjacency()
        stats.vertices = g.vertexCount; stats.edges = g.edgeCount; stats.restrictions = g.restrictions.count
        progress?(.building, 1)
        return (g, stats)
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
        let b = [UInt8](data)
        var i = 0
        guard b.count >= 8, Array(b[0..<4]) == magic else { throw FileError.notAGraph }
        i = 4
        func u32() throws -> UInt32 {
            guard b.count - i >= 4 else { throw FileError.damaged("truncated") }
            defer { i += 4 }
            return UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
        }
        func arr<T>(_: T.Type) throws -> [T] {
            let n = Int(try u32())
            let bytes = n * MemoryLayout<T>.stride
            guard n >= 0, bytes >= 0, b.count - i >= bytes else { throw FileError.damaged("array") }
            let out = [T](unsafeUninitializedCapacity: n) { buf, count in
                b.withUnsafeBytes { src in
                    UnsafeMutableRawBufferPointer(buf).copyMemory(from: UnsafeRawBufferPointer(rebasing: src[i ..< i + bytes]))
                }
                count = n
            }
            i += bytes
            return out
        }
        guard try u32() == version else { throw FileError.version }
        var g = RoadGraph()
        g.lat = try arr(Int32.self); g.lon = try arr(Int32.self)
        g.from = try arr(Int32.self); g.to = try arr(Int32.self); g.length = try arr(Float.self)
        g.speedForward = try arr(UInt8.self); g.speedBackward = try arr(UInt8.self)
        g.roadClass = try arr(UInt8.self); g.flags = try arr(UInt8.self); g.name = try arr(Int32.self)
        g.shapeStart = try arr(Int32.self); g.shape = try arr(Int32.self)
        let rs = try arr(Int32.self)
        let nb = Int(try u32())
        guard b.count - i >= nb else { throw FileError.damaged("names") }
        g.names = nb == 0 ? [] : String(decoding: b[i ..< i + nb], as: UTF8.self).components(separatedBy: "\u{0}")

        // Check everything an index points at.
        let V = g.lat.count, E = g.from.count
        guard g.lon.count == V, [g.to.count, g.length.count, g.speedForward.count, g.speedBackward.count,
                                  g.roadClass.count, g.flags.count, g.name.count].allSatisfy({ $0 == E }),
              g.shapeStart.count == E + 1, g.shapeStart.first == 0, Int(g.shapeStart.last ?? -1) == g.shape.count,
              g.shape.count % 2 == 0, rs.count % 4 == 0 else { throw FileError.damaged("counts") }
        for e in 0..<E {
            guard g.from[e] >= 0, g.from[e] < V, g.to[e] >= 0, g.to[e] < V, g.length[e].isFinite, g.length[e] >= 0,
                  g.shapeStart[e] <= g.shapeStart[e + 1], g.shapeStart[e + 1] - g.shapeStart[e] >= 0,
                  (g.shapeStart[e + 1] - g.shapeStart[e]) % 2 == 0,
                  g.name[e] >= -1, Int(g.name[e]) < g.names.count, RoadClass(rawValue: g.roadClass[e]) != nil
            else { throw FileError.damaged("edge \(e)") }
        }
        var k = 0
        while k < rs.count {
            let r = RoadGraph.TurnRestriction(fromEdge: rs[k], via: rs[k + 1], toEdge: rs[k + 2], only: rs[k + 3] != 0)
            guard r.fromEdge >= 0, r.fromEdge < E, r.toEdge >= 0, r.toEdge < E, r.via >= 0, r.via < V else { throw FileError.damaged("restriction") }
            g.restrictions.append(r)
            k += 4
        }
        g.buildAdjacency()
        return g
    }
}
