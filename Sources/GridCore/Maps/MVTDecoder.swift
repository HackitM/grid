import Foundation
import simd

// Mapbox Vector Tile (protobuf) decoder. Input is untrusted: every read is bounds-checked, every
// count is checked against the bytes that remain, and every MVTLimits field is enforced. The
// decoder is total: malformed input throws or drops the offending feature; it never traps.

public enum MVTDecoder {
    /// Decodes `data`. When `layers` is non-nil only layers with those names are parsed (the others
    /// are skipped without looking at their features).
    public static func decode(_ data: Data, layers wanted: Set<String>? = nil, limits: MVTLimits = .init()) throws -> MVTTile {
        guard data.count <= limits.maxBytes else { throw MVTError.tooLarge }
        let bytes = [UInt8](data)
        var reader = PBReader(bytes, 0..<bytes.count)
        var out: [MVTLayer] = []
        var layerCount = 0
        var geometryBudget = max(0, limits.maxGeometryInts)
        var scratchGeom: [UInt32] = []
        var scratchTags: [UInt32] = []
        while let (field, wire) = try reader.nextField() {
            if field == 3 && wire == 2 {
                let range = try reader.lengthDelimited()
                layerCount += 1
                if layerCount > limits.maxLayers { throw MVTError.limitExceeded("layers") }
                if let layer = try decodeLayer(bytes, range, wanted, limits, &geometryBudget, &scratchGeom, &scratchTags) {
                    out.append(layer)
                }
            } else {
                try reader.skip(wire)
            }
        }
        return MVTTile(layers: out)
    }

    // MARK: Layer

    private static func decodeLayer(_ bytes: [UInt8], _ range: Range<Int>, _ wanted: Set<String>?, _ limits: MVTLimits,
                                    _ geometryBudget: inout Int, _ geom: inout [UInt32], _ tagScratch: inout [UInt32]) throws -> MVTLayer? {
        // Pass 1: find the name without parsing anything else.
        var nameRange: Range<Int>?
        do {
            var r = PBReader(bytes, range)
            while let (field, wire) = try r.nextField() {
                if field == 1 && wire == 2 { nameRange = try r.lengthDelimited(); break }
                try r.skip(wire)
            }
        }
        guard let nr = nameRange, nr.count <= limits.maxStringBytes,
              let name = String(bytes: bytes[nr], encoding: .utf8) else { return nil }
        if let wanted, !wanted.contains(name) { return nil }

        // Pass 2: collect the ranges of features, keys and values.
        var extent: Int64 = 4096
        var featureRanges: [Range<Int>] = []
        var keyRanges: [Range<Int>] = []
        var valueRanges: [Range<Int>] = []
        var r = PBReader(bytes, range)
        while let (field, wire) = try r.nextField() {
            switch (field, wire) {
            case (2, 2):
                featureRanges.append(try r.lengthDelimited())
                if featureRanges.count > limits.maxFeaturesPerLayer { throw MVTError.limitExceeded("features") }
            case (3, 2):
                keyRanges.append(try r.lengthDelimited())
                if keyRanges.count > limits.maxKeysOrValuesPerLayer { throw MVTError.limitExceeded("keys") }
            case (4, 2):
                valueRanges.append(try r.lengthDelimited())
                if valueRanges.count > limits.maxKeysOrValuesPerLayer { throw MVTError.limitExceeded("values") }
            case (5, 0):
                let v = try r.varint()
                extent = v > UInt64(Int32.max) ? 0 : Int64(v)
            default:
                try r.skip(wire)
            }
        }
        guard extent > 0, extent <= 1 << 16 else { return nil }

        var keys: [String?] = []
        keys.reserveCapacity(keyRanges.count)
        for kr in keyRanges {
            keys.append(kr.count <= limits.maxStringBytes ? String(bytes: bytes[kr], encoding: .utf8) : nil)
        }
        var values: [MVTValue?] = []
        values.reserveCapacity(valueRanges.count)
        for vr in valueRanges { values.append(parseValue(bytes, vr, limits)) }

        var features: [MVTFeature] = []
        features.reserveCapacity(featureRanges.count)
        let ext = Int32(extent)
        for fr in featureRanges {
            if let f = try decodeFeature(bytes, fr, keys, values, ext, limits, &geometryBudget, &geom, &tagScratch) {
                features.append(f)
            }
        }
        return MVTLayer(name: name, extent: ext, features: features)
    }

    // MARK: Values

    private static func parseValue(_ bytes: [UInt8], _ range: Range<Int>, _ limits: MVTLimits) -> MVTValue? {
        var r = PBReader(bytes, range)
        var result: MVTValue?
        do {
            while let (field, wire) = try r.nextField() {
                switch (field, wire) {
                case (1, 2):
                    let sr = try r.lengthDelimited()
                    if sr.count > limits.maxStringBytes { result = nil; continue }
                    if let s = String(bytes: bytes[sr], encoding: .utf8) { result = .string(s) } else { result = nil }
                case (2, 5):
                    guard r.i + 4 <= r.end else { return nil }
                    var bits: UInt32 = 0
                    for k in 0..<4 { bits |= UInt32(bytes[r.i + k]) << UInt32(8 * k) }
                    r.i += 4
                    let f = Float(bitPattern: bits)
                    result = f.isFinite ? .double(Double(f)) : nil
                case (3, 1):
                    guard r.i + 8 <= r.end else { return nil }
                    var bits: UInt64 = 0
                    for k in 0..<8 { bits |= UInt64(bytes[r.i + k]) << UInt64(8 * k) }
                    r.i += 8
                    let d = Double(bitPattern: bits)
                    result = d.isFinite ? .double(d) : nil
                case (4, 0):
                    result = .int(Int64(bitPattern: try r.varint()))
                case (5, 0):
                    let v = try r.varint()
                    result = v <= UInt64(Int64.max) ? .int(Int64(v)) : .double(Double(v))
                case (6, 0):
                    let v = try r.varint()
                    result = .int(Int64(bitPattern: v >> 1) ^ -Int64(bitPattern: v & 1))
                case (7, 0):
                    result = .bool(try r.varint() != 0)
                default:
                    try r.skip(wire)
                }
            }
        } catch {
            return nil
        }
        return result
    }

    // MARK: Features

    private static func decodeFeature(_ bytes: [UInt8], _ range: Range<Int>, _ keys: [String?], _ values: [MVTValue?], _ extent: Int32,
                                      _ limits: MVTLimits, _ budget: inout Int, _ ints: inout [UInt32], _ tagInts: inout [UInt32]) throws -> MVTFeature? {
        var id: UInt64?
        var type = 0
        ints.removeAll(keepingCapacity: true)
        tagInts.removeAll(keepingCapacity: true)
        do {
            var r = PBReader(bytes, range)
            while let (field, wire) = try r.nextField() {
                switch (field, wire) {
                case (1, 0): id = try r.varint()
                case (3, 0): type = Int(truncatingIfNeeded: try r.varint())
                case (2, 2):
                    var pr = PBReader(bytes, try r.lengthDelimited())
                    while pr.i < pr.end {
                        let v = try pr.varint()
                        guard v <= UInt64(UInt32.max) else { return nil }
                        tagInts.append(UInt32(v))
                        if tagInts.count > 2 * limits.maxKeysOrValuesPerLayer { return nil }
                    }
                case (2, 0):
                    let v = try r.varint()
                    guard v <= UInt64(UInt32.max) else { return nil }
                    tagInts.append(UInt32(v))
                    if tagInts.count > 2 * limits.maxKeysOrValuesPerLayer { return nil }
                case (4, 2):
                    var pr = PBReader(bytes, try r.lengthDelimited())
                    // Every int takes at least one byte, so the byte length bounds the count.
                    budget -= pr.end - pr.i
                    if budget < 0 { throw MVTError.limitExceeded("geometry") }
                    while pr.i < pr.end {
                        let v = try pr.varint()
                        guard v <= UInt64(UInt32.max) else { return nil }
                        ints.append(UInt32(v))
                    }
                case (4, 0):
                    budget -= 1
                    if budget < 0 { throw MVTError.limitExceeded("geometry") }
                    let v = try r.varint()
                    guard v <= UInt64(UInt32.max) else { return nil }
                    ints.append(UInt32(v))
                default:
                    try r.skip(wire)
                }
            }
        } catch let e as MVTError {
            if case .limitExceeded = e { throw e }
            return nil
        }
        guard tagInts.count % 2 == 0 else { return nil }
        var tags: [String: MVTValue] = [:]
        var t = 0
        while t < tagInts.count {
            let k = Int(tagInts[t]), v = Int(tagInts[t + 1])
            t += 2
            guard k < keys.count, v < values.count else { return nil }
            if let key = keys[k], let value = values[v] { tags[key] = value }
        }
        guard let geometry = decodeGeometry(type: type, ints, extent: extent, maxVertices: limits.maxVerticesPerFeature) else { return nil }
        return MVTFeature(id: id, tags: tags, geometry: geometry)
    }

    // MARK: Geometry

    @inline(__always) private static func unzigzag(_ v: UInt32) -> Int64 { Int64(v >> 1) ^ -Int64(v & 1) }

    private static func decodeGeometry(type: Int, _ ints: [UInt32], extent: Int32, maxVertices: Int) -> MVTGeometry? {
        guard type >= 1, type <= 3, !ints.isEmpty else { return nil }
        let lim = Int64(extent) * 2
        var cx: Int64 = 0, cy: Int64 = 0
        var total = 0
        var points: [SIMD2<Int32>] = []
        var parts: [[SIMD2<Int32>]] = []
        var current: [SIMD2<Int32>] = []
        var polygons: [[[SIMD2<Int32>]]] = []
        var haveCurrent = false

        func finish() {
            defer { current = []; haveCurrent = false }
            guard haveCurrent else { return }
            var ring = dedupe(current)
            if type == 2 {
                if ring.count >= 2 { parts.append(ring) }
                return
            }
            if ring.count > 1, ring.first == ring.last { ring.removeLast() }
            guard ring.count >= 3 else { return }
            var area: Int64 = 0
            var prev = ring[ring.count - 1]
            for p in ring {
                area += Int64(prev.x) * Int64(p.y) - Int64(p.x) * Int64(prev.y)
                prev = p
            }
            if area > 0 { polygons.append([ring]) }
            else if area < 0, !polygons.isEmpty { polygons[polygons.count - 1].append(ring) }
        }

        var i = 0
        let n = ints.count
        while i < n {
            let cmdInt = ints[i]; i += 1
            let cmd = cmdInt & 7
            let count = Int(cmdInt >> 3)
            switch cmd {
            case 1, 2:
                guard count <= (n - i) / 2 else { return nil }
                if cmd == 2 && type != 1 && !haveCurrent { return nil }
                for _ in 0..<count {
                    cx = cx &+ unzigzag(ints[i]); cy = cy &+ unzigzag(ints[i + 1]); i += 2
                    total += 1
                    if total > maxVertices { return nil }
                    let p = SIMD2<Int32>(Int32(max(-lim, min(lim, cx))), Int32(max(-lim, min(lim, cy))))
                    if type == 1 { points.append(p); continue }
                    if cmd == 1 { finish(); haveCurrent = true }
                    current.append(p)
                }
            case 7:
                if type == 3 { finish() }
            default:
                return nil
            }
        }
        if type != 1 { finish() }
        switch type {
        case 1: return points.isEmpty ? nil : .points(points)
        case 2: return parts.isEmpty ? nil : .lines(parts)
        default: return polygons.isEmpty ? nil : .polygons(polygons)
        }
    }

    private static func dedupe(_ pts: [SIMD2<Int32>]) -> [SIMD2<Int32>] {
        var out: [SIMD2<Int32>] = []
        out.reserveCapacity(pts.count)
        for p in pts where out.last != p { out.append(p) }
        return out
    }
}

// MARK: - Protobuf reader

struct PBReader {
    let b: [UInt8]
    var i: Int
    let end: Int

    init(_ bytes: [UInt8], _ range: Range<Int>) { b = bytes; i = range.lowerBound; end = range.upperBound }

    mutating func varint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        for k in 0..<10 {
            guard i < end else { throw MVTError.truncated }
            let byte = b[i]; i += 1
            if k == 9 && byte > 1 { throw MVTError.malformed("varint overflow") }
            result |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        throw MVTError.malformed("varint too long")
    }

    /// Next (field number, wire type), or nil at the end of the message.
    mutating func nextField() throws -> (Int, Int)? {
        guard i < end else { return nil }
        let key = try varint()
        let field = Int(key >> 3)
        guard field > 0 else { throw MVTError.malformed("field 0") }
        return (field, Int(key & 7))
    }

    mutating func lengthDelimited() throws -> Range<Int> {
        let len = try varint()
        guard len <= UInt64(end - i) else { throw MVTError.truncated }
        let r = i..<(i + Int(len))
        i = r.upperBound
        return r
    }

    mutating func skip(_ wire: Int) throws {
        switch wire {
        case 0: _ = try varint()
        case 1: guard end - i >= 8 else { throw MVTError.truncated }; i += 8
        case 2: _ = try lengthDelimited()
        case 5: guard end - i >= 4 else { throw MVTError.truncated }; i += 4
        default: throw MVTError.malformed("wire type \(wire)")
        }
    }
}
