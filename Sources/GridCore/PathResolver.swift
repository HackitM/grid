import Foundation

public enum PathResolver {
    /// Expands `~`, resolves relative input against `base`, and standardizes `.`/`..`.
    /// Symlinks are deliberately *not* resolved, so breadcrumbs reflect the path the user chose.
    public static func resolve(_ input: String, relativeTo base: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.hasPrefix("file://"), let u = URL(string: s), u.isFileURL { return u.standardizedFileURL }
        // Tolerate a shell-quoted path pasted into the field ('/a b' or "/a b").
        if s.count >= 2, let f = s.first, let l = s.last, (f == "'" && l == "'") || (f == "\"" && l == "\"") {
            s = String(s.dropFirst().dropLast())
        }
        if s == "~" { return home.standardizedFileURL }
        if s.hasPrefix("~/") { return home.appendingPathComponent(String(s.dropFirst(2))).standardizedFileURL }
        if s.hasPrefix("/") { return URL(fileURLWithPath: s).standardizedFileURL }
        return base.appendingPathComponent(s).standardizedFileURL
    }

    /// `/Users/me/Projects` -> `~/Projects` for compact display.
    public static func abbreviate(_ path: String, home: String = NSHomeDirectory()) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// Ancestor chain for breadcrumbs: [/, /Users, /Users/me, ...]
    public static func ancestors(of url: URL) -> [URL] {
        var out: [URL] = []
        var cur = url.standardizedFileURL
        while true {
            out.append(cur)
            let parent = cur.deletingLastPathComponent().standardizedFileURL
            if parent.path == cur.path { break }
            cur = parent
        }
        return out.reversed()
    }
}

public enum WebAddress {
    /// Normalizes user input into an http(s) URL. Other schemes (javascript:, file:, data:, custom
    /// app schemes) are rejected on purpose: this entry point only ever opens web pages.
    public static func normalize(_ input: String) -> URL? {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        let lower = s.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            guard let u = URL(string: s), let host = u.host, !host.isEmpty else { return nil }
            return u
        }
        if s.contains("://") { return nil }  // any other explicit scheme is refused
        guard looksLikeHost(s) else { return nil }  // also rejects "javascript:..." / "data:..."
        let isLocal = lower.hasPrefix("localhost") || lower.hasPrefix("127.0.0.1")
        return URL(string: (isLocal ? "http://" : "https://") + s)
    }

    private static func looksLikeHost(_ s: String) -> Bool {
        if s.range(of: #"^localhost(:\d{1,5})?(/.*)?$"#, options: .regularExpression) != nil { return true }
        if s.range(of: #"^\d{1,3}(\.\d{1,3}){3}(:\d{1,5})?(/.*)?$"#, options: .regularExpression) != nil { return true }
        return s.range(of: #"^([A-Za-z0-9-]+\.)+[A-Za-z]{2,}(:\d{1,5})?([/?#].*)?$"#, options: .regularExpression) != nil
    }
}
