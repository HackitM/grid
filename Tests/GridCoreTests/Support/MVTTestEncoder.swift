import Foundation
import simd
@testable import GridCore

/// TEST-ONLY synthetic Mapbox Vector Tile encoder. All fixtures in the Maps tests are built with
/// this (never real map data, which is ODbL and must not enter the repository).
enum MVTTestEncoder {
    enum Val {
        case string(String), float(Float), double(Double), int(Int64), uint(UInt64), sint(Int64), bool(Bool)

        init(_ v: MVTValue) {
            switch v {
            case .string(let s): self = .string(s)
            case .int(let i): self = .int(i)
            case .double(let d): self = .double(d)
            case .bool(let b): self = .bool(b)
            }
        }
    }

    struct Feature {
        var id: UInt64? = nil
        var tags: [(String, Val)] = []
        /// 1 point, 2 line, 3 polygon (anything else is written verbatim, for malformed tests).
        var type: Int
        var geometry: [UInt32]
        var rawTagInts: [UInt32]? = nil
    }

    struct Layer {
        var name: String
        var extent: Int = 4096
        var features: [Feature]
        var version: Int = 2
        var writeExtent = true
    }

    // MARK: Feature builders

    static func tags(_ t: [String: MVTValue]) -> [(String, Val)] {
        t.keys.sorted().map { ($0, Val(t[$0]!)) }
    }

    static func point(_ pts: [SIMD2<Int32>], tags t: [String: MVTValue] = [:], id: UInt64? = nil) -> Feature {
        var g: [UInt32] = [command(1, pts.count)]
        var cursor = SIMD2<Int32>(0, 0)
        for p in pts { g += delta(from: &cursor, to: p) }
        return Feature(id: id, tags: tags(t), type: 1, geometry: g)
    }

    static func line(_ lines: [[SIMD2<Int32>]], tags t: [String: MVTValue] = [:], id: UInt64? = nil) -> Feature {
        var g: [UInt32] = []
        var cursor = SIMD2<Int32>(0, 0)
        for l in lines where !l.isEmpty {
            g.append(command(1, 1)); g += delta(from: &cursor, to: l[0])
            if l.count > 1 {
                g.append(command(2, l.count - 1))
                for p in l.dropFirst() { g += delta(from: &cursor, to: p) }
            }
        }
        return Feature(id: id, tags: tags(t), type: 2, geometry: g)
    }

    /// Polygons as [exterior, holes…]. With `autoWind` exteriors are reoriented to positive
    /// shoelace area (y down) and holes to negative, as the MVT spec requires.
    static func polygon(_ polys: [[[SIMD2<Int32>]]], tags t: [String: MVTValue] = [:], id: UInt64? = nil, autoWind: Bool = true) -> Feature {
        var g: [UInt32] = []
        var cursor = SIMD2<Int32>(0, 0)
        for poly in polys {
            for (ri, ring0) in poly.enumerated() {
                var ring = ring0
                if autoWind {
                    let a = shoelace(ring)
                    if (ri == 0 && a < 0) || (ri > 0 && a > 0) { ring.reverse() }
                }
                guard ring.count >= 1 else { continue }
                g.append(command(1, 1)); g += delta(from: &cursor, to: ring[0])
                if ring.count > 1 {
                    g.append(command(2, ring.count - 1))
                    for p in ring.dropFirst() { g += delta(from: &cursor, to: p) }
                }
                g.append(command(7, 1))
            }
        }
        return Feature(id: id, tags: tags(t), type: 3, geometry: g)
    }

    static func shoelace(_ r: [SIMD2<Int32>]) -> Int64 {
        var a: Int64 = 0
        for i in 0..<r.count {
            let p = r[i], q = r[(i + 1) % r.count]
            a += Int64(p.x) * Int64(q.y) - Int64(q.x) * Int64(p.y)
        }
        return a
    }

    static func command(_ id: Int, _ count: Int) -> UInt32 { UInt32(count << 3 | id) }

    static func zigzag(_ v: Int32) -> UInt32 { UInt32(bitPattern: (v << 1) ^ (v >> 31)) }

    static func delta(from c: inout SIMD2<Int32>, to p: SIMD2<Int32>) -> [UInt32] {
        let out = [zigzag(p.x &- c.x), zigzag(p.y &- c.y)]
        c = p
        return out
    }

    // MARK: Encoding

    static func encode(_ layers: [Layer]) -> Data {
        var tile = Data()
        for l in layers { appendLen(&tile, field: 3, encodeLayer(l)) }
        return tile
    }

    static func encodeLayer(_ l: Layer) -> Data {
        var keys: [String] = [], keyIndex: [String: Int] = [:]
        var values: [Data] = [], valueIndex: [Data: Int] = [:]
        var layer = Data()
        appendVarintField(&layer, field: 15, UInt64(l.version))
        appendLen(&layer, field: 1, Data(l.name.utf8))
        for f in l.features {
            var fd = Data()
            if let id = f.id { appendVarintField(&fd, field: 1, id) }
            var tagInts: [UInt32] = []
            if let raw = f.rawTagInts { tagInts = raw } else {
                for (k, v) in f.tags {
                    let ki = keyIndex[k] ?? { keys.append(k); keyIndex[k] = keys.count - 1; return keys.count - 1 }()
                    let vd = encodeValue(v)
                    let vi = valueIndex[vd] ?? { values.append(vd); valueIndex[vd] = values.count - 1; return values.count - 1 }()
                    tagInts += [UInt32(ki), UInt32(vi)]
                }
            }
            if !tagInts.isEmpty { appendLen(&fd, field: 2, packed(tagInts)) }
            appendVarintField(&fd, field: 3, UInt64(f.type))
            if !f.geometry.isEmpty { appendLen(&fd, field: 4, packed(f.geometry)) }
            appendLen(&layer, field: 2, fd)
        }
        for k in keys { appendLen(&layer, field: 3, Data(k.utf8)) }
        for v in values { appendLen(&layer, field: 4, v) }
        if l.writeExtent { appendVarintField(&layer, field: 5, UInt64(l.extent)) }
        return layer
    }

    static func encodeValue(_ v: Val) -> Data {
        var d = Data()
        switch v {
        case .string(let s): appendLen(&d, field: 1, Data(s.utf8))
        case .float(let f):
            appendKey(&d, field: 2, wire: 5)
            var b = f.bitPattern.littleEndian; withUnsafeBytes(of: &b) { d.append(contentsOf: $0) }
        case .double(let x):
            appendKey(&d, field: 3, wire: 1)
            var b = x.bitPattern.littleEndian; withUnsafeBytes(of: &b) { d.append(contentsOf: $0) }
        case .int(let i): appendVarintField(&d, field: 4, UInt64(bitPattern: i))
        case .uint(let u): appendVarintField(&d, field: 5, u)
        case .sint(let i): appendVarintField(&d, field: 6, UInt64(bitPattern: (i << 1) ^ (i >> 63)))
        case .bool(let b): appendVarintField(&d, field: 7, b ? 1 : 0)
        }
        return d
    }

    static func packed(_ ints: [UInt32]) -> Data {
        var d = Data()
        for i in ints { appendVarint(&d, UInt64(i)) }
        return d
    }

    static func appendVarint(_ d: inout Data, _ v: UInt64) {
        var v = v
        while v >= 0x80 { d.append(UInt8(v & 0x7f) | 0x80); v >>= 7 }
        d.append(UInt8(v))
    }
    static func appendKey(_ d: inout Data, field: Int, wire: Int) { appendVarint(&d, UInt64(field << 3 | wire)) }
    static func appendVarintField(_ d: inout Data, field: Int, _ v: UInt64) { appendKey(&d, field: field, wire: 0); appendVarint(&d, v) }
    static func appendLen(_ d: inout Data, field: Int, _ payload: Data) {
        appendKey(&d, field: field, wire: 2); appendVarint(&d, UInt64(payload.count)); d.append(payload)
    }
}
