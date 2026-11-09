import Foundation

/// Quotes filesystem paths so they can be inserted into an interactive POSIX-ish shell
/// prompt (zsh, bash, sh) as a single literal word.
///
/// Guarantees:
/// - The returned string never contains raw control characters (no CR/LF, no ESC), so inserting it
///   at a prompt can never execute anything by itself.
/// - Ordinary paths stay readable: safe paths are returned unchanged, others are single-quoted,
///   and only paths containing control characters fall back to `$'...'` ANSI-C quoting.
public enum ShellQuoting {
    private static let safeScalars: Set<Unicode.Scalar> = {
        var s = Set<Unicode.Scalar>()
        for c in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_@%+=:,./-".unicodeScalars {
            s.insert(c)
        }
        return s
    }()

    static func isControl(_ u: Unicode.Scalar) -> Bool {
        u.value < 0x20 || u.value == 0x7F || (0x80...0x9F).contains(u.value)
    }

    public static func quote(_ s: String) -> String {
        if s.isEmpty { return "''" }
        if s.unicodeScalars.allSatisfy({ safeScalars.contains($0) }) && !s.hasPrefix("-") {
            return s
        }
        if !s.unicodeScalars.contains(where: isControl) {
            return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        var out = "$'"
        for u in s.unicodeScalars {
            switch u {
            case "\\": out += "\\\\"
            case "'": out += "\\'"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default:
                if isControl(u) {
                    out += u.value <= 0x7F ? String(format: "\\x%02x", u.value) : String(format: "\\u%04x", u.value)
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        return out + "'"
    }

    /// Space-separated quoted words, with a trailing space so the user can keep typing.
    public static func insertionText(forPaths paths: [String]) -> String {
        guard !paths.isEmpty else { return "" }
        return paths.map(quote).joined(separator: " ") + " "
    }
}
