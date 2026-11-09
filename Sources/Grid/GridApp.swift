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
        .windowResizability(.contentMinSize)
        .commands { GridCommands(app: delegate.state, refresher: delegate.commandsRefresher) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()
    lazy var commandsRefresher = CommandsRefresher(app: state)
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
            state.present(Confirmation(
                code: "QUIT.ACTIVE", title: "Quit GRID?", message: message, confirmLabel: "Quit", destructive: true,
                onConfirm: { [weak self] in
                    self?.shutdown()
                    NSApp.reply(toApplicationShouldTerminate: true)
                },
                onCancel: { NSApp.reply(toApplicationShouldTerminate: false) }), replacing: true)
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
        #if DEBUG
        DebugHooks.uninstall()
        #endif
    }
}

/// SwiftUI doesn't re-evaluate `Commands` when @Observable state read in its body changes, so
/// menu titles, enabled states, and shortcuts went stale. This watches exactly the state the
/// menus depend on and republishes it through an ObservableObject, which Commands do observe.
@MainActor
final class CommandsRefresher: ObservableObject {
    @Published private(set) var revision = 0
    private let app: AppState

    init(app: AppState) {
        self.app = app
        observe()
    }

    private func observe() {
        withObservationTracking {
            _ = GridCommands.dependencies(app)
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.revision &+= 1
                self.observe()
                // SwiftUI rebuilds its NSMenu items lazily (when a menu is about to show), so key
                // equivalents for keypresses would stay stale until then. Refresh them now, the
                // same way AppKit does before displaying a menu.
                DispatchQueue.main.async { Self.refreshMenus() }
            }
        }
    }

    static func refreshMenus() {
        func refresh(_ m: NSMenu) {
            m.delegate?.menuNeedsUpdate?(m)
            m.update()
            for item in m.items { if let sub = item.submenu { refresh(sub) } }
        }
        if let main = NSApp.mainMenu { refresh(main) }
    }
}

struct GridCommands: Commands {
    let app: AppState
    @ObservedObject var refresher: CommandsRefresher

    /// Everything the menu bar reads. Keep in sync with `body`.
    @MainActor
    static func dependencies(_ app: AppState) -> [AnyHashable] {
        let t = app.terminals
        return [app.panel, app.filesSidebar, app.inspectorVisible, app.deckVisible, app.terminalPanelVisible, app.confirmation != nil,
                t.active?.hasFocus, t.active?.find.visible, t.activeTab?.panes.count, t.tabs.count,
                t.sessions.isEmpty, t.activeTabID, t.activeID,
                app.files.canGoBack, app.files.canGoForward, app.files.canGoUp, app.files.showHidden,
                app.settings.theme, GridCommand.allCases.map { app.shortcuts.binding($0) },
                app.browser.activeID, app.browser.tabs.count, app.browser.active?.canGoBack, app.browser.active?.canGoForward,
                app.browser.active?.reader != nil, app.browser.findVisible]
    }

    private var terminalFocused: Bool { app.panel == .terminal && (app.terminals.active?.hasFocus ?? false) }
    private var filesVisible: Bool { app.panel == .files || (app.panel == .terminal && app.filesSidebar) }
    /// The Web page is showing: tab, close, find, back/forward and ⌘L act on the browser.
    private var web: Bool { app.panel == .web }
    /// Configured shortcut for a command (Settings › Keyboard); nil when unassigned.
    private func key(_ c: GridCommand) -> KeyboardShortcut? { app.shortcuts.shortcut(c) }

    var body: some Commands {
        let _ = refresher.revision
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { app.show(.settings) }.keyboardShortcut(key(.settings))
        }
        CommandGroup(replacing: .newItem) {
            Button("New Tab") {
                if web { app.browser.newTab(); app.browser.focusAddressToken += 1 } else { app.newTerminal() }
            }
            .keyboardShortcut(key(.newTab))
            Button("New Tab in Files Folder") { app.openTerminalHere() }.keyboardShortcut(key(.terminalHere))
            Button("New Folder") {
                if !filesVisible { app.show(.files) }
                app.fileOps.newFolder()
            }
            .keyboardShortcut(key(.newFolder))
            .disabled(terminalFocused)
            Divider()
            // The close command never quits GRID by accident: it closes the focused pane (or the tab
            // when it has one pane) in the Terminal panel; on other panels it returns to the terminal.
            // Only with no sessions left does it close the window (which quits the single-window app).
            Button(web && app.browser.active != nil ? "Close Browser Tab" : app.panel != .terminal && !app.terminals.sessions.isEmpty ? "Back to Terminal"
                   : ((app.terminals.activeTab?.panes.count ?? 0) > 1 ? "Close Pane" : "Close Tab")) {
                if app.confirmation != nil { NSSound.beep(); return }
                if web, let t = app.browser.active { app.browser.close(t.id); return }
                if app.panel != .terminal && !app.terminals.sessions.isEmpty {
                    app.show(.terminal)
                    app.focusTerminal()
                } else if let id = app.terminals.activeID {
                    app.requestCloseTerminal(id)
                } else {
                    NSApp.keyWindow?.performClose(nil)
                }
            }
            .keyboardShortcut(key(.closePane))
            Button("Close Tab") {
                if let id = app.terminals.activeTabID { app.requestCloseTab(id) }
            }
            .keyboardShortcut(key(.closeTab))
            .disabled(app.terminals.activeTabID == nil)
        }
        CommandGroup(after: .textEditing) {
            Button("Find") {
                if web { if app.browser.active != nil { app.browser.findVisible = true }; return }
                if app.panel == .terminal, let s = app.terminals.active, terminalFocused || s.find.visible {
                    s.find.open()
                } else {
                    if app.panel != .files && !(app.panel == .terminal && app.filesSidebar) { app.show(.files) }
                    NotificationCenter.default.post(name: .gridFocusFileFilter, object: nil)
                }
            }
            .keyboardShortcut(key(.find))
            Button("Find Next") { if let s = app.terminals.active, s.find.visible { s.find.next(s.view) } }
                .keyboardShortcut(key(.findNext))
                .disabled(!(app.terminals.active?.find.visible ?? false))
            Button("Find Previous") { if let s = app.terminals.active, s.find.visible { s.find.previous(s.view) } }
                .keyboardShortcut(key(.findPrevious))
                .disabled(!(app.terminals.active?.find.visible ?? false))
        }
        CommandMenu("Go") {
            Button("Back") { if web { app.browser.active?.goBack() } else { app.files.goBack() } }.keyboardShortcut(key(.goBack))
                .disabled(web ? !(app.browser.active?.canGoBack ?? false) : (!filesVisible || terminalFocused || !app.files.canGoBack))
            Button("Forward") { if web { app.browser.active?.goForward() } else { app.files.goForward() } }.keyboardShortcut(key(.goForward))
                .disabled(web ? !(app.browser.active?.canGoForward ?? false) : (!filesVisible || terminalFocused || !app.files.canGoForward))
            Button("Enclosing Folder") { app.files.goUp() }.keyboardShortcut(key(.goUp))
                .disabled(!filesVisible || terminalFocused || !app.files.canGoUp)
            Button("Home") { app.files.navigate(to: FileManager.default.homeDirectoryForCurrentUser); if !filesVisible { app.show(.files) } }
                .keyboardShortcut(key(.goHome))
            Button(web ? "Open Location…" : "Go to Folder…") {
                if web { app.browser.focusAddressToken += 1; return }
                if !filesVisible { app.show(.files) }
                NotificationCenter.default.post(name: .gridFocusPathField, object: nil)
            }
            .keyboardShortcut(key(.goToFolder))
            Divider()
            Button("Show Terminal Directory in Files") { app.revealTerminalDirectoryInFiles() }
                .keyboardShortcut(key(.revealTerminalDirectory))
            Button(app.files.showHidden ? "Hide Hidden Files" : "Show Hidden Files") { app.files.showHidden.toggle() }
                .keyboardShortcut(key(.toggleHidden))
        }
        CommandGroup(before: .sidebar) {
            Button("Command Palette") { app.paletteOpen.toggle() }
                .keyboardShortcut(key(.palette))
            Divider()
            ForEach([(PanelID.terminal, GridCommand.showTerminal), (.files, .showFiles), (.apps, .showApps), (.web, .showWeb)], id: \.0) { p, cmd in
                Button(p.title) {
                    app.show(p)
                    if p == .apps { NotificationCenter.default.post(name: .gridFocusAppSearch, object: nil) }
                }
                .keyboardShortcut(key(cmd))
            }
            Divider()
            Button(app.filesSidebar ? "Hide Files Sidebar" : "Show Files Sidebar") {
                if app.panel != .terminal { app.show(.terminal); app.filesSidebar = true } else { app.filesSidebar.toggle() }
            }
            .keyboardShortcut(key(.toggleSidebar))
            Button(app.inspectorVisible ? "Hide Inspector" : "Show Inspector") { app.inspectorVisible.toggle() }
                .keyboardShortcut(key(.toggleInspector))
            Button(app.deckVisible ? "Hide Widget Deck" : "Show Widget Deck") {
                if app.panel != .terminal { app.show(.terminal); app.deckVisible = true } else { app.deckVisible.toggle() }
            }
            .keyboardShortcut(key(.toggleDeck))
            Button(app.terminalPanelVisible ? "Hide Terminal Panel" : "Show Terminal Panel") {
                if app.panel != .terminal { app.show(.terminal); app.terminalPanelVisible = true }
                else if app.terminalPanelVisible { app.closePanel(.terminal) }
                else { app.terminalPanelVisible = true; app.focusTerminal() }
            }
            .keyboardShortcut(key(.toggleTerminalPanel))
            Button("Reset Workspace Layout") { app.workspace.reset() }
            Menu("Theme") {
                ForEach(ThemeID.allCases) { t in
                    Button((t == app.settings.theme ? "● " : "   ") + t.label) { app.setTheme(t) }
                }
            }
            Divider()
        }
        CommandMenu("Browser") {
            Button("Reload Page") { app.browser.active?.reload() }
                .keyboardShortcut("r", modifiers: .command).disabled(!web || app.browser.active == nil)
            Button(app.browser.active?.reader != nil ? "Exit Reader View" : "Reader View") { Task { await app.browser.toggleReader() } }
                .keyboardShortcut("r", modifiers: [.command, .shift]).disabled(!web || app.browser.active == nil)
            Divider()
            Button("Zoom In") { app.browser.active?.zoom(0.1) }.keyboardShortcut("=", modifiers: .command).disabled(!web)
            Button("Zoom Out") { app.browser.active?.zoom(-0.1) }.keyboardShortcut("-", modifiers: .command).disabled(!web)
            Button("Actual Size") { app.browser.active?.zoom(nil) }.keyboardShortcut("0", modifiers: .command).disabled(!web)
            Divider()
            Button("Open Page in Default Browser") { if let u = app.browser.active?.url { NSWorkspace.shared.open(u) } }
                .disabled(app.browser.active?.url == nil)
        }
        CommandMenu("Session") {
            Button("Split Right") { app.split(.horizontal) }.keyboardShortcut(key(.splitRight))
            Button("Split Down") { app.split(.vertical) }.keyboardShortcut(key(.splitDown))
            Button("Next Pane") { app.terminals.cyclePane(1); app.focusTerminal() }
                .keyboardShortcut(key(.nextPane))
                .disabled((app.terminals.activeTab?.panes.count ?? 0) < 2)
            Button("Previous Pane") { app.terminals.cyclePane(-1); app.focusTerminal() }
                .keyboardShortcut(key(.previousPane))
                .disabled((app.terminals.activeTab?.panes.count ?? 0) < 2)
            Divider()
            Button("Previous Tab") { if web { app.browser.cycle(-1) } else { app.terminals.cycle(-1); app.show(.terminal) } }
                .keyboardShortcut(key(.previousTab))
            Button("Next Tab") { if web { app.browser.cycle(1) } else { app.terminals.cycle(1); app.show(.terminal) } }
                .keyboardShortcut(key(.nextTab))
            Divider()
            ForEach(1...9, id: \.self) { n in
                Button("Tab \(n)") { app.terminals.selectIndex(n - 1); app.show(.terminal) }
                    .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
                    .disabled(app.terminals.tabs.count < n)
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
            .keyboardShortcut(key(.clearScrollback))
        }
    }
}
