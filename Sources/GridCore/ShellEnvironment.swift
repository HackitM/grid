import Darwin
import Foundation

public enum ShellEnvironment {
    /// The user's login shell from the directory service, then $SHELL, then /bin/zsh.
    public static func resolveShell(override: String? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let o = override?.trimmingCharacters(in: .whitespaces), isUsableShell(o) { return o }
        if let pw = getpwuid(getuid()), let cs = pw.pointee.pw_shell {
            let s = String(cString: cs)
            if isUsableShell(s) { return s }
        }
        if let s = environment["SHELL"], isUsableShell(s) { return s }
        return "/bin/zsh"
    }

    /// An absolute path to an executable file. A folder also counts as "executable" to the
    /// system (the bit means searchable there), and a relative path would depend on wherever
    /// GRID happened to be started from, so both are refused.
    public static func isUsableShell(_ path: String) -> Bool {
        guard path.hasPrefix("/") else { return false }
        var isDir: ObjCBool = false
        let fm = FileManager.default
        return fm.fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue && fm.isExecutableFile(atPath: path)
    }

    /// Variables describing *another* terminal or tool that must not leak into our sessions
    /// (e.g. if GRID itself was started from iTerm, VS Code, or a Claude Code session).
    static let strippedExact: Set<String> = [
        "TERM", "COLORTERM", "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "TERM_SESSION_ID",
        "COLORFGBG", "LC_TERMINAL", "LC_TERMINAL_VERSION", "INSIDE_EMACS", "SHLVL", "PWD",
        "OLDPWD", "_", "__CFBundleIdentifier", "XPC_SERVICE_NAME", "XPC_FLAGS", "CLAUDECODE",
        "LINES", "COLUMNS", "TMUX", "TMUX_PANE", "STY",
        // Markers of a *parent* Claude Code session (user config such as CLAUDE_CODE_USE_BEDROCK is kept).
        "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SSE_PORT",
    ]
    static let strippedPrefixes = [
        "ITERM_", "VSCODE_", "GHOSTTY_", "KITTY_", "WEZTERM_", "ALACRITTY_",
        "WARP_",
    ]

    /// Builds the environment for a new PTY session as `KEY=VALUE` strings.
    public static func build(shell: String, inherited: [String: String], appVersion: String, locale: Locale = .current) -> [String] {
        var env: [String: String] = [:]
        for (k, v) in inherited {
            if strippedExact.contains(k) { continue }
            if strippedPrefixes.contains(where: { k.hasPrefix($0) }) { continue }
            env[k] = v
        }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "Grid"
        env["TERM_PROGRAM_VERSION"] = appVersion
        env["SHELL"] = shell
        if let pw = getpwuid(getuid()) {
            if env["HOME"] == nil, let d = pw.pointee.pw_dir { env["HOME"] = String(cString: d) }
            if env["USER"] == nil, let n = pw.pointee.pw_name { env["USER"] = String(cString: n) }
            if env["LOGNAME"] == nil { env["LOGNAME"] = env["USER"] }
        }
        // Apps launched from Finder get a minimal PATH; the login shell (path_helper,
        // ~/.zprofile) extends it. Only guarantee a sane floor here.
        if env["PATH"]?.isEmpty ?? true { env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin" }
        if env["LANG"] == nil && env["LC_ALL"] == nil && env["LC_CTYPE"] == nil {
            env["LANG"] = utf8LocaleName(locale)
        }
        return env.keys.sorted().map { "\($0)=\(env[$0]!)" }
    }

    static func utf8LocaleName(_ locale: Locale) -> String {
        let lang = locale.language.languageCode?.identifier ?? "en"
        let region = locale.region?.identifier ?? "US"
        let candidate = "\(lang)_\(region).UTF-8"
        // Only use locales the C library actually knows; otherwise tools print warnings.
        if FileManager.default.fileExists(atPath: "/usr/share/locale/\(candidate)") { return candidate }
        return "en_US.UTF-8"
    }
}
