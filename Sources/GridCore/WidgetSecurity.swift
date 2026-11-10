import Foundation

// MARK: - Manifest

/// A widget package's manifest (docs/WIDGETS.md). Decoded leniently, then validated strictly.
public struct WidgetManifest: Codable, Equatable, Sendable {
    public var api: Int
    public var id: String
    public var name: String
    public var version: String
    public var description: String?
    public var author: String?
    public var entry: String
    public var scripts: [String]?
    public var refresh: Int?
    public var events: [String]?
    public var settings: [WidgetSettingSpec]?
    public var permissions: WidgetPermissions?

    public static let supportedAPI = 1
    public static let knownEvents: Set<String> = ["files.selection", "files.folder", "terminal.cwd", "terminal.sessions", "theme", "settings"]

    /// Problems that make the manifest unusable (empty = valid).
    public func validationErrors() -> [String] {
        var e: [String] = []
        if api != Self.supportedAPI { e.append("Unsupported api version \(api) (this GRID supports \(Self.supportedAPI)).") }
        if id.range(of: #"^[a-z0-9]+([.-][a-z0-9]+)+$"#, options: .regularExpression) == nil || id.count > 100 {
            e.append("id must be reverse-DNS style, e.g. com.example.my-widget.")
        }
        if name.trimmingCharacters(in: .whitespaces).isEmpty || name.count > 40 { e.append("name must be 1–40 characters.") }
        // Shown on the approval screen: keep them short so they can't crowd out the permissions.
        if (description ?? "").count > 300 { e.append("description must be at most 300 characters.") }
        if (author ?? "").count > 60 { e.append("author must be at most 60 characters.") }
        for t in [name, description ?? "", author ?? ""] where t.unicodeScalars.contains(where: { $0.value < 0x20 || (0x202A...0x202E).contains($0.value) || (0x2066...0x2069).contains($0.value) }) {
            e.append("name, description and author can't contain control or bidi characters."); break
        }
        if version.range(of: #"^\d+(\.\d+){0,3}$"#, options: .regularExpression) == nil { e.append("version must look like 1.2.3.") }
        for f in [entry] + (scripts ?? []) where !Self.isSafeScriptName(f) {
            e.append("Script \"\(f)\" must be a .js file inside the package (no ../, no absolute paths).")
        }
        if let r = refresh, r != 0 && !(1...3600).contains(r) { e.append("refresh must be 0 or 1–3600 seconds.") }
        for ev in events ?? [] where !Self.knownEvents.contains(ev) { e.append("Unknown event \"\(ev)\".") }
        for s in settings ?? [] { e += s.validationErrors() }
        if Set((settings ?? []).map(\.key)).count != (settings ?? []).count { e.append("Setting keys must be unique.") }
        let perms = permissions ?? WidgetPermissions()
        e += perms.validationErrors()
        // Events need the matching read permission.
        for ev in events ?? [] {
            switch ev {
            case "files.selection", "files.folder": if perms.filesSelection != true { e.append("Event \(ev) requires the files.selection permission.") }
            case "terminal.cwd": if perms.terminalCwd != true { e.append("Event terminal.cwd requires the terminal.cwd permission.") }
            case "terminal.sessions": if perms.terminalSessions != true { e.append("Event terminal.sessions requires the terminal.sessions permission.") }
            default: break
            }
        }
        // {setting:key} in exec only for settings whose values can't smuggle arbitrary strings.
        let types = Dictionary((settings ?? []).map { ($0.key, $0.type) }, uniquingKeysWith: { a, _ in a })
        for t in perms.exec ?? [] {
            for a in t.args where a.hasPrefix("{setting:") {
                let key = String(a.dropFirst(9).dropLast())
                guard let ty = types[key] else { e.append("exec uses {setting:\(key)} but there's no such setting."); continue }
                if !["number", "bool", "choice"].contains(ty) { e.append("exec can only use number, bool or choice settings ({setting:\(key)} is \(ty)).") }
            }
        }
        // Secrets may only be sent to hosts the widget can reach anyway.
        let net = perms.net ?? []
        for s in settings ?? [] where s.type == "secret" {
            for h in s.hosts ?? [] where !net.contains(h) { e.append("Secret \(s.key) may be sent to \(h), which isn't in net.") }
        }
        if perms.filesSelection != true {
            for a in (perms.exec ?? []).flatMap(\.args) + (perms.fsRead ?? []) where a.hasPrefix("{selection}") || a.hasPrefix("{folder}") {
                e.append("\(a) requires the files.selection permission.")
            }
        }
        if perms.terminalCwd != true {
            for a in (perms.exec ?? []).flatMap(\.args) + (perms.fsRead ?? []) where a.hasPrefix("{cwd}") {
                e.append("\(a) requires the terminal.cwd permission.")
            }
        }
        return Array(NSOrderedSet(array: e)) as! [String]
    }

    static func isSafeScriptName(_ s: String) -> Bool {
        !s.isEmpty && s.hasSuffix(".js") && !s.hasPrefix("/") && !s.contains("..") && !s.contains("\\")
            && s.range(of: #"^[A-Za-z0-9._/-]+$"#, options: .regularExpression) != nil
    }

    /// Settings with their defaults, as strings (the deck stores settings as strings).
    public var defaultSettings: [String: String] {
        var d: [String: String] = [:]
        for s in settings ?? [] where s.type != "secret" {
            switch s.default {
            case .string(let v): d[s.key] = v
            case .number(let n): d[s.key] = WidgetSettingSpec.format(n)
            case .bool(let b): d[s.key] = b ? "true" : "false"
            default: if s.type == "choice", let f = s.options?.first { d[s.key] = f }
            }
        }
        return d
    }
}

public struct WidgetSettingSpec: Codable, Equatable, Sendable {
    public var key: String
    public var type: String          // string | number | bool | choice | secret
    public var label: String
    public var `default`: WidgetJSON?
    public var min: Double?
    public var max: Double?
    public var maxLength: Int?
    public var options: [String]?
    /// For `secret`: the only hosts its value may be sent to (via {secret:key} in net.fetch).
    public var hosts: [String]?

    public func validationErrors() -> [String] {
        var e: [String] = []
        if key.range(of: #"^[A-Za-z][A-Za-z0-9_]{0,31}$"#, options: .regularExpression) == nil { e.append("Setting key \"\(key)\" is invalid.") }
        if !["string", "number", "bool", "choice", "secret"].contains(type) { e.append("Setting \(key): unknown type \"\(type)\".") }
        if type == "choice" && (options ?? []).isEmpty { e.append("Setting \(key): choice needs options.") }
        if type == "secret" && (hosts ?? []).isEmpty { e.append("Secret \(key) must list the hosts it may be sent to.") }
        if type == "secret" && self.default != nil { e.append("Secret \(key) can't have a default.") }
        return e
    }

    /// A number as the deck stores it: whole numbers without a fraction ("5", not "5.0").
    /// Manifests are untrusted, so a default or bound like 1e300 must not reach `Int(_:)`,
    /// which traps on values it can't represent.
    static func format(_ n: Double) -> String {
        guard n.isFinite else { return "0" }
        return n == n.rounded() && abs(n) < 1e15 ? String(Int(n)) : String(n)
    }

    /// Normalizes a user-entered value; nil if invalid.
    public func normalize(_ raw: String) -> String? {
        switch type {
        case "number":
            guard let n = Double(raw.trimmingCharacters(in: .whitespaces)), n.isFinite else { return nil }
            return Self.format(Swift.min(Swift.max(n, min ?? -1e12), max ?? 1e12))
        case "bool": return raw == "true" || raw == "1" ? "true" : "false"
        case "choice": return (options ?? []).contains(raw) ? raw : nil
        default: return String(raw.prefix(maxLength ?? 500))
        }
    }
}

/// Who a widget may send you to on click: specific hosts, or any https URL.
public enum OpenURLRule: Codable, Equatable, Sendable {
    case any
    case hosts([String])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self), s == "any" { self = .any } else { self = .hosts(try c.decode([String].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self { case .any: try c.encode("any"); case .hosts(let h): try c.encode(h) }
    }

    public func allows(_ url: URL) -> Bool {
        switch self {
        case .any: return url.scheme?.lowercased() == "https" && url.host != nil && url.user == nil && url.password == nil
        case .hosts(let h): return NetRule.allows(url, hosts: h)
        }
    }
}

/// Permissions as declared in the manifest. JSON keys use the dotted names from the spec.
public struct WidgetPermissions: Codable, Equatable, Sendable {
    public var filesSelection: Bool?
    public var terminalCwd: Bool?
    public var terminalSessions: Bool?
    public var terminalInsertPath: Bool?
    public var clipboardWrite: Bool?
    public var fsRead: [String]?
    public var exec: [ExecTemplate]?
    public var net: [String]?
    public var openURL: OpenURLRule?

    public init() {}

    enum CodingKeys: String, CodingKey {
        case filesSelection = "files.selection", terminalCwd = "terminal.cwd", terminalSessions = "terminal.sessions"
        case terminalInsertPath = "terminal.insertPath", clipboardWrite = "clipboard.write"
        case fsRead = "fs.read", exec, net, openURL
    }

    public var isEmpty: Bool {
        filesSelection != true && terminalCwd != true && terminalSessions != true && terminalInsertPath != true
            && clipboardWrite != true && (fsRead ?? []).isEmpty && (exec ?? []).isEmpty && (net ?? []).isEmpty && openURL == nil
    }

    static let pathPlaceholders = ["{cwd}", "{folder}", "{selection}"]

    public func validationErrors() -> [String] {
        var e: [String] = []
        for g in fsRead ?? [] {
            let ok = g.hasPrefix("/") || g.hasPrefix("~/") || g == "~"
                || Self.pathPlaceholders.contains { g == $0 || g.hasPrefix($0 + "/") }
            if !ok { e.append("fs.read pattern \"\(g)\" must be absolute, ~/…, or start with {cwd}, {folder} or {selection}.") }
        }
        for t in exec ?? [] { e += t.validationErrors() }
        for h in net ?? [] where !NetRule.isValidPattern(h) { e.append("net host \"\(h)\" must be a hostname like api.example.com or *.example.com.") }
        if case .hosts(let hs) = openURL { for h in hs where !NetRule.isValidPattern(h) { e.append("openURL host \"\(h)\" is invalid.") } }
        return e
    }
}

// MARK: - Exec templates

/// An approved command shape. Arguments are literals or placeholders; values substituted for
/// placeholders can never start with "-" (no option injection) and never contain NUL/newlines.
/// Commands run without a shell, with a scrubbed environment, inside a sandbox that denies
/// network access and file writes unless the template asks for them (shown at approval).
public struct ExecTemplate: Codable, Equatable, Sendable {
    /// Absolute paths; the first that exists is used (e.g. Homebrew on Apple silicon vs Intel).
    public var commands: [String]
    public var args: [String]
    /// Seconds (default 5, max 60).
    public var timeout: Int?
    /// Only callable while handling a click (`onAction`), never from `render`.
    public var userInitiated: Bool?
    /// Allows the command network access.
    public var net: Bool?
    /// Allows the command to write files (outside its temporary folder).
    public var writes: Bool?

    public var command: String { commands.first ?? "" }

    public init(command: String, args: [String], timeout: Int? = nil, userInitiated: Bool? = nil, net: Bool? = nil, writes: Bool? = nil) {
        self.commands = [command]; self.args = args; self.timeout = timeout; self.userInitiated = userInitiated; self.net = net; self.writes = writes
    }

    enum CodingKeys: String, CodingKey { case command, args, timeout, userInitiated, net, writes }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let one = try? c.decode(String.self, forKey: .command) { commands = [one] } else { commands = try c.decode([String].self, forKey: .command) }
        args = try c.decodeIfPresent([String].self, forKey: .args) ?? []
        timeout = try c.decodeIfPresent(Int.self, forKey: .timeout)
        userInitiated = try c.decodeIfPresent(Bool.self, forKey: .userInitiated)
        net = try c.decodeIfPresent(Bool.self, forKey: .net)
        writes = try c.decodeIfPresent(Bool.self, forKey: .writes)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if commands.count == 1 { try c.encode(commands[0], forKey: .command) } else { try c.encode(commands, forKey: .command) }
        try c.encode(args, forKey: .args)
        try c.encodeIfPresent(timeout, forKey: .timeout)
        try c.encodeIfPresent(userInitiated, forKey: .userInitiated)
        try c.encodeIfPresent(net, forKey: .net)
        try c.encodeIfPresent(writes, forKey: .writes)
    }

    public var effectiveTimeout: Int { min(max(timeout ?? 5, 1), 60) }

    public static let placeholders = ["{cwd}", "{folder}", "{selection}", "{int}", "{word}", "{token}"]

    /// Executables that turn arguments into arbitrary code (shells, interpreters, launchers,
    /// editors with command modes), reach the network or Keychain directly, or drive the user's
    /// terminal. Refused outright: approving `python3 {word}` would be approving anything.
    public static let forbiddenCommands: Set<String> = [
        "sh", "bash", "zsh", "fish", "csh", "tcsh", "ksh", "dash", "nu", "pwsh", "elvish", "xonsh",
        "env", "xargs", "sudo", "su", "doas", "login", "chroot", "sandbox-exec", "arch", "caffeinate",
        "nohup", "time", "nice", "renice", "timeout", "gtimeout", "watch", "parallel", "entr", "script", "exec", "eval", "command",
        "osascript", "osacompile", "automator", "shortcuts", "open", "launchctl", "crontab", "at", "batch", "defaults",
        "deno", "bun", "awk", "gawk", "nawk", "mawk", "tclsh", "wish", "expect", "swift", "swiftc", "make", "gmake", "cmake",
        "npx", "npm", "pnpm", "yarn", "pip", "pip3", "pipx", "uv", "uvx", "cargo", "go", "gcc", "cc", "clang", "ld",
        "vim", "vi", "nvim", "view", "ex", "ed", "emacs", "nano", "pico", "less", "more", "man",
        "ssh", "scp", "sftp", "rsync", "curl", "wget", "nc", "ncat", "netcat", "socat", "telnet", "ftp",
        "tmux", "screen", "security", "sqlite3", "dtrace", "dtruss", "lldb", "gdb", "find", "git-shell",
        "xcrun", "xcodebuild", "ssh-add", "ssh-keygen", "ssh-agent", "gpg", "gpg2", "gpg-agent", "gem", "bundle", "bundler",
        "rake", "jsc", "dc", "m4", "groff", "screencapture", "pbpaste", "launchd", "hdiutil", "mount", "umount", "installer",
        "pkgutil", "kextload", "kmutil", "dscl", "sysadminctl", "csrutil", "nvram", "systemsetup", "tccutil", "scutil", "chflags",
    ]
    /// Name stems: `python3.12`, `perl5.34`, `ruby3.3`, `node20`, `php8.3`, …
    public static let forbiddenStems = ["python", "pypy", "perl", "ruby", "irb", "jruby", "node", "php", "lua", "luajit",
                                        "java", "jshell", "scala", "kotlin", "groovy", "julia", "rscript", "osascript", "sqlite"]
    /// Literal git arguments that load code or config from elsewhere.
    static let forbiddenGitArgs = ["-c", "--exec-path", "--upload-pack", "--receive-pack", "--config-env", "--git-dir", "--work-tree", "-u",
                                   "--ext-diff", "--textconv"]

    public static func isForbidden(_ command: String) -> Bool {
        let base = (command as NSString).lastPathComponent.lowercased()
        return forbiddenCommands.contains(base) || forbiddenStems.contains { base.hasPrefix($0) }
    }

    public func validationErrors() -> [String] {
        var e: [String] = []
        guard !commands.isEmpty, commands.count <= 4 else { return ["exec command must list 1–4 absolute paths."] }
        for c in commands {
            guard c.hasPrefix("/"), !c.contains(".."), !c.contains("//") else { e.append("exec command \"\(c)\" must be an absolute path."); continue }
            if Self.isForbidden(c) { e.append("exec command \"\(c)\" can run arbitrary code or bypass GRID's guardrails, so it isn't allowed.") }
        }
        let bases = Set(commands.map { ($0 as NSString).lastPathComponent })
        guard bases.count == 1 else { return e + ["exec alternatives must all be the same program (got \(bases.sorted().joined(separator: ", ")))."] }
        let base = bases.first!
        if args.count > 32 { e.append("exec \(base): at most 32 arguments.") }
        if let t = timeout, !(1...60).contains(t) { e.append("exec \(base): timeout must be 1–60 seconds.") }
        for a in args {
            if a.hasPrefix("{"), !(Self.placeholders.contains(a) || a.range(of: #"^\{setting:[A-Za-z][A-Za-z0-9_]{0,31}\}$"#, options: .regularExpression) != nil) {
                e.append("exec \(base): unknown placeholder \(a).")
            }
            if a.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) { e.append("exec \(base): arguments can't contain control characters.") }
        }
        if tier == .modifies && userInitiated != true {
            e.append("exec \(base) \(args.prefix(3).joined(separator: " ")): commands that change things must set \"userInitiated\": true (run only after a click).")
        }
        if base == "git" {
            for a in args where Self.forbiddenGitArgs.contains(where: { a == $0 || a.hasPrefix($0 + "=") }) {
                e.append("exec git: \(a) isn't allowed (it can load commands or config from elsewhere).")
            }
        }
        return e
    }

    // MARK: Risk tier (shown at approval)

    public enum Tier: Int, Comparable, Sendable {
        case readOnly = 0, modifies = 1, opaque = 2
        public static func < (a: Tier, b: Tier) -> Bool { a.rawValue < b.rawValue }
    }

    /// Setuid programs that only read process tables; they run outside sandbox-exec (which
    /// can't start setuid binaries). Every other setuid program is refused at run time.
    public static let setuidReadOnly: Set<String> = ["ps", "top"]

    static let readOnlyPrograms: Set<String> = ["ps", "du", "df", "stat", "file", "wc", "ls", "uptime", "sw_vers", "uname", "whoami",
                                                "vm_stat", "top", "iostat", "netstat", "lsof", "mdls", "mdfind", "head", "tail",
                                                "cat", "date", "cal", "sysctl", "system_profiler", "ioreg", "hostname", "id",
                                                "pgrep", "wc", "shasum", "md5", "otool", "codesign", "spctl", "xattr", "plutil", "sort", "uniq", "grep"]
    static let readOnlySubcommands: [String: Set<String>] = [
        "git": ["status", "log", "diff", "show", "branch", "rev-parse", "remote", "describe", "ls-files", "blame", "shortlog",
                "rev-list", "symbolic-ref", "tag", "stash", "for-each-ref", "cat-file", "reflog", "worktree"],
        "brew": ["list", "info", "outdated", "services", "deps", "leaves", "search", "config", "--prefix", "--version"],
        "docker": ["ps", "images", "info", "version", "stats", "logs", "inspect", "volume", "network", "compose"],
        "port": ["installed", "outdated", "info"],
        "gh": ["pr", "issue", "run", "repo", "status"],
    ]
    static let modifyingPrograms: Set<String> = ["kill", "killall", "pkill", "mv", "cp", "rm", "mkdir", "rmdir", "touch", "ln",
                                                 "chmod", "chown", "brew", "docker", "git", "port", "tar", "unzip", "zip", "ditto",
                                                 "tmutil", "networksetup", "say", "afplay", "pbcopy", "diskutil", "pmset"]

    /// How much to worry: known read-only commands, known commands that change things, or
    /// programs GRID can't reason about.
    public var tier: Tier {
        let base = (command as NSString).lastPathComponent
        let words = args.filter { !$0.hasPrefix("-") && !$0.hasPrefix("{") }
        if let subs = Self.readOnlySubcommands[base] {
            // brew services list / docker volume ls are read-only; brew services start isn't.
            guard let sub = words.first, subs.contains(sub) else { return .modifies }
            let second = words.dropFirst().first
            if ["services", "volume", "network", "compose", "stash", "worktree", "remote", "tag", "branch", "pr", "issue", "run", "repo"].contains(sub),
               let s2 = second, !["list", "ls", "show", "view", "status", "info", "get-url", "inspect"].contains(s2) { return .modifies }
            if net == true || writes == true { return .modifies }
            return .readOnly
        }
        if Self.readOnlyPrograms.contains(base) { return (net == true || writes == true) ? .modifies : .readOnly }
        if Self.modifyingPrograms.contains(base) { return .modifies }
        return .opaque
    }
}

/// Context for resolving placeholders at call time.
public struct WidgetCallContext: Sendable {
    public var cwd: String?
    public var folder: String?
    public var selection: [String]
    public var settings: [String: String]
    public init(cwd: String?, folder: String? = nil, selection: [String], settings: [String: String]) {
        self.cwd = cwd; self.folder = folder; self.selection = selection; self.settings = settings
    }
}

public enum ExecMatcher {
    /// Returns the template that `command` + `args` satisfies, or a reason it's refused.
    public static func match(command: String, args: [String], templates: [ExecTemplate], context: WidgetCallContext) -> Result<ExecTemplate, WidgetDenied> {
        var reasons: [String] = []
        for t in templates where t.commands.contains(command) && t.args.count == args.count && t.validationErrors().isEmpty {
            if let why = mismatch(t, args, context) { reasons.append(why) } else { return .success(t) }
        }
        return .failure(WidgetDenied("exec \(command) \(args.joined(separator: " ")) doesn't match an approved command" + (reasons.first.map { " (\($0))" } ?? "") + "."))
    }

    static func mismatch(_ t: ExecTemplate, _ args: [String], _ c: WidgetCallContext) -> String? {
        for (pattern, value) in zip(t.args, args) {
            if !pattern.hasPrefix("{") {
                if pattern != value { return "argument \"\(value)\" ≠ \"\(pattern)\"" }
                continue
            }
            // Substituted values: never options, never control characters, never empty.
            if value.isEmpty { return "empty argument" }
            if value.hasPrefix("-") { return "argument \"\(value)\" starts with '-'" }
            if value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) { return "argument contains control characters" }
            switch pattern {
            case "{int}": if value.range(of: #"^[1-9][0-9]{0,8}$"#, options: .regularExpression) == nil { return "\"\(value)\" isn't a positive integer" }
            case "{word}": if value.range(of: #"^[A-Za-z0-9._][A-Za-z0-9._-]{0,63}$"#, options: .regularExpression) == nil { return "\"\(value)\" isn't a simple word" }
            case "{token}": if value.range(of: #"^[A-Za-z0-9][A-Za-z0-9@._+:-]{0,63}$"#, options: .regularExpression) == nil { return "\"\(value)\" isn't a simple token" }
            case "{cwd}": if value != c.cwd { return "\"\(value)\" isn't the terminal's folder" }
            case "{folder}": if value != c.folder { return "\"\(value)\" isn't the Files folder" }
            case "{selection}": if !c.selection.contains(value) { return "\"\(value)\" isn't selected in Files" }
            default:
                if pattern.hasPrefix("{setting:") {
                    let key = String(pattern.dropFirst("{setting:".count).dropLast())
                    if c.settings[key] != value { return "\"\(value)\" isn't the value of setting \(key)" }
                } else { return "unknown placeholder" }
            }
        }
        return nil
    }

    /// Sandbox profile for an exec'd command (sandbox-exec): no Apple Events, no Keychain, no
    /// credential files; no network unless `net`; no writes outside `tmp` unless `writes`.
    public static func sandboxProfile(for t: ExecTemplate, exe: String? = nil, tmp: String, home: String = NSHomeDirectory()) -> String {
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        let realHome = PathRule.canonical(home, home: home)
        var p = ["(version 1)", "(allow default)", "(deny appleevent-send)",
                 "(deny mach-lookup (global-name \"com.apple.SecurityServer\") (global-name \"com.apple.securityd.xpc\") (global-name \"com.apple.pasteboard.1\") (global-name-regex #\"^com\\.1password\") (global-name-regex #\"^2BUA8C4S2C\\.\"))"]
        let secrets = PathRule.sensitiveRoots(home: home).map { "(subpath \(q(PathRule.canonical($0, home: home))))" }
        p.append("(deny file-read* file-write* " + secrets.joined(separator: " ") + ")")
        // Places a command could be persisted from, even when the template may write files.
        let persistence = ["Library/LaunchAgents", "Library/Preferences", ".gitconfig", ".config/git", ".zshrc", ".zshenv", ".zprofile",
                           ".bashrc", ".bash_profile", ".profile", ".config/fish", ".ssh"].map { "(subpath \(q(realHome + "/" + $0)))" }
        p.append("(deny file-write* " + persistence.joined(separator: " ") + ")")
        // No network at all (IP or Unix sockets: ssh-agent, docker, password managers) unless asked for.
        if t.net != true { p.append("(deny network*)") }
        if t.writes != true {
            p.append("(deny file-write*)")
            p.append("(allow file-write* (literal \"/dev/null\") (literal \"/dev/dtracehelper\") (regex #\"^/dev/tty\") (subpath \(q(tmp))))")
        }
        // Nothing from home, temp or removable volumes may be executed (e.g. scripts a cloned repo's
        // config points git at); only the approved program itself.
        p.append("(deny process-exec (subpath \(q(realHome))) (subpath \"/private/tmp\") (subpath \"/private/var/folders\") (subpath \"/Volumes\"))")
        if (t.command as NSString).lastPathComponent == "git" {
            // git only needs a shell for config-driven helpers (external diff, textconv, ssh): refuse them.
            p.append("(deny process-exec (literal \"/bin/sh\") (literal \"/bin/bash\") (literal \"/bin/zsh\") (literal \"/bin/dash\") (literal \"/bin/ksh\") (literal \"/bin/csh\") (literal \"/bin/tcsh\") (literal \"/usr/bin/env\") (literal \"/private/var/select/sh\"))")
        }
        for c in Set(t.commands + (exe.map { [$0] } ?? [])) { p.append("(allow process-exec (literal \(q(c))))") }
        return p.joined(separator: "\n")
    }
}

public struct WidgetDenied: Error, Equatable, Sendable {
    public let message: String
    public init(_ m: String) { message = m }
}

/// Simple token bucket for per-widget rate limits (burst, then `perMinute`).
public struct TokenBucket: Sendable {
    public let capacity: Double
    public let perSecond: Double
    private var tokens: Double
    private var last: TimeInterval

    public init(burst: Int, perMinute: Int, now: TimeInterval) {
        capacity = Double(burst); perSecond = Double(perMinute) / 60; tokens = Double(burst); last = now
    }

    public mutating func take(now: TimeInterval) -> Bool {
        tokens = min(capacity, tokens + (now - last) * perSecond)
        last = now
        guard tokens >= 1 else { return false }
        tokens -= 1
        return true
    }
}

// MARK: - File access

public enum PathRule {
    /// Locations with credentials or private data. A pattern only reaches inside them if the
    /// pattern itself names that location (e.g. "~/.ssh/config"), never through "~/**".
    public static func sensitiveRoots(home: String) -> [String] {
        [".ssh", ".gnupg", ".aws", ".azure", ".kube", ".docker", ".netrc", ".config/gh", ".config/gcloud", ".config/op",
         ".password-store", ".npmrc", ".pypirc", ".git-credentials", ".zsh_history", ".bash_history", ".local/share/fish",
         ".zsh_sessions", ".bash_sessions", "Library/Keychains", "Library/Cookies", "Library/Mail",
         "Library/Messages", "Library/Safari", "Library/Application Support/Google/Chrome",
         "Library/Application Support/Firefox", "Library/Application Support/GRID", "Library/Application Support/1Password",
         "Library/Application Support/Code/User/globalStorage", "Library/Containers", "Library/Group Containers",
         ".zshrc", ".zshenv", ".zprofile", ".zlogin", ".bashrc", ".bash_profile", ".profile", ".claude", ".claude.json",
         ".cargo/credentials", ".cargo/credentials.toml", ".gem/credentials", ".m2/settings.xml", ".gradle/gradle.properties",
         ".terraform.d", ".vault-token", ".config/hub", ".config/doctl", ".config/fish", "Library/Preferences", "Library/HTTPStorages",
         "Library/Accounts", "Library/LaunchAgents", "Library/Application Support/Arc", "Library/Application Support/BraveSoftware",
         "Library/Application Support/Microsoft Edge", "Library/Application Support/Slack", "Library/Application Support/discord",
         "Library/Application Support/Claude", "Library/Application Support/Code/User"].map { home + "/" + $0 }
    }

    /// The protected location containing `target`, most specific first: a listed credential store,
    /// else any dot-entry directly in your home folder, else ~/Library. A pattern reaches inside
    /// only if it names (a path within) that location itself.
    static func protectedRoot(_ target: String, home: String, listed: [String]) -> String? {
        if let r = listed.filter({ target == $0 || target.hasPrefix($0 + "/") }).max(by: { $0.count < $1.count }) { return r }
        let realHome = canonical(home, home: home)
        guard target.hasPrefix(realHome + "/") else { return nil }
        let first = target.dropFirst(realHome.count + 1).split(separator: "/").first.map(String.init) ?? ""
        if first.hasPrefix(".") || first == "Library" { return realHome + "/" + first }
        return nil
    }

    /// Cheap, filesystem-free check that `path` could match one of `patterns` at all (run before
    /// resolving symlinks, so arbitrary paths can't stall the app on slow mounts).
    public static func lexicallyPlausible(_ path: String, patterns: [String], context: WidgetCallContext, home: String = NSHomeDirectory()) -> Bool {
        var p = path
        if p == "~" { p = home } else if p.hasPrefix("~/") { p = home + p.dropFirst(1) }
        guard p.hasPrefix("/") else { return false }
        let target = (p as NSString).standardizingPath
        for raw in patterns {
            var bases: [String]
            if raw.hasPrefix("{cwd}") { bases = context.cwd.map { [$0] } ?? [] }
            else if raw.hasPrefix("{folder}") { bases = context.folder.map { [$0] } ?? [] }
            else if raw.hasPrefix("{selection}") { bases = context.selection }
            else {
                var r = raw
                if r == "~" { r = home } else if r.hasPrefix("~/") { r = home + r.dropFirst(1) }
                let literal = r.prefix { !"*?[".contains($0) }
                bases = [String(literal.hasSuffix("/") ? literal.dropLast() : literal)]
            }
            // Symlinked spellings (/var vs /private/var, a linked home) are settled by the full check.
            for b in bases where target.hasPrefix(b) || b.hasPrefix("/var") || b.hasPrefix("/tmp") || b.hasPrefix("/etc") || target.hasPrefix("/private") { return true }
        }
        return false
    }

    /// Canonical form: ~ expanded, standardized, symlinks resolved (so links can't escape a glob).
    public static func canonical(_ path: String, home: String) -> String {
        var p = path
        if p == "~" { p = home } else if p.hasPrefix("~/") { p = home + p.dropFirst(1) }
        return URL(fileURLWithPath: p).standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// The sensitive locations with symlinks resolved. Resolving ~70 paths touches the disk, so a
    /// caller checking many paths in one go (a list's icons) computes this once and passes it to
    /// `allows`. Don't keep it across calls: a location swapped for a link later would be missed.
    public static func canonicalSensitiveRoots(home: String = NSHomeDirectory()) -> [String] {
        sensitiveRoots(home: home).map { canonical($0, home: home) }
    }

    /// Whether `path` may be read under the approved `patterns`.
    public static func allows(_ path: String, patterns: [String], context: WidgetCallContext, home: String = NSHomeDirectory(),
                              sensitiveRoots precomputed: [String]? = nil) -> Bool {
        guard path.hasPrefix("/") || path.hasPrefix("~") else { return false }
        let target = canonical(path, home: home)
        if target == "/dev" || target.hasPrefix("/dev/") { return false }
        let sensitive = precomputed ?? canonicalSensitiveRoots(home: home)
        let targetRoot = protectedRoot(target, home: home, listed: sensitive)
        func within(_ p: String, _ root: String) -> Bool { p == root || p.hasPrefix(root + "/") }

        for raw in patterns {
            // Placeholder patterns: the placeholder value is matched literally (it may contain
            // glob characters), the rest of the pattern as a glob below it.
            var bases: [String] = []
            var rest = raw
            if let ph = WidgetPermissions.pathPlaceholders.first(where: { raw == $0 || raw.hasPrefix($0 + "/") }) {
                rest = String(raw.dropFirst(ph.count))
                switch ph {
                case "{cwd}": bases = context.cwd.map { [$0] } ?? []
                case "{folder}": bases = context.folder.map { [$0] } ?? []
                default: bases = context.selection
                }
                for b in bases {
                    let base = canonical(b, home: home)
                    // A placeholder reaches into a protected location only if its value is itself inside it
                    // (you cd'd or navigated there).
                    if let root = targetRoot, !within(base, root) { continue }
                    if rest.isEmpty { if target == base { return true }; continue }
                    guard target.hasPrefix(base == "/" ? "/" : base + "/") else { continue }
                    let remainder = String(target.dropFirst(base == "/" ? 1 : base.count + 1))
                    if globMatch(pattern: String(rest.dropFirst()), path: remainder) { return true }
                }
                continue
            }
            let p = canonical(raw, home: home)
            guard globMatch(pattern: p, path: target) else { continue }
            // Reaching into a sensitive location requires the pattern to name it explicitly.
            if let root = targetRoot, !within(p, root) { continue }
            return true
        }
        return false
    }

    /// Glob over path components: `*` within a component, `?` one character, `**` any depth.
    ///
    /// Patterns come from untrusted manifests, so matching fills a table over (pattern index,
    /// path index) rather than backtracking: a pattern like `/**/**/**/**/x` costs
    /// components × components, not exponential time on the thread doing the permission check.
    public static func globMatch(pattern: String, path: String) -> Bool {
        let p = pattern.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let t = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var memo = [Bool?](repeating: nil, count: (p.count + 1) * (t.count + 1))
        func match(_ i: Int, _ j: Int) -> Bool {
            let slot = i * (t.count + 1) + j
            if let known = memo[slot] { return known }
            let result: Bool
            if i == p.count { result = j == t.count }
            else if p[i] == "**" { result = match(i + 1, j) || (j < t.count && match(i, j + 1)) }
            else { result = j < t.count && componentMatch(p[i], t[j]) && match(i + 1, j + 1) }
            memo[slot] = result
            return result
        }
        return match(0, 0)
    }

    static func componentMatch(_ pattern: String, _ s: String) -> Bool {
        if !pattern.contains("*") && !pattern.contains("?") { return pattern == s }
        let p = Array(pattern), c = Array(s)
        var memo = [[Bool?]](repeating: [Bool?](repeating: nil, count: c.count + 1), count: p.count + 1)
        func go(_ i: Int, _ j: Int) -> Bool {
            if let m = memo[i][j] { return m }
            let r: Bool
            if i == p.count { r = j == c.count }
            else if p[i] == "*" { r = go(i + 1, j) || (j < c.count && go(i, j + 1)) }
            else { r = j < c.count && (p[i] == "?" || p[i] == c[j]) && go(i + 1, j + 1) }
            memo[i][j] = r
            return r
        }
        return go(0, 0)
    }
}

// MARK: - Network

public enum NetRule {
    public static func isValidPattern(_ h: String) -> Bool {
        h.range(of: #"^(\*\.)?([a-z0-9-]+\.)+[a-z]{2,}$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Loopback, private, link-local, CGNAT and unique-local addresses: refused so a widget can't
    /// reach services on your machine or network (including via DNS rebinding).
    public static func isPrivateAddress(_ ip: String) -> Bool {
        func v4(_ b: [UInt8]) -> Bool {
            switch (b[0], b[1]) {
            case (0, _), (10, _), (127, _), (169, 254), (192, 168): return true
            case (172, 16...31), (100, 64...127), (198, 18...19): return true
            case (192, 0) where b[2] == 0 || b[2] == 2: return true
            default: return b[0] >= 224
            }
        }
        var a4 = in_addr()
        if inet_pton(AF_INET, ip, &a4) == 1 { return v4(withUnsafeBytes(of: a4) { Array($0) }) }
        var a6 = in6_addr()
        guard inet_pton(AF_INET6, ip, &a6) == 1 else { return true }      // unparseable: refuse
        let b = withUnsafeBytes(of: a6) { Array($0) }
        if b.allSatisfy({ $0 == 0 }) || (b[0..<15].allSatisfy { $0 == 0 } && b[15] == 1) { return true }   // :: and ::1
        if b[0] == 0xFF { return true }                                                                // multicast
        if b[0] == 0xFE && (b[1] & 0xC0) == 0x80 { return true }                                         // fe80::/10
        if (b[0] & 0xFE) == 0xFC { return true }                                                         // fc00::/7
        if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xFF && b[11] == 0xFF { return v4(Array(b[12..<16])) }  // ::ffff:a.b.c.d
        if b[0..<12].allSatisfy({ $0 == 0 }) { return v4(Array(b[12..<16])) }                            // ::a.b.c.d
        if b[0] == 0x00 && b[1] == 0x64 && b[2] == 0xFF && b[3] == 0x9B { return v4(Array(b[12..<16])) } // 64:ff9b::/96
        if b[0] == 0x20 && b[1] == 0x02 { return v4(Array(b[2..<6])) }                                  // 2002::/16 (6to4)
        if b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x0D && b[3] == 0xB8 { return true }                 // documentation
        return false
    }

    /// Request headers a widget may not set.
    public static let forbiddenHeaders: Set<String> = ["cookie", "cookie2", "host", "connection", "content-length", "transfer-encoding",
                                                        "proxy-authorization", "proxy-connection", "te", "upgrade", "origin", "referer"]

    /// Replaces `{secret:key}` in `text` with the secret's value, only if `host` is one the
    /// secret may be sent to. Secrets never reach the widget's script.
    public static func expandSecrets(_ text: String, secrets: [String: (value: String, hosts: [String])], host: String) -> Result<String, WidgetDenied> {
        guard text.contains("{secret:") else { return .success(text) }
        var out = text
        let re = try! NSRegularExpression(pattern: #"\{secret:([A-Za-z][A-Za-z0-9_]{0,31})\}"#)
        for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            let key = String(text[Range(m.range(at: 1), in: text)!])
            guard let s = secrets[key] else { return .failure(WidgetDenied("Secret \(key) isn't set.")) }
            guard let u = URL(string: "https://\(host)/"), allows(u, hosts: s.hosts) else {
                return .failure(WidgetDenied("Secret \(key) may not be sent to \(host)."))
            }
            out.replaceSubrange(Range(m.range, in: out)!, with: s.value)
        }
        return .success(out)
    }

    /// https only, host must match an approved pattern ("*.example.com" matches subdomains only).
    public static func allows(_ url: URL, hosts: [String]) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(), url.user == nil, url.password == nil else { return false }
        if url.port != nil && url.port != 443 { return false }
        return hosts.contains { pattern in
            let p = pattern.lowercased()
            if p.hasPrefix("*.") { return host.hasSuffix(String(p.dropFirst(1))) && host != String(p.dropFirst(2)) }
            return host == p
        }
    }
}

// MARK: - JSON value + view tree

/// A JSON value (settings defaults, API payloads, view trees).
public enum WidgetJSON: Codable, Equatable, Sendable {
    case null, bool(Bool), number(Double), string(String), array([WidgetJSON]), object([String: WidgetJSON])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([WidgetJSON].self) { self = .array(a) }
        else { self = .object(try c.decode([String: WidgetJSON].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public subscript(_ k: String) -> WidgetJSON? { if case .object(let o) = self { return o[k] } else { return nil } }
    public var string: String? { if case .string(let s) = self { return s } else { return nil } }
    public var number: Double? { if case .number(let n) = self { return n } else { return nil } }
    public var bool: Bool? { if case .bool(let b) = self { return b } else { return nil } }
    public var array: [WidgetJSON]? { if case .array(let a) = self { return a } else { return nil } }
}

/// Validated view tree. Unknown node types become `.unsupported`; limits are enforced while parsing.
public indirect enum WidgetNode: Equatable, Sendable {
    case stack(axis: String, gap: Double, children: [WidgetNode])
    case text(String, style: String, tone: String, lines: Int?)
    case readout(label: String, value: String, detail: String)
    case bar(Double, warnAbove: Double, tone: String?)
    case display(String, detail: String, tone: String)
    case spacer
    case sparkline([Double], max: Double?)
    case kv([(String, String)])
    case list([WidgetListItem])
    case tag(String, tone: String)
    case button(String, action: WidgetActionSpec, prominent: Bool)
    case divider
    case progress(Double?)
    case empty(title: String, message: String)
    case code(String, lines: Int?)
    case unsupported(String)

    /// Written out because `.kv` holds tuples (so it can't be synthesized). Compared on the main
    /// thread for every new tree a widget sends, so it must be cheap: no reflection, no strings.
    public static func == (a: WidgetNode, b: WidgetNode) -> Bool {
        switch (a, b) {
        case let (.stack(a1, g1, c1), .stack(a2, g2, c2)): a1 == a2 && g1 == g2 && c1 == c2
        case let (.text(s1, st1, t1, l1), .text(s2, st2, t2, l2)): s1 == s2 && st1 == st2 && t1 == t2 && l1 == l2
        case let (.readout(l1, v1, d1), .readout(l2, v2, d2)): l1 == l2 && v1 == v2 && d1 == d2
        case let (.bar(v1, w1, t1), .bar(v2, w2, t2)): v1 == v2 && w1 == w2 && t1 == t2
        case let (.display(v1, d1, t1), .display(v2, d2, t2)): v1 == v2 && d1 == d2 && t1 == t2
        case (.spacer, .spacer), (.divider, .divider): true
        case let (.sparkline(v1, m1), .sparkline(v2, m2)): v1 == v2 && m1 == m2
        case let (.kv(r1), .kv(r2)): r1.count == r2.count && zip(r1, r2).allSatisfy { $0 == $1 }
        case let (.list(i1), .list(i2)): i1 == i2
        case let (.tag(s1, t1), .tag(s2, t2)): s1 == s2 && t1 == t2
        case let (.button(s1, a1, p1), .button(s2, a2, p2)): s1 == s2 && a1 == a2 && p1 == p2
        case let (.progress(v1), .progress(v2)): v1 == v2
        case let (.empty(t1, m1), .empty(t2, m2)): t1 == t2 && m1 == m2
        case let (.code(s1, l1), .code(s2, l2)): s1 == s2 && l1 == l2
        case let (.unsupported(s1), .unsupported(s2)): s1 == s2
        default: false
        }
    }
}

public struct WidgetListItem: Equatable, Sendable {
    public var title: String
    public var subtitle: String?
    public var trailing: String?
    public var tone: String
    public var icon: String?
    public var action: WidgetActionSpec?
}

public struct WidgetActionSpec: Equatable, Sendable {
    public var kind: String        // custom | copy | openURL | revealInFiles | insertPath | openFile
    public var value: String?      // id / text / url / path
    public var payload: WidgetJSON?
    /// Native confirmation GRID shows before performing the action.
    public var confirm: String?
    /// insertPath with several paths.
    public var paths: [String]?
}

public enum WidgetTreeParser {
    public static let maxNodes = 400, maxDepth = 12, maxText = 4000
    public static let tones: Set<String> = ["default", "dim", "mute", "accent", "ok", "warn", "danger"]
    public static let styles: Set<String> = ["body", "small", "label", "title", "mono"]
    public static let actionKinds: Set<String> = ["custom", "copy", "openURL", "revealInFiles", "insertPath", "openFile"]

    /// Parses a view tree, enforcing size limits. Returns the tree and any warnings.
    public static func parse(_ json: WidgetJSON) -> (WidgetNode, [String]) {
        var budget = maxNodes
        var warnings: [String] = []
        let node = parse(json, depth: 0, budget: &budget, warnings: &warnings)
        return (node, warnings)
    }

    static func clip(_ s: String?, _ warnings: inout [String]) -> String {
        guard let s else { return "" }
        if s.count > maxText { warnings.append("text truncated to \(maxText) characters"); return String(s.prefix(maxText)) + "…" }
        return s
    }

    static func tone(_ j: WidgetJSON?) -> String { j?.string.flatMap { tones.contains($0) ? $0 : nil } ?? "default" }

    static func action(_ j: WidgetJSON?) -> WidgetActionSpec? {
        guard let j, let kind = j["kind"]?.string, actionKinds.contains(kind) else { return nil }
        let paths = j["paths"]?.array?.prefix(64).compactMap { $0.string.map { String($0.prefix(4096)) } }
        if kind == "insertPath" && j["value"]?.string == nil && (paths ?? []).isEmpty { return nil }
        return WidgetActionSpec(kind: kind, value: j["value"]?.string.map { String($0.prefix(4096)) }, payload: j["payload"],
                                confirm: j["confirm"]?.string.map { String($0.prefix(200)) }, paths: paths)
    }

    static func parse(_ j: WidgetJSON, depth: Int, budget: inout Int, warnings: inout [String]) -> WidgetNode {
        guard budget > 0 else { return .unsupported("node limit") }
        budget -= 1
        if depth > maxDepth { warnings.append("tree deeper than \(maxDepth); truncated"); return .unsupported("too deep") }
        guard let type = j["type"]?.string else { return .unsupported("missing type") }
        switch type {
        case "stack":
            var kids: [WidgetNode] = []
            for c in j["children"]?.array ?? [] {
                if budget <= 0 { warnings.append("tree larger than \(maxNodes) nodes; truncated"); break }
                kids.append(parse(c, depth: depth + 1, budget: &budget, warnings: &warnings))
            }
            return .stack(axis: j["axis"]?.string == "h" ? "h" : "v", gap: min(max(j["gap"]?.number ?? 6, 0), 32), children: kids)
        case "text":
            return .text(clip(j["text"]?.string, &warnings), style: j["style"]?.string.flatMap { styles.contains($0) ? $0 : nil } ?? "body",
                         tone: tone(j["tone"]), lines: j["lines"]?.number.map { Int(min(max($0, 1), 40)) })
        case "readout":
            return .readout(label: String(clip(j["label"]?.string, &warnings).prefix(16)), value: String(clip(j["value"]?.string, &warnings).prefix(40)),
                            detail: String(clip(j["detail"]?.string, &warnings).prefix(80)))
        case "bar":
            let t = j["tone"]?.string.flatMap { tones.contains($0) ? $0 : nil }
            return .bar(min(max(j["value"]?.number ?? 0, 0), 1), warnAbove: j["warnAbove"]?.number ?? 0.85, tone: t)
        case "display":
            return .display(String(clip(j["value"]?.string, &warnings).prefix(24)), detail: String(clip(j["detail"]?.string, &warnings).prefix(80)), tone: tone(j["tone"]))
        case "spacer": return .spacer
        case "sparkline":
            let vals = (j["values"]?.array ?? []).compactMap(\.number).filter(\.isFinite).suffix(240)
            return .sparkline(Array(vals), max: j["max"]?.number)
        case "kv":
            let rows = (j["rows"]?.array ?? []).prefix(60).compactMap { r -> (String, String)? in
                guard let a = r.array, a.count == 2 else { return nil }
                return (String(clip(a[0].string, &warnings).prefix(40)), clip(a[1].string, &warnings))
            }
            budget -= rows.count / 4
            return .kv(Array(rows))
        case "list":
            let items = (j["items"]?.array ?? []).prefix(100).map { it in
                WidgetListItem(title: String(clip(it["title"]?.string, &warnings).prefix(200)), subtitle: it["subtitle"]?.string.map { String($0.prefix(200)) },
                               trailing: it["trailing"]?.string.map { String($0.prefix(40)) }, tone: tone(it["tone"]),
                               icon: it["icon"]?.string.map { String($0.prefix(1024)) }, action: action(it["action"]))
            }
            budget -= items.count / 2
            return .list(Array(items))
        case "tag": return .tag(String(clip(j["text"]?.string, &warnings).prefix(24)), tone: tone(j["tone"]))
        case "button":
            guard let a = action(j["action"]) else { return .unsupported("button without a valid action") }
            return .button(String(clip(j["title"]?.string, &warnings).prefix(40)), action: a, prominent: j["prominent"]?.bool ?? false)
        case "divider": return .divider
        case "progress": return .progress(j["value"]?.number.map { min(max($0, 0), 1) })
        case "empty": return .empty(title: String(clip(j["title"]?.string, &warnings).prefix(80)), message: clip(j["message"]?.string, &warnings))
        case "code": return .code(clip(j["text"]?.string, &warnings), lines: j["lines"]?.number.map { Int(min(max($0, 1), 60)) })
        default:
            warnings.append("unknown component \"\(type)\"")
            return .unsupported(type)
        }
    }
}
