import Compression
import Foundation
@testable import GridCore

/// TEST-ONLY synthetic OSM PBF writer (never real OSM data in the repository).
enum PBFTestEncoder {
    struct Node { var id: Int64; var lat: Double; var lon: Double }
    struct Way { var id: Int64; var refs: [Int64]; var tags: [String: String] }
    struct Relation { var id: Int64; var members: [(type: Int, ref: Int64, role: String)]; var tags: [String: String] }

    // MARK: protobuf

    struct W {
        var b: [UInt8] = []
        mutating func varint(_ v: UInt64) { var v = v; while v >= 0x80 { b.append(UInt8(v & 0x7F) | 0x80); v >>= 7 }; b.append(UInt8(v)) }
        mutating func key(_ f: Int, _ w: Int) { varint(UInt64(f << 3 | w)) }
        mutating func uint(_ f: Int, _ v: UInt64) { key(f, 0); varint(v) }
        mutating func sint(_ f: Int, _ v: Int64) { key(f, 0); varint(zz(v)) }
        mutating func bytes(_ f: Int, _ d: [UInt8]) { key(f, 2); varint(UInt64(d.count)); b += d }
        mutating func packed(_ f: Int, _ vs: [UInt64]) { var w = W(); for v in vs { w.varint(v) }; bytes(f, w.b) }
        func zz(_ v: Int64) -> UInt64 { UInt64(bitPattern: (v << 1) ^ (v >> 63)) }
    }

    static func zz(_ v: Int64) -> UInt64 { UInt64(bitPattern: (v << 1) ^ (v >> 63)) }

    static func zlib(_ raw: [UInt8]) -> [UInt8] {
        var dst = [UInt8](repeating: 0, count: raw.count + 1024)
        let n = raw.withUnsafeBufferPointer { src in
            dst.withUnsafeMutableBufferPointer { compression_encode_buffer($0.baseAddress!, $0.count, src.baseAddress!, src.count, nil, COMPRESSION_ZLIB) }
        }
        var a: UInt32 = 1, b: UInt32 = 0
        for x in raw { a = (a + UInt32(x)) % 65521; b = (b + a) % 65521 }
        let adler = b << 16 | a
        return [0x78, 0x9C] + dst[0..<n] + [UInt8(adler >> 24), UInt8(adler >> 16 & 0xFF), UInt8(adler >> 8 & 0xFF), UInt8(adler & 0xFF)]
    }

    static func blob(type: String, _ payload: [UInt8], compress: Bool) -> [UInt8] {
        var blob = W()
        if compress { blob.uint(2, UInt64(payload.count)); blob.bytes(3, zlib(payload)) } else { blob.bytes(1, payload) }
        var header = W()
        header.bytes(1, Array(type.utf8))
        header.uint(3, UInt64(blob.b.count))
        let n = UInt32(header.b.count)
        return [UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)] + header.b + blob.b
    }

    /// One header blob, then one data block with dense nodes, ways and relations.
    static func encode(nodes: [Node], ways: [Way], relations: [Relation] = [], compress: Bool = true,
                       features: [String] = ["OsmSchema-V0.6", "DenseNodes"]) -> Data {
        var hb = W()
        for f in features { hb.bytes(4, Array(f.utf8)) }
        var out = blob(type: "OSMHeader", hb.b, compress: compress)

        var strings = [""]
        func s(_ x: String) -> UInt64 {
            if let i = strings.firstIndex(of: x) { return UInt64(i) }
            strings.append(x); return UInt64(strings.count - 1)
        }
        // Dense nodes (sorted by id), delta coded, granularity 100.
        var dense = W()
        var ids: [UInt64] = [], lats: [UInt64] = [], lons: [UInt64] = []
        var pid: Int64 = 0, plat: Int64 = 0, plon: Int64 = 0
        for n in nodes.sorted(by: { $0.id < $1.id }) {
            let la = Int64((n.lat * 1e7).rounded()), lo = Int64((n.lon * 1e7).rounded())
            ids.append(zz(n.id - pid)); lats.append(zz(la - plat)); lons.append(zz(lo - plon))
            pid = n.id; plat = la; plon = lo
        }
        dense.packed(1, ids); dense.packed(8, lats); dense.packed(9, lons)
        var g1 = W(); g1.bytes(2, dense.b)
        var g2 = W()
        for w in ways {
            var ww = W()
            ww.uint(1, UInt64(w.id))
            let keys = w.tags.keys.sorted()
            ww.packed(2, keys.map(s)); ww.packed(3, keys.map { s(w.tags[$0]!) })
            var prev: Int64 = 0
            ww.packed(8, w.refs.map { r in defer { prev = r }; return zz(r - prev) })
            g2.bytes(3, ww.b)
        }
        var g3 = W()
        for r in relations {
            var rw = W()
            rw.uint(1, UInt64(r.id))
            let keys = r.tags.keys.sorted()
            rw.packed(2, keys.map(s)); rw.packed(3, keys.map { s(r.tags[$0]!) })
            rw.packed(8, r.members.map { s($0.role) })
            var prev: Int64 = 0
            rw.packed(9, r.members.map { m in defer { prev = m.ref }; return zz(m.ref - prev) })
            rw.packed(10, r.members.map { UInt64($0.type) })
            g3.bytes(4, rw.b)
        }
        var block = W()
        var st = W()
        for x in strings { st.bytes(1, Array(x.utf8)) }
        block.bytes(1, st.b)
        block.bytes(2, g1.b)
        if !ways.isEmpty { block.bytes(2, g2.b) }
        if !relations.isEmpty { block.bytes(2, g3.b) }
        out += blob(type: "OSMData", block.b, compress: compress)
        return Data(out)
    }
}
