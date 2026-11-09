import AppKit
import GridCore
import Observation
import SwiftUI

/// A terminal tab: panes (sessions) arranged by a split tree, so panes can be split right or
/// down anywhere and divided unevenly.
@Observable
@MainActor
final class TerminalTab: Identifiable {
    let id = UUID()
    private(set) var layout: SplitTree
    private(set) var sessionsByID: [UUID: TerminalSession]
    var focusedPaneID: UUID
    /// User-chosen name (double-click the tab); nil = automatic (focused pane's title).
    var customTitle: String?

    init(first: TerminalSession) {
        layout = .leaf(first.id)
        sessionsByID = [first.id: first]
        focusedPaneID = first.id
    }

    /// Panes in reading order.
    var panes: [TerminalSession] { layout.leaves.compactMap { sessionsByID[$0] } }

    func session(_ id: UUID) -> TerminalSession? { sessionsByID[id] }

    func insert(_ s: TerminalSession, splitting target: UUID, axis: SplitAxis) {
        sessionsByID[s.id] = s
        layout = layout.splitting(target, axis: axis, with: s.id)
        focusedPaneID = s.id
    }

    /// Removes a pane from the layout. Returns false if it was the last one.
    func remove(_ id: UUID) -> Bool {
        let order = layout.leaves
        sessionsByID[id] = nil
        guard let next = layout.removing(id) else { return false }
        layout = next
        if focusedPaneID == id, let i = order.firstIndex(of: id) {
            let remaining = next.leaves
            focusedPaneID = remaining[min(max(i - 1, 0), remaining.count - 1)]
        }
        return true
    }

    func resize(split: UUID, divider: Int, by delta: Double, minFraction: Double) {
        layout = layout.resizing(splitID: split, divider: divider, by: delta, minFraction: minFraction)
    }

    func equalize(split: UUID) { layout = layout.equalizing(splitID: split) }

    var focused: TerminalSession? { panes.first { $0.id == focusedPaneID } ?? panes.first }
    var title: String { customTitle ?? focused?.displayTitle ?? "shell" }
    var isBusy: Bool { panes.contains { $0.isBusy } }
    var hasUnseenCompletion: Bool { panes.contains { $0.unseenCompletion } }
    var hasBell: Bool { panes.contains { $0.bellPending } }
}

@Observable
@MainActor
final class TerminalManager {
    static let maxPanesPerTab = 6

    private(set) var tabs: [TerminalTab] = []
    var activeTabID: UUID?
    /// Called when a background tab's job finishes or a session needs user attention.
    @ObservationIgnored var onSessionsChanged: (() -> Void)?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var counter = 0
    @ObservationIgnored private let settings: Settings
    @ObservationIgnored var isTerminalVisible: () -> Bool = { true }

    init(settings: Settings) {
        self.settings = settings
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// Every session across all tabs, in tab order.
    var sessions: [TerminalSession] { tabs.flatMap(\.panes) }
    var activeTab: TerminalTab? { tabs.first { $0.id == activeTabID } }
    /// The focused pane of the active tab.
    var active: TerminalSession? { activeTab?.focused }
    var activeID: UUID? { active?.id }

    func tab(containing id: UUID) -> TerminalTab? { tabs.first { $0.session(id) != nil } }

    private func makeSession(at directory: String?) -> TerminalSession {
        counter += 1
        let shell = ShellEnvironment.resolveShell(override: settings.shellOverride)
        let s = TerminalSession(number: counter, shell: shell, directory: directory,
                                scrollback: settings.scrollback, font: settings.terminalFont)
        s.view.apply(theme: settings.themeValue, font: settings.terminalFont, optionAsMeta: settings.optionAsMeta)
        s.onExit = { [weak self] session in self?.sessionExited(session) }
        // Clicking into a pane makes it the tab's focused pane.
        s.view.onFocusChange = { [weak self, weak s] f in
            guard let self, let s else { return }
            s.hasFocus = f
            if f { self.paneDidFocus(s) }
        }
        return s
    }

    /// New tab with one pane.
    @discardableResult
    func newSession(at directory: String? = nil) -> TerminalSession {
        let s = makeSession(at: directory)
        let t = TerminalTab(first: s)
        tabs.append(t)
        activeTabID = t.id
        s.start(directory: directory)
        return s
    }

    /// Splits the focused pane of the active tab right (.horizontal) or down (.vertical); the
    /// new pane opens in the focused pane's current directory.
    @discardableResult
    func split(_ axis: SplitAxis) -> TerminalSession? {
        guard let t = activeTab, let focused = t.focused else { return newSession() }
        guard t.panes.count < Self.maxPanesPerTab else { return nil }
        focused.refresh()
        let cwd = focused.cwd
        let s = makeSession(at: cwd)
        t.insert(s, splitting: focused.id, axis: axis)
        s.start(directory: cwd)
        return s
    }

    /// Selects the tab containing a session and focuses that pane.
    func select(_ id: UUID) {
        guard let t = tab(containing: id) else { return }
        activeTabID = t.id
        t.focusedPaneID = id
        clearAttention(t)
    }

    func selectTab(_ id: UUID) {
        guard let t = tabs.first(where: { $0.id == id }) else { return }
        activeTabID = id
        clearAttention(t)
    }

    func selectIndex(_ i: Int) {
        guard tabs.indices.contains(i) else { return }
        selectTab(tabs[i].id)
    }

    func cycle(_ delta: Int) {
        guard let a = activeTab, let i = tabs.firstIndex(where: { $0.id == a.id }), !tabs.isEmpty else { return }
        selectTab(tabs[(i + delta + tabs.count) % tabs.count].id)
    }

    /// Moves focus between panes of the active tab.
    func cyclePane(_ delta: Int) {
        guard let t = activeTab, t.panes.count > 1, let i = t.panes.firstIndex(where: { $0.id == t.focusedPaneID }) else { return }
        t.focusedPaneID = t.panes[(i + delta + t.panes.count) % t.panes.count].id
    }

    private func paneDidFocus(_ s: TerminalSession) {
        guard let t = tab(containing: s.id) else { return }
        if t.focusedPaneID != s.id { t.focusedPaneID = s.id }
        if activeTabID != t.id { activeTabID = t.id }
        s.bellPending = false
        s.unseenCompletion = false
    }

    private func clearAttention(_ t: TerminalTab) {
        t.focused?.unseenCompletion = false
        t.focused?.bellPending = false
    }

    /// Removes one pane (session) after hanging it up; removes the tab when it was the last pane.
    /// Callers confirm first if `needsConfirmation`.
    func close(_ id: UUID) {
        guard let t = tab(containing: id), let s = t.session(id) else { return }
        s.onExit = nil
        s.hangUp()
        s.view.removeFromSuperview()
        if !t.remove(id) {
            let ti = tabs.firstIndex { $0.id == t.id } ?? 0
            tabs.removeAll { $0.id == t.id }
            if activeTabID == t.id { activeTabID = tabs.isEmpty ? nil : tabs[min(ti, tabs.count - 1)].id }
        }
    }

    func closeTab(_ id: UUID) {
        guard let t = tabs.first(where: { $0.id == id }) else { return }
        for p in t.panes { close(p.id) }
    }

    func needsConfirmation(_ id: UUID) -> Bool {
        guard settings.confirmCloseBusy, let s = sessions.first(where: { $0.id == id }) else { return false }
        s.refresh()
        return s.isBusy
    }

    /// Busy panes in a tab (for the close-tab confirmation).
    func busyPanes(in tabID: UUID) -> [TerminalSession] {
        guard settings.confirmCloseBusy, let t = tabs.first(where: { $0.id == tabID }) else { return [] }
        return t.panes.filter { $0.refresh(); return $0.isBusy }
    }

    var busySessions: [TerminalSession] {
        sessions.filter { $0.refresh(); return $0.isBusy }
    }

    func applyAppearance() {
        let theme = settings.themeValue, font = settings.terminalFont
        for s in sessions { s.view.apply(theme: theme, font: font, optionAsMeta: settings.optionAsMeta) }
    }

    /// Quit path: hang up everything, wait briefly for shells to exit, then SIGKILL leftovers.
    func shutdownAll(timeout: TimeInterval = 1.5) {
        var targets: [ProcessInspector.Identity] = []
        for s in sessions where !s.exited {
            guard let p = s.view.process, p.shellPid > 0 else { continue }
            targets += TerminalSession.sendHangup(shell: p.shellPid, ptyMaster: p.childfd)
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline,
              targets.contains(where: { ProcessInspector.identity(of: $0.pid) == $0 }) {
            usleep(20_000)
        }
        TerminalSession.forceKill(targets)
    }

    private func tick() {
        let visible = isTerminalVisible()
        for t in tabs {
            for s in t.panes {
                let finished = s.refresh()
                let onScreen = visible && t.id == activeTabID
                if finished && !onScreen { s.unseenCompletion = true }
            }
        }
    }

    private func sessionExited(_ s: TerminalSession) {
        // Keep the pane so the user can read final output; it shows an EXITED state with the code.
        onSessionsChanged?()
    }
}
