import Foundation

/// A site theme pack: CSS for one site plus a small header that says which site and which
/// version. Packs ship inside GRID, can be updated from GRID's repository without a new app,
/// and can be written by the user. They are CSS only (never JavaScript), and the CSS is checked
/// so a pack can't make the page load anything or send page data anywhere.
///
/// Format: the file starts with a header comment, then plain CSS.
///
///     /* grid-site-theme
///     id: youtube
///     name: YouTube
///     version: 3
///     hosts: youtube.com, m.youtube.com
///     paths: /, /results          (optional: only these exact paths)
///     description: Tron HUD …     (optional)
///     */
///     html[data-grid-theme="youtube"] body { … }
///
/// Selectors should be scoped to `html[data-grid-theme="<id>"]`, which GRID sets only while the
/// theme is on; GRID's palette is available as `--grid-*` variables.
public struct SiteThemePack: Equatable, Sendable {
    public var entry: SiteThemeEntry
    public var version: Int
    public var description: String?
    public var css: String

    public var id: String { entry.id }

    public static let maxBytes = 256 << 10
    public static let headerMarker = "grid-site-theme"

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case tooLarge, noHeader, missing(String), invalid(String), unsafeCSS([String])
        public var description: String {
            switch self {
            case .tooLarge: "the file is larger than 256 KB"
            case .noHeader: "it doesn't start with a /* grid-site-theme … */ header"
            case .missing(let k): "the header has no \(k)"
            case .invalid(let k): "the header's \(k) isn't valid"
            case .unsafeCSS(let v): "its CSS uses " + v.joined(separator: ", ")
            }
        }
    }

    public init(entry: SiteThemeEntry, version: Int, description: String? = nil, css: String) {
        self.entry = entry; self.version = version; self.description = description; self.css = css
    }

    public static func parse(_ text: String) throws -> SiteThemePack {
        guard text.utf8.count <= maxBytes else { throw ParseError.tooLarge }
        let trimmed = text.drop { $0.isWhitespace || $0 == "\u{FEFF}" }
        guard trimmed.hasPrefix("/*"), let close = trimmed.range(of: "*/") else { throw ParseError.noHeader }
        let header = trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)..<close.lowerBound]
        let css = String(trimmed[close.upperBound...])
        var lines = header.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard lines.first == headerMarker else { throw ParseError.noHeader }
        lines.removeFirst()
        var fields: [String: String] = [:]
        for l in lines {
            guard let colon = l.firstIndex(of: ":") else { throw ParseError.invalid("line “\(l.prefix(40))”") }
            fields[l[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] = l[l.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard let id = fields["id"] else { throw ParseError.missing("id") }
        guard validID(id) else { throw ParseError.invalid("id") }
        guard let name = fields["name"].map { DisplayText.stripped($0) }?.trimmingCharacters(in: .whitespaces), !name.isEmpty, name.count <= 60
        else { throw ParseError.missing("name") }
        guard let v = fields["version"], let version = Int(v), version >= 1, version < 1_000_000 else { throw ParseError.invalid("version") }
        guard let rawHosts = fields["hosts"] else { throw ParseError.missing("hosts") }
        let hosts = rawHosts.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
        guard !hosts.isEmpty, hosts.count <= 40, hosts.allSatisfy(validHostPattern) else { throw ParseError.invalid("hosts") }
        var paths: [String]?
        if let raw = fields["paths"] {
            let p = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard !p.isEmpty, p.count <= 40, p.allSatisfy({ $0.hasPrefix("/") && $0.count <= 200 && !$0.contains(where: \.isWhitespace) })
            else { throw ParseError.invalid("paths") }
            paths = p
        }
        let description = fields["description"].map { String(DisplayText.stripped($0).prefix(200)) }
        let problems = SiteThemeCSS.violations(css)
        guard problems.isEmpty else { throw ParseError.unsafeCSS(problems) }
        return SiteThemePack(entry: SiteThemeEntry(id: id, name: name, hosts: hosts, paths: paths), version: version,
                             description: description, css: css)
    }

    /// `[a-z0-9-]`, 1…40 characters, not starting with a hyphen.
    public static func validID(_ s: String) -> Bool {
        guard (1...40).contains(s.count), !s.hasPrefix("-") else { return false }
        return s.unicodeScalars.allSatisfy { ($0 >= "a" && $0 <= "z") || ($0 >= "0" && $0 <= "9") || $0 == "-" }
    }

    /// A hostname (`example.com`) or a subdomain pattern (`*.example.com`): letters, digits,
    /// hyphens and dots, at least one dot, no empty labels.
    public static func validHostPattern(_ s: String) -> Bool {
        let host = s.hasPrefix("*.") ? String(s.dropFirst(2)) : s
        guard (3...253).contains(host.count), host.contains("."), !host.hasPrefix("."), !host.hasSuffix("."), !host.contains("..") else { return false }
        return host.unicodeScalars.allSatisfy { ($0 >= "a" && $0 <= "z") || ($0 >= "0" && $0 <= "9") || $0 == "-" || $0 == "." }
    }
}

/// What a theme pack's CSS may not do. A theme only restyles: anything that loads a resource (a
/// `url()` that isn't an inline `data:` image or font, `@import`, `image-set()` of URLs) could also
/// leak what's on the page (an attribute selector plus a background URL is a classic keylogger),
/// and old engine hooks (`expression()`, `-moz-binding`, `behavior`, `javascript:`) run code.
/// CSS escapes are decoded first, so `u\72l(` is caught too.
public enum SiteThemeCSS {
    public static func violations(_ css: String) -> [String] {
        let text = decodeEscapes(stripComments(css)).lowercased()
        var found: [String] = []
        if text.contains("@import") { found.append("@import") }
        if text.contains("expression(") { found.append("expression()") }
        if text.contains("-moz-binding") { found.append("-moz-binding") }
        if text.range(of: #"(^|[^-a-z])behavior\s*:"#, options: .regularExpression) != nil { found.append("behavior") }
        if text.contains("javascript:") { found.append("javascript:") }
        if text.contains("vbscript:") { found.append("vbscript:") }
        // Every url( / image-set( / src( must hold an inline data: value.
        for fn in ["url(", "src(", "image-set(", "-webkit-image-set(", "image(", "cross-fade(", "element("] {
            var search = text.startIndex..<text.endIndex
            while let r = text.range(of: fn, range: search) {
                let arg = text[r.upperBound...].drop { $0 == " " || $0 == "\"" || $0 == "'" || $0 == "\t" || $0 == "\n" }
                let ok = (fn == "image-set(" || fn == "-webkit-image-set(" || fn == "cross-fade(" || fn == "image(")
                    ? setArgumentsAreInline(text[r.upperBound...]) : arg.hasPrefix("data:")
                if !ok, !found.contains(fn + ")") { found.append(fn + ")") }
                search = r.upperBound..<text.endIndex
            }
        }
        return found
    }

    /// `image-set("a.png" 1x, url(b.png) 2x)`: plain strings inside it are URLs too.
    private static func setArgumentsAreInline(_ rest: Substring) -> Bool {
        var depth = 1
        var body = ""
        for ch in rest {
            if ch == "(" { depth += 1 } else if ch == ")" { depth -= 1; if depth == 0 { break } }
            body.append(ch)
            if body.count > 4000 { return false }
        }
        // Quoted strings must be data: URIs (nested url( are checked by the main loop).
        var i = body.startIndex
        while i < body.endIndex {
            let c = body[i]
            if c == "\"" || c == "'" {
                let start = body.index(after: i)
                guard let end = body[start...].firstIndex(of: c) else { return false }
                if !body[start..<end].hasPrefix("data:") { return false }
                i = body.index(after: end)
            } else {
                i = body.index(after: i)
            }
        }
        return true
    }

    static func stripComments(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        var i = s.startIndex
        while i < s.endIndex {
            if s[i...].hasPrefix("/*") {
                guard let end = s[s.index(i, offsetBy: 2)...].range(of: "*/") else { break }
                out.append(" ")
                i = end.upperBound
            } else {
                out.append(s[i]); i = s.index(after: i)
            }
        }
        return out
    }

    /// Resolves CSS escapes (`\75`, `\000075 `, `\(`) so obfuscated keywords can't slip through.
    static func decodeEscapes(_ s: String) -> String {
        guard s.contains("\\") else { return s }
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            guard c == "\\" else { out.append(c); i = s.index(after: i); continue }
            var j = s.index(after: i)
            var hex = ""
            while j < s.endIndex, hex.count < 6, s[j].isHexDigit { hex.append(s[j]); j = s.index(after: j) }
            if !hex.isEmpty {
                if let v = UInt32(hex, radix: 16), let u = Unicode.Scalar(v) { out.unicodeScalars.append(u) }
                if j < s.endIndex, s[j].isWhitespace { j = s.index(after: j) }   // one whitespace ends a hex escape
                i = j
            } else if j < s.endIndex {
                if !s[j].isNewline { out.append(s[j]) }
                i = s.index(after: j)
            } else {
                i = j
            }
        }
        return out
    }
}

/// The list of packs GRID's repository publishes (`site-themes/index.json`).
public struct SiteThemeIndex: Equatable, Sendable {
    public struct Item: Equatable, Sendable {
        public var id: String
        public var version: Int
        /// File name inside `site-themes/packs/` (`[a-z0-9-]+\.css`).
        public var file: String
        /// Lowercase hex SHA-256 of the file.
        public var sha256: String
        /// The oldest GRID that can use this pack (packs may rely on newer `--grid-*` variables).
        public var minimumApp: String?
    }
    public var packs: [Item]

    public static let maxBytes = 128 << 10

    public enum ParseError: Error, Equatable { case tooLarge, notJSON, format }

    public static func parse(_ data: Data) throws -> SiteThemeIndex {
        guard data.count <= maxBytes else { throw ParseError.tooLarge }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw ParseError.notJSON }
        guard (root["format"] as? Int) == 1, let arr = root["packs"] as? [Any] else { throw ParseError.format }
        var items: [Item] = []
        var seen = Set<String>()
        for case let o as [String: Any] in arr.prefix(500) {
            guard let id = o["id"] as? String, SiteThemePack.validID(id), !seen.contains(id),
                  let version = o["version"] as? Int, version >= 1, version < 1_000_000,
                  let file = o["file"] as? String, validFile(file),
                  let sha = (o["sha256"] as? String)?.lowercased(), sha.count == 64, sha.allSatisfy(\.isHexDigit) else { continue }
            seen.insert(id)
            let minimum = (o["minimumApp"] as? String).flatMap { SemanticVersion($0) != nil ? $0 : nil }
            items.append(Item(id: id, version: version, file: file, sha256: sha, minimumApp: minimum))
        }
        return SiteThemeIndex(packs: items)
    }

    static func validFile(_ s: String) -> Bool {
        guard s.hasSuffix(".css"), (5...80).contains(s.count) else { return false }
        return s.dropLast(4).unicodeScalars.allSatisfy { ($0 >= "a" && $0 <= "z") || ($0 >= "0" && $0 <= "9") || $0 == "-" }
    }
}

/// Which copy of each pack is used: your own packs win, then a downloaded pack newer than the
/// one inside GRID, then GRID's own.
public enum SiteThemeResolver {
    public enum Source: String, Sendable { case builtIn, downloaded, user }

    public struct Resolved: Equatable, Sendable {
        public var pack: SiteThemePack
        public var source: Source
    }

    public static func merge(builtIn: [SiteThemePack], downloaded: [SiteThemePack], user: [SiteThemePack]) -> [Resolved] {
        var byID: [String: Resolved] = [:]
        var order: [String] = []
        func put(_ p: SiteThemePack, _ s: Source, replaceIf: (Resolved) -> Bool) {
            if let have = byID[p.id] {
                if replaceIf(have) { byID[p.id] = Resolved(pack: p, source: s) }
            } else {
                byID[p.id] = Resolved(pack: p, source: s); order.append(p.id)
            }
        }
        for p in builtIn { put(p, .builtIn) { _ in false } }
        for p in downloaded { put(p, .downloaded) { $0.source == .builtIn && p.version > $0.pack.version } }
        for p in user { put(p, .user) { _ in true } }
        return order.compactMap { byID[$0] }.sorted { $0.pack.entry.name.localizedCaseInsensitiveCompare($1.pack.entry.name) == .orderedAscending }
    }
}
