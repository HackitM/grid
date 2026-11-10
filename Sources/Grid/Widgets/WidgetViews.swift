import AppKit
import GridCore
import SwiftUI

struct WidgetContent: View {
    let widget: WidgetInstance
    var body: some View {
        switch widget.kind {
        case .clock: ClockWidget(widget: widget)
        case .system: SystemWidget(widget: widget)
        case .network: NetworkWidget(widget: widget)
        case .storage: StorageWidget(widget: widget)
        case .battery: PowerWidget(widget: widget)
        case .sessions: SessionsWidget(widget: widget)
        case .apps: PinnedAppsWidget(widget: widget)
        case .git: GitWidget(widget: widget)
        case .notes: NotesWidget(widget: widget)
        case .folder: RecentFilesWidget(widget: widget)
        case .inspector: FileInspectorWidget(widget: widget)
        case .music: NowPlayingWidget(widget: widget)
        case .custom: CustomWidgetView(widget: widget)
        }
    }
}

// MARK: - Clock

private struct ClockWidget: View {
    @Environment(\.theme) private var theme
    let widget: WidgetInstance

    var body: some View {
        let use24 = widget.bool("24h", true)
        let seconds = widget.bool("seconds", false)
        let zones = widget.string("zones", "").split(separator: ",").map(String.init).compactMap(TimeZone.init(identifier:))
        TimelineView(.periodic(from: .now, by: seconds ? 1 : 15)) { ctx in
            VStack(alignment: .leading, spacing: 6) {
                Text(Self.time(ctx.date, zone: .current, use24: use24, seconds: seconds))
                    .font(.system(size: 30, weight: .light, design: .monospaced)).monospacedDigit()
                    .foregroundStyle(theme.text)
                Text(Self.date(ctx.date)).font(GridFont.small).foregroundStyle(theme.textDim)
                if !zones.isEmpty && (widget.expanded || zones.count <= 2) {
                    TerminatedRule().padding(.vertical, 2)
                    ForEach(zones, id: \.identifier) { z in
                        HStack {
                            Text(Self.city(z)).font(GridFont.small).foregroundStyle(theme.textDim).lineLimit(1)
                            Spacer()
                            Text(Self.offset(z, at: ctx.date)).font(GridFont.small).foregroundStyle(theme.textMute)
                            Text(Self.time(ctx.date, zone: z, use24: use24, seconds: false))
                                .font(GridFont.bodyStrong).foregroundStyle(theme.text).monospacedDigit()
                        }
                    }
                } else if !zones.isEmpty {
                    WidgetFootnote(text: "\(zones.count) zones · expand to show")
                }
            }
        }
    }

    /// Formatters by "zone|format". Creating a DateFormatter costs far more than using one, and a
    /// clock showing seconds would otherwise create several every second for as long as it's on screen.
    @MainActor private static var formatters: [String: DateFormatter] = [:]

    @MainActor private static func formatter(_ format: String, zone: TimeZone) -> DateFormatter {
        let key = zone.identifier + "|" + format
        if let f = formatters[key] { return f }
        let f = DateFormatter()
        f.timeZone = zone
        f.dateFormat = format
        formatters[key] = f
        return f
    }

    @MainActor static func time(_ d: Date, zone: TimeZone, use24: Bool, seconds: Bool) -> String {
        formatter(use24 ? (seconds ? "HH:mm:ss" : "HH:mm") : (seconds ? "h:mm:ss a" : "h:mm a"), zone: zone).string(from: d)
    }
    @MainActor static func date(_ d: Date) -> String {
        formatter("EEEE · d MMMM yyyy", zone: .current).string(from: d).uppercased()
    }
    static func city(_ z: TimeZone) -> String {
        (z.identifier.split(separator: "/").last.map(String.init) ?? z.identifier).replacingOccurrences(of: "_", with: " ")
    }
    static func offset(_ z: TimeZone, at d: Date) -> String {
        let diff = (z.secondsFromGMT(for: d) - TimeZone.current.secondsFromGMT(for: d)) / 60
        if diff == 0 { return "±0" }
        let h = diff / 60, m = abs(diff % 60)
        return (diff > 0 ? "+" : "−") + "\(abs(h))" + (m > 0 ? ":\(String(format: "%02d", m))" : "") + "h"
    }
}

// MARK: - System

private struct SystemWidget: View {
    @Environment(\.theme) private var theme
    let widget: WidgetInstance
    private var mon: SystemMonitor { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let cpu = mon.cpu {
                Readout(label: "cpu", value: String(format: "%3.0f%%", cpu * 100),
                        detail: "\(ProcessInfo.processInfo.activeProcessorCount) cores")
                SegmentBar(value: cpu)
                if widget.expanded { Sparkline(values: mon.cpuHistory) }
            } else {
                Readout(label: "cpu", value: "—", detail: "measuring…")
            }
            if let used = mon.memoryUsed {
                let frac = Double(used) / Double(max(mon.memoryTotal, 1))
                Readout(label: "mem", value: Formatters.size(Int64(used)),
                        detail: "of " + Formatters.size(Int64(mon.memoryTotal)))
                SegmentBar(value: frac, warnAbove: 0.9)
                if widget.expanded { Sparkline(values: mon.memoryHistory) }
            }
            if let l = mon.load {
                Readout(label: "load", value: String(format: "%.2f", l.0), detail: String(format: "%.2f · %.2f (5 · 15 min)", l.1, l.2))
            }
            WidgetFootnote(text: "measured · every \(Int(SystemMonitor.interval)) s · up \(Self.uptime())")
        }
        .onAppear { mon.subscribe() }
        .onDisappear { mon.unsubscribe() }
    }

    static func uptime() -> String {
        let s = Int(ProcessInfo.processInfo.systemUptime)
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        return d > 0 ? "\(d)d \(h)h" : "\(h)h \(m)m"
    }
}

// MARK: - Network

private struct NetworkWidget: View {
    @Environment(\.theme) private var theme
    let widget: WidgetInstance
    private var mon: SystemMonitor { .shared }

    var body: some View {
        let chosen = widget.string("iface", "auto")
        let iface = chosen == "auto" ? mon.primaryInterface : chosen
        VStack(alignment: .leading, spacing: 8) {
            if let iface, let r = mon.net[iface] {
                Readout(label: "down", value: Self.rate(r.rx))
                Readout(label: "up", value: Self.rate(r.tx))
                if widget.expanded { Sparkline(values: mon.netHistory[iface] ?? [], maxValue: nil) }
                WidgetFootnote(text: "\(iface)\(chosen == "auto" ? " (auto)" : "") · \(r.ipv4 ?? "no IPv4")")
            } else if let iface {
                Readout(label: "net", value: "—", detail: "measuring \(iface)…")
            } else {
                Readout(label: "net", value: "—", detail: "no active interface")
            }
        }
        .onAppear { mon.subscribe() }
        .onDisappear { mon.unsubscribe() }
    }

    static func rate(_ bps: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bps), countStyle: .binary) + "/s"
    }
}

// MARK: - Storage

private struct StorageWidget: View {
    @Environment(\.theme) private var theme
    let widget: WidgetInstance

    var body: some View {
        let url = URL(fileURLWithPath: widget.string("volume", "/"))
        TimelineView(.periodic(from: .now, by: 15)) { _ in
            if let v = Volumes.info(url) {
                let used = Double(v.total - v.available) / Double(max(v.total, 1))
                VStack(alignment: .leading, spacing: 8) {
                    Readout(label: "free", value: Formatters.size(v.available), detail: "of " + Formatters.size(v.total))
                    SegmentBar(value: used, warnAbove: 0.9)
                    WidgetFootnote(text: "\(v.name) · \(Int(used * 100))% used")
                }
            } else {
                Text("✕ Volume unavailable: \(url.path)").font(GridFont.small).foregroundStyle(theme.danger)
            }
        }
    }
}

// MARK: - Power

private struct PowerWidget: View {
    @Environment(\.theme) private var theme
    let widget: WidgetInstance
    private var mon: SystemMonitor { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let p = mon.power {
                if p.hasBattery, let pct = p.percent {
                    Readout(label: "batt", value: "\(pct)%", detail: p.charging ? "charging" : (p.onAC ? "on power" : "on battery"))
                    SegmentBar(value: Double(pct) / 100, warnAbove: 2)
                    if let m = p.minutesRemaining {
                        WidgetFootnote(text: "\(m / 60)h \(String(format: "%02d", m % 60))m \(p.charging ? "to full" : "remaining")")
                    } else {
                        WidgetFootnote(text: p.charging ? "estimating time to full…" : (p.onAC ? "not charging" : "estimating…"))
                    }
                } else {
                    Readout(label: "pwr", value: "AC", detail: "no battery")
                }
            } else {
                Readout(label: "pwr", value: "—", detail: "power info unavailable")
            }
        }
        .onAppear { mon.subscribe() }
        .onDisappear { mon.unsubscribe() }
    }
}

// MARK: - Sessions

private struct SessionsWidget: View {
    @Environment(AppState.self) private var app
    @Environment(\.theme) private var theme
    let widget: WidgetInstance

    var body: some View {
        let showDirs = widget.bool("dirs", true)
        VStack(alignment: .leading, spacing: 2) {
            if app.terminals.tabs.isEmpty {
                Text("No sessions.").font(GridFont.small).foregroundStyle(theme.textMute)
            }
            ForEach(Array(app.terminals.tabs.enumerated()), id: \.element.id) { ti, tab in
                ForEach(tab.panes) { s in
                    Button {
                        app.terminals.select(s.id)
                        app.show(.terminal)
                        app.focusTerminal()
                    } label: {
                        HStack(spacing: 6) {
                            Text(String(format: "%02d", ti + 1) + (tab.panes.count > 1 ? "." + String(s.number) : ""))
                                .font(GridFont.label)
                                .foregroundStyle(s.id == app.terminals.activeID ? theme.accent : theme.textMute)
                            Text(s.isBusy ? "◆" : (s.exited ? "■" : "▸")).font(.system(size: 8))
                                .foregroundStyle(s.isBusy ? theme.accent : theme.textMute)
                            Text(s.foregroundName ?? (s.exited ? "exited" : (s.shellPath as NSString).lastPathComponent))
                                .font(GridFont.small).foregroundStyle(theme.text)
                            if showDirs, let cwd = s.cwd {
                                Text(PathResolver.abbreviate(cwd)).font(GridFont.small).foregroundStyle(theme.textMute)
                                    .lineLimit(1).truncationMode(.head)
                            }
                            Spacer(minLength: 0)
                            if s.unseenCompletion { Tag("done") }
                        }
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            WidgetFootnote(text: "\(app.terminals.sessions.count) session\(app.terminals.sessions.count == 1 ? "" : "s") · \(app.terminals.sessions.filter(\.isBusy).count) running").padding(.top, 4)
        }
    }
}

// MARK: - Pinned apps

private struct PinnedAppsWidget: View {
    @Environment(AppState.self) private var app
    @Environment(\.theme) private var theme
    let widget: WidgetInstance

    var body: some View {
        let pins = app.apps.favorites.compactMap { app.apps.record(forPath: $0) }
        let names = widget.bool("names", widget.expanded)
        if pins.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("No pinned apps yet.").font(GridFont.small).foregroundStyle(theme.textMute)
                Button("Pin apps in Applications") { app.show(.apps) }.buttonStyle(GridButtonStyle(compact: true))
            }
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: names ? 64 : 34), spacing: 6)], spacing: 6) {
                ForEach(pins) { r in
                    Button { app.apps.launch(r) } label: {
                        VStack(spacing: 3) {
                            Image(nsImage: app.apps.icon(for: r.path)).resizable().frame(width: 26, height: 26)
                            if names {
                                Text(r.name).font(.system(size: 9)).foregroundStyle(theme.textDim).lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Open \(r.name)")
                    .accessibilityLabel("Open \(r.name)")
                }
            }
        }
    }
}

// MARK: - Git

@Observable
@MainActor
final class GitWidgetModel {
    enum State: Equatable { case idle, noGit, notRepo(String), error(String), ok(GitStatus, lastCommit: String?) }
    var state: State = .idle
    var path: String?

    /// git is a shim on macOS that pops an "install developer tools" dialog when the tools are
    /// missing; check once so a periodic refresh can never trigger that dialog.
    nonisolated static let gitAvailable: Bool = {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        p.arguments = ["-p"]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 } catch { return false }
    }()

    func refresh(_ path: String?) async {
        self.path = path
        guard let path else { state = .notRepo("no directory"); return }
        guard Self.gitAvailable else { state = .noGit; return }
        let result = await BlockingWork.run { () -> State in
            let (code, out, err) = Self.git(["status", "--porcelain=v2", "--branch", "--ignore-submodules=all"], in: path)
            if code != 0 {
                return err.contains("not a git repository") ? .notRepo(path) : .error(err.split(separator: "\n").first.map(String.init) ?? "git failed")
            }
            let status = GitStatus.parse(porcelainV2: out)
            let (lc, log, _) = Self.git(["log", "-1", "--format=%s · %cr"], in: path)
            return .ok(status, lastCommit: lc == 0 ? log.trimmingCharacters(in: .whitespacesAndNewlines) : nil)
        }
        // A slower refresh for a previous folder must not overwrite the current one.
        guard !Task.isCancelled, self.path == path else { return }
        if result != state { state = result }
    }

    /// Runs git with structured arguments (no shell). Hardened for read-only status queries:
    /// no fsmonitor hook execution, no optional locks, no credential prompts, 3 s timeout.
    nonisolated static func git(_ args: [String], in dir: String) -> (Int32, String, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", dir, "-c", "core.fsmonitor=false", "--no-optional-locks"] + args
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["LC_ALL"] = "C"
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, "", error.localizedDescription) }
        // Read both pipes while git runs. A pipe holds 64 KB: a status longer than that (thousands
        // of changed files) would otherwise block git until the timeout, and the widget would
        // report "git timed out" on exactly the repositories with the most to show.
        let reads = DispatchGroup()
        let collected = PipeOutput()
        for (pipe, isError) in [(out, false), (err, true)] {
            reads.enter()
            DispatchQueue.global(qos: .utility).async {
                collected.set(pipe.fileHandleForReading.readDataToEndOfFile(), isError: isError)
                reads.leave()
            }
        }
        let deadline = Date().addingTimeInterval(3)
        while p.isRunning && Date() < deadline { usleep(20_000) }
        if p.isRunning {
            p.terminate()
            return (-1, "", "git timed out")
        }
        reads.wait()
        return (p.terminationStatus, collected.text(isError: false), collected.text(isError: true))
    }

    /// What a child process wrote to stdout and stderr, filled in from two reader threads.
    private final class PipeOutput: @unchecked Sendable {
        private let lock = NSLock()
        private var out = Data(), err = Data()
        func set(_ d: Data, isError: Bool) { lock.lock(); if isError { err = d } else { out = d }; lock.unlock() }
        func text(isError: Bool) -> String { lock.lock(); defer { lock.unlock() }; return String(decoding: isError ? err : out, as: UTF8.self) }
    }
}

private struct GitWidget: View {
    @Environment(AppState.self) private var app
    @Environment(\.theme) private var theme
    let widget: WidgetInstance
    @State private var model = GitWidgetModel()

    private var target: String? {
        let fixed = widget.string("path", "")
        return fixed.isEmpty ? app.terminals.active?.cwd : fixed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch model.state {
            case .idle:
                Text("Reading repository…").font(GridFont.small).foregroundStyle(theme.textMute)
            case .noGit:
                Text("△ git isn't available (install the Xcode Command Line Tools).").font(GridFont.small).foregroundStyle(theme.warn)
            case .notRepo(let p):
                Text("Not a git repository").font(GridFont.small).foregroundStyle(theme.textDim)
                Text(PathResolver.abbreviate(p)).font(GridFont.small).foregroundStyle(theme.textMute).lineLimit(1).truncationMode(.head)
            case .error(let e):
                Text("✕ \(e)").font(GridFont.small).foregroundStyle(theme.danger).lineLimit(2)
            case .ok(let s, let last):
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 10)).foregroundStyle(theme.accent)
                    Text(s.branch).font(GridFont.bodyStrong).foregroundStyle(theme.text).lineLimit(1)
                    if s.ahead > 0 { Text("↑\(s.ahead)").font(GridFont.small).foregroundStyle(theme.accent) }
                    if s.behind > 0 { Text("↓\(s.behind)").font(GridFont.small).foregroundStyle(theme.warn) }
                    Spacer(minLength: 0)
                    if s.isClean { Text("✓ CLEAN").font(GridFont.label).foregroundStyle(theme.ok) }
                }
                if !s.isClean {
                    HStack(spacing: 10) {
                        count(s.staged, "staged", theme.ok)
                        count(s.modified, "modified", theme.warn)
                        count(s.untracked, "new", theme.textDim)
                        if s.conflicted > 0 { count(s.conflicted, "conflict", theme.danger) }
                    }
                }
                if let last, widget.expanded || s.isClean {
                    Text(last).font(GridFont.small).foregroundStyle(theme.textDim).lineLimit(2)
                }
                if let p = model.path {
                    WidgetFootnote(text: (widget.string("path", "").isEmpty ? "terminal · " : "") + PathResolver.abbreviate(p))
                        .lineLimit(1).truncationMode(.head)
                }
            }
        }
        .task(id: target) {
            // Refresh when the folder changes, then every 5 s while the widget is on screen.
            // Each refresh starts two git processes, so none run while GRID can't be seen.
            var first = true
            while !Task.isCancelled {
                if first || AppVisibility.isOnScreen { await model.refresh(target) }
                first = false
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func count(_ n: Int, _ label: String, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Text("\(n)").font(GridFont.bodyStrong).foregroundStyle(n > 0 ? color : theme.textMute)
            Text(label).font(GridFont.small).foregroundStyle(theme.textMute)
        }
    }
}

// MARK: - Notes

private struct NotesWidget: View {
    @Environment(AppState.self) private var app
    @Environment(\.theme) private var theme
    let widget: WidgetInstance
    @State private var text = ""
    @State private var pendingSave: Task<Void, Never>?

    var body: some View {
        TextEditor(text: $text)
            .font(GridFont.body)
            .foregroundStyle(theme.text)
            .scrollContentBackground(.hidden)
            .frame(height: widget.expanded ? 220 : 96)
            .padding(4)
            .background(theme.bg1)
            .overlay(Rectangle().stroke(theme.line, lineWidth: Metrics.hairline))
            .onAppear { text = widget.string("text", "") }
            .onChange(of: text) { _, _ in scheduleSave() }
            .onDisappear { saveNow() }
            .accessibilityLabel("Notes")
    }

    /// Saves shortly after the last keystroke. Saving on every keystroke re-encoded the whole
    /// deck and redrew every card for each character typed.
    private func scheduleSave() {
        pendingSave?.cancel()
        pendingSave = Task {
            try? await Task.sleep(for: .milliseconds(300))
            if !Task.isCancelled { saveNow() }
        }
    }

    private func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        if text != widget.string("text", "") { app.widgets.set(widget.id, "text", text) }
    }
}

// MARK: - Recent files

private struct RecentFilesWidget: View {
    @Environment(AppState.self) private var app
    @Environment(\.theme) private var theme
    let widget: WidgetInstance
    @State private var items: [FileEntry] = []
    @State private var failure: String?

    private var folder: URL {
        let fixed = widget.string("path", "")
        return fixed.isEmpty ? app.files.currentURL : URL(fileURLWithPath: fixed)
    }

    var body: some View {
        let limit = widget.expanded ? 12 : 5
        VStack(alignment: .leading, spacing: 2) {
            if let failure {
                Text("✕ \(failure)").font(GridFont.small).foregroundStyle(theme.danger).lineLimit(2)
            } else if items.isEmpty {
                Text("Nothing here.").font(GridFont.small).foregroundStyle(theme.textMute)
            }
            ForEach(items.prefix(limit)) { e in
                Button { app.files.activate(e); if e.isNavigableFolder { app.show(.files) } } label: {
                    HStack(spacing: 6) {
                        Text(e.isNavigableFolder ? "▸" : "·").font(GridFont.label).foregroundStyle(e.isNavigableFolder ? theme.accent : theme.textMute)
                        Text(e.name).font(GridFont.small).foregroundStyle(theme.text).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text(e.modified.map(Self.ago) ?? "").font(GridFont.small).foregroundStyle(theme.textMute)
                    }
                    .padding(.vertical, 1)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .gridContextMenu(title: "file") {
                    GridMenuItem.action("Reveal in Finder") { app.files.reveal([e.url]) }
                    GridMenuItem.action("Insert Path in Terminal") { app.insertPathsIntoTerminal([e.url]) }
                }
            }
            WidgetFootnote(text: (widget.string("path", "").isEmpty ? "files panel · " : "") + PathResolver.abbreviate(folder.path))
                .lineLimit(1).truncationMode(.head).padding(.top, 4)
        }
        .task(id: folder) {
            var first = true
            while !Task.isCancelled {
                // Re-reading the folder every 10 s is pointless while GRID can't be seen.
                guard first || AppVisibility.isOnScreen else { try? await Task.sleep(for: .seconds(10)); continue }
                first = false
                let dir = folder
                let result = await BlockingWork.run { () -> Result<[FileEntry], ListingError> in
                    do {
                        let list = try FileListing.list(dir, showHidden: false)
                        return .success(list.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) })
                    } catch let e as ListingError { return .failure(e) }
                    catch { return .failure(.other(dir.path, error.localizedDescription)) }
                }
                guard !Task.isCancelled, dir == folder else { return }   // stale: folder changed meanwhile
                switch result {
                case .success(let l):
                    let newest = Array(l.prefix(12))
                    if newest != items { items = newest }     // unchanged every 10 s: nothing to redraw
                    if failure != nil { failure = nil }
                case .failure(let e):
                    items = []
                    if case .permissionDenied = e { failure = "No permission to read this folder" } else { failure = "Can't read folder" }
                }
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    static func ago(_ d: Date) -> String {
        let s = Int(Date().timeIntervalSince(d))
        if s < 60 { return "now" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h" }
        return "\(s / 86400)d"
    }
}

// MARK: - Settings faces

struct WidgetSettings: View {
    @Environment(AppState.self) private var app
    @Environment(\.theme) private var theme
    let widget: WidgetInstance
    let done: () -> Void

    var body: some View {
        let store = app.widgets
        VStack(alignment: .leading, spacing: 10) {
            switch widget.kind {
            case .clock: ClockSettings(widget: widget)
            case .network:
                PickerRow(label: "Interface", selection: widget.string("iface", "auto"),
                          options: [("auto", "Auto (busiest)")] + SystemMonitor.shared.net.keys.sorted().map { ($0, $0) }) {
                    store.set(widget.id, "iface", $0)
                }
            case .storage:
                PickerRow(label: "Volume", selection: widget.string("volume", "/"),
                          options: Volumes.mounted().map { ($0.path, Volumes.info($0)?.name ?? $0.path) }) {
                    store.set(widget.id, "volume", $0)
                }
            case .sessions:
                toggle("Show folders", widget.bool("dirs", true)) { store.set(widget.id, "dirs", $0 ? "1" : "0") }
            case .apps:
                toggle("Show names", widget.bool("names", false)) { store.set(widget.id, "names", $0 ? "1" : "0") }
                Text("Pin or unpin apps in the Applications panel.").font(GridFont.small).foregroundStyle(theme.textMute)
            case .git:
                PathSetting(widget: widget, label: "Repository", empty: "Follow the active terminal's folder")
            case .folder:
                PathSetting(widget: widget, label: "Folder", empty: "Follow the Files panel's folder")
            case .inspector:
                toggle("Preview when expanded", widget.bool("preview", true)) { store.set(widget.id, "preview", $0 ? "1" : "0") }
                Text("Follows the Files selection. Folder totals are measured only when you ask.").font(GridFont.small).foregroundStyle(theme.textMute)
            case .music:
                PickerRow(label: "Player", selection: widget.string("source", "auto"),
                          options: [("auto", "Whichever is playing"), ("com.apple.Music", "Apple Music"), ("com.spotify.client", "Spotify")]) {
                    store.set(widget.id, "source", $0)
                }
                PickerRow(label: "Artwork", selection: widget.string("art", ArtStyle.dots.rawValue),
                          options: ArtStyle.allCases.map { ($0.rawValue, $0.label) }) {
                    store.set(widget.id, "art", $0)
                }
                toggle("Show in the status bar on every page", widget.bool("status", true)) { store.set(widget.id, "status", $0 ? "1" : "0") }
                Text("Track changes come from the players themselves. Controls and artwork need macOS Automation permission for the player, asked once when you press Connect or a control. Spotify artwork is downloaded from Spotify's image server; nothing else leaves your Mac.")
                    .font(GridFont.small).foregroundStyle(theme.textMute).fixedSize(horizontal: false, vertical: true)
            case .custom:
                CustomWidgetSettings(widget: widget)
            case .system, .battery, .notes:
                Text("No options. Use expand (↗) for more detail.").font(GridFont.small).foregroundStyle(theme.textMute)
            }
            TerminatedRule()
            HStack {
                toggle("Expanded", widget.expanded) { v in store.update(widget.id) { $0.expanded = v } }
                Spacer()
                Button("Remove") { store.remove(widget.id) }.buttonStyle(GridButtonStyle(compact: true))
                Button("Done") { done() }.buttonStyle(GridButtonStyle(prominent: true, compact: true))
            }
        }
    }

    private func toggle(_ label: String, _ value: Bool, _ set: @escaping (Bool) -> Void) -> some View {
        Toggle(isOn: Binding(get: { value }, set: set)) { Text(label).font(GridFont.small).foregroundStyle(theme.text) }
            .toggleStyle(GridToggleStyle())
    }
}

private struct PickerRow: View {
    @Environment(\.theme) private var theme
    let label: String
    let selection: String
    let options: [(String, String)]
    let onChange: (String) -> Void

    var body: some View {
        HStack {
            Text(label).font(GridFont.small).foregroundStyle(theme.textDim).frame(width: 70, alignment: .leading)
            Picker("", selection: Binding(get: { selection }, set: onChange)) {
                ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
            }
            .labelsHidden()
        }
    }
}

/// Optional fixed path with validation; empty = follow (terminal / Files).
private struct PathSetting: View {
    @Environment(AppState.self) private var app
    @Environment(\.theme) private var theme
    let widget: WidgetInstance
    let label: String
    let empty: String
    @State private var draft = ""
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased()).font(GridFont.label).tracking(1.2).foregroundStyle(theme.textMute)
            GridField(placeholder: empty, text: $draft, focus: $focused) { apply() }
            HStack {
                Button("Apply") { apply() }.buttonStyle(GridButtonStyle(compact: true))
                Button("Follow Automatically") { draft = ""; apply() }.buttonStyle(GridButtonStyle(compact: true))
            }
            if let error { Text("✕ \(error)").font(GridFont.small).foregroundStyle(theme.danger) }
        }
        .onAppear { draft = widget.string("path", "") }
    }

    private func apply() {
        let t = draft.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { app.widgets.set(widget.id, "path", nil); error = nil; return }
        guard let url = PathResolver.resolve(t, relativeTo: app.files.currentURL) else { error = "Enter a path"; return }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            error = "Not a folder: \(PathResolver.abbreviate(url.path))"; return
        }
        error = nil
        draft = PathResolver.abbreviate(url.path)
        app.widgets.set(widget.id, "path", url.path)
    }
}

private struct ClockSettings: View {
    @Environment(AppState.self) private var app
    @Environment(\.theme) private var theme
    let widget: WidgetInstance
    @State private var query = ""
    @FocusState private var focused: Bool

    private var zones: [String] { widget.string("zones", "").split(separator: ",").map(String.init) }

    var body: some View {
        let store = app.widgets
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                Toggle(isOn: Binding(get: { widget.bool("24h", true) }, set: { store.set(widget.id, "24h", $0 ? "1" : "0") })) {
                    Text("24-hour").font(GridFont.small).foregroundStyle(theme.text)
                }.toggleStyle(GridToggleStyle())
                Toggle(isOn: Binding(get: { widget.bool("seconds", false) }, set: { store.set(widget.id, "seconds", $0 ? "1" : "0") })) {
                    Text("Seconds").font(GridFont.small).foregroundStyle(theme.text)
                }.toggleStyle(GridToggleStyle())
            }
            Text("EXTRA TIME ZONES").font(GridFont.label).tracking(1.2).foregroundStyle(theme.textMute)
            ForEach(zones, id: \.self) { z in
                HStack {
                    Text(z).font(GridFont.small).foregroundStyle(theme.text)
                    Spacer()
                    Button { setZones(zones.filter { $0 != z }) } label: { Image(systemName: "xmark").font(.system(size: 8)) }
                        .buttonStyle(.plain).foregroundStyle(theme.textDim).accessibilityLabel("Remove \(z)")
                }
            }
            GridField(placeholder: "search a city, e.g. Tokyo", text: $query, focus: $focused) {
                if let first = matches.first { add(first) }
            }
            ForEach(matches, id: \.self) { id in
                Button { add(id) } label: {
                    HStack { Text("+").foregroundStyle(theme.accent); Text(id).foregroundStyle(theme.textDim); Spacer() }
                        .font(GridFont.small).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
    }

    private var matches: [String] {
        let q = query.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "_")
        guard q.count >= 2 else { return [] }
        return TimeZone.knownTimeZoneIdentifiers.filter { $0.localizedCaseInsensitiveContains(q) && !zones.contains($0) }.prefix(5).map { $0 }
    }

    private func add(_ id: String) {
        guard TimeZone(identifier: id) != nil else { return }
        setZones(zones + [id])
        query = ""
    }

    private func setZones(_ z: [String]) {
        app.widgets.set(widget.id, "zones", z.isEmpty ? nil : z.joined(separator: ","))
    }
}
