import AppKit
import Darwin
import Foundation
import GridCore
import Observation

/// Runs one third-party widget card: owns its sandboxed host process, schedules renders (refresh
/// ticks, debounced events, actions), enforces budgets, and brokers every `grid.*` call against
/// the approved manifest. The host is untrusted: everything it sends is validated here.
@Observable
@MainActor
final class WidgetRuntime {
    enum Phase: Equatable {
        case idle, starting, running
        case error(String)          // load/render error (widget's fault, shown in the card)
        case suspended(String)      // budget exceeded; restarts after a backoff
        case stopped(String)        // 3 strikes: waits for the user
    }

    private(set) var phase: Phase = .idle
    private(set) var tree: WidgetNode?
    private(set) var busy = false

    // Configuration
    @ObservationIgnored let instanceID: UUID
    @ObservationIgnored private(set) var ref = ""
    @ObservationIgnored private var package: WidgetPackage?
    @ObservationIgnored private weak var app: AppState?
    @ObservationIgnored private var settings: [String: String] = [:]
    @ObservationIgnored private var expanded = false

    // Process + protocol state
    @ObservationIgnored private var host: WidgetHostProcess?
    @ObservationIgnored private var nextID = 1
    @ObservationIgnored private var renderInFlight: Int?
    @ObservationIgnored private var renderReason = "start"
    @ObservationIgnored private var renderDirty: String?
    @ObservationIgnored private var actionInFlight: Int?
    @ObservationIgnored private var outstandingCalls = 0
    @ObservationIgnored private var jsTime: Double = 0         // seconds of host time for the current render/action
    @ObservationIgnored private var taskStarted: Date?         // wall clock for the current render/action (calls included)
    /// One userInitiated command per click: granted by the click, spent by the first such exec.
    @ObservationIgnored private var clickExecTokens = 0
    @ObservationIgnored private var callBucket = TokenBucket(burst: 120, perMinute: 600, now: Date().timeIntervalSince1970)
    static let maxOutstandingCalls = 32
    @ObservationIgnored private var lastTick = Date()
    /// Messages received since the last watchdog tick. The host can write lines far faster than a
    /// well-behaved widget needs; each one costs main-thread time here, so a flood is a strike.
    @ObservationIgnored private var messagesSinceTick = 0
    static let maxMessagesPerTick = 3000

    // Scheduling
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var watchdog: Timer?
    @ObservationIgnored private var restartTask: Task<Void, Never>?
    @ObservationIgnored private var stopTask: Task<Void, Never>?
    @ObservationIgnored private var lastInvalidate = Date.distantPast
    /// A delayed `grid.invalidate()` render is already queued (at most one at a time).
    @ObservationIgnored private var invalidateScheduled = false
    @ObservationIgnored private var hostRefresh: Int?

    // Budgets
    @ObservationIgnored private var strikes = 0
    @ObservationIgnored private var cpuSamples: [(Date, Double)] = []
    @ObservationIgnored private var execBucket = TokenBucket(burst: 10, perMinute: 30, now: Date().timeIntervalSince1970)
    @ObservationIgnored private var netBucket = TokenBucket(burst: 10, perMinute: 30, now: Date().timeIntervalSince1970)
    @ObservationIgnored private var logBucket = TokenBucket(burst: 40, perMinute: 120, now: Date().timeIntervalSince1970)
    @ObservationIgnored private var usesSystemStats = false

    static let renderBudget = 2.0
    static let memoryLimit: UInt64 = 150 * 1024 * 1024
    static let cpuLimit = 0.25

    init(instanceID: UUID) { self.instanceID = instanceID }

    #if DEBUG
    /// Live runtimes by card, for the QA hooks only.
    static var live: [UUID: WeakRuntime] = [:]
    struct WeakRuntime { weak var value: WidgetRuntime? }
    func registerForQA() { Self.live[instanceID] = WeakRuntime(value: self) }

    /// Every clickable action in the current tree, in document order (QA).
    var actionsForQA: [WidgetActionSpec] {
        var out: [WidgetActionSpec] = []
        func walk(_ n: WidgetNode) {
            switch n {
            case .stack(_, _, let c): c.forEach(walk)
            case .button(_, let a, _): out.append(a)
            case .list(let items): out += items.compactMap(\.action)
            default: break
            }
        }
        if let tree { walk(tree) }
        return out
    }
    #endif

    var library: WidgetLibrary? { app?.widgetLibrary }
    var hostPID: Int32? { host.map(\.pid) }
    private var manifest: WidgetManifest? { package?.manifest }
    private var perms: WidgetPermissions { manifest?.permissions ?? WidgetPermissions() }

    // MARK: - Lifecycle (driven by the card's visibility)

    /// Card became visible (or its package/settings changed): make sure the widget is running.
    func activate(app: AppState, ref: String, settings: [String: String], expanded: Bool) {
        self.app = app
        stopTask?.cancel(); stopTask = nil
        let lib = app.widgetLibrary
        guard lib.status(ref).runnable, let pkg = lib.entry(ref)?.package else {
            shutdown(); phase = .idle; tree = nil
            self.ref = ref
            return
        }
        let changed = ref != self.ref || pkg.digest != package?.digest
        self.ref = ref
        self.package = pkg
        let settingsChanged = settings != self.settings || expanded != self.expanded
        self.settings = settings
        self.expanded = expanded
        if changed || host == nil {
            if case .stopped = phase, !changed { return }   // waits for Restart
            restart(resetStrikes: changed)
        } else if settingsChanged {
            requestRender("settings")
        } else if eventTask == nil && refreshTask == nil && phase == .running {
            // Shown again within the grace period: resume events and bring the view up to date.
            startEventObservation()
            requestRender("refresh")
        }
    }

    /// Card hidden: stop ticking now, keep the process briefly in case it comes right back.
    func deactivate() {
        refreshTask?.cancel(); refreshTask = nil
        eventTask?.cancel(); eventTask = nil
        stopTask?.cancel()
        stopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            self?.shutdown()
            self?.phase = .idle
        }
    }

    /// User pressed Restart (after strikes) or the package reloaded.
    func restart(resetStrikes: Bool = true) {
        if resetStrikes { strikes = 0 }
        shutdown()
        start()
    }

    private func start() {
        guard let pkg = package else { return }
        phase = .starting
        let h = WidgetHostProcess()
        h.onMessage = { [weak self, weak h] msg in
            guard let self, let h, h === self.host else { return }
            if let msg { self.handle(msg) } else { self.hostExited() }
        }
        do { try h.start() } catch {
            phase = .error(error.localizedDescription); return
        }
        host = h
        lastTick = Date()
        cpuSamples = []
        let sources = pkg.sources.map { ["name": $0.name, "code": $0.code] }
        h.send(["t": "load", "sources": sources])
        watchdog?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.1      // lets macOS batch this wake-up with others
        watchdog = timer
        messagesSinceTick = 0
        // Loading counts against the render budget too.
        renderInFlight = 0
        jsTime = 0
        taskStarted = Date()
    }

    func shutdown() {
        refreshTask?.cancel(); refreshTask = nil
        eventTask?.cancel(); eventTask = nil
        restartTask?.cancel(); restartTask = nil
        watchdog?.invalidate(); watchdog = nil
        if let h = host { h.onMessage = nil; h.terminate() }
        host = nil
        renderInFlight = nil; actionInFlight = nil; outstandingCalls = 0; renderDirty = nil
        invalidateScheduled = false
        busy = false
        if usesSystemStats { SystemMonitor.shared.unsubscribe(); usesSystemStats = false }
    }

    private func hostExited() {
        guard host != nil else { return }
        host = nil
        if case .running = phase { strike("The widget's process exited (it may have run out of its 200 MB memory limit).") }
        else if phase == .starting { strike("The widget's process exited while loading.") }
    }

    // MARK: - Budgets

    private func tick() {
        guard let h = host else { return }
        let now = Date()
        let dt = now.timeIntervalSince(lastTick)
        lastTick = now
        messagesSinceTick = 0
        // Time spent waiting on GRID (exec, net, files) doesn't count against the widget.
        if (renderInFlight != nil || actionInFlight != nil) && outstandingCalls == 0 {
            jsTime += dt
            if jsTime > Self.renderBudget {
                strike(renderInFlight == 0 ? "Loading took longer than 2 s." : (actionInFlight != nil ? "An action took longer than 2 s." : "Rendering took longer than 2 s."))
                return
            }
        }
        // Wall-clock limit too, so a widget can't keep a render or click "open" by chaining slow calls.
        if let started = taskStarted, renderInFlight != nil || actionInFlight != nil,
           now.timeIntervalSince(started) > wallLimit {
            strike(actionInFlight != nil ? "An action didn't finish within \(Int(wallLimit)) s." : "Rendering didn't finish within \(Int(wallLimit)) s.")
            return
        }
        guard let u = h.usage() else { return }
        if u.footprint > Self.memoryLimit {
            strike("Used more than 150 MB of memory (\(u.footprint / 1_048_576) MB).")
            return
        }
        cpuSamples.append((now, u.cpuSeconds))
        cpuSamples.removeAll { now.timeIntervalSince($0.0) > 10.5 }
        if let first = cpuSamples.first, now.timeIntervalSince(first.0) >= 10 {
            let share = (u.cpuSeconds - first.1) / now.timeIntervalSince(first.0)
            if share > Self.cpuLimit { strike(String(format: "Used %.0f%% of a CPU core for 10 s.", share * 100)) }
        }
    }

    /// 30 s, or longer when an approved command may legitimately take longer.
    private var wallLimit: Double {
        Double(max(30, ((perms.exec ?? []).map(\.effectiveTimeout).max() ?? 0) + 10))
    }

    private func strike(_ reason: String) {
        strikes += 1
        library?.log(ref, "error", "Suspended: \(reason)")
        shutdown()
        if strikes >= 3 {
            phase = .stopped(reason)
            return
        }
        phase = .suspended(reason)
        let delay = 5.0 * pow(2, Double(strikes - 1))
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.start()
        }
    }

    private func violation(_ what: String) { strike("Protocol violation: \(what).") }

    // MARK: - Messages from the host

    private func handle(_ m: [String: Any]) {
        messagesSinceTick += 1
        guard messagesSinceTick <= Self.maxMessagesPerTick else { violation("more than \(Self.maxMessagesPerTick) messages in half a second"); return }
        guard let t = m["t"] as? String else { violation("message without a type"); return }
        switch t {
        case "ready":
            guard phase == .starting else { violation("unexpected ready"); return }
            renderInFlight = nil
            taskStarted = nil
            phase = .running
            hostRefresh = (m["refresh"] as? NSNumber)?.intValue
            startEventObservation()
            requestRender("start")
        case "loadError":
            renderInFlight = nil
            phase = .error(String(describing: m["error"] ?? "Couldn't load.").prefix(500).description)
            library?.log(ref, "error", "Load failed: \(m["error"] ?? "")")
            shutdown()
        case "view": handleView(m)
        case "renderError":
            guard let id = (m["id"] as? NSNumber)?.intValue, id == renderInFlight else { return }
            finishRender()
            let msg = String(describing: m["error"] ?? "Render failed").prefix(500)
            library?.log(ref, "error", String(msg))
            phase = .error(String(msg))
            scheduleRefresh(nil)
        case "actionDone":
            guard let id = (m["id"] as? NSNumber)?.intValue, id == actionInFlight else { return }
            actionInFlight = nil
            clickExecTokens = 0
            jsTime = 0
            if renderInFlight == nil { taskStarted = nil }
            busy = renderInFlight != nil
            if let e = m["error"] as? String { library?.log(ref, "error", "Action failed: \(e)") }
            requestRender("action")
        case "call": handleCall(m)
        case "log":
            guard logBucket.take(now: Date().timeIntervalSince1970) else { return }
            library?.log(ref, (m["level"] as? String).flatMap { ["log", "warn", "error"].contains($0) ? $0 : nil } ?? "log",
                         String(describing: m["msg"] ?? "").prefix(2000).description)
        case "invalidate": handleInvalidate()
        case "__malformed": violation("malformed message")
        case "__oversize": violation("message larger than 1 MiB")
        default: violation("unknown message \(t.prefix(40))")
        }
    }

    /// A finished render: validate the tree, show it if it changed, and schedule the next refresh.
    private func handleView(_ m: [String: Any]) {
        guard let id = (m["id"] as? NSNumber)?.intValue, id == renderInFlight else { return }   // stale
        finishRender()
        if (m["same"] as? Bool) != true {
            guard let raw = m["tree"] else { violation("unreadable view"); return }
            let (parsed, warnings) = WidgetTreeParser.parse(Self.widgetJSON(raw))
            let node = sanitizeIcons(parsed)
            for w in Set(warnings).prefix(3) { library?.log(ref, "warn", w) }
            if node != tree { tree = node }
        }
        if case .error = phase { phase = .running }
        scheduleRefresh((m["refreshIn"] as? NSNumber)?.doubleValue)
        if let again = renderDirty { renderDirty = nil; requestRender(again) }
    }

    /// A `grid.*` API call: rate-limit it, broker it against the approved manifest, and answer.
    private func handleCall(_ m: [String: Any]) {
        guard let call = (m["call"] as? NSNumber)?.intValue, let api = m["api"] as? String else { violation("bad call"); return }
        let args = m["args"] as? [Any] ?? []
        guard outstandingCalls < Self.maxOutstandingCalls else { violation("more than \(Self.maxOutstandingCalls) calls in flight"); return }
        guard callBucket.take(now: Date().timeIntervalSince1970) else {
            host?.send(["t": "result", "call": call, "ok": false, "error": "Rate limited: too many calls.", "kind": "RateLimited"]); return
        }
        outstandingCalls += 1
        let caller = host
        Task { [weak self] in
            guard let self else { return }
            let result = await self.broker(api, args)
            // The host may have been replaced while GRID worked (strike, restart, reload). The answer
            // then belongs to a process that is gone, and the new process's call count isn't ours to lower.
            guard let h = self.host, h === caller else { return }
            self.outstandingCalls = max(0, self.outstandingCalls - 1)
            switch result {
            case .success(let v): h.send(["t": "result", "call": call, "ok": true, "value": v])
            case .failure(let e): h.send(["t": "result", "call": call, "ok": false, "error": e.message, "kind": e.kind])
            }
        }
    }

    /// `grid.invalidate()`: render now if the last one was over a second ago, else once, a second
    /// from now. However often the widget asks, at most one delayed render is ever queued.
    private func handleInvalidate() {
        let now = Date()
        if now.timeIntervalSince(lastInvalidate) >= 1 {
            lastInvalidate = now
            requestRender("invalidate")
        } else if !invalidateScheduled {
            invalidateScheduled = true
            let caller = host
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.host === caller, self.invalidateScheduled else { return }
                self.invalidateScheduled = false
                self.lastInvalidate = Date()
                self.requestRender("invalidate")
            }
        }
    }

    /// File icons reveal whether a path exists, so they're shown only for paths the widget may read
    /// (or that are selected); otherwise the row just has no icon.
    private func sanitizeIcons(_ n: WidgetNode) -> WidgetNode {
        let ctx = callContext()
        let patterns = (perms.fsRead ?? []) + (perms.filesSelection == true ? ["{selection}", "{folder}/*"] : [])
        // Resolved once per tree (and only if some row has a path icon), not once per row.
        var sensitiveRoots: [String]?
        func fix(_ n: WidgetNode) -> WidgetNode {
            switch n {
            case .stack(let a, let g, let c): return .stack(axis: a, gap: g, children: c.map(fix))
            case .list(let items):
                return .list(items.map { it in
                    var it = it
                    if let i = it.icon, i.hasPrefix("/") || i.hasPrefix("~") {
                        var ok = PathRule.lexicallyPlausible(i, patterns: patterns, context: ctx)
                        if ok {
                            let roots = sensitiveRoots ?? PathRule.canonicalSensitiveRoots()
                            sensitiveRoots = roots
                            ok = PathRule.allows(i, patterns: patterns, context: ctx, sensitiveRoots: roots)
                        }
                        if !ok { it.icon = nil }
                    }
                    return it
                })
            default: return n
            }
        }
        return fix(n)
    }

    private func finishRender() {
        renderInFlight = nil
        jsTime = 0
        if actionInFlight == nil { taskStarted = nil }
        busy = actionInFlight != nil
    }

    // MARK: - Rendering + scheduling

    func requestRender(_ reason: String) {
        guard let h = host, phase == .running || isError else { return }
        // One render at a time; a newer request replaces any queued one (superseded renders are skipped).
        // grid.invalidate() may render mid-action so slow actions can show progress.
        if renderInFlight != nil || (actionInFlight != nil && reason != "invalidate") { renderDirty = reason; return }
        let id = nextID; nextID += 1
        renderInFlight = id
        renderReason = reason
        jsTime = 0
        if taskStarted == nil { taskStarted = Date() }
        busy = true
        h.send(["t": "render", "id": id, "ctx": context(reason)])
    }

    private var isError: Bool { if case .error = phase { true } else { false } }

    private func context(_ reason: String) -> [String: Any] {
        var s: [String: Any] = [:]
        let specs = manifest?.settings ?? []
        let values = (manifest?.defaultSettings ?? [:]).merging(settings) { _, new in new }
        var secrets: [String: Bool] = [:]
        for spec in specs {
            if spec.type == "secret" { secrets[spec.key] = library?.hasSecret(ref, spec.key) ?? false; continue }
            guard let v = values[spec.key] else { continue }
            switch spec.type {
            case "number": s[spec.key] = Double(v) ?? 0
            case "bool": s[spec.key] = v == "true"
            default: s[spec.key] = v
            }
        }
        return ["settings": s, "secrets": secrets, "size": expanded ? "expanded" : "compact",
                "theme": app?.settings.theme.rawValue ?? "legacy", "now": Date().widgetISO8601, "reason": reason]
    }

    /// Next automatic refresh: the render's `refreshIn`, else the manifest's `refresh`.
    /// One-second refresh is only for widgets that don't run commands or use the network.
    private func scheduleRefresh(_ refreshIn: Double?) {
        refreshTask?.cancel()
        let heavy = !(perms.exec ?? []).isEmpty || !(perms.net ?? []).isEmpty
        let floor = heavy ? 5.0 : 1.0
        let base = refreshIn ?? Double(hostRefresh ?? manifest?.refresh ?? 0)
        guard base > 0 else { return }
        let delay = min(max(base, floor), 3600)
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            // Don't burn cycles while GRID is hidden or the screen is locked: try again later.
            guard AppVisibility.isOnScreen else { self.scheduleRefresh(refreshIn); return }
            self.requestRender("refresh")
        }
    }

    /// Re-renders when subscribed app state changes, debounced (arrowing through Files, busy flips).
    private func startEventObservation() {
        eventTask?.cancel()
        let events = Set(manifest?.events ?? [])
        guard !events.isEmpty, let app else { return }
        eventTask = Task { [weak self] in
            var last = Self.eventSnapshot(app, events)
            while !Task.isCancelled {
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    withObservationTracking { _ = Self.eventSnapshot(app, events) } onChange: { c.resume() }
                }
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled, let self else { return }
                let now = Self.eventSnapshot(app, events)
                if let changed = now.first(where: { last[$0.key] != $0.value })?.key {
                    last = now
                    self.requestRender("event:" + changed)
                }
            }
        }
    }

    private static func eventSnapshot(_ app: AppState, _ events: Set<String>) -> [String: String] {
        var s: [String: String] = [:]
        if events.contains("files.selection") { s["files.selection"] = app.files.selectedIDs.sorted().joined(separator: "\n") }
        if events.contains("files.folder") { s["files.folder"] = app.files.currentURL.path }
        if events.contains("terminal.cwd") { s["terminal.cwd"] = app.terminals.active?.cwd ?? "" }
        if events.contains("terminal.sessions") {
            s["terminal.sessions"] = app.terminals.sessions.map { "\($0.number)|\($0.cwd ?? "")|\($0.foregroundName ?? "")" }.joined(separator: "\n")
        }
        if events.contains("theme") { s["theme"] = app.settings.theme.rawValue }
        return s
    }

    // MARK: - Actions (user clicks only)

    func perform(_ a: WidgetActionSpec) {
        guard let app, let m = manifest else { return }
        if let c = a.confirm, !c.isEmpty {
            _ = app.present(Confirmation(code: "WIDGET.CONFIRM", title: "\(m.name) asks:", message: c + "\n\nThis request comes from the \(m.name) widget\(m.author.map { " by \($0)" } ?? "").",
                                         confirmLabel: "Continue", destructive: false, onConfirm: { [weak self] in
                var b = a; b.confirm = nil
                self?.perform(b)
            }))
            return
        }
        let ctx = callContext()
        switch a.kind {
        case "custom":
            guard let h = host, phase == .running || isError, actionInFlight == nil else { NSSound.beep(); return }
            let id = nextID; nextID += 1
            actionInFlight = id
            clickExecTokens = 1
            jsTime = 0
            if taskStarted == nil { taskStarted = Date() }
            busy = true
            var msg: [String: Any] = ["t": "action", "id": id, "action": a.value ?? "", "ctx": context("action")]
            if let payload = Self.jsonObject(a.payload) { msg["payload"] = payload }
            h.send(msg)
        case "copy":
            guard perms.clipboardWrite == true else { return deny("clipboard.write") }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(String((a.value ?? "").prefix(100_000)), forType: .string)
            app.flash(.info, "\(m.name): copied")
        case "openURL":
            guard let s = a.value, let url = URL(string: s), perms.openURL?.allows(url) == true else { return deny("openURL") }
            NSWorkspace.shared.open(url)
        case "revealInFiles":
            guard let p = a.value, PathRule.lexicallyPlausible(p, patterns: perms.fsRead ?? [], context: ctx),
                  PathRule.allows(p, patterns: perms.fsRead ?? [], context: ctx) else { return deny("fs.read") }
            let url = URL(fileURLWithPath: PathRule.canonical(p, home: NSHomeDirectory()))
            app.files.navigate(to: url.deletingLastPathComponent())
            app.files.select(paths: [url.path])
            app.show(.files)
        case "openFile":
            guard let p = a.value, PathRule.lexicallyPlausible(p, patterns: perms.fsRead ?? [], context: ctx),
                  PathRule.allows(p, patterns: perms.fsRead ?? [], context: ctx) else { return deny("fs.read") }
            // Always ask, naming the exact item and what opens it: a row's title can say anything,
            // and "opening" an app or script runs it.
            let url = URL(fileURLWithPath: PathRule.canonical(p, home: NSHomeDirectory()))
            let opener = NSWorkspace.shared.isFilePackage(atPath: url.path) && url.pathExtension == "app" ? "It is an application: opening it runs it."
                : (NSWorkspace.shared.urlForApplication(toOpen: url).map { "Opens with \($0.deletingPathExtension().lastPathComponent)." } ?? "")
            _ = app.present(Confirmation(code: "WIDGET.OPEN", title: "Open “\(url.lastPathComponent)”?",
                                         message: "\(m.name) wants to open\n\(PathResolver.abbreviate(url.path))\n\(opener)",
                                         confirmLabel: "Open", destructive: false, onConfirm: { [weak app] in app?.files.open(url) }))   // still applies GRID's "Run?" check
        case "insertPath":
            guard perms.terminalInsertPath == true else { return deny("terminal.insertPath") }
            let paths = (a.paths ?? [a.value].compactMap { $0 }).filter { $0.hasPrefix("/") }
            guard !paths.isEmpty else { return }
            app.insertPathsIntoTerminal(paths.map { URL(fileURLWithPath: $0) })
        default: break
        }
    }

    private func deny(_ permission: String) {
        library?.log(ref, "warn", "Blocked a click action: needs \(permission).")
        app?.flash(.error, "\(manifest?.name ?? "Widget"): not allowed (\(permission))")
    }

    private func callContext() -> WidgetCallContext {
        WidgetCallContext(cwd: app?.terminals.active?.cwd, folder: app?.files.currentURL.path,
                          selection: app?.files.selectedEntries.map(\.url.path) ?? [],
                          settings: (manifest?.defaultSettings ?? [:]).merging(settings) { _, n in n })
    }

    // MARK: - Broker

    struct CallError: Error { let message: String; var kind = "GridError" }
    typealias CallResult = Result<Any, CallError>

    private func denied(_ what: String) -> CallResult { .failure(CallError(message: "Not permitted: \(what).", kind: "PermissionError")) }

    private func broker(_ api: String, _ args: [Any]) async -> CallResult {
        guard let app, let library else { return .failure(CallError(message: "Widget stopped.")) }
        let p = perms
        let ctx = callContext()
        func str(_ i: Int) -> String? { args.count > i ? args[i] as? String : nil }
        switch api {
        case "files.selection":
            guard p.filesSelection == true else { return denied("files.selection") }
            return .success(app.files.selectedEntries.prefix(500).map(Self.info))
        case "files.folder":
            guard p.filesSelection == true else { return denied("files.selection") }
            return .success(Self.info(FileListing.entry(for: app.files.currentURL)))
        case "terminal.cwd":
            guard p.terminalCwd == true else { return denied("terminal.cwd") }
            return .success(app.terminals.active?.cwd ?? NSNull())
        case "terminal.sessions":
            guard p.terminalSessions == true else { return denied("terminal.sessions") }
            return .success(app.terminals.sessions.map { s -> [String: Any] in
                ["number": s.number, "cwd": s.cwd ?? NSNull(), "running": s.foregroundName ?? NSNull(),
                 "title": s.displayTitle, "active": s.id == app.terminals.activeID, "exited": s.exited]
            })
        case "fs.stat", "fs.list", "fs.readText":
            guard let path = str(0) else { return .failure(CallError(message: "\(api) needs a path.")) }
            let patterns = p.fsRead ?? []
            guard PathRule.lexicallyPlausible(path, patterns: patterns, context: ctx) else { return denied("reading \(path)") }
            let opts = args.count > 1 ? args[1] as? [String: Any] : nil
            let maxBytes = (args.count > 1 ? (args[1] as? NSNumber)?.intValue : nil) ?? 64 * 1024
            // Symlink resolution touches the disk: do it (and the read) off the main thread.
            return await BlockingWork.run { () -> CallResult in
                guard PathRule.allows(path, patterns: patterns, context: ctx) else {
                    return .failure(CallError(message: "Not permitted: reading \(path).", kind: "PermissionError"))
                }
                return Self.fileCall(api, PathRule.canonical(path, home: NSHomeDirectory()), opts: opts, maxBytes: maxBytes)
            }
        case "exec":
            guard let command = str(0), let argv = args.count > 1 ? args[1] as? [String] : [] else { return .failure(CallError(message: "exec(command, args).")) }
            let t: ExecTemplate
            switch ExecMatcher.match(command: command, args: argv, templates: p.exec ?? [], context: ctx) {
            case .success(let m): t = m
            case .failure(let e): return .failure(CallError(message: e.message, kind: "PermissionError"))
            }
            if t.userInitiated == true {
                guard actionInFlight != nil, clickExecTokens > 0 else { return denied("this command runs only once per click (userInitiated)") }
                clickExecTokens -= 1
            }
            // Never signal GRID itself or a widget host, by process ID or (killall, pkill) by name.
            let program = (t.command as NSString).lastPathComponent
            if ["kill", "killall", "pkill"].contains(program) {
                let pids = Set([String(getpid())] + library.hostPIDs.map(String.init))
                let names = Set([ProcessInfo.processInfo.processName, "GridWidgetHost"].map { $0.lowercased() })
                let targetsGRID = argv.contains { pids.contains($0) || (program != "kill" && names.contains($0.lowercased())) }
                if targetsGRID { return denied("signalling GRID's own processes") }
            }
            guard execBucket.take(now: Date().timeIntervalSince1970) else { return .failure(CallError(message: "Rate limited: too many commands (30/min).", kind: "RateLimited")) }
            return await Self.runExec(t, argv)
        case "net.fetch":
            guard let s = str(0), let url = URL(string: s), NetRule.allows(url, hosts: p.net ?? []) else { return denied("connecting to \(str(0) ?? "?")") }
            guard netBucket.take(now: Date().timeIntervalSince1970) else { return .failure(CallError(message: "Rate limited: too many requests (30/min).", kind: "RateLimited")) }
            var secrets: [String: (value: String, hosts: [String])] = [:]
            for spec in manifest?.settings ?? [] where spec.type == "secret" {
                if let v = library.secret(ref, spec.key) { secrets[spec.key] = (v, spec.hosts ?? []) }
            }
            return await Self.fetch(url, options: args.count > 1 ? args[1] as? [String: Any] ?? [:] : [:], secrets: secrets)
        case "system.stats":
            let mon = SystemMonitor.shared
            if !usesSystemStats { mon.subscribe(); usesSystemStats = true }
            var d: [String: Any] = ["memTotal": mon.memoryTotal, "cores": ProcessInfo.processInfo.activeProcessorCount]
            if let c = mon.cpu { d["cpu"] = c }
            if let m = mon.memoryUsed { d["memUsed"] = m }
            if let l = mon.load { d["load"] = [l.0, l.1, l.2] }
            d["cpuHistory"] = mon.cpuHistory
            return .success(d)
        case "storage.get":
            guard let k = str(0) else { return .success(NSNull()) }
            return .success(Self.jsonObject(library.storageDict(ref)[k]) ?? NSNull())
        case "storage.keys":
            return .success(library.storageDict(ref).keys.sorted())
        case "storage.set":
            guard let k = str(0), k.count <= 200 else { return .failure(CallError(message: "storage.set(key, value).")) }
            let v = args.count > 1 ? Self.widgetJSON(args[1]) : .null
            return library.updateStorage(ref, { $0[k] = v }) ? .success(true) : .failure(CallError(message: "Storage is full (256 KiB).", kind: "QuotaExceeded"))
        case "storage.remove":
            guard let k = str(0) else { return .success(false) }
            _ = library.updateStorage(ref) { $0[k] = nil }
            return .success(true)
        case "storage.clear":
            _ = library.updateStorage(ref) { $0 = [:] }
            return .success(true)
        default:
            return .failure(CallError(message: "Unknown API \(api.prefix(40))."))
        }
    }

    // MARK: Broker helpers (off-main where they touch the disk, processes or network)

    nonisolated static func info(_ e: FileEntry) -> [String: Any] {
        var d: [String: Any] = ["path": e.url.path, "name": e.name, "kind": e.kind, "isFolder": e.isNavigableFolder,
                                "isPackage": e.isPackage, "isHidden": e.isHidden, "isSymlink": e.isSymlink]
        if let s = e.size { d["size"] = s }
        if let m = e.modified { d["modified"] = m.widgetISO8601 }
        if let u = e.typeIdentifier { d["uti"] = u }
        return d
    }

    nonisolated static func fileCall(_ api: String, _ path: String, opts: [String: Any]?, maxBytes: Int) -> CallResult {
        let url = URL(fileURLWithPath: path)
        var st = stat()
        guard lstat(path, &st) == 0 else {
            return .failure(CallError(message: errno == EACCES || errno == EPERM ? "macOS denied access to \(path)." : "No such file: \(path).",
                                      kind: errno == EACCES || errno == EPERM ? "AccessDenied" : "NotFound"))
        }
        switch api {
        case "fs.stat":
            var d = info(FileListing.entry(for: url))
            d["mode"] = String(format: "%o", st.st_mode & 0o7777)
            d["created"] = Date(timeIntervalSince1970: TimeInterval(st.st_birthtimespec.tv_sec)).widgetISO8601
            return .success(d)
        case "fs.list":
            do {
                let hidden = opts?["includeHidden"] as? Bool ?? false
                let limit = min(max((opts?["limit"] as? NSNumber)?.intValue ?? 2000, 1), 2000)
                var list = try FileListing.list(url, showHidden: hidden)
                switch opts?["sortBy"] as? String {
                case "modified": list.sort { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
                case "size": list.sort { ($0.size ?? 0) > ($1.size ?? 0) }
                default: list = FileListing.sorted(list, by: .name, ascending: true)
                }
                return .success(list.prefix(limit).map(info))
            } catch {
                if case .permissionDenied = ListingError.from(error, path: path) {
                    return .failure(CallError(message: "macOS denied access to \(path).", kind: "AccessDenied"))
                }
                return .failure(CallError(message: "Couldn't list \(path)."))
            }
        default: // fs.readText
            // Regular files only (never FIFOs/devices), opened without following a swapped-in link.
            let fd = Darwin.open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { return .failure(CallError(message: "Couldn't open \(path).", kind: errno == EACCES || errno == EPERM ? "AccessDenied" : "GridError")) }
            let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            var fst = stat()
            guard fstat(fd, &fst) == 0, (fst.st_mode & S_IFMT) == S_IFREG else { return .failure(CallError(message: "\(path) isn't a regular file.")) }
            let limit = min(max(maxBytes, 1), 256 * 1024)
            let data = (try? h.read(upToCount: limit)) ?? Data()
            if data.contains(0) { return .failure(CallError(message: "\(path) is binary.", kind: "NotText")) }
            return .success(String(decoding: data, as: UTF8.self))
        }
    }

    /// Waits for the command on a GCD thread: it may block for the template's whole timeout.
    nonisolated static func runExec(_ t: ExecTemplate, _ argv: [String]) async -> CallResult {
        await BlockingWork.run { runExecSync(t, argv) }
    }

    /// Runs an approved command under sandbox-exec with a scrubbed environment (blocking).
    nonisolated static func runExecSync(_ t: ExecTemplate, _ argv: [String]) -> CallResult {
        do {
            guard let exe = t.commands.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
                return .failure(CallError(message: "\(t.command) isn't installed.", kind: "NotFound"))
            }
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("grid-widget-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: tmp) }
            // realpath, not resolvingSymlinksInPath (which strips /private): the sandbox matches real paths.
            let tmpPath = tmp.path.withCString { p -> String in
                guard let r = realpath(p, nil) else { return tmp.path }
                defer { free(r) }
                return String(cString: r)
            }
            var args = argv
            if (exe as NSString).lastPathComponent == "git" {
                // Repos can't make git run code for a widget: no fsmonitor, no hooks, no pager.
                args = ["-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "--no-pager"] + args
            }
            let p = Process()
            // macOS won't start setuid programs inside a sandbox. The read-only process listers
            // (ps, top) run directly (still no shell, clean env); any other setuid program is refused.
            var st = stat()
            let setuid = stat(exe, &st) == 0 && (st.st_mode & (S_ISUID | S_ISGID)) != 0
            if setuid {
                guard ExecTemplate.setuidReadOnly.contains((exe as NSString).lastPathComponent), t.net != true, t.writes != true else {
                    return .failure(CallError(message: "\(exe) runs with elevated privileges and can't be used by widgets.", kind: "PermissionError"))
                }
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = args
            } else {
                p.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
                p.arguments = ["-p", ExecMatcher.sandboxProfile(for: t, exe: exe, tmp: tmpPath), exe] + args
            }
            p.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin", "HOME": NSHomeDirectory(),
                             "LANG": "en_US.UTF-8", "TMPDIR": tmpPath + "/", "NO_COLOR": "1", "TERM": "dumb", "PAGER": "cat",
                             "GIT_TERMINAL_PROMPT": "0", "GIT_OPTIONAL_LOCKS": "0", "GIT_PAGER": "cat",
                             "HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_ANALYTICS": "1", "HOMEBREW_NO_ENV_HINTS": "1"]
            p.currentDirectoryURL = tmp
            let out = Pipe(), err = Pipe()
            p.standardOutput = out; p.standardError = err; p.standardInput = FileHandle.nullDevice
            let cap = 256 * 1024
            let group = DispatchGroup()
            var o = Data(), e = Data()
            func drain(_ pipe: Pipe, into: @escaping (Data) -> Void) {
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    var acc = Data()
                    while true {
                        let d = pipe.fileHandleForReading.availableData
                        if d.isEmpty { break }
                        if acc.count < cap { acc.append(d.prefix(cap - acc.count)) }
                    }
                    into(acc); group.leave()
                }
            }
            let lock = NSLock()
            drain(out) { d in lock.lock(); o = d; lock.unlock() }
            drain(err) { d in lock.lock(); e = d; lock.unlock() }
            do { try p.run() } catch { return .failure(CallError(message: "Couldn't run \(exe).")) }
            let deadline = Date().addingTimeInterval(TimeInterval(t.effectiveTimeout))
            var timedOut = false
            while p.isRunning {
                if Date() > deadline { timedOut = true; p.terminate(); usleep(300_000); if p.isRunning { kill(p.processIdentifier, SIGKILL) }; break }
                usleep(20_000)
            }
            p.waitUntilExit()
            group.wait()
            lock.lock(); defer { lock.unlock() }
            return .success(["code": Int(p.terminationStatus), "stdout": String(decoding: o, as: UTF8.self),
                             "stderr": String(decoding: e, as: UTF8.self), "timedOut": timedOut, "truncated": o.count >= cap])
        }
    }

    /// Refuses redirects (a listed host could bounce us anywhere); the widget sees the 3xx.
    final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? { nil }
    }

    nonisolated static func fetch(_ url: URL, options: [String: Any], secrets: [String: (value: String, hosts: [String])]) async -> CallResult {
        guard let host = url.host?.lowercased() else { return .failure(CallError(message: "Bad URL.")) }
        // Refuse hosts that resolve to this Mac or the local network (DNS rebinding included).
        let addrs = await BlockingWork.run { resolve(host) }
        if addrs.isEmpty { return .failure(CallError(message: "Couldn't resolve \(host).", kind: "NetworkError")) }
        if addrs.contains(where: NetRule.isPrivateAddress) { return .failure(CallError(message: "\(host) resolves to a private address.", kind: "PermissionError")) }

        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 10)
        let method = (options["method"] as? String)?.uppercased() ?? "GET"
        guard ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD"].contains(method) else { return .failure(CallError(message: "Method \(method) isn't allowed.")) }
        req.httpMethod = method
        req.httpShouldHandleCookies = false
        req.setValue("GRID-widget", forHTTPHeaderField: "User-Agent")
        for (k, v) in (options["headers"] as? [String: Any] ?? [:]).prefix(32) {
            let name = k.lowercased()
            guard !NetRule.forbiddenHeaders.contains(name), !name.hasPrefix("proxy-"), !name.hasPrefix("sec-"),
                  name.range(of: #"^[a-z0-9-]{1,64}$"#, options: .regularExpression) != nil, let value = v as? String else { continue }
            switch NetRule.expandSecrets(String(value.prefix(8192)), secrets: secrets, host: host) {
            case .success(let s): req.setValue(s.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: ""), forHTTPHeaderField: k)
            case .failure(let e): return .failure(CallError(message: e.message, kind: "PermissionError"))
            }
        }
        if let body = options["body"] as? String, method != "GET", method != "HEAD" {
            guard body.utf8.count <= 256 * 1024 else { return .failure(CallError(message: "Request body larger than 256 KiB.")) }
            switch NetRule.expandSecrets(body, secrets: secrets, host: host) {
            case .success(let s): req.httpBody = Data(s.utf8)
            case .failure(let e): return .failure(CallError(message: e.message, kind: "PermissionError"))
            }
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieStorage = nil; cfg.urlCache = nil; cfg.httpShouldSetCookies = false
        cfg.timeoutIntervalForRequest = 10; cfg.timeoutIntervalForResource = 10
        cfg.connectionProxyDictionary = [:]
        let session = URLSession(configuration: cfg, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (bytes, response) = try await session.bytes(for: req)
            var data = Data()
            for try await b in bytes {
                data.append(b)
                if data.count > 1 << 20 { return .failure(CallError(message: "Response larger than 1 MiB.", kind: "NetworkError")) }
            }
            let http = response as? HTTPURLResponse
            var headers: [String: String] = [:]
            for (k, v) in http?.allHeaderFields ?? [:] {
                if let k = k as? String, k.lowercased() != "set-cookie" { headers[k.lowercased()] = "\(v)" }
            }
            return .success(["status": http?.statusCode ?? 0, "headers": headers, "text": String(decoding: data, as: UTF8.self)])
        } catch {
            return .failure(CallError(message: "Request failed: \(error.localizedDescription)", kind: "NetworkError"))
        }
    }

    nonisolated static func resolve(_ host: String) -> [String] {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, "443", &hints, &res) == 0, let first = res else { return [] }
        defer { freeaddrinfo(first) }
        var out: [String] = []
        var p: UnsafeMutablePointer<addrinfo>? = first
        while let a = p {
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(a.pointee.ai_addr, a.pointee.ai_addrlen, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 {
                out.append(String(cString: buf).split(separator: "%").first.map(String.init) ?? "")
            }
            p = a.pointee.ai_next
        }
        return out
    }

    // MARK: JSON values (JSONSerialization objects ⇄ WidgetJSON)

    /// Converts what `JSONSerialization` produced into a `WidgetJSON`, directly. (Going through
    /// `Data` and `JSONDecoder` again cost several times as much, on the main thread, per render.)
    nonisolated static func widgetJSON(_ any: Any) -> WidgetJSON {
        switch any {
        case let s as String: return .string(s)
        case let n as NSNumber:
            // JSON true/false arrive as CFBoolean; every other NSNumber is a number.
            return CFGetTypeID(n) == CFBooleanGetTypeID() ? .bool(n.boolValue) : .number(n.doubleValue)
        case let a as [Any]: return .array(a.map(widgetJSON))
        case let o as [String: Any]: return .object(o.mapValues(widgetJSON))
        default: return .null
        }
    }

    /// The reverse: a value `JSONSerialization` can write. nil only for nil.
    nonisolated static func jsonObject(_ j: WidgetJSON?) -> Any? {
        switch j {
        case nil: return nil
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n): return n.isFinite ? n : NSNull()
        case .string(let s): return s
        case .array(let a): return a.map { jsonObject($0) ?? NSNull() }
        case .object(let o): return o.mapValues { jsonObject($0) ?? NSNull() }
        }
    }
}
