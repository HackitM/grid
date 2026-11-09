import Foundation

// MARK: - Address bar

/// What the browser's address bar should do with what the user typed.
public enum BrowserInput: Equatable, Sendable {
    case open(URL)
    case search(URL)
    case refused(String)
}

public enum SearchEngine: String, CaseIterable, Codable, Sendable, Identifiable {
    case duckduckgo, google, bing, kagi, startpage
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .duckduckgo: "DuckDuckGo"; case .google: "Google"; case .bing: "Bing"
        case .kagi: "Kagi"; case .startpage: "Startpage"
        }
    }

    public func url(for query: String) -> URL {
        var c: URLComponents
        switch self {
        case .duckduckgo: c = URLComponents(string: "https://duckduckgo.com/")!
        case .google: c = URLComponents(string: "https://www.google.com/search")!
        case .bing: c = URLComponents(string: "https://www.bing.com/search")!
        case .kagi: c = URLComponents(string: "https://kagi.com/search")!
        case .startpage: c = URLComponents(string: "https://www.startpage.com/do/search")!
        }
        c.queryItems = [URLQueryItem(name: "q", value: query)]
        return c.url!
    }
}

public enum BrowserAddress {
    /// Typed text → a page to open or a search. Explicit non-web schemes are refused (the address
    /// bar never runs `javascript:` or opens `file:` URLs).
    public static func interpret(_ raw: String, engine: SearchEngine) -> BrowserInput {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return .refused("Type an address or a search.") }
        let lower = s.lowercased()
        if lower == "about:blank" { return .open(URL(string: "about:blank")!) }
        if let url = WebAddress.normalize(s) { return .open(url) }
        // An explicit scheme that isn't http(s): refuse rather than search for it.
        if let colon = s.firstIndex(of: ":"), !s.contains(" "),
           s[..<colon].range(of: #"^[A-Za-z][A-Za-z0-9+.-]*$"#, options: .regularExpression) != nil,
           !s[s.index(after: colon)...].allSatisfy(\.isNumber) {
            return .refused("Only web addresses (http and https) open here.")
        }
        return .search(engine.url(for: s))
    }

    /// What the address bar shows for a URL (drops the scheme for https, keeps it otherwise).
    public static func display(_ url: URL?) -> String {
        guard let url else { return "" }
        if url.scheme == "https" {
            var s = url.absoluteString.replacingOccurrences(of: "https://", with: "")
            if s.hasSuffix("/") && url.path == "/" && url.query == nil { s.removeLast() }
            return s
        }
        return url.absoluteString
    }
}

// MARK: - Navigation policy

public enum BrowserNavigationDecision: Equatable, Sendable {
    case allow
    /// Hand to another app (mail, FaceTime, Zoom…) only after the user agrees.
    case askToOpenExternally(scheme: String)
    case refuse(String)
}

public enum BrowserNavigationPolicy {
    /// Schemes that may load inside the browser.
    static let internalSchemes: Set<String> = ["http", "https", "blob", "data", "about"]
    /// Schemes that are handed to other apps with confirmation.
    static let externalSchemes: Set<String> = ["mailto", "tel", "facetime", "facetime-audio", "sms", "maps", "itms-apps",
                                               "macappstore", "zoommtg", "zoomus", "msteams", "slack", "spotify", "webcal", "x-apple.systempreferences"]

    /// Decide a navigation. `isMainFrame`: top-level navigations of `data:` URLs are refused
    /// (a classic phishing trick); subresources and frames are left to WebKit.
    public static func decide(_ url: URL, isMainFrame: Bool, userInitiated: Bool) -> BrowserNavigationDecision {
        let scheme = (url.scheme ?? "").lowercased()
        if internalSchemes.contains(scheme) {
            if isMainFrame && scheme == "data" { return .refuse("data: pages can't be opened.") }
            if scheme == "about" && url.absoluteString != "about:blank" && url.absoluteString != "about:srcdoc" {
                return .refuse("Unsupported page.")
            }
            return .allow
        }
        if scheme == "file" { return .refuse("Local files can't be opened from web pages.") }
        if scheme == "javascript" { return .refuse("Blocked a javascript: link.") }
        if externalSchemes.contains(scheme) {
            return userInitiated ? .askToOpenExternally(scheme: scheme) : .refuse("A page tried to open \(scheme): without a click.")
        }
        return .refuse("\(scheme): links aren't supported.")
    }
}

// MARK: - Sites

public enum SiteKey {
    /// The per-site key used for settings (ad blocking off, theme on): the host without "www.".
    public static func of(_ url: URL?) -> String? {
        guard let host = url?.host?.lowercased(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// Built-in site themes: which theme pack applies to a host.
public struct SiteThemeEntry: Equatable, Sendable {
    public let id: String
    public let name: String
    /// Hosts this theme covers; "*.example.org" covers subdomains (and the bare domain).
    public let hosts: [String]
    /// When set, only these exact paths are themed (e.g. a search engine's home and results pages,
    /// not the maps or mail apps on the same host).
    public let paths: [String]?

    public init(id: String, name: String, hosts: [String], paths: [String]? = nil) {
        self.id = id; self.name = name; self.hosts = hosts; self.paths = paths
    }

    public func matches(_ url: URL) -> Bool {
        guard let host = url.host, matches(host) else { return false }
        guard let paths else { return true }
        let path = url.path.isEmpty ? "/" : url.path
        return paths.contains(path)
    }

    public func matches(_ host: String) -> Bool {
        let h = host.lowercased()
        return hosts.contains { p in
            if p.hasPrefix("*.") {
                let base = String(p.dropFirst(2))
                return h == base || h.hasSuffix("." + base)
            }
            return h == p || h == "www." + p
        }
    }
}

public enum SiteThemeCatalog {
    public static let entries: [SiteThemeEntry] = [
        SiteThemeEntry(id: "github", name: "GitHub", hosts: ["github.com", "gist.github.com"]),
        SiteThemeEntry(id: "hackernews", name: "Hacker News", hosts: ["news.ycombinator.com"]),
        SiteThemeEntry(id: "mdn", name: "MDN Web Docs", hosts: ["developer.mozilla.org"]),
        SiteThemeEntry(id: "wikipedia", name: "Wikipedia", hosts: ["*.wikipedia.org"]),
        SiteThemeEntry(id: "stackoverflow", name: "Stack Overflow", hosts: ["stackoverflow.com", "*.stackexchange.com", "superuser.com", "serverfault.com", "askubuntu.com"]),
        // Search only: Maps, Gmail, Docs and the rest live on the same or sibling hosts.
        SiteThemeEntry(id: "google", name: "Google Search",
                       hosts: ["google.com", "google.co.uk", "google.ca", "google.com.au", "google.de", "google.fr", "google.es",
                               "google.it", "google.nl", "google.co.in", "google.co.jp", "google.com.br", "google.com.mx", "google.ie",
                               "google.co.nz", "google.ch", "google.at", "google.be", "google.se", "google.no", "google.dk", "google.pl"],
                       paths: ["/", "/search", "/webhp"]),
    ]

    public static func entry(for url: URL?) -> SiteThemeEntry? {
        guard let url else { return nil }
        return entries.first { $0.matches(url) }
    }
}

// MARK: - Downloads

extension FileNaming {
    /// A safe file name for a download: no path parts, control or bidi characters (which can
    /// disguise "evil.app" as "ppa.live"), no leading dots, at most 200 characters.
    public static func sanitizedDownloadName(_ suggested: String) -> String {
        var s = (suggested as NSString).lastPathComponent
        s = String(s.unicodeScalars.filter { u in
            !(u.value < 0x20 || u.value == 0x7F || (0x200B...0x200F).contains(u.value) || (0x202A...0x202E).contains(u.value)
              || (0x2066...0x2069).contains(u.value) || u == "/" || u == ":" || u == "\\")
        }.map(Character.init))
        while s.hasPrefix(".") { s.removeFirst() }
        s = s.trimmingCharacters(in: .whitespaces)
        if s.count > 200 {
            var ext = (s as NSString).pathExtension
            if ext.count > 20 { ext = "" }          // a "extension" that long isn't one (and can't be kept)
            s = String(s.prefix(ext.isEmpty ? 200 : 200 - ext.count - 1)) + (ext.isEmpty ? "" : "." + ext)
        }
        return s.isEmpty ? "download" : s
    }

    /// `dir/name`, or `dir/name 2.ext`… if taken.
    public static func uniqueURL(in dir: URL, name: String) -> URL {
        let n = uniqueName(for: name) { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }
        return dir.appendingPathComponent(n)
    }
}
