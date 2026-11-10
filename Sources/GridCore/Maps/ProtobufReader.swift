import Foundation

/// A cursor over one protobuf message inside a byte buffer (vector tiles, OSM PBF blocks).
///
/// The bytes are untrusted: every read is checked against the message's end, a length-delimited
/// field can never reach past the message that holds it, and malformed input throws (`MVTError`)
/// instead of trapping.
///
/// The reader borrows the buffer and does not keep it alive: use it only inside the
/// `withUnsafeBytes` / `withUnsafeBufferPointer` call that produced the buffer. (It holds a pointer
/// rather than an array because a reader is made for every feature, way and node group; retaining
/// an array each time is measurable on a 150 MB extract.)
struct PBReader {
    let bytes: UnsafeBufferPointer<UInt8>
    /// Offset of the next unread byte.
    var i: Int
    /// Offset just past the message.
    let end: Int

    /// A reader for `range` of `bytes`. A range outside the buffer is cut down to it, so no reader
    /// can read out of bounds however it was made.
    init(_ bytes: UnsafeBufferPointer<UInt8>, _ range: Range<Int>) {
        self.bytes = bytes
        let lower = min(max(range.lowerBound, 0), bytes.count)
        i = lower
        end = min(max(range.upperBound, lower), bytes.count)
    }

    init(_ bytes: UnsafeBufferPointer<UInt8>) { self.init(bytes, 0..<bytes.count) }

    var isAtEnd: Bool { i >= end }

    @inline(__always)
    mutating func varint() throws -> UInt64 {
        // One-byte values are by far the most common (tags, small deltas).
        guard i < end else { throw MVTError.truncated }
        let first = bytes[i]
        if first < 0x80 { i += 1; return UInt64(first) }
        return try longVarint()
    }

    private mutating func longVarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        for k in 0..<10 {
            guard i < end else { throw MVTError.truncated }
            let byte = bytes[i]; i += 1
            // The tenth byte holds bit 63 only.
            if k == 9 && byte > 1 { throw MVTError.malformed("varint overflow") }
            result |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        throw MVTError.malformed("varint too long")
    }

    /// Next (field number, wire type), or nil at the end of the message.
    @inline(__always)
    mutating func nextField() throws -> (Int, Int)? {
        guard i < end else { return nil }
        let key = try varint()
        let field = Int(key >> 3)
        guard field > 0 else { throw MVTError.malformed("field 0") }
        return (field, Int(key & 7))
    }

    /// The byte range of a length-delimited field (always inside this message).
    @inline(__always)
    mutating func lengthDelimited() throws -> Range<Int> {
        let len = try varint()
        guard len <= UInt64(end - i) else { throw MVTError.truncated }
        let r = i..<(i + Int(len))
        i = r.upperBound
        return r
    }

    mutating func fixed32() throws -> UInt32 {
        guard end - i >= 4 else { throw MVTError.truncated }
        var v: UInt32 = 0
        for k in 0..<4 { v |= UInt32(bytes[i + k]) << UInt32(8 * k) }
        i += 4
        return v
    }

    mutating func fixed64() throws -> UInt64 {
        guard end - i >= 8 else { throw MVTError.truncated }
        var v: UInt64 = 0
        for k in 0..<8 { v |= UInt64(bytes[i + k]) << UInt64(8 * k) }
        i += 8
        return v
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

    /// The bytes of `range` (which came from `lengthDelimited`) as a sub-buffer.
    func slice(_ range: Range<Int>) -> UnsafeBufferPointer<UInt8> {
        UnsafeBufferPointer(rebasing: bytes[range])
    }

    /// ZigZag-decoded signed value of a `sint64` varint.
    @inline(__always)
    static func zigzag(_ n: UInt64) -> Int64 { Int64(bitPattern: (n >> 1) ^ (0 &- (n & 1))) }
}
