import Compression
import Foundation

// OpenStreetMap PBF reader (https://wiki.openstreetmap.org/wiki/PBF_Format). The file is untrusted:
// every read is bounds-checked (PBReader), block sizes are capped as the format specifies (header
// ≤ 64 KiB, blob ≤ 32 MiB), decompressed sizes must match, and malformed blocks throw; nothing
// traps. Only what routing needs is decoded: node coordinates, way refs and tags, and relation
// members and tags.

public enum PBFError: Error, Equatable {
    case truncated, malformed(String), unsupported(String), cancelled
}

/// A way as read from the file (refs are OSM node ids).
public struct OSMWay: Sendable {
    public var id: Int64
    public var refs: [Int64]
    public var tags: [String: String]
}

public struct OSMRelation: Sendable {
    public enum MemberType: UInt8, Sendable { case node = 0, way = 1, relation = 2 }
    public struct Member: Sendable { public var type: MemberType; public var ref: Int64; public var role: String }
    public var id: Int64
    public var members: [Member]
    public var tags: [String: String]
}

public struct PBFReader {
    public struct Visitor {
        /// Node id and position (degrees × 1e7). nil: node groups are skipped.
        public var node: ((Int64, Int32, Int32) -> Void)?
        /// Only ways that have this tag key are decoded (all ways when nil).
        public var wayKey: String?
        public var way: ((OSMWay) -> Void)?
        /// Only relations whose `type` tag is one of these are decoded.
        public var relationTypes: Set<String> = []
        public var relation: ((OSMRelation) -> Void)?
        public init() {}
    }

    static let maxHeader = 64 << 10
    static let maxBlob = 32 << 20

    let data: Data

    public init(data: Data) { self.data = data }

    /// Reads the whole file. `progress` gets the fraction of bytes read; `cancelled` is polled per block.
    public func scan(_ v: Visitor, progress: ((Double) -> Void)? = nil, cancelled: (() -> Bool)? = nil) throws {
        var offset = 0
        let total = data.count
        var sawHeader = false
        while offset < total {
            if cancelled?() == true { throw PBFError.cancelled }
            guard total - offset >= 4 else { throw PBFError.truncated }
            let hlen = data.withUnsafeBytes { raw -> Int in
                let p = raw.baseAddress!.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
                return Int(p[0]) << 24 | Int(p[1]) << 16 | Int(p[2]) << 8 | Int(p[3])
            }
            offset += 4
            guard hlen > 0, hlen <= Self.maxHeader, total - offset >= hlen else { throw PBFError.malformed("blob header size") }
            let header = [UInt8](data[data.startIndex + offset ..< data.startIndex + offset + hlen])
            offset += hlen
            var type = ""
            var dataSize = -1
            var r = PBReader(header, 0..<header.count)
            while let (f, w) = try wrap({ try r.nextField() }) {
                switch (f, w) {
                case (1, 2): let rg = try wrap { try r.lengthDelimited() }; type = String(decoding: header[rg], as: UTF8.self)
                case (3, 0): dataSize = Int(clamping: try wrap { try r.varint() })
                default: try wrap { try r.skip(w) }
                }
            }
            guard dataSize > 0, dataSize <= Self.maxBlob, total - offset >= dataSize else { throw PBFError.malformed("blob size") }
            let blob = [UInt8](data[data.startIndex + offset ..< data.startIndex + offset + dataSize])
            offset += dataSize
            progress?(Double(offset) / Double(max(1, total)))
            switch type {
            case "OSMHeader":
                try checkHeader(try Self.inflate(blob))
                sawHeader = true
            case "OSMData":
                guard sawHeader else { throw PBFError.malformed("data before header") }
                try readBlock(try Self.inflate(blob), v)
            default:
                continue   // unknown blob types are skipped, as the format allows
            }
        }
    }

    private func wrap<T>(_ f: () throws -> T) throws -> T {
        do { return try f() } catch let e as MVTError {
            switch e { case .truncated: throw PBFError.truncated; default: throw PBFError.malformed("\(e)") }
        }
    }

    // MARK: Blobs

    /// The uncompressed bytes of a Blob (raw, or zlib). Other compressions are refused.
    static func inflate(_ blob: [UInt8]) throws -> [UInt8] {
        var r = PBReader(blob, 0..<blob.count)
        var raw: Range<Int>?
        var zlib: Range<Int>?
        var rawSize = -1
        do {
            while let (f, w) = try r.nextField() {
                switch (f, w) {
                case (1, 2): raw = try r.lengthDelimited()
                case (2, 0): rawSize = Int(clamping: try r.varint())
                case (3, 2): zlib = try r.lengthDelimited()
                case (4, 2), (5, 2), (6, 2), (7, 2): throw PBFError.unsupported("compression")
                default: try r.skip(w)
                }
            }
        } catch let e as MVTError { throw PBFError.malformed("\(e)") }
        if let raw { return Array(blob[raw]) }
        guard let z = zlib, z.count > 6, rawSize > 0, rawSize <= maxBlob else { throw PBFError.malformed("blob") }
        // zlib = 2-byte header + raw DEFLATE + 4-byte Adler-32; Compression's ZLIB is raw DEFLATE.
        let cmf = blob[z.lowerBound]
        guard cmf & 0x0F == 8, (UInt16(cmf) << 8 | UInt16(blob[z.lowerBound + 1])) % 31 == 0 else { throw PBFError.malformed("zlib header") }
        var out = [UInt8](repeating: 0, count: rawSize)
        let n = blob.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                compression_decode_buffer(dst.baseAddress!, rawSize, src.baseAddress!.advanced(by: z.lowerBound + 2),
                                          z.count - 2, nil, COMPRESSION_ZLIB)
            }
        }
        guard n == rawSize else { throw PBFError.malformed("inflated size") }
        return out
    }

    private func checkHeader(_ b: [UInt8]) throws {
        var r = PBReader(b, 0..<b.count)
        while let (f, w) = try wrap({ try r.nextField() }) {
            if f == 4 && w == 2 {
                let rg = try wrap { try r.lengthDelimited() }
                let feature = String(decoding: b[rg], as: UTF8.self)
                guard ["OsmSchema-V0.6", "DenseNodes"].contains(feature) else { throw PBFError.unsupported(feature) }
            } else {
                try wrap { try r.skip(w) }
            }
        }
    }

    // MARK: Primitive blocks

    private func readBlock(_ b: [UInt8], _ v: Visitor) throws {
        var strings: [Range<Int>] = []
        var groups: [Range<Int>] = []
        var granularity: Int64 = 100
        var latOffset: Int64 = 0, lonOffset: Int64 = 0
        var r = PBReader(b, 0..<b.count)
        try wrap {
            while let (f, w) = try r.nextField() {
                switch (f, w) {
                case (1, 2):
                    let st = try r.lengthDelimited()
                    var sr = PBReader(b, st)
                    while let (sf, sw) = try sr.nextField() {
                        if sf == 1 && sw == 2 { strings.append(try sr.lengthDelimited()) } else { try sr.skip(sw) }
                    }
                case (2, 2): groups.append(try r.lengthDelimited())
                case (17, 0): granularity = Int64(clamping: try r.varint())
                case (19, 0): latOffset = Int64(bitPattern: try r.varint())
                case (20, 0): lonOffset = Int64(bitPattern: try r.varint())
                default: try r.skip(w)
                }
            }
        }
        guard granularity > 0, granularity <= 1_000_000 else { throw PBFError.malformed("granularity") }
        // Strings are decoded on first use only.
        var cache = [String?](repeating: nil, count: strings.count)
        func str(_ i: Int) -> String? {
            guard i >= 0, i < strings.count else { return nil }
            if let s = cache[i] { return s }
            let s = String(decoding: b[strings[i]], as: UTF8.self)
            cache[i] = s
            return s
        }
        func index(of s: String) -> Int? { strings.indices.first { str($0) == s } }
        let wayKeyIndex: Int? = v.wayKey.flatMap(index(of:))
        if v.wayKey != nil && wayKeyIndex == nil && v.node == nil && v.relation == nil { return }   // nothing here

        func e7(_ raw: Int64, _ off: Int64) -> Int32 {
            let nano = off &+ granularity &* raw          // degrees × 1e9
            return Int32(clamping: nano / 100)
        }

        for g in groups {
            var gr = PBReader(b, g)
            while let (f, w) = try wrap({ try gr.nextField() }) {
                switch (f, w) {
                case (1, 2) where v.node != nil:   // plain Node
                    let rg = try wrap { try gr.lengthDelimited() }
                    var nr = PBReader(b, rg)
                    var id: Int64 = 0, lat: Int64 = 0, lon: Int64 = 0
                    while let (nf, nw) = try wrap({ try nr.nextField() }) {
                        switch (nf, nw) {
                        case (1, 0): id = Self.zigzag(try wrap { try nr.varint() })
                        case (8, 0): lat = Self.zigzag(try wrap { try nr.varint() })
                        case (9, 0): lon = Self.zigzag(try wrap { try nr.varint() })
                        default: try wrap { try nr.skip(nw) }
                        }
                    }
                    v.node?(id, e7(lat, latOffset), e7(lon, lonOffset))
                case (2, 2) where v.node != nil:   // DenseNodes
                    let rg = try wrap { try gr.lengthDelimited() }
                    var ids: Range<Int>?, lats: Range<Int>?, lons: Range<Int>?
                    var dr = PBReader(b, rg)
                    while let (df, dw) = try wrap({ try dr.nextField() }) {
                        switch (df, dw) {
                        case (1, 2): ids = try wrap { try dr.lengthDelimited() }
                        case (8, 2): lats = try wrap { try dr.lengthDelimited() }
                        case (9, 2): lons = try wrap { try dr.lengthDelimited() }
                        default: try wrap { try dr.skip(dw) }
                        }
                    }
                    guard let ids, let lats, let lons else { continue }
                    var ir = PBReader(b, ids), ar = PBReader(b, lats), or = PBReader(b, lons)
                    var id: Int64 = 0, lat: Int64 = 0, lon: Int64 = 0
                    while ir.i < ir.end {
                        guard ar.i < ar.end, or.i < or.end else { throw PBFError.malformed("dense node arrays") }
                        id &+= Self.zigzag(try wrap { try ir.varint() })
                        lat &+= Self.zigzag(try wrap { try ar.varint() })
                        lon &+= Self.zigzag(try wrap { try or.varint() })
                        v.node?(id, e7(lat, latOffset), e7(lon, lonOffset))
                    }
                case (3, 2) where v.way != nil:
                    let rg = try wrap { try gr.lengthDelimited() }
                    var wr = PBReader(b, rg)
                    var id: Int64 = 0
                    var keys: Range<Int>?, vals: Range<Int>?, refs: Range<Int>?
                    while let (wf, ww) = try wrap({ try wr.nextField() }) {
                        switch (wf, ww) {
                        case (1, 0): id = Int64(bitPattern: try wrap { try wr.varint() })
                        case (2, 2): keys = try wrap { try wr.lengthDelimited() }
                        case (3, 2): vals = try wrap { try wr.lengthDelimited() }
                        case (8, 2): refs = try wrap { try wr.lengthDelimited() }
                        default: try wrap { try wr.skip(ww) }
                        }
                    }
                    let k = try packed(b, keys), vv = try packed(b, vals)
                    guard k.count == vv.count else { throw PBFError.malformed("way tags") }
                    if v.wayKey != nil {
                        guard let want = wayKeyIndex, k.contains(UInt64(want)) else { continue }
                    }
                    var tags: [String: String] = [:]
                    for (ki, vi) in zip(k, vv) {
                        if let ks = str(Int(clamping: ki)), let vs = str(Int(clamping: vi)) { tags[ks] = vs }
                    }
                    var out: [Int64] = []
                    if let refs {
                        var rr = PBReader(b, refs)
                        var cur: Int64 = 0
                        while rr.i < rr.end {
                            cur &+= Self.zigzag(try wrap { try rr.varint() })
                            out.append(cur)
                            if out.count > 100_000 { throw PBFError.malformed("way too long") }
                        }
                    }
                    v.way?(OSMWay(id: id, refs: out, tags: tags))
                case (4, 2) where v.relation != nil:
                    let rg = try wrap { try gr.lengthDelimited() }
                    var rr = PBReader(b, rg)
                    var id: Int64 = 0
                    var keys: Range<Int>?, vals: Range<Int>?, roles: Range<Int>?, mems: Range<Int>?, types: Range<Int>?
                    while let (rf, rw) = try wrap({ try rr.nextField() }) {
                        switch (rf, rw) {
                        case (1, 0): id = Int64(bitPattern: try wrap { try rr.varint() })
                        case (2, 2): keys = try wrap { try rr.lengthDelimited() }
                        case (3, 2): vals = try wrap { try rr.lengthDelimited() }
                        case (8, 2): roles = try wrap { try rr.lengthDelimited() }
                        case (9, 2): mems = try wrap { try rr.lengthDelimited() }
                        case (10, 2): types = try wrap { try rr.lengthDelimited() }
                        default: try wrap { try rr.skip(rw) }
                        }
                    }
                    let k = try packed(b, keys), vv = try packed(b, vals)
                    guard k.count == vv.count else { throw PBFError.malformed("relation tags") }
                    var tags: [String: String] = [:]
                    for (ki, vi) in zip(k, vv) {
                        if let ks = str(Int(clamping: ki)), let vs = str(Int(clamping: vi)) { tags[ks] = vs }
                    }
                    guard let t = tags["type"], v.relationTypes.contains(t) else { continue }
                    let rs = try packed(b, roles), ts = try packed(b, types)
                    var ms: [Int64] = []
                    if let mems {
                        var mr = PBReader(b, mems)
                        var cur: Int64 = 0
                        while mr.i < mr.end { cur &+= Self.zigzag(try wrap { try mr.varint() }); ms.append(cur) }
                    }
                    guard rs.count == ms.count, ts.count == ms.count, ms.count <= 10_000 else { throw PBFError.malformed("relation members") }
                    var members: [OSMRelation.Member] = []
                    for i in ms.indices {
                        guard let type = OSMRelation.MemberType(rawValue: UInt8(clamping: ts[i])) else { continue }
                        members.append(.init(type: type, ref: ms[i], role: str(Int(clamping: rs[i])) ?? ""))
                    }
                    v.relation?(OSMRelation(id: id, members: members, tags: tags))
                default:
                    try wrap { try gr.skip(w) }
                }
            }
        }
    }

    private func packed(_ b: [UInt8], _ r: Range<Int>?) throws -> [UInt64] {
        guard let r else { return [] }
        var out: [UInt64] = []
        var pr = PBReader(b, r)
        while pr.i < pr.end { out.append(try wrap { try pr.varint() }) }
        return out
    }

    @inline(__always) static func zigzag(_ n: UInt64) -> Int64 { Int64(bitPattern: (n >> 1) ^ (0 &- (n & 1))) }
}
