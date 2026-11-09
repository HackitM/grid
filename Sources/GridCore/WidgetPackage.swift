import CryptoKit
import Darwin
import Foundation

/// A widget package read from disk with the limits in docs/WIDGETS.md: at most 1 MiB and 64
/// files, only `.js`, `.json` and `.md` files are read, symlinks and special files are refused.
public struct WidgetPackage: Equatable, Sendable {
    public let folder: URL
    public let manifest: WidgetManifest
    /// Scripts in load order (`scripts` first, then `entry`).
    public let sources: [(name: String, code: String)]
    public let readme: String?
    /// SHA-256 over every file read (path + contents), hex. Approvals of installed widgets are
    /// pinned to it, so any change to the package needs a new approval.
    public let digest: String

    public static let maxBytes = 1 << 20
    public static let maxFiles = 64
    public static let allowedExtensions: Set<String> = ["js", "json", "md"]

    public enum LoadError: Error, Equatable, CustomStringConvertible {
        case missingManifest, unreadable(String), tooLarge, tooManyFiles, badFile(String), invalidManifest([String])
        public var description: String {
            switch self {
            case .missingManifest: "No manifest.json in this folder."
            case .unreadable(let p): "Couldn't read \(p)."
            case .tooLarge: "Package is larger than 1 MiB."
            case .tooManyFiles: "Package has more than 64 files."
            case .badFile(let why): why
            case .invalidManifest(let e): "Invalid manifest: " + e.joined(separator: " ")
            }
        }
    }

    public static func == (a: WidgetPackage, b: WidgetPackage) -> Bool { a.folder == b.folder && a.digest == b.digest }

    public static func load(_ folder: URL) throws -> WidgetPackage {
        let root = folder.standardizedFileURL.resolvingSymlinksInPath()
        let files = try collect(root)
        guard let manifestData = files["manifest.json"] else { throw LoadError.missingManifest }
        let manifest: WidgetManifest
        do { manifest = try JSONDecoder().decode(WidgetManifest.self, from: manifestData) } catch {
            throw LoadError.invalidManifest(["manifest.json isn't valid: \(Self.describe(error))"])
        }
        let errors = manifest.validationErrors()
        guard errors.isEmpty else { throw LoadError.invalidManifest(errors) }
        var sources: [(String, String)] = []
        for name in (manifest.scripts ?? []) + [manifest.entry] {
            guard let d = files[name] else { throw LoadError.badFile("Script \(name) is missing.") }
            guard let s = String(data: d, encoding: .utf8) else { throw LoadError.badFile("Script \(name) isn't UTF-8.") }
            sources.append((name, s))
        }
        let readme = files["README.md"].flatMap { String(data: $0, encoding: .utf8) }
        return WidgetPackage(folder: root, manifest: manifest, sources: sources, readme: readme, digest: digest(files))
    }

    /// Order-independent digest of (relative path, contents).
    public static func digest(_ files: [String: Data]) -> String {
        var h = SHA256()
        for name in files.keys.sorted() {
            h.update(data: Data(name.utf8)); h.update(data: Data([0]))
            var n = UInt64(files[name]!.count).bigEndian
            h.update(data: Data(bytes: &n, count: 8))
            h.update(data: files[name]!)
        }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Reads allowed files under `root` (relative path → bytes), enforcing the limits.
    public static func collect(_ root: URL) throws -> [String: Data] {
        var out: [String: Data] = [:]
        var total = 0, count = 0
        func walk(_ dir: URL, _ prefix: String, depth: Int) throws {
            guard depth <= 4 else { throw LoadError.badFile("Folders nest too deeply.") }
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { throw LoadError.unreadable(dir.path) }
            for name in names.sorted() where !name.hasPrefix(".") {
                let url = dir.appendingPathComponent(name)
                var st = stat()
                guard lstat(url.path, &st) == 0 else { throw LoadError.unreadable(url.path) }
                let rel = prefix + name
                switch st.st_mode & S_IFMT {
                case S_IFDIR: try walk(url, rel + "/", depth: depth + 1)
                case S_IFREG:
                    guard allowedExtensions.contains(url.pathExtension.lowercased()) else { continue }   // ignored, never read
                    count += 1
                    guard count <= maxFiles else { throw LoadError.tooManyFiles }
                    total += Int(st.st_size)
                    guard total <= maxBytes else { throw LoadError.tooLarge }
                    let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                    guard fd >= 0 else { throw LoadError.unreadable(rel) }
                    let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                    let d = (try? h.read(upToCount: maxBytes + 1)) ?? Data()
                    guard d.count == Int(st.st_size) else { throw LoadError.unreadable(rel) }
                    out[rel] = d
                case S_IFLNK: throw LoadError.badFile("\(rel) is a symbolic link; packages can't contain links.")
                default: throw LoadError.badFile("\(rel) is a special file.")
                }
            }
        }
        try walk(root, "", depth: 0)
        return out
    }

    static func describe(_ e: Error) -> String {
        switch e {
        case DecodingError.keyNotFound(let k, _): "missing \"\(k.stringValue)\""
        case DecodingError.typeMismatch(_, let c), DecodingError.valueNotFound(_, let c):
            "wrong type at \(c.codingPath.map(\.stringValue).joined(separator: "."))"
        case DecodingError.dataCorrupted(let c): c.debugDescription
        default: e.localizedDescription
        }
    }
}

// MARK: - Plain-language permission summary (shown before approval)

public enum WidgetPermissionText {
    /// One line per capability, with exact paths, commands and hosts. Order: most sensitive first.
    public static func lines(_ p: WidgetPermissions?, settings: [WidgetSettingSpec] = []) -> [(risk: Int, text: String)] {
        guard let p else { return [] }
        func describeArg(_ a: String) -> String {
            // A choice setting substitutes author-chosen literals: show them.
            if a.hasPrefix("{setting:"), let s = settings.first(where: { "{setting:\($0.key)}" == a }), s.type == "choice" {
                return "‹" + (s.options ?? []).joined(separator: "|") + "›"
            }
            return Self.describeArg(a)
        }
        var out: [(Int, String)] = []
        for t in (p.exec ?? []).sorted(by: { $0.tier > $1.tier }) {
            var flags: [String] = []
            if t.net == true { flags.append("with network access") }
            if t.writes == true { flags.append("can write files") }
            if let s = t.timeout, s > 5 { flags.append("up to \(s) s") }
            if t.userInitiated == true { flags.append("only after a click") }
            let risk = t.tier == .readOnly && t.net != true && t.writes != true ? 0 : (t.tier == .opaque ? 2 : 1)
            out.append((risk, "Run \(t.command) " + t.args.map(describeArg).joined(separator: " ") + (flags.isEmpty ? "" : "  (" + flags.joined(separator: ", ") + ")")))
        }
        if let n = p.net, !n.isEmpty { out.append((1, "Connect to " + n.joined(separator: ", ") + " (https only)")) }
        for g in p.fsRead ?? [] { out.append((1, "Read files: " + describeGlob(g))) }
        switch p.openURL {
        case .any: out.append((0, "Open https links in your browser when you click"))
        case .hosts(let h): out.append((0, "Open links on " + h.joined(separator: ", ") + " when you click"))
        case nil: break
        }
        if p.terminalInsertPath == true { out.append((0, "Insert file paths at the terminal prompt when you click (never runs them)")) }
        if p.clipboardWrite == true { out.append((0, "Copy text to the clipboard when you click")) }
        if p.filesSelection == true { out.append((0, "See what's selected in Files and the Files folder")) }
        if p.terminalCwd == true { out.append((0, "See the active terminal's folder")) }
        if p.terminalSessions == true { out.append((0, "See your terminal sessions' folders and running programs (not their contents)")) }
        return out
    }

    /// Domains where anyone can host a subdomain: a wildcard there reaches strangers.
    static let sharedHosting = ["github.io", "vercel.app", "workers.dev", "pages.dev", "netlify.app", "herokuapp.com", "glitch.me",
                                "ngrok.io", "ngrok-free.app", "ngrok.app", "repl.co", "replit.dev", "onrender.com", "fly.dev", "web.app",
                                "firebaseapp.com", "appspot.com", "azurewebsites.net", "cloudfront.net", "amazonaws.com", "deno.dev", "surge.sh"]

    /// Combinations worth a second look, in plain words.
    public static func warnings(_ m: WidgetManifest) -> [String] {
        let p = m.permissions ?? WidgetPermissions()
        var w: [String] = []
        let net = p.net ?? []
        var reads: [String] = []
        if !(p.fsRead ?? []).isEmpty { reads.append("files") }
        if p.filesSelection == true { reads.append("your Files selection") }
        if p.terminalCwd == true || p.terminalSessions == true { reads.append("what your terminals are doing") }
        if !reads.isEmpty && !net.isEmpty {
            w.append("Can read \(reads.joined(separator: ", ")) and send data to \(net.joined(separator: ", ")).")
        }
        for h in net where h.hasPrefix("*.") {
            let d = String(h.dropFirst(2))
            if sharedHosting.contains(where: { d == $0 || d.hasSuffix("." + $0) }) {
                w.append("\(h) includes sites anyone can create, so data could go to a stranger.")
            }
        }
        for t in p.exec ?? [] {
            let name = (t.command as NSString).lastPathComponent
            if t.net == true { w.append("\(name) can use the network directly, not only the hosts listed.") }
            if t.writes == true { w.append("\(name) can create, change or delete files you can.") }
            if t.tier == .opaque { w.append("GRID can't tell what \(name) does. Approve only if you trust this widget's author.") }
        }
        return w
    }

    public static func describeArg(_ a: String) -> String {
        switch a {
        case "{cwd}": "‹terminal folder›"
        case "{selection}": "‹selected file›"
        case "{int}": "‹number›"
        case "{word}", "{token}": "‹name›"
        case "{folder}": "‹Files folder›"
        default: a.hasPrefix("{setting:") ? "‹setting \(a.dropFirst(9).dropLast())›" : a
        }
    }

    static func describeGlob(_ g: String) -> String {
        if g == "{selection}" { return "whatever you select in Files" }
        if g.hasPrefix("{selection}/") { return "inside whatever you select in Files" }
        if g.hasPrefix("{folder}") { return "the Files folder" + (g == "{folder}/**" ? " and everything inside it" : g.dropFirst(8)) }
        if g.hasPrefix("{cwd}") { return "the terminal's folder" + (g == "{cwd}/**" ? " and everything inside it" : g.dropFirst(5)) }
        if g.hasSuffix("/**") { return String(g.dropLast(3)) + " and everything inside it" }
        return g
    }
}
