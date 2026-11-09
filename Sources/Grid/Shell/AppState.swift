import AppKit
import GridCore
import Observation
import SwiftUI

enum PanelID: String, CaseIterable, Identifiable {
    case terminal, files, apps, web, settings
    var id: String { rawValue }
    var index: String {
        switch self { case .terminal: "01"; case .files: "02"; case .apps: "03"; case .web: "04"; case .settings: "05" }
    }
    var label: String {
        switch self { case .terminal: "TERM"; case .files: "FILES"; case .apps: "APPS"; case .web: "WEB"; case .settings: "SYS" }
    }
    var title: String {
        switch self { case .terminal: "Terminal"; case .files: "Files"; case .apps: "Applications"; case .web: "Web"; case .settings: "Settings" }
    }
    var symbol: String {
        switch self {
        case .terminal: "terminal"; case .files: "folder"; case .apps: "square.grid.2x2"
        case .web: "globe"; case .settings: "slider.horizontal.3"
        }
    }
    var shortcutKey: Character {
        switch self { case .terminal: "1"; case .files: "2"; case .apps: "3"; case .web: "4"; case .settings: "," }
    }
}

/// An in-app, themed confirmation (replaces NSAlert so prompts match the design system).
struct Confirmation: Identifiable {
    let id = UUID()
    let code: String
    let title: String
    let message: String
    let confirmLabel: String
    let destructive: Bool
    let onConfirm: () -> Void
    var onCancel: () -> Void = {}
    /// Optional third choice (e.g. "Keep Both").
    var alternateLabel: String? = nil
    var onAlternate: () -> Void = {}
    var cancelLabel: String = "Cancel"
}

struct Notice: Identifiable, Equatable {
    enum Tone { case info, error }
    let id = UUID()
    let tone: Tone
    let text: String
    var actionLabel: String? = nil
    var action: (() -> Void)? = nil
    static func == (a: Notice, b: Notice) -> Bool { a.id == b.id }
}

@Observable
@MainActor
final class AppState {
    var panel: PanelID = .terminal
    /// Dockable Terminal-workspace panels (Files / Terminal / Deck), persisted.
    let workspace = WorkspaceLayout()
    /// Files panel in the Terminal workspace (kept as a Bool for existing call sites).
    var filesSidebar: Bool {
        get { workspace.contains(.files) }
        set { if newValue { workspace.show(.files) } else { workspace.hide(.files) } }
    }
    var inspectorVisible = UserDefaults.standard.object(forKey: "layout.inspector") as? Bool ?? true {
        didSet { UserDefaults.standard.set(inspectorVisible, forKey: "layout.inspector") }
    }
    var deckVisible: Bool {
        get { workspace.contains(.deck) }
        set { if newValue { workspace.show(.deck) } else { workspace.hide(.deck) } }
    }
    var terminalPanelVisible: Bool {
        get { workspace.contains(.terminal) }
        set { if newValue { workspace.show(.terminal) } else { workspace.hide(.terminal) } }
    }

    /// Closing the terminal panel only hides it: sessions keep running.
    func closePanel(_ p: WorkspacePanel) {
        workspace.hide(p)
        if p == .terminal, !terminals.sessions.isEmpty {
            flash(.info, "Terminal panel closed; \(terminals.sessions.count) session\(terminals.sessions.count == 1 ? "" : "s") still running" + shortcuts.hint(.toggleTerminalPanel))
        }
    }
    let layout = LayoutState()
    let shortcuts = ShortcutStore()
    let widgets = WidgetStore()
    let widgetLibrary = WidgetLibrary()
    var paletteOpen = false
    var confirmation: Confirmation?
    /// Pending "Allow this widget?" review (Settings › Widgets, gallery, or a card).
    var widgetApproval: WidgetApprovalRequest?
    var notice: Notice?

    let settings: Settings
    let terminals: TerminalManager
    let files: FileBrowserModel
    let apps: AppCatalog
    let fileOps: FileOperations

    @ObservationIgnored private var noticeTask: Task<Void, Never>?

    init() {
        let s = Settings()
        settings = s
        terminals = TerminalManager(settings: s)
        files = FileBrowserModel(settings: s)
        apps = AppCatalog()
        fileOps = FileOperations(files: files)
        terminals.isTerminalVisible = { [weak self] in
            guard let self else { return false }
            return self.panel == .terminal && self.workspace.contains(.terminal) && NSApp.isActive
        }
        fileOps.app = self
        widgets.onRemove = { [weak self] keep in self?.widgetLibrary.pruneRuntimes(keeping: keep) }
        configureDocking()
        // Restore the last Files folder if it still exists; remember it as the user navigates.
        if let last = UserDefaults.standard.string(forKey: "files.lastFolder"),
           FileManager.default.fileExists(atPath: last), last != files.currentURL.path {
            files.navigate(to: URL(fileURLWithPath: last), recordHistory: false)
        }
        files.onNavigate = { url in UserDefaults.standard.set(url.path, forKey: "files.lastFolder") }
        files.confirmRun = { [weak self] url, reason, proceed in
            self?.present(Confirmation(
                code: "EXEC.CONFIRM",
                title: "Run “\(url.lastPathComponent)”?",
                message: "\(reason) Opening it will execute it with your permissions. Use “Insert Path in Terminal” instead if you only want its path.",
                confirmLabel: "Run", destructive: true, onConfirm: proceed))
        }
        terminals.newSession()
        // A job that finished while GRID was in the background is "seen" once the user returns
        // and that session is the one on screen.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.panel == .terminal else { return }
                self.terminals.active?.unseenCompletion = false
            }
        }
    }

    // MARK: Docking (GRID drag tracking)

    private func configureDocking() {
        let drag = DockDrag.shared
        drag.isAllowed = { [weak self] payload, target in
            guard let self else { return false }
            let tm = self.terminals
            switch (payload, target) {
            case (.panel(let p), .panel(let t)): return p != t
            case (.pane(let id), .pane(let other)):
                return id != other && tm.tab(containing: id)?.id == tm.tab(containing: other)?.id
            case (.pane(let id), .tab(let tabID)):
                return tm.tab(containing: id)?.id != tabID
                    && (tm.tabs.first { $0.id == tabID }?.panes.count ?? 0) < TerminalManager.maxPanesPerTab
            case (.pane(let id), .tabBar): return (tm.tab(containing: id)?.panes.count ?? 0) > 1
            case (.tab(let id), .tab(let other)): return id != other
            case (.tab, .tabBar): return true
            case (.widget(let id), .widget(let other)): return id != other
            case (.widget, .widgetEnd): return true
            default: return false
            }
        }
        drag.perform = { [weak self] payload, target, edge in
            guard let self else { return }
            let tm = self.terminals
            let anim: Animation? = self.settings.effects.motion ? GridMotion.snap : nil
            withAnimation(anim) {
                switch (payload, target) {
                case (.panel(let p), .panel(let t)):
                    if let edge { self.workspace.move(p, to: t, edge: edge) }
                case (.pane(let id), .pane(let other)):
                    if let edge, let tab = tm.tab(containing: other) { tab.movePane(id, to: other, edge: edge) }
                case (.pane(let id), .tab(let tabID)): tm.movePane(id, toTab: tabID)
                case (.pane(let id), .tabBar): tm.detachPane(id)
                case (.tab(let id), .tab(let other)): tm.moveTab(id, before: other)
                case (.tab(let id), .tabBar): tm.moveTab(id, before: nil)
                case (.widget(let id), .widget(let other)): self.widgets.place(id, at: other, edge: edge)
                case (.widget(let id), .widgetEnd): self.widgets.place(id, at: nil, edge: nil)
                default: break
                }
            }
            if case .pane = payload { self.focusTerminal() }
        }
    }

    // MARK: Cross-feature actions

    func show(_ p: PanelID) {
        panel = p
        paletteOpen = false
        if p == .terminal { terminals.active?.unseenCompletion = false }
        if p == .apps { apps.refreshIfStale() }
    }

    func newTerminal(at directory: String? = nil) {
        terminals.newSession(at: directory)
        workspace.show(.terminal)
        show(.terminal)
    }

    /// Shows a confirmation. Only one can be on screen: a normal request made while another is
    /// showing is refused (returns false). `replacing: true` (used by Quit) cancels the visible one
    /// first, so its `onCancel` always runs and no pending reply (e.g. to AppKit) is lost.
    @discardableResult
    func present(_ c: Confirmation, replacing: Bool = false) -> Bool {
        if let existing = confirmation {
            guard replacing else { NSSound.beep(); return false }
            confirmation = nil
            existing.onCancel()
        }
        confirmation = c
        return true
    }

    func split(_ axis: SplitAxis) {
        if panel != .terminal { show(.terminal) }
        workspace.show(.terminal)
        if terminals.split(axis) == nil {
            flash(.error, "A tab holds at most \(TerminalManager.maxPanesPerTab) panes.")
        }
    }

    /// Closes a whole tab (all its panes), confirming if any pane is running a program.
    func requestCloseTab(_ id: UUID) {
        guard confirmation == nil else { NSSound.beep(); return }
        let busy = terminals.busyPanes(in: id)
        guard !busy.isEmpty else { terminals.closeTab(id); return }
        let names = busy.map { "“\($0.foregroundName ?? "job")”" }.joined(separator: ", ")
        present(Confirmation(
            code: "PROCESS.ACTIVE", title: "Close this tab?",
            message: "\(names) \(busy.count == 1 ? "is" : "are") still running in this tab. Closing sends a hangup signal (SIGHUP), which normally ends \(busy.count == 1 ? "it" : "them").",
            confirmLabel: "Close Tab", destructive: true,
            onConfirm: { [weak self] in self?.terminals.closeTab(id) }))
    }

    func requestCloseTerminal(_ id: UUID) {
        // Don't act behind an open confirmation (e.g. a pending Quit prompt).
        guard confirmation == nil else { NSSound.beep(); return }
        if terminals.needsConfirmation(id), let s = terminals.sessions.first(where: { $0.id == id }) {
            present(Confirmation(
                code: "PROCESS.ACTIVE",
                title: "Close session \(s.number)?",
                message: "“\(s.foregroundName ?? "A job")” is still running in this session. Closing sends it a hangup signal (SIGHUP), which normally ends it.",
                confirmLabel: "Close Session", destructive: true,
                onConfirm: { [weak self] in self?.terminals.close(id) }))
        } else {
            terminals.close(id)
        }
    }

    /// "Show terminal directory in Files": reads the shell's real cwd at this moment.
    func revealTerminalDirectoryInFiles() {
        guard let s = terminals.active else { return }
        s.refresh()
        guard let cwd = s.cwd else { flash(.error, "Could not read the session's current directory."); return }
        files.navigate(to: URL(fileURLWithPath: cwd))
        if panel == .terminal { filesSidebar = true } else { show(.files) }
    }

    func openTerminalHere(_ url: URL? = nil) {
        let target = url ?? files.selectedEntry.flatMap { $0.isNavigableFolder ? $0.url : nil } ?? files.currentURL
        newTerminal(at: target.path)
    }

    func insertPathsIntoTerminal(_ urls: [URL]) {
        guard let s = terminals.active, !s.exited else { flash(.error, "No running terminal session."); return }
        show(.terminal)
        s.view.insertPaths(urls.map(\.path))
        focusTerminal()
    }

    func focusTerminal() {
        guard workspace.contains(.terminal) || panel != .terminal else { return }
        guard let v = terminals.active?.view else { return }
        DispatchQueue.main.async { v.window?.makeFirstResponder(v) }
    }

    func openURL(_ raw: String) {
        guard let url = WebAddress.normalize(raw) else {
            flash(.error, "Not a web address: \(raw)")
            return
        }
        NSWorkspace.shared.open(url)
        flash(.info, "Opened \(url.host ?? url.absoluteString) in the default browser")
    }

    func flash(_ tone: Notice.Tone, _ text: String, actionLabel: String? = nil, action: (() -> Void)? = nil) {
        notice = Notice(tone: tone, text: text, actionLabel: actionLabel, action: action)
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(tone == .error || actionLabel != nil ? 6 : 3))
            if !Task.isCancelled { self?.notice = nil }
        }
    }

    func setTheme(_ t: ThemeID) {
        settings.theme = t
        terminals.applyAppearance()
    }
}
