import Compression
import Foundation

// OpenStreetMap PBF reader (https://wiki.openstreetmap.org/wiki/PBF_Format). The file is untrusted:
// every read is bounds-checked (PBReader), block sizes are capped as the format specifies (header
// ≤ 64 KiB, blob ≤ 32 MiB), decompressed sizes must match, and malformed blocks throw; nothing
// traps. Only what routing needs is decoded: node coordinates, way refs and tags, and relation
// members and tags.
//
// Extracts run to hundreds of megabytes, so the reader works in place: blobs are read straight
// from the (memory-mapped) file, one inflate buffer is reused for every block, strings are decoded
// only when a wanted way or relation uses them, and nothing is allocated per node.

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
        /// Only these tags are put in `OSMWay.tags` (all tags when nil). Most of a way's tags are
        /// of no use to a caller that reads a handful of keys; leaving them out saves the bulk of
        /// the per-way work.
        public var wayTagKeys: Set<String>?
        public var way: ((OSMWay) -> Void)?
        /// Only relations whose `type` tag is one of these are decoded.
        public var relationTypes: Set<String> = []
        public var relation: ((OSMRelation) -> Void)?
        public init() {}

        /// The kinds of element this visitor looks at.
        var wanted: BlobContents {
            var w: BlobContents = []
            if node != nil { w.insert(.nodes) }
            if way != nil { w.insert(.ways) }
            if relation != nil { w.insert(.relations) }
            return w
        }
    }

    /// The kinds of element a data blob holds. A first scan reports this for every data blob, so
    /// a second scan of the same file can skip (without inflating them) the blobs it has no use
    /// for: extracts are sorted nodes, then ways, then relations.
    public struct BlobContents: OptionSet, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let nodes = BlobContents(rawValue: 1)
        public static let ways = BlobContents(rawValue: 2)
        public static let relations = BlobContents(rawValue: 4)
    }

    static let maxHeader = 64 << 10
    static let maxBlob = 32 << 20
    static let maxWayRefs = 100_000
    static let maxRelationMembers = 10_000

    let data: Data

    public init(data: Data) { self.data = data }

    /// Reads the whole file. `progress` gets the fraction of bytes read; `cancelled` is polled per block.
    ///
    /// - Parameter known: What each data blob holds, as returned by an earlier scan of this same
    ///   file. Blobs with nothing the visitor wants are then skipped without being inflated.
    /// - Returns: What each data blob holds, in file order.
    @discardableResult
    public func scan(_ v: Visitor, skipping known: [BlobContents]? = nil, progress: ((Double) -> Void)? = nil,
                     cancelled: (() -> Bool)? = nil) throws -> [BlobContents] {
        try data.withUnsafeBytes { raw in
            try Self.rethrowingAsPBFError {
                try scan(raw.bindMemory(to: UInt8.self), v, known, progress, cancelled)
            }
        }
    }

    private func scan(_ file: UnsafeBufferPointer<UInt8>, _ v: Visitor, _ known: [BlobContents]?,
                      _ progress: ((Double) -> Void)?, _ cancelled: (() -> Bool)?) throws -> [BlobContents] {
        let inflater = BlobInflater()
        let wanted = v.wanted
        var contents: [BlobContents] = []
        var offset = 0
        var sawHeader = false
        while offset < file.count {
            if cancelled?() == true { throw PBFError.cancelled }
            let blob = try Self.nextBlob(file, at: &offset)
            progress?(Double(offset) / Double(max(1, file.count)))
            switch blob.kind {
            case .header:
                try inflater.withPayload(of: file, blob.body) { try Self.checkHeader($0) }
                sawHeader = true
            case .data:
                guard sawHeader else { throw PBFError.malformed("data before header") }
                if let known, contents.count < known.count, known[contents.count].isDisjoint(with: wanted) {
                    contents.append(known[contents.count])
                    continue
                }
                contents.append(try inflater.withPayload(of: file, blob.body) { block in
                    var reader = BlockReader(block, v)
                    return try reader.read()
                })
            case .other:
                continue   // unknown blob types are skipped, as the format allows
            }
        }
        return contents
    }

    /// PBReader reports bad bytes as `MVTError`; callers of this reader see `PBFError` only.
    private static func rethrowingAsPBFError<T>(_ body: () throws -> T) throws -> T {
        do { return try body() } catch let e as MVTError {
            switch e {
            case .truncated: throw PBFError.truncated
            default: throw PBFError.malformed("\(e)")
            }
        }
    }

    // MARK: Blobs

    private enum BlobKind { case header, data, other }

    /// Reads the BlobHeader at `offset` and steps over the blob that follows it.
    private static func nextBlob(_ file: UnsafeBufferPointer<UInt8>, at offset: inout Int) throws -> (kind: BlobKind, body: Range<Int>) {
        guard file.count - offset >= 4 else { throw PBFError.truncated }
        // Big-endian length of the BlobHeader.
        let headerLength = Int(file[offset]) << 24 | Int(file[offset + 1]) << 16 | Int(file[offset + 2]) << 8 | Int(file[offset + 3])
        offset += 4
        guard headerLength > 0, headerLength <= maxHeader, file.count - offset >= headerLength else {
            throw PBFError.malformed("blob header size")
        }
        var kind = BlobKind.other
        var bodySize = -1
        var r = PBReader(file, offset..<(offset + headerLength))
        while let (field, wire) = try r.nextField() {
            switch (field, wire) {
            case (1, 2):
                let type = r.slice(try r.lengthDelimited())
                kind = type.elementsEqual("OSMHeader".utf8) ? .header : type.elementsEqual("OSMData".utf8) ? .data : .other
            case (3, 0): bodySize = Int(clamping: try r.varint())
            default: try r.skip(wire)
            }
        }
        offset += headerLength
        guard bodySize > 0, bodySize <= maxBlob, file.count - offset >= bodySize else { throw PBFError.malformed("blob size") }
        defer { offset += bodySize }
        return (kind, offset..<(offset + bodySize))
    }

    /// Hands out the uncompressed bytes of blobs, reusing one output buffer for every block.
    private final class BlobInflater {
        private var buffer: UnsafeMutablePointer<UInt8>?
        private var capacity = 0
        private let scratch = UnsafeMutableRawPointer.allocate(byteCount: compression_decode_scratch_buffer_size(COMPRESSION_ZLIB), alignment: 16)

        deinit {
            buffer?.deallocate()
            scratch.deallocate()
        }

        /// Calls `body` with the uncompressed bytes of the Blob at `range` (stored raw, or zlib).
        /// Other compressions are refused. The bytes are only valid during the call.
        func withPayload<T>(of file: UnsafeBufferPointer<UInt8>, _ range: Range<Int>,
                            _ body: (UnsafeBufferPointer<UInt8>) throws -> T) throws -> T {
            var r = PBReader(file, range)
            var raw: Range<Int>?
            var zlib: Range<Int>?
            var rawSize = -1
            while let (field, wire) = try r.nextField() {
                switch (field, wire) {
                case (1, 2): raw = try r.lengthDelimited()
                case (2, 0): rawSize = Int(clamping: try r.varint())
                case (3, 2): zlib = try r.lengthDelimited()
                case (4, 2), (5, 2), (6, 2), (7, 2): throw PBFError.unsupported("compression")
                default: try r.skip(wire)
                }
            }
            if let raw { return try body(r.slice(raw)) }
            guard let z = zlib, z.count > 6, rawSize > 0, rawSize <= PBFReader.maxBlob else { throw PBFError.malformed("blob") }
            // zlib = 2-byte header + raw DEFLATE + 4-byte Adler-32; Compression's ZLIB is raw DEFLATE.
            let cmf = file[z.lowerBound], flg = file[z.lowerBound + 1]
            guard cmf & 0x0F == 8, (UInt16(cmf) << 8 | UInt16(flg)) % 31 == 0 else { throw PBFError.malformed("zlib header") }
            if capacity < rawSize {
                buffer?.deallocate()
                buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: rawSize)
                capacity = rawSize
            }
            guard let out = buffer, let source = file.baseAddress else { throw PBFError.malformed("blob") }
            let written = compression_decode_buffer(out, rawSize, source + z.lowerBound + 2, z.count - 2, scratch, COMPRESSION_ZLIB)
            guard written == rawSize else { throw PBFError.malformed("inflated size") }
            return try body(UnsafeBufferPointer(start: out, count: rawSize))
        }
    }

    /// Refuses files that need a feature this reader doesn't implement.
    private static func checkHeader(_ block: UnsafeBufferPointer<UInt8>) throws {
        var r = PBReader(block)
        while let (field, wire) = try r.nextField() {
            if field == 4 && wire == 2 {   // required_features
                let feature = String(decoding: r.slice(try r.lengthDelimited()), as: UTF8.self)
                guard ["OsmSchema-V0.6", "DenseNodes"].contains(feature) else { throw PBFError.unsupported(feature) }
            } else {
                try r.skip(wire)
            }
        }
    }
}

// MARK: - Primitive blocks

/// Decodes one PrimitiveBlock for a visitor.
private struct BlockReader {
    let block: UnsafeBufferPointer<UInt8>
    let visitor: PBFReader.Visitor
    private var strings = StringTable()
    private var groups: [Range<Int>] = []
    /// Positions are `offset + granularity × raw`, in nanodegrees.
    private var granularity: Int64 = 100
    private var latOffset: Int64 = 0, lonOffset: Int64 = 0

    init(_ block: UnsafeBufferPointer<UInt8>, _ visitor: PBFReader.Visitor) {
        self.block = block
        self.visitor = visitor
    }

    /// The block's strings, decoded on first use, and what each means as a way tag key.
    private struct StringTable {
        var ranges: [Range<Int>] = []
        private var decoded: [String?] = []
        private var keyClass: [UInt8] = []
        static let classified: UInt8 = 1, isWayKey: UInt8 = 2, isKeptTag: UInt8 = 4

        mutating func string(_ i: Int, in block: UnsafeBufferPointer<UInt8>) -> String? {
            guard i >= 0, i < ranges.count else { return nil }
            if decoded.isEmpty { decoded = [String?](repeating: nil, count: ranges.count) }
            if let s = decoded[i] { return s }
            let s = String(decoding: UnsafeBufferPointer(rebasing: block[ranges[i]]), as: UTF8.self)
            decoded[i] = s
            return s
        }

        /// Whether string `i`, used as a way's tag key, is the visitor's `wayKey` and whether its
        /// tag is kept. Worked out once per string.
        mutating func wayKeyClass(_ i: Int, in block: UnsafeBufferPointer<UInt8>, _ v: PBFReader.Visitor) -> UInt8 {
            guard i >= 0, i < ranges.count else { return Self.classified }
            if keyClass.isEmpty { keyClass = [UInt8](repeating: 0, count: ranges.count) }
            if keyClass[i] != 0 { return keyClass[i] }
            var c = Self.classified
            if let s = string(i, in: block) {
                if s == v.wayKey { c |= Self.isWayKey }
                if v.wayTagKeys?.contains(s) ?? true { c |= Self.isKeptTag }
            }
            keyClass[i] = c
            return c
        }
    }

    /// Visits everything the visitor wants and reports what the block holds.
    mutating func read() throws -> PBFReader.BlobContents {
        try readHeader()
        var contents: PBFReader.BlobContents = []
        for group in groups {
            var r = PBReader(block, group)
            while let (field, wire) = try r.nextField() {
                switch (field, wire) {
                case (1, 2):
                    contents.insert(.nodes)
                    let range = try r.lengthDelimited()
                    if let visit = visitor.node { try readNode(range, visit) }
                case (2, 2):
                    contents.insert(.nodes)
                    let range = try r.lengthDelimited()
                    if let visit = visitor.node { try readDenseNodes(range, visit) }
                case (3, 2):
                    contents.insert(.ways)
                    let range = try r.lengthDelimited()
                    if let visit = visitor.way { try readWay(range, visit) }
                case (4, 2):
                    contents.insert(.relations)
                    let range = try r.lengthDelimited()
                    if let visit = visitor.relation { try readRelation(range, visit) }
                default:
                    try r.skip(wire)
                }
            }
        }
        return contents
    }

    /// The string table, the primitive groups and the coordinate scale.
    private mutating func readHeader() throws {
        var r = PBReader(block)
        while let (field, wire) = try r.nextField() {
            switch (field, wire) {
            case (1, 2):
                var table = PBReader(block, try r.lengthDelimited())
                while let (f, w) = try table.nextField() {
                    if f == 1 && w == 2 { strings.ranges.append(try table.lengthDelimited()) } else { try table.skip(w) }
                }
            case (2, 2): groups.append(try r.lengthDelimited())
            case (17, 0): granularity = Int64(clamping: try r.varint())
            case (19, 0): latOffset = Int64(bitPattern: try r.varint())
            case (20, 0): lonOffset = Int64(bitPattern: try r.varint())
            default: try r.skip(wire)
            }
        }
        guard granularity > 0, granularity <= 1_000_000 else { throw PBFError.malformed("granularity") }
    }

    /// Degrees × 1e7 from a raw coordinate. Wrapping arithmetic: hostile values must not trap.
    @inline(__always)
    private func e7(_ raw: Int64, _ offset: Int64) -> Int32 {
        let nano = offset &+ granularity &* raw          // degrees × 1e9
        return Int32(clamping: nano / 100)
    }

    // MARK: Nodes

    private func readNode(_ range: Range<Int>, _ visit: (Int64, Int32, Int32) -> Void) throws {
        var r = PBReader(block, range)
        var id: Int64 = 0, lat: Int64 = 0, lon: Int64 = 0
        while let (field, wire) = try r.nextField() {
            switch (field, wire) {
            case (1, 0): id = PBReader.zigzag(try r.varint())
            case (8, 0): lat = PBReader.zigzag(try r.varint())
            case (9, 0): lon = PBReader.zigzag(try r.varint())
            default: try r.skip(wire)
            }
        }
        visit(id, e7(lat, latOffset), e7(lon, lonOffset))
    }

    /// DenseNodes: three parallel delta-coded arrays (ids, latitudes, longitudes).
    private func readDenseNodes(_ range: Range<Int>, _ visit: (Int64, Int32, Int32) -> Void) throws {
        var r = PBReader(block, range)
        var idRange: Range<Int>?, latRange: Range<Int>?, lonRange: Range<Int>?
        while let (field, wire) = try r.nextField() {
            switch (field, wire) {
            case (1, 2): idRange = try r.lengthDelimited()
            case (8, 2): latRange = try r.lengthDelimited()
            case (9, 2): lonRange = try r.lengthDelimited()
            default: try r.skip(wire)
            }
        }
        guard let idRange, let latRange, let lonRange else { return }
        var ids = PBReader(block, idRange), lats = PBReader(block, latRange), lons = PBReader(block, lonRange)
        var id: Int64 = 0, lat: Int64 = 0, lon: Int64 = 0
        while !ids.isAtEnd {
            guard !lats.isAtEnd, !lons.isAtEnd else { throw PBFError.malformed("dense node arrays") }
            id &+= PBReader.zigzag(try ids.varint())
            lat &+= PBReader.zigzag(try lats.varint())
            lon &+= PBReader.zigzag(try lons.varint())
            visit(id, e7(lat, latOffset), e7(lon, lonOffset))
        }
    }

    // MARK: Ways

    private mutating func readWay(_ range: Range<Int>, _ visit: (OSMWay) -> Void) throws {
        var r = PBReader(block, range)
        var id: Int64 = 0
        var keys: Range<Int>?, values: Range<Int>?, refs: Range<Int>?
        while let (field, wire) = try r.nextField() {
            switch (field, wire) {
            case (1, 0): id = Int64(bitPattern: try r.varint())
            case (2, 2): keys = try r.lengthDelimited()
            case (3, 2): values = try r.lengthDelimited()
            case (8, 2): refs = try r.lengthDelimited()
            default: try r.skip(wire)
            }
        }
        guard varintCount(keys) == varintCount(values) else { throw PBFError.malformed("way tags") }
        if visitor.wayKey != nil, try !hasWayKey(keys) { return }

        var tags: [String: String] = [:]
        if let keys, let values {
            var k = PBReader(block, keys), v = PBReader(block, values)
            while !k.isAtEnd, !v.isAtEnd {
                let key = Int(clamping: try k.varint()), value = Int(clamping: try v.varint())
                guard strings.wayKeyClass(key, in: block, visitor) & StringTable.isKeptTag != 0 else { continue }
                if let ks = strings.string(key, in: block), let vs = strings.string(value, in: block) { tags[ks] = vs }
            }
        }
        var nodes: [Int64] = []
        if let refs {
            nodes.reserveCapacity(min(refs.count, PBFReader.maxWayRefs))
            var rr = PBReader(block, refs)
            var ref: Int64 = 0
            while !rr.isAtEnd {
                ref &+= PBReader.zigzag(try rr.varint())
                nodes.append(ref)
                if nodes.count > PBFReader.maxWayRefs { throw PBFError.malformed("way too long") }
            }
        }
        visit(OSMWay(id: id, refs: nodes, tags: tags))
    }

    /// Whether one of the way's tag keys is the visitor's `wayKey`.
    private mutating func hasWayKey(_ keys: Range<Int>?) throws -> Bool {
        guard let keys else { return false }
        var k = PBReader(block, keys)
        while !k.isAtEnd {
            let key = Int(clamping: try k.varint())
            if strings.wayKeyClass(key, in: block, visitor) & StringTable.isWayKey != 0 { return true }
        }
        return false
    }

    /// How many varints a packed field holds (each ends with a byte whose top bit is clear).
    private func varintCount(_ range: Range<Int>?) -> Int {
        guard let range else { return 0 }
        var n = 0
        for i in range where block[i] & 0x80 == 0 { n += 1 }
        return n
    }

    // MARK: Relations

    private mutating func readRelation(_ range: Range<Int>, _ visit: (OSMRelation) -> Void) throws {
        var r = PBReader(block, range)
        var id: Int64 = 0
        var keys: Range<Int>?, values: Range<Int>?, roles: Range<Int>?, memberIDs: Range<Int>?, types: Range<Int>?
        while let (field, wire) = try r.nextField() {
            switch (field, wire) {
            case (1, 0): id = Int64(bitPattern: try r.varint())
            case (2, 2): keys = try r.lengthDelimited()
            case (3, 2): values = try r.lengthDelimited()
            case (8, 2): roles = try r.lengthDelimited()
            case (9, 2): memberIDs = try r.lengthDelimited()
            case (10, 2): types = try r.lengthDelimited()
            default: try r.skip(wire)
            }
        }
        guard varintCount(keys) == varintCount(values) else { throw PBFError.malformed("relation tags") }
        var tags: [String: String] = [:]
        if let keys, let values {
            var k = PBReader(block, keys), v = PBReader(block, values)
            while !k.isAtEnd, !v.isAtEnd {
                let key = Int(clamping: try k.varint()), value = Int(clamping: try v.varint())
                if let ks = strings.string(key, in: block), let vs = strings.string(value, in: block) { tags[ks] = vs }
            }
        }
        guard let type = tags["type"], visitor.relationTypes.contains(type) else { return }

        let count = varintCount(memberIDs)
        guard varintCount(roles) == count, varintCount(types) == count, count <= PBFReader.maxRelationMembers else {
            throw PBFError.malformed("relation members")
        }
        var members: [OSMRelation.Member] = []
        members.reserveCapacity(count)
        if let roles, let memberIDs, let types {
            var rr = PBReader(block, roles), mr = PBReader(block, memberIDs), tr = PBReader(block, types)
            var ref: Int64 = 0
            while !mr.isAtEnd, !rr.isAtEnd, !tr.isAtEnd {
                ref &+= PBReader.zigzag(try mr.varint())
                let role = Int(clamping: try rr.varint())
                // Members of a kind this reader doesn't know are left out.
                guard let memberType = OSMRelation.MemberType(rawValue: UInt8(clamping: try tr.varint())) else { continue }
                members.append(.init(type: memberType, ref: ref, role: strings.string(role, in: block) ?? ""))
            }
        }
        visit(OSMRelation(id: id, members: members, tags: tags))
    }
}
