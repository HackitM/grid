import Foundation

/// Cleaning for text that arrives from outside (tile and OpenStreetMap names, search answers,
/// attribution) before GRID shows it or sends it on. One place, so every source gets the same
/// treatment.
enum DisplayText {
    /// Explicit bidirectional embeddings and overrides (U+202A…U+202E) and isolates
    /// (U+2066…U+2069): invisible, and able to reorder the text around them on screen.
    static func isBidiControl(_ u: Unicode.Scalar) -> Bool {
        (0x202A...0x202E).contains(u.value) || (0x2066...0x2069).contains(u.value)
    }

    /// `scalars` without control characters and, unless `keepingBidi`, without bidi controls.
    static func stripped<S: Sequence>(_ scalars: S, keepingBidi: Bool = false) -> String where S.Element == Unicode.Scalar {
        var out = String.UnicodeScalarView()
        for u in scalars where !CharacterSet.controlCharacters.contains(u) && (keepingBidi || !isBidiControl(u)) {
            out.append(u)
        }
        return String(out)
    }

    static func stripped(_ s: String, keepingBidi: Bool = false) -> String {
        stripped(s.unicodeScalars, keepingBidi: keepingBidi)
    }
}
