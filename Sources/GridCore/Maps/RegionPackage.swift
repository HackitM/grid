import Foundation

/// On-disk camera package for one region (little-endian):
///
///     "GALP"  u32 version = 1  u32 count
///     per camera: i32 lat ×1e-7, i32 lon ×1e-7, u8 osm type (0 node, 1 way), i64 osm id,
///                 u8 vendor, u8 direction count (≤ 8), u16 × count directions (0…359),
///                 u32 operator, u32 mount, u32 zone, u32 vendor-other (string indices,
///                 0xFFFFFFFF = nil), i64 lastEdited seconds (Int64.min = nil)
///     string table: u32 count, then per string u32 byte length + UTF-8 bytes
///
/// Decoding treats the file as untrusted: every read is bounds-checked, every index validated,
/// and truncation or trailing bytes are rejected.
public enum RegionPackage {
    static let magic: [UInt8] = [0x47, 0x41, 0x4C, 0x50]   // "GALP"
    static let noString: UInt32 = 0xFFFF_FFFF
    static let minCameraBytes = 4 + 4 + 1 + 8 + 1 + 1 + 16 + 8
    /// Longest string GRID writes is 120 characters (≤ 480 UTF-8 bytes); anything longer is a
    /// tampered file.
    static let maxStringBytes = 512

    private static let vendorCodes: [ALPRVendor] = [.unknown, .flock, .motorola, .genetec, .axis, .leonardo, .rekor, .axon, .neology]
    private static let otherCode: UInt8 = 9

    // MARK: Encode

    public static func encode(_ cameras: [ALPRCamera]) -> Data {
        var out = [UInt8]()
        out.reserveCapacity(16 + cameras.count * 56)
        var strings: [String] = []
        var lookup: [String: UInt32] = [:]
        func idx(_ s: String?) -> UInt32 {
            guard let s else { return noString }
            if let i = lookup[s] { return i }
            let i = UInt32(strings.count)
            strings.append(s); lookup[s] = i
            return i
        }
        func u32(_ v: UInt32) { for s in stride(from: 0, to: 32, by: 8) { out.append(UInt8(truncatingIfNeeded: v >> UInt32(s))) } }
        func u64(_ v: UInt64) { for s in stride(from: 0, to: 64, by: 8) { out.append(UInt8(truncatingIfNeeded: v >> UInt64(s))) } }
        func e7(_ v: Double) -> UInt32 { UInt32(bitPattern: Int32(clamping: Int((v * 1e7).rounded()))) }

        out.append(contentsOf: magic)
        u32(1); u32(UInt32(truncatingIfNeeded: cameras.filter { $0.coordinate.isValid }.count))
        let cameras = cameras.filter { $0.coordinate.isValid }
        for c in cameras {
            u32(e7(c.coordinate.lat)); u32(e7(c.coordinate.lon))
            switch c.id {
            case .node(let n): out.append(0); u64(UInt64(bitPattern: n))
            case .way(let w): out.append(1); u64(UInt64(bitPattern: w))
            }
            var otherString: String?
            switch c.vendor {
            case .other(let s): out.append(otherCode); otherString = s
            default: out.append(UInt8(vendorCodes.firstIndex(of: c.vendor) ?? 0))
            }
            let dirs = c.directions.prefix(8)
            out.append(UInt8(dirs.count))
            for d in dirs { out.append(UInt8(d & 0xFF)); out.append(UInt8(d >> 8)) }
            u32(idx(c.operatorName)); u32(idx(c.mount)); u32(idx(c.zone)); u32(idx(otherString))
            if let d = c.lastEdited, d.timeIntervalSince1970.isFinite {
                u64(UInt64(bitPattern: Int64(max(-1e15, min(1e15, d.timeIntervalSince1970.rounded(.down))))))
            } else { u64(UInt64(bitPattern: Int64.min)) }
        }
        u32(UInt32(strings.count))
        for s in strings {
            let b = Array(s.utf8)
            u32(UInt32(b.count)); out.append(contentsOf: b)
        }
        return Data(out)
    }

    // MARK: Decode

    private struct Reader {
        let b: [UInt8]
        var o = 0
        var remaining: Int { b.count - o }
        mutating func take(_ n: Int) throws -> Int {
            guard n >= 0, n <= remaining else { throw ALPRParseError.truncated }
            defer { o += n }
            return o
        }
        mutating func u8() throws -> UInt8 { b[try take(1)] }
        mutating func u16() throws -> UInt16 { let p = try take(2); return UInt16(b[p]) | UInt16(b[p + 1]) << 8 }
        mutating func u32() throws -> UInt32 {
            let p = try take(4)
            return UInt32(b[p]) | UInt32(b[p + 1]) << 8 | UInt32(b[p + 2]) << 16 | UInt32(b[p + 3]) << 24
        }
        mutating func u64() throws -> UInt64 {
            let p = try take(8)
            var v: UInt64 = 0
            for i in 0..<8 { v |= UInt64(b[p + i]) << UInt64(8 * i) }
            return v
        }
    }

    private struct Raw {
        var id: OSMElementID, coord: LonLat, dirs: [UInt16], vendor: UInt8
        var op: UInt32, mount: UInt32, zone: UInt32, other: UInt32, edited: Int64
    }

    public static func decode(_ data: Data, maxCount: Int = 2_000_000) throws -> [ALPRCamera] {
        var r = Reader(b: [UInt8](data))
        guard r.remaining >= 12 else { throw ALPRParseError.truncated }
        for m in magic { guard try r.u8() == m else { throw ALPRParseError.malformed("magic") } }
        guard try r.u32() == 1 else { throw ALPRParseError.malformed("version") }
        let count = Int(try r.u32())
        guard count <= maxCount else { throw ALPRParseError.tooLarge }
        // The cameras alone need this many bytes (plus the 4-byte string count).
        guard count <= (r.remaining - 4) / minCameraBytes else { throw ALPRParseError.truncated }

        var raws: [Raw] = []
        raws.reserveCapacity(count)
        for _ in 0..<count {
            let lat = Double(Int32(bitPattern: try r.u32())) * 1e-7, lon = Double(Int32(bitPattern: try r.u32())) * 1e-7
            let coord = LonLat(lon: lon, lat: lat)
            guard coord.isValid else { throw ALPRParseError.malformed("coordinate") }
            let type = try r.u8()
            let oid = Int64(bitPattern: try r.u64())
            let id: OSMElementID
            switch type {
            case 0: id = .node(oid)
            case 1: id = .way(oid)
            default: throw ALPRParseError.malformed("osm type")
            }
            let vendor = try r.u8()
            guard vendor <= otherCode else { throw ALPRParseError.malformed("vendor") }
            let nd = Int(try r.u8())
            guard nd <= 8 else { throw ALPRParseError.malformed("direction count") }
            var dirs: [UInt16] = []
            for _ in 0..<nd {
                let d = try r.u16()
                guard d < 360 else { throw ALPRParseError.malformed("direction") }
                dirs.append(d)
            }
            let op = try r.u32(), mount = try r.u32(), zone = try r.u32(), other = try r.u32()
            let edited = Int64(bitPattern: try r.u64())
            raws.append(Raw(id: id, coord: coord, dirs: dirs, vendor: vendor, op: op, mount: mount, zone: zone, other: other, edited: edited))
        }

        let stringCount = Int(try r.u32())
        guard stringCount <= r.remaining / 4 else { throw ALPRParseError.truncated }
        var strings: [String] = []
        strings.reserveCapacity(stringCount)
        for _ in 0..<stringCount {
            let len = Int(try r.u32())
            guard len <= maxStringBytes else { throw ALPRParseError.malformed("string length") }
            let p = try r.take(len)
            guard let s = String(bytes: r.b[p..<(p + len)], encoding: .utf8) else { throw ALPRParseError.malformed("utf8") }
            strings.append(s)
        }
        guard r.remaining == 0 else { throw ALPRParseError.malformed("trailing bytes") }

        func str(_ i: UInt32) throws -> String? {
            if i == noString { return nil }
            guard Int(i) < strings.count else { throw ALPRParseError.malformed("string index") }
            return strings[Int(i)]
        }
        var out: [ALPRCamera] = []
        out.reserveCapacity(count)
        for x in raws {
            let vendor: ALPRVendor
            if x.vendor == otherCode {
                guard let s = try str(x.other) else { throw ALPRParseError.malformed("vendor string") }
                vendor = .other(s)
            } else { vendor = vendorCodes[Int(x.vendor)]; _ = try str(x.other) }
            let edited: Date? = x.edited == Int64.min ? nil : Date(timeIntervalSince1970: Double(max(-1_000_000_000_000, min(1_000_000_000_000, x.edited))))
            out.append(ALPRCamera(id: x.id, coordinate: x.coord, directions: x.dirs, vendor: vendor,
                                  operatorName: try str(x.op), mount: try str(x.mount), zone: try str(x.zone), lastEdited: edited))
        }
        return out
    }
}
