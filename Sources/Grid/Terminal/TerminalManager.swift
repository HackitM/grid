import AppKit
import GridCore
import Observation

@Observable
@MainActor
final class TerminalManager {
    private(set) var sessions: [TerminalSession] = []
    var activeID: UUID?
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

    var active: TerminalSession? { sessions.first { $0.id == activeID } }

    @discardableResult
    func newSession(at directory: String? = nil) -> TerminalSession {
        counter += 1
        let shell = ShellEnvironment.resolveShell(override: settings.shellOverride)
        let s = TerminalSession(number: counter, shell: shell, directory: directory,
                                scrollback: settings.scrollback, font: settings.terminalFont)
        s.view.apply(theme: settings.themeValue, font: settings.terminalFont, optionAsMeta: settings.optionAsMeta)
        s.onExit = { [weak self] session in self?.sessionExited(session) }
        sessions.append(s)
        activeID = s.id
        s.start(directory: directory)
        return s
    }

    func select(_ id: UUID) {
        activeID = id
        active?.unseenCompletion = false
    }

    func selectIndex(_ i: Int) {
        guard sessions.indices.contains(i) else { return }
        select(sessions[i].id)
    }

    func cycle(_ delta: Int) {
        guard let a = active, let i = sessions.firstIndex(where: { $0.id == a.id }), !sessions.isEmpty else { return }
        select(sessions[(i + delta + sessions.count) % sessions.count].id)
    }

    /// Removes a session after hanging it up. Callers confirm first if `needsConfirmation`.
    func close(_ id: UUID) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        let s = sessions[i]
        s.onExit = nil
        s.hangUp()
        s.view.removeFromSuperview()
        sessions.remove(at: i)
        if activeID == id {
            activeID = sessions.isEmpty ? nil : sessions[min(i, sessions.count - 1)].id
        }
    }

    func needsConfirmation(_ id: UUID) -> Bool {
        guard settings.confirmCloseBusy, let s = sessions.first(where: { $0.id == id }) else { return false }
        s.refresh()
        return s.isBusy
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
        let targets: [(pid_t, pid_t?)] = sessions.compactMap { s in
            guard !s.exited, let p = s.view.process, p.shellPid > 0 else { return nil }
            return (p.shellPid, ProcessInspector.foregroundProcessGroup(ptyMaster: p.childfd))
        }
        for (pid, fg) in targets {
            if let fg, fg != pid { killpg(fg, SIGHUP) }
            kill(pid, SIGHUP)
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, targets.contains(where: { ProcessInspector.isAlive($0.0) }) {
            usleep(20_000)
        }
        for (pid, fg) in targets { TerminalSession.forceKill(shell: pid, foreground: fg) }
    }

    private func tick() {
        let visible = isTerminalVisible()
        for s in sessions {
            let finished = s.refresh()
            if finished && (s.id != activeID || !visible) {
                s.unseenCompletion = true
            }
        }
    }

    private func sessionExited(_ s: TerminalSession) {
        // Keep the tab so the user can read final output; it shows an EXITED state with the code.
        onSessionsChanged?()
    }
}
