import AppKit
import CryptoKit
import Foundation
import GridCore
import Observation

/// Every site theme GRID knows: the packs inside the app, newer packs downloaded from GRID's
/// repository (so themes improve without an app update), and the user's own packs from a folder
/// they can edit. Packs are CSS only and checked before use (`SiteThemePack.parse`).
@Observable
@MainActor
final class SiteThemeLibrary {
    /// GRID's public repository; the only host theme updates come from.
    nonisolated static let feedHost = "raw.githubusercontent.com"
    nonisolated static let feedBase = URL(string: "https://raw.githubusercontent.com/HackitM/grid/master/site-themes/")!

    enum UpdateState: Equatable {
        case idle
        case checking
        case done(updated: Int, at: Date)
        case failed(String)
    }

    private(set) var packs: [SiteThemeResolver.Resolved] = []
    /// Problems with the user's own packs, by file name (shown in Settings).
    private(set) var userErrors: [String: String] = [:]
    private(set) var updateState: UpdateState = .idle
    /// Check GRID's repository for new and improved themes once a day.
    var autoUpdate: Bool {
        didSet { UserDefaults.standard.set(autoUpdate, forKey: "browser.themes.autoUpdate"); if autoUpdate { checkIfDue() } }
    }
    @ObservationIgnored var onChange: (() -> Void)?

    nonisolated static var dir: URL { AdBlocker.dir.appendingPathComponent("SiteThemes", isDirectory: true) }
    nonisolated static var downloadedDir: URL { dir.appendingPathComponent("Downloaded", isDirectory: true) }
    nonisolated static var userDir: URL { dir.appendingPathComponent("Yours", isDirectory: true) }

    /// The packs inside the app bundle (`Contents/Resources/SiteThemes`). A debug build run from
    /// the repository falls back to the repository's `site-themes/packs`.
    nonisolated static var builtInDir: URL? {
        if let r = Bundle.main.resourceURL?.appendingPathComponent("SiteThemes", isDirectory: true),
           FileManager.default.fileExists(atPath: r.path) { return r }
        #if DEBUG
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("site-themes/packs", isDirectory: true)
        if FileManager.default.fileExists(atPath: repo.path) { return repo }
        #endif
        return nil
    }

    init() {
        autoUpdate = UserDefaults.standard.bool(forKey: "browser.themes.autoUpdate")
        reload()
        checkIfDue()
    }

    var entries: [SiteThemeEntry] { packs.map(\.pack.entry) }

    func entry(for url: URL?) -> SiteThemeEntry? {
        guard let url else { return nil }
        return packs.first { $0.pack.entry.matches(url) }?.pack.entry
    }

    func pack(_ id: String) -> SiteThemePack? { packs.first { $0.pack.id == id }?.pack }

    // MARK: Loading

    /// Re-reads all three sources (after an update, or when the user edited their packs).
    func reload() {
        let builtIn = Self.builtInDir.map { Self.load($0).packs } ?? []
        let downloaded = Self.load(Self.downloadedDir).packs
        let (user, errors) = Self.load(Self.userDir)
        userErrors = errors
        packs = SiteThemeResolver.merge(builtIn: builtIn, downloaded: downloaded, user: user)
        onChange?()
    }

    /// Every `.css` pack in a folder: regular files only (no symlinks), at most 200 of them.
    nonisolated static func load(_ dir: URL) -> (packs: [SiteThemePack], errors: [String: String]) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return ([], [:]) }
        var packs: [SiteThemePack] = []
        var errors: [String: String] = [:]
        var seen = Set<String>()
        for name in names.filter({ $0.hasSuffix(".css") }).sorted().prefix(200) {
            let url = dir.appendingPathComponent(name)
            guard let attrs = try? fm.attributesOfItem(atPath: url.path), attrs[.type] as? FileAttributeType == .typeRegular,
                  let size = attrs[.size] as? NSNumber, size.intValue <= SiteThemePack.maxBytes else {
                errors[name] = "not a regular file under 256 KB"; continue
            }
            guard let data = fm.contents(atPath: url.path), let text = String(data: data, encoding: .utf8) else {
                errors[name] = "not UTF-8 text"; continue
            }
            do {
                let p = try SiteThemePack.parse(text)
                guard seen.insert(p.id).inserted else { errors[name] = "another file already uses the id “\(p.id)”"; continue }
                packs.append(p)
            } catch let e as SiteThemePack.ParseError {
                errors[name] = e.description
            } catch {
                errors[name] = "\(error)"
            }
        }
        return (packs, errors)
    }

    // MARK: Your own packs

    /// Opens the folder for the user's packs in Finder (creating it, with a starter pack, if needed).
    func revealUserFolder() {
        try? FileManager.default.createDirectory(at: Self.userDir, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([Self.userDir])
    }

    /// Writes a starter pack for `host` into the user's folder and reveals it.
    func newUserPack(for host: String?) {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.userDir, withIntermediateDirectories: true)
        let site = (host ?? "example.com").lowercased().replacingOccurrences(of: "www.", with: "")
        let base = site.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "-" }.joined().lowercased()
        var id = String(base.prefix(30)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if id.isEmpty || !SiteThemePack.validID(id) { id = "my-theme" }
        var file = Self.userDir.appendingPathComponent(id + ".css")
        var n = 2
        while fm.fileExists(atPath: file.path) { file = Self.userDir.appendingPathComponent("\(id)-\(n).css"); n += 1 }
        let hostLine = SiteThemePack.validHostPattern(site) ? site : "example.com"
        let text = """
        /* grid-site-theme
        id: \(file.deletingPathExtension().lastPathComponent)
        name: \(hostLine)
        version: 1
        hosts: \(hostLine)
        description: My GRID theme for \(hostLine).
        */
        /* GRID's palette is available as variables: --grid-bg0 … --grid-bg3, --grid-text, --grid-dim,
           --grid-mute, --grid-accent, --grid-accent-soft, --grid-line, --grid-line-strong, --grid-mono.
           Scope rules to html[data-grid-theme="<id>"]: GRID sets it only while the theme is on.
           Packs can't load anything: url() is limited to inline data: images. */
        html[data-grid-theme="\(file.deletingPathExtension().lastPathComponent)"] body {
          background: var(--grid-bg1) !important;
          color: var(--grid-text) !important;
          font-family: var(--grid-mono) !important;
        }
        html[data-grid-theme="\(file.deletingPathExtension().lastPathComponent)"] a { color: var(--grid-accent) !important; }

        """
        try? text.write(to: file, atomically: true, encoding: .utf8)
        reload()
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }

    // MARK: Updates

    private func checkIfDue() {
        guard autoUpdate else { return }
        let last = UserDefaults.standard.double(forKey: "browser.themes.lastCheck")
        guard Date().timeIntervalSince1970 - last > 24 * 3600 else { return }
        Task { await checkForUpdates() }
    }

    /// Downloads the repository's theme index and any pack newer than the one in use. Each pack
    /// must match the index's SHA-256 and pass `SiteThemePack.parse` before it's saved.
    func checkForUpdates() async {
        guard updateState != .checking else { return }
        updateState = .checking
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "browser.themes.lastCheck")
        do {
            let indexData = try await Self.get(Self.feedBase.appendingPathComponent("index.json"), maxBytes: SiteThemeIndex.maxBytes)
            let index = try SiteThemeIndex.parse(indexData)
            let appVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).flatMap(SemanticVersion.init)
            var updated = 0
            for item in index.packs {
                if let have = packs.first(where: { $0.pack.id == item.id }), have.source == .user || have.pack.version >= item.version { continue }
                if let min = item.minimumApp.flatMap(SemanticVersion.init), let appVersion, appVersion < min { continue }
                let data = try await Self.get(Self.feedBase.appendingPathComponent("packs").appendingPathComponent(item.file),
                                              maxBytes: SiteThemePack.maxBytes)
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                guard digest == item.sha256, let text = String(data: data, encoding: .utf8),
                      let pack = try? SiteThemePack.parse(text), pack.id == item.id, pack.version == item.version else { continue }
                try FileManager.default.createDirectory(at: Self.downloadedDir, withIntermediateDirectories: true)
                try data.write(to: Self.downloadedDir.appendingPathComponent(item.id + ".css"), options: .atomic)
                updated += 1
            }
            if updated > 0 { reload() }
            updateState = .done(updated: updated, at: Date())
        } catch {
            updateState = .failed((error as? LocalizedError)?.errorDescription ?? "Couldn't reach GitHub.")
        }
    }

    /// Removes downloaded packs (back to the themes inside GRID).
    func resetDownloaded() {
        try? FileManager.default.removeItem(at: Self.downloadedDir)
        reload()
    }

    enum FeedError: LocalizedError {
        case blocked, http(Int), tooLarge
        var errorDescription: String? {
            switch self {
            case .blocked: "Blocked a theme download from an unexpected address."
            case .http(let s): "GitHub answered \(s)."
            case .tooLarge: "A theme file was larger than allowed."
            }
        }
    }

    private nonisolated static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.urlCache = nil
        c.httpAdditionalHeaders = ["User-Agent": "GRID"]
        c.timeoutIntervalForRequest = 30
        return URLSession(configuration: c, delegate: NoRedirects(), delegateQueue: nil)
    }()

    /// https GET from the feed host only, no redirects, stopped once it passes `maxBytes`.
    nonisolated static func get(_ url: URL, maxBytes: Int) async throws -> Data {
        guard url.scheme == "https", url.host == feedHost, url.user == nil, url.port == nil else { throw FeedError.blocked }
        let (bytes, resp) = try await session.bytes(for: URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
        guard let http = resp as? HTTPURLResponse else { throw FeedError.http(0) }
        guard http.statusCode == 200 else { throw FeedError.http(http.statusCode) }
        var data = Data()
        for try await b in bytes {
            data.append(b)
            if data.count > maxBytes { throw FeedError.tooLarge }
        }
        return data
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? { nil }
    }
}
