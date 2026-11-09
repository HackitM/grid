import Foundation

public enum TileSourceError: Error, Equatable {
    case tooLarge
    case notJSON
    case unsupportedVersion
    case insecureOrInvalidURL(String)
    case foreignHost
    case badTemplate(String)
}

/// A validated vector-tile source parsed from a TileJSON document. The TileJSON is remote input:
/// the tile template must be https, carry no userinfo or port, live on the same host the TileJSON
/// came from, and contain only the `{z}`, `{x}` and `{y}` placeholders.
public struct TileSource: Sendable, Equatable {
    public let tileJSONURL: URL
    public let template: String
    public let minZoom: Int
    public let maxZoom: Int
    public let attribution: String
    /// The path segment right before `{z}` (OpenFreeMap puts the build there), when there is one.
    public let version: String?
    public let host: String

    static let maxTemplateLength = 2048
    static let maxAttributionLength = 400

    public static func parse(_ data: Data, from url: URL, maxBytes: Int = 1 << 20) throws -> TileSource {
        guard data.count <= maxBytes else { throw TileSourceError.tooLarge }
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil, url.port == nil,
              let jsonHost = url.host?.lowercased(), isPlainHost(jsonHost) else {
            throw TileSourceError.insecureOrInvalidURL("tilejson")
        }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw TileSourceError.notJSON }
        if let v = root["tilejson"] {
            guard let s = v as? String, s.hasPrefix("2.") || s.hasPrefix("3.") else { throw TileSourceError.unsupportedVersion }
        }
        if let scheme = root["scheme"] as? String, scheme.lowercased() != "xyz" { throw TileSourceError.badTemplate("scheme") }
        guard let tiles = root["tiles"] as? [Any], let template = tiles.first as? String else { throw TileSourceError.badTemplate("tiles") }
        try validate(template: template, host: jsonHost)

        func zoom(_ key: String, _ fallback: Int) -> Int {
            guard let n = root[key] as? NSNumber, !(root[key] is Bool), n.doubleValue.isFinite else { return fallback }
            return Int(max(0, min(22, n.doubleValue.rounded())))
        }
        var lo = zoom("minzoom", 0), hi = zoom("maxzoom", 22)
        if lo > hi { swap(&lo, &hi) }
        let attribution = sanitize(root["attribution"] as? String ?? "")
        return TileSource(tileJSONURL: url, template: template, minZoom: lo, maxZoom: hi, attribution: attribution,
                          version: version(of: template), host: jsonHost)
    }

    /// The URL of a tile, or nil when the tile is invalid or outside this source's zoom range.
    public func url(for t: TileID) -> URL? {
        guard t.isValid, Int(t.z) >= minZoom, Int(t.z) <= maxZoom else { return nil }
        let s = template
            .replacingOccurrences(of: "{z}", with: String(t.z))
            .replacingOccurrences(of: "{x}", with: String(t.x))
            .replacingOccurrences(of: "{y}", with: String(t.y))
        guard let u = URL(string: s), u.scheme == "https", u.host?.lowercased() == host, u.user == nil, u.port == nil else { return nil }
        return u
    }

    // MARK: Validation

    private static func isPlainHost(_ h: String) -> Bool {
        guard !h.isEmpty, h.count <= 253 else { return false }
        return h.unicodeScalars.allSatisfy { ($0 >= "a" && $0 <= "z") || ($0 >= "0" && $0 <= "9") || $0 == "." || $0 == "-" }
            && !h.hasPrefix(".") && !h.hasPrefix("-")
    }

    private static func validate(template: String, host expectedHost: String) throws {
        guard template.utf8.count <= maxTemplateLength else { throw TileSourceError.badTemplate("too long") }
        guard template.hasPrefix("https://") else { throw TileSourceError.insecureOrInvalidURL("scheme") }
        for u in template.unicodeScalars where u.value < 0x21 || u.value == 0x7f || u == "\\" || u == "#" || u.value > 0x7e {
            throw TileSourceError.badTemplate("character")
        }
        let rest = template.dropFirst("https://".count)
        let authority = rest.prefix { $0 != "/" && $0 != "?" }
        guard !authority.isEmpty, !authority.contains("@"), !authority.contains(":"), !authority.contains("{") else {
            throw TileSourceError.insecureOrInvalidURL("authority")
        }
        let host = authority.lowercased()
        guard isPlainHost(host) else { throw TileSourceError.insecureOrInvalidURL("host") }
        guard host == expectedHost else { throw TileSourceError.foreignHost }
        // Placeholders: only {z}, {x}, {y}, each at least once.
        var seen = Set<String>()
        var i = template.startIndex
        while let open = template[i...].firstIndex(of: "{") {
            guard let close = template[open...].firstIndex(of: "}") else { throw TileSourceError.badTemplate("unbalanced") }
            let name = String(template[template.index(after: open)..<close])
            guard name == "z" || name == "x" || name == "y" else { throw TileSourceError.badTemplate("placeholder {\(name)}") }
            seen.insert(name)
            i = template.index(after: close)
        }
        if template[i...].contains("}") { throw TileSourceError.badTemplate("unbalanced") }
        guard seen == ["z", "x", "y"] else { throw TileSourceError.badTemplate("missing placeholder") }
    }

    private static func version(of template: String) -> String? {
        let path = template.dropFirst("https://".count)
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let zi = parts.firstIndex(where: { $0 == "{z}" }), zi >= 2 else { return nil }   // index 0 is the host
        let seg = parts[zi - 1]
        guard !seg.isEmpty, seg.count <= 64,
              seg.unicodeScalars.allSatisfy({ ($0 >= "a" && $0 <= "z") || ($0 >= "A" && $0 <= "Z") || ($0 >= "0" && $0 <= "9") || $0 == "_" || $0 == "-" || $0 == "." }),
              seg != "." && seg != ".." else { return nil }
        return seg
    }

    /// Strips HTML tags, decodes a few entities, collapses whitespace and caps the length.
    static func sanitize(_ html: String) -> String {
        var out = ""
        var inTag = false
        for ch in html {
            if ch == "<" { inTag = true; continue }
            if ch == ">" && inTag { inTag = false; out.append(" "); continue }
            if !inTag { out.append(ch) }
        }
        for (e, r) in [("&copy;", "©"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")] {
            out = out.replacingOccurrences(of: e, with: r)
        }
        let cleaned = out.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) || $0 == " " }
        let words = String(String.UnicodeScalarView(cleaned)).split(whereSeparator: { $0.isWhitespace })
        return String(words.joined(separator: " ").prefix(maxAttributionLength))
    }
}
