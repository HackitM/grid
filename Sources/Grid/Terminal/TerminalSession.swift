import AppKit
import GridCore
import Observation
import SwiftTerm

/// One PTY-backed shell session.
@Observable
@MainActor
final class TerminalSession: Identifiable {
    let id = UUID()
    let number: Int
    let shellPath: String
    let view: GridTerminalView

    /// Title set by the program via OSC 0/2 (e.g. "vim file.txt"); empty if none.
    var programTitle = ""
    /// Shell's real working directory, read from the kernel (see ProcessInspector).
    var cwd: String?
    /// Name of the foreground job when it is not the shell itself (e.g. "vim", "node").
    var foregroundName: String?
    var columns = 0
    var rows = 0
    var exitCode: Int32?
    var exited = false
    var failedToStart: String?
    var hasFocus = false
    /// A foreground job finished while this tab was not visible.
    var unseenCompletion = false

    var isBusy: Bool { foregroundName != nil && !exited }

    @ObservationIgnored private var delegateProxy: DelegateProxy?
    @ObservationIgnored var onExit: ((TerminalSession) -> Void)?
    @ObservationIgnored var onDirectoryHint: ((TerminalSession) -> Void)?
    @ObservationIgnored private var shellName: String

    init(number: Int, shell: String, directory: String?, scrollback: Int, font: NSFont) {
        self.number = number
        self.shellPath = shell
        self.shellName = (shell as NSString).lastPathComponent
        var options = TerminalOptions.default
        options.scrollback = scrollback
        view = GridTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 500), font: font, options: options)
        let proxy = DelegateProxy(owner: self)
        delegateProxy = proxy
        view.processDelegate = proxy
        view.onFocusChange = { [weak self] f in self?.hasFocus = f }
    }

    var displayTitle: String {
        if exited { return "exited" }
        if let fg = foregroundName { return fg }
        if let cwd { return (cwd as NSString).lastPathComponent.isEmpty ? "/" : (cwd as NSString).lastPathComponent }
        return shellName
    }

    var shellPID: pid_t { view.process?.shellPid ?? 0 }

    func start(directory: String?) {
        let env = ShellEnvironment.build(shell: shellPath, inherited: ProcessInfo.processInfo.environment,
                                         appVersion: GridInfo.version)
        var dir = directory ?? NSHomeDirectory()
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: dir, isDirectory: &isDir) || !isDir.boolValue {
            dir = NSHomeDirectory()
        }
        // Leading "-" in argv[0] makes it a login shell, like Terminal.app: this sources
        // /etc/zprofile (path_helper) and ~/.zprofile so PATH matches the user's normal setup.
        view.startProcess(executable: shellPath, args: [], environment: env,
                          execName: "-" + shellName, currentDirectory: dir)
        cwd = dir
    }

    /// Re-reads kernel state. Cheap (two syscalls); called on a timer and on demand.
    /// Returns true if a foreground job just finished.
    @discardableResult
    func refresh() -> Bool {
        guard !exited, let process = view.process else { return false }
        let pid = process.shellPid
        guard pid > 0 else { return false }
        if let d = ProcessInspector.currentDirectory(pid: pid) { cwd = d }
        let wasBusy = isBusy
        if let pg = ProcessInspector.foregroundProcessGroup(ptyMaster: process.childfd), pg != pid {
            foregroundName = ProcessInspector.name(pid: pg) ?? "job"
        } else {
            foregroundName = nil
        }
        return wasBusy && !isBusy
    }

    // MARK: Shutdown

    /// Hangs up the session the way closing a terminal window does: SIGHUP to the foreground job
    /// and to the shell (which forwards it to its jobs), escalating to SIGKILL if ignored.
    /// Processes the user deliberately detached (nohup, setsid, disown) are left alone.
    func hangUp(escalateAfter seconds: Double = 2.0) {
        guard !exited, let process = view.process else { return }
        let pid = process.shellPid
        guard pid > 0 else { return }
        let fg = ProcessInspector.foregroundProcessGroup(ptyMaster: process.childfd)
        if let fg, fg != pid { killpg(fg, SIGHUP) }
        kill(pid, SIGHUP)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            Self.forceKill(shell: pid, foreground: fg)
        }
    }

    nonisolated static func forceKill(shell pid: pid_t, foreground fg: pid_t?) {
        if let fg, fg != pid, ProcessInspector.isAlive(fg) { killpg(fg, SIGKILL) }
        if ProcessInspector.isAlive(pid) { kill(pid, SIGKILL) }
    }

    fileprivate func handleExit(_ code: Int32?) {
        exited = true
        exitCode = code
        foregroundName = nil
        onExit?(self)
    }

    /// Bridges SwiftTerm's delegate callbacks (delivered on the main queue).
    private final class DelegateProxy: NSObject, LocalProcessTerminalViewDelegate {
        weak var owner: TerminalSession?
        init(owner: TerminalSession) { self.owner = owner }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
            MainActor.assumeIsolated {
                owner?.columns = newCols
                owner?.rows = newRows
            }
        }
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
            MainActor.assumeIsolated { owner?.programTitle = title }
        }
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
            // OSC 7 from a shell integration: treat as a hint and re-read the kernel's truth
            // (an OSC 7 from an ssh session would describe a *remote* path).
            MainActor.assumeIsolated {
                guard let owner else { return }
                owner.refresh()
                owner.onDirectoryHint?(owner)
            }
        }
        func processTerminated(source: TerminalView, exitCode: Int32?) {
            MainActor.assumeIsolated { owner?.handleExit(exitCode) }
        }
        func processFailedToStart(source: TerminalView, error: LocalProcessError) {
            MainActor.assumeIsolated {
                owner?.failedToStart = "\(error)"
                owner?.handleExit(nil)
            }
        }
    }
}

enum GridInfo {
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0-dev"
    }
}
