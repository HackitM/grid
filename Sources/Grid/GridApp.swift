import AppKit
import GridCore
import SwiftTerm
import SwiftUI

@main
struct GridApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("GRID", id: "main") {
            RootView()
                .environment(delegate.state)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 800)
        .commands { GridCommands(app: delegate.state) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()
    private var didShutdown = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        NSWindow.allowsAutomaticWindowTabbing = false
        #if DEBUG
        DebugHooks.install(state)
        #endif
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let busy = state.settings.confirmCloseBusy ? state.terminals.busySessions : []
        guard !busy.isEmpty else {
            shutdown()
            return .terminateNow
        }
        let names = busy.map { "• session \(String(format: "%02d", $0.number)): \($0.foregroundName ?? "job")" }.joined(separator: "\n")
        let message = "These programs are still running and will be sent a hangup signal (SIGHUP):\n\(names)"
        if NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) {
            state.confirmation = Confirmation(
                code: "QUIT.ACTIVE", title: "Quit GRID?", message: message, confirmLabel: "Quit", destructive: true,
                onConfirm: { [weak self] in
                    self?.shutdown()
                    NSApp.reply(toApplicationShouldTerminate: true)
                },
                onCancel: { NSApp.reply(toApplicationShouldTerminate: false) })
            return .terminateLater
        }
        // No visible window (closed via the title bar): fall back to a native alert.
        let alert = NSAlert()
        alert.messageText = "Quit GRID?"
        alert.informativeText = message
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            shutdown()
            return .terminateNow
        }
        return .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) { shutdown() }

    private func shutdown() {
        guard !didShutdown else { return }
        didShutdown = true
        state.terminals.shutdownAll()
    }
}

struct GridCommands: Commands {
    let app: AppState

    private var terminalFocused: Bool { app.panel == .terminal && (app.terminals.active?.hasFocus ?? false) }
    private var filesVisible: Bool { app.panel == .files || (app.panel == .terminal && app.filesSidebar) }

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { app.show(.settings) }.keyboardShortcut(",", modifiers: .command)
        }
        CommandGroup(replacing: .newItem) {
            Button("New Session") { app.newTerminal() }.keyboardShortcut("t", modifiers: .command)
            Button("New Session in Files Folder") { app.openTerminalHere() }.keyboardShortcut("t", modifiers: [.command, .option])
            Divider()
            Button("Close Session") {
                if let id = app.terminals.activeID, app.panel == .terminal { app.requestCloseTerminal(id) }
                else { NSApp.keyWindow?.performClose(nil) }
            }
            .keyboardShortcut("w", modifiers: .command)
        }
        CommandGroup(after: .textEditing) {
            Button("Find") {
                if terminalFocused, let v = app.terminals.active?.view {
                    let item = NSMenuItem()
                    item.tag = NSTextFinder.Action.showFindInterface.rawValue
                    v.performTextFinderAction(item)
                } else {
                    if app.panel != .files && !(app.panel == .terminal && app.filesSidebar) { app.show(.files) }
                    NotificationCenter.default.post(name: .gridFocusFileFilter, object: nil)
                }
            }
            .keyboardShortcut("f", modifiers: .command)
        }
        CommandMenu("Go") {
            Button("Back") { app.files.goBack() }.keyboardShortcut("[", modifiers: .command)
                .disabled(!filesVisible || terminalFocused || !app.files.canGoBack)
            Button("Forward") { app.files.goForward() }.keyboardShortcut("]", modifiers: .command)
                .disabled(!filesVisible || terminalFocused || !app.files.canGoForward)
            Button("Enclosing Folder") { app.files.goUp() }.keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(!filesVisible || terminalFocused || !app.files.canGoUp)
            Button("Home") { app.files.navigate(to: FileManager.default.homeDirectoryForCurrentUser); if !filesVisible { app.show(.files) } }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            Button("Go to Folder…") {
                if !filesVisible { app.show(.files) }
                NotificationCenter.default.post(name: .gridFocusPathField, object: nil)
            }
            .keyboardShortcut("l", modifiers: .command)
            Divider()
            Button("Show Terminal Directory in Files") { app.revealTerminalDirectoryInFiles() }
                .keyboardShortcut("j", modifiers: [.command, .shift])
            Button(app.files.showHidden ? "Hide Hidden Files" : "Show Hidden Files") { app.files.showHidden.toggle() }
                .keyboardShortcut(".", modifiers: [.command, .shift])
        }
        CommandGroup(before: .sidebar) {
            Button("Command Palette") { app.paletteOpen.toggle() }
                .keyboardShortcut(app.settings.paletteShortcut.shortcut)
            Divider()
            ForEach([PanelID.terminal, .files, .apps, .web]) { p in
                Button(p.title) {
                    app.show(p)
                    if p == .apps { NotificationCenter.default.post(name: .gridFocusAppSearch, object: nil) }
                }
                .keyboardShortcut(KeyEquivalent(p.shortcutKey), modifiers: [.command, .option])
            }
            Divider()
            Button(app.filesSidebar ? "Hide Files Sidebar" : "Show Files Sidebar") {
                if app.panel != .terminal { app.show(.terminal); app.filesSidebar = true } else { app.filesSidebar.toggle() }
            }
            .keyboardShortcut("b", modifiers: .command)
            Button(app.inspectorVisible ? "Hide Inspector" : "Show Inspector") { app.inspectorVisible.toggle() }
                .keyboardShortcut("i", modifiers: .command)
            Menu("Theme") {
                ForEach(ThemeID.allCases) { t in
                    Button((t == app.settings.theme ? "● " : "   ") + t.label) { app.setTheme(t) }
                }
            }
            Divider()
        }
        CommandMenu("Session") {
            Button("Previous Session") { app.terminals.cycle(-1); app.show(.terminal) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Button("Next Session") { app.terminals.cycle(1); app.show(.terminal) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Divider()
            ForEach(1...9, id: \.self) { n in
                Button("Session \(n)") { app.terminals.selectIndex(n - 1); app.show(.terminal) }
                    .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
                    .disabled(app.terminals.sessions.count < n)
            }
            Divider()
            Button("Clear Scrollback") {
                guard let s = app.terminals.active else { return }
                // Erase screen + scrollback in the emulator (ED 2 / ED 3); this is display-only.
                s.view.feed(text: "\u{1b}[H\u{1b}[2J\u{1b}[3J")
                // Ask an idle shell to redraw its prompt (Ctrl-L). Never sent while a program runs.
                s.refresh()
                if !s.isBusy && !s.exited { s.view.send(txt: "\u{0C}") }
            }
            .keyboardShortcut(app.settings.paletteShortcut == .cmdK ? nil : KeyboardShortcut("k", modifiers: .command))
        }
    }
}
