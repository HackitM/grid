import Foundation

/// A `shasum -a 256` output file: lines of `<64 hex>  <file name>` (two spaces, or space + `*`
/// for binary mode). Anything else is ignored.
public struct ChecksumFile: Equatable, Sendable {
    public let entries: [String: String]   // file name → lowercase hex digest

    public init?(_ text: String) {
        guard text.utf8.count <= 64 * 1024 else { return nil }
        var out: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let s = line.trimmingCharacters(in: .whitespaces)
            guard s.count > 66 else { continue }
            let hash = String(s.prefix(64)).lowercased()
            guard hash.allSatisfy({ $0.isHexDigit }) else { continue }
            var rest = s.dropFirst(64)
            guard rest.first == " " else { continue }
            rest = rest.dropFirst()
            if rest.first == " " || rest.first == "*" { rest = rest.dropFirst() }
            let name = String(rest)
            guard !name.isEmpty, !name.contains("/") else { continue }
            out[name] = hash
        }
        guard !out.isEmpty else { return nil }
        entries = out
    }

    public func digest(for name: String) -> String? { entries[name] }

    /// Constant-time comparison of two hex digests.
    public static func matches(_ a: String, _ b: String) -> Bool {
        let x = Array(a.lowercased().utf8), y = Array(b.lowercased().utf8)
        guard x.count == y.count, x.count == 64 else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }
}
