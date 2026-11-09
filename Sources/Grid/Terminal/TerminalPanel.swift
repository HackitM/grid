import AppKit
import GridCore
import SwiftUI

/// Hosts a session's long-lived NSView. Terminal views are owned by their session, not by
/// SwiftUI, so switching tabs/panels never destroys scrollback or restarts the shell.
struct TerminalHostView: NSViewRepresentable {
    let session: TerminalSession
    /// Only the tab's focused pane takes keyboard focus when it (re)appears.
    let wantsFocus: Bool

    final class Container: NSView {
        weak var hosted: NSView?
        func host(_ v: NSView) {
            if hosted === v { return }
            if let h = hosted, h.superview === self { h.removeFromSuperview() }
            v.removeFromSuperview()
            v.frame = bounds
            v.autoresizingMask = [.width, .height]
            addSubview(v)
            hosted = v
        }
        override var isFlipped: Bool { true }
    }

    final class Coordinator { var lastWantsFocus = false }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> Container { Container() }

    func updateNSView(_ c: Container, context: Context) {
        let changed = c.hosted !== session.view
        c.host(session.view)
        let gainedFocusRole = wantsFocus && !context.coordinator.lastWantsFocus
        context.coordinator.lastWantsFocus = wantsFocus
        if wantsFocus && (changed || gainedFocusRole) {
            let v = session.view
            DispatchQueue.main.async { if v.window?.firstResponder !== v { v.window?.makeFirstResponder(v) } }
        }
    }

    static func dismantleNSView(_ c: Container, coordinator: Coordinator) {
        if let h = c.hosted, h.superview === c { h.removeFromSuperview() }
    }
}

/// The Terminal workspace: dockable panels (Files, Terminal, Widget Deck) arranged by a split tree.
/// Drag a panel's title bar onto another panel's edge to move it; × closes it; dividers resize.
struct TerminalPanel: View {
    @Environment(AppState.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        let ws = app.workspace
        if let tree = ws.tree {
            GeometryReader { geo in
                SplitTreeView(node: tree, divider: Metrics.gutter, dividerFill: theme.bg0,
                              leafMinimum: { WorkspacePanel(nodeID: $0).map(WorkspaceLayout.minimumSize) ?? .zero },
                              onResize: { ws.resize(split: $0, divider: $1, by: $2, minFraction: $3) },
                              onEqualize: { ws.equalize(split: $0) }) { id in
                    if let p = WorkspacePanel(nodeID: id) {
                        panel(p)
                            .environment(\.panelChrome, PanelChrome(drag: .panel(p), onClose: { app.closePanel(p) },
                                                                     closeHelp: "Close \(p.title)" + app.shortcuts.hint(p.toggleCommand)))
                            .dockTarget(.panel(p))
                    }
                }
                // The model repairs its fractions for the real size, so stored and rendered agree.
                .onAppear { ws.viewport = geo.size }
                .onChange(of: geo.size) { _, s in ws.viewport = s }
            }
        } else {
            VStack {
                Spacer()
                StateBlock(code: "WORKSPACE.EMPTY", title: "All panels are closed",
                           message: "Your terminal sessions keep running. Reopen a panel:") {
                    Button("Terminal" + app.shortcuts.hint(.toggleTerminalPanel)) { ws.show(.terminal); app.focusTerminal() }
                    Button("Files" + app.shortcuts.hint(.toggleSidebar)) { ws.show(.files) }
                    Button("Widget Deck" + app.shortcuts.hint(.toggleDeck)) { ws.show(.deck) }
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func panel(_ p: WorkspacePanel) -> some View {
        switch p {
        case .files: FileBrowserView(compact: true)
        case .terminal: TerminalSessionsPanel()
        case .deck: WidgetDeck()
        }
    }
}

/// The terminal panel itself: tabs, panes, and session controls.
private struct TerminalSessionsPanel: View {
    @Environment(AppState.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        let tm = app.terminals
        let canSplit = (tm.activeTab?.panes.count ?? 0) < TerminalManager.maxPanesPerTab
        Panel(index: "01", title: "Terminal", suffix: tm.active.map { "tty-\(String(format: "%02d", $0.number))" } ?? "idle",
              focused: tm.active?.hasFocus ?? false) {
            HStack(spacing: 2) {
                IconButton(symbol: "sidebar.left", label: "Toggle Files panel" + app.shortcuts.hint(.toggleSidebar), active: app.filesSidebar) {
                    app.filesSidebar.toggle()
                }
                IconButton(symbol: "folder.badge.gearshape", label: "Show terminal directory in Files" + app.shortcuts.hint(.revealTerminalDirectory),
                           disabled: tm.active == nil) { app.revealTerminalDirectoryInFiles() }
                IconButton(symbol: "rectangle.split.2x1", label: "Split right" + app.shortcuts.hint(.splitRight), disabled: !canSplit) { app.split(.horizontal) }
                IconButton(symbol: "rectangle.split.1x2", label: "Split down" + app.shortcuts.hint(.splitDown), disabled: !canSplit) { app.split(.vertical) }
                IconButton(symbol: "plus", label: "New tab" + app.shortcuts.hint(.newTab)) { app.newTerminal() }
                IconButton(symbol: "square.grid.2x2", label: "Toggle widget deck" + app.shortcuts.hint(.toggleDeck), active: app.deckVisible) {
                    app.deckVisible.toggle()
                }
            }
        } overflow: {
            // Same actions as the toolbar, for a header too narrow to show the buttons.
            GridMenuItem.action("New Tab", shortcut: app.shortcuts.display(.newTab)) { app.newTerminal() }
            GridMenuItem.action("Split Right", shortcut: app.shortcuts.display(.splitRight), enabled: canSplit) { app.split(.horizontal) }
            GridMenuItem.action("Split Down", shortcut: app.shortcuts.display(.splitDown), enabled: canSplit) { app.split(.vertical) }
            GridMenuItem.divider
            GridMenuItem.action((app.filesSidebar ? "Hide" : "Show") + " Files Panel", shortcut: app.shortcuts.display(.toggleSidebar)) { app.filesSidebar.toggle() }
            GridMenuItem.action("Show Terminal Directory in Files", shortcut: app.shortcuts.display(.revealTerminalDirectory),
                                enabled: tm.active != nil) { app.revealTerminalDirectoryInFiles() }
            GridMenuItem.action((app.deckVisible ? "Hide" : "Show") + " Widget Deck", shortcut: app.shortcuts.display(.toggleDeck)) { app.deckVisible.toggle() }
        } content: {
            VStack(spacing: 0) {
                TabStrip()
                Rectangle().fill(theme.line).frame(height: Metrics.hairline)
                if let t = tm.activeTab {
                    PaneLayout(tab: t)
                } else {
                    Spacer()
                    StateBlock(code: "NO.SESSION", title: "No terminal sessions",
                               message: "Start a shell session in your home folder or any folder from Files.") {
                        Button("New Session" + app.shortcuts.hint(.newTab)) { app.newTerminal() }
                    }
                    Spacer()
                }
            }
        }
    }
}

/// The panes of one tab, laid out by its split tree. Dividers can be dragged; double-click one
/// to give its split equal shares again.
private struct PaneLayout: View {
    let tab: TerminalTab
    var body: some View {
        let multi = tab.panes.count > 1
        SplitTreeView(node: tab.layout, divider: 6, minLeaf: 120,
                      onResize: { tab.resize(split: $0, divider: $1, by: $2, minFraction: $3) },
                      onEqualize: { tab.equalize(split: $0) }) { id in
            if let s = tab.session(id) {
                PaneView(session: s, tab: tab, focusedPane: s.id == tab.focusedPaneID, showMarker: multi)
            }
        }
    }
}

private struct PaneView: View {
    @Environment(AppState.self) private var app
    @Environment(\.theme) private var theme
    let session: TerminalSession
    let tab: TerminalTab
    let focusedPane: Bool
    let showMarker: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            Color(nsColor: theme.termBackground)
            TerminalHostView(session: session, wantsFocus: focusedPane)
                .padding(.leading, 8).padding(.top, showMarker ? 18 : 4).padding(.trailing, 2)
                .accessibilityLabel("Terminal session \(session.number)")
            if showMarker {
                // Pane header: which pane is focused (bar + label, not color alone). Drag it to move
                // the pane; × closes just this pane.
                VStack(spacing: 0) {
                    HStack(spacing: 6) {
                        Image(systemName: "line.3.horizontal").font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(theme.textMute)
                        Text(String(format: "%02d", session.number)).font(GridFont.label)
                            .foregroundStyle(focusedPane ? theme.accent : theme.textMute)
                        Text(session.displayTitle).font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(focusedPane ? theme.textDim : theme.textMute).lineLimit(1)
                        if session.isBusy { Text("◆").font(.system(size: 6)).foregroundStyle(theme.accent) }
                        if session.bellPending { Tag("bell", color: theme.warn).popIn() }
                        Spacer()
                        if focusedPane { SectionLabel("active", color: theme.accent) }
                        Button { app.requestCloseTerminal(session.id) } label: {
                            Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                                .foregroundStyle(theme.textDim).frame(width: 14, height: 14).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Close this pane" + app.shortcuts.hint(.closePane))
                        .accessibilityLabel("Close pane \(session.number)")
                    }
                    .padding(.horizontal, 8).frame(height: 16)
                    .background(focusedPane ? theme.accentSoft : theme.bg1.opacity(0.9))
                    .contentShape(Rectangle())
                    .onTapGesture { app.terminals.select(session.id); app.focusTerminal() }
                    .dockDragSource(.pane(session.id), label: "Pane \(String(format: "%02d", session.number)) · \(session.displayTitle)")
                    .help("Drag to move this pane (onto another pane's edge, a tab, or the tab bar)")
                    Rectangle().fill(focusedPane ? theme.accent : theme.line).frame(height: focusedPane ? 1.5 : Metrics.hairline)
                        .allowsHitTesting(false)
                    Spacer().allowsHitTesting(false)
                }
            }
            if session.exited { ExitedBar(session: session) }
        }
        .dockTarget(.pane(session.id))
        .overlay(alignment: .topTrailing) {
            if session.find.visible {
                TerminalFindBar(session: session).padding(.top, showMarker ? 22 : 6).padding(.trailing, 10)
            }
        }
        .contentShape(Rectangle())
    }
}

private struct TabStrip: View {
    @Environment(AppState.self) private var app
    @Environment(\.theme) private var theme
    @Environment(\.effects) private var effects
    /// The active-tab marker slides between tabs.
    @Namespace private var selector

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(Array(app.terminals.tabs.enumerated()), id: \.element.id) { i, t in
                    TabItem(tab: t, position: i, active: t.id == app.terminals.activeTabID, selector: selector)
                }

            }
        }
        .frame(height: 26)
        .background(theme.bg1)
        .animation(effects.motion ? GridMotion.snap : nil, value: app.terminals.activeTabID)
        // The whole strip (outside the tabs, which are smaller targets) accepts drops: a pane gets
        // its own tab; a tab moves to the end.
        .dockTarget(.tabBar)
        .help("Drop a pane on the tab bar to move it into its own tab")
    }
}

private struct TabItem: View {
    @Environment(AppState.self) private var app
    @Environment(\.theme) private var theme
    let tab: TerminalTab
    let position: Int
    let active: Bool
    let selector: Namespace.ID
    @State private var hover = false
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(String(format: "%02d", position + 1))
                .font(GridFont.label)
                .foregroundStyle(active ? theme.accent : theme.textMute)
            if tab.isBusy {
                // Busy: filled diamond + name of the running program (shape and text, not just color).
                Text("◆").font(.system(size: 7)).foregroundStyle(theme.accent)
                    .accessibilityLabel("running")
            }
            if editing {
                TextField("", text: $draft, prompt: Text("tab name").foregroundStyle(theme.textMute))
                    .textFieldStyle(.plain).font(GridFont.small).foregroundStyle(theme.text)
                    .frame(width: 120)
                    .focused($fieldFocused)
                    .onSubmit { commit() }
                    .onExitCommand { editing = false }
                    .onChange(of: fieldFocused) { _, f in if !f && editing { commit() } }
            } else {
                Text(tab.title)
                    .font(GridFont.small)
                    .foregroundStyle(tab.focused?.exited == true ? theme.textMute : (active ? theme.text : theme.textDim))
                    .lineLimit(1)
                    .frame(maxWidth: 160, alignment: .leading)
            }
            if tab.panes.count > 1 { Text("⊞\(tab.panes.count)").font(GridFont.label).foregroundStyle(theme.textMute) }
            if tab.hasUnseenCompletion { Tag("done").popIn() }
            if tab.hasBell { Tag("bell", color: theme.warn).popIn() }
            if let f = tab.focused, f.exited, tab.panes.count == 1 { Tag("exit \(f.exitCode.map(String.init) ?? "?")", color: theme.textMute) }
            Button {
                app.requestCloseTab(tab.id)
            } label: {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                    .frame(width: 14, height: 14)
                    .foregroundStyle(theme.textDim)
            }
            .buttonStyle(.plain)
            .opacity(hover || active ? 1 : 0)
            .help("Close tab (⇧⌘W)")
            .accessibilityLabel("Close tab \(position + 1)")
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(active ? theme.bg2 : (hover ? theme.bg2.opacity(0.5) : .clear))
        .overlay(alignment: .top) {
            if active { Rectangle().fill(theme.accent).frame(height: 2).matchedGeometryEffect(id: "tab.active", in: selector) }
        }
        .overlay(alignment: .trailing) { Rectangle().fill(theme.line).frame(width: Metrics.hairline) }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { beginRename() }
        .simultaneousGesture(TapGesture().onEnded {
            app.terminals.selectTab(tab.id)
            app.focusTerminal()
        })
        .onHover { hover = $0 }
        .dockDragSource(.tab(tab.id), label: "Tab · " + tab.title)
        // A tab dropped here goes before this one; a pane dropped here moves into this tab.
        .dockTarget(.tab(tab.id))
        .gridContextMenu(title: "tab") {
            GridMenuItem.action("Rename Tab…") { beginRename() }
            if tab.customTitle != nil { GridMenuItem.action("Use Automatic Name") { tab.customTitle = nil } }
            GridMenuItem.divider
            GridMenuItem.action("Close Tab", shortcut: app.shortcuts.display(.closeTab)) { app.requestCloseTab(tab.id) }
        }
        .help((tab.focused?.cwd).map { PathResolver.abbreviate($0) } ?? "")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(active ? [.isSelected, .isButton] : .isButton)
    }

    private func beginRename() {
        draft = tab.customTitle ?? ""
        editing = true
        DispatchQueue.main.async { fieldFocused = true }
    }

    private func commit() {
        let t = draft.trimmingCharacters(in: .whitespaces)
        tab.customTitle = t.isEmpty ? nil : String(t.prefix(40))
        editing = false
    }
}

private struct ExitedBar: View {
    @Environment(AppState.self) private var app
    @Environment(\.theme) private var theme
    let session: TerminalSession

    var body: some View {
        HStack(spacing: 10) {
            Text("■").foregroundStyle(theme.warn)
            SectionLabel("process exited", color: theme.warn)
            Text(session.failedToStart.map { "failed to start: \($0)" } ?? "code \(session.exitCode.map(String.init) ?? "unknown")")
                .font(GridFont.small).foregroundStyle(theme.textDim)
            Spacer()
            Button("New Session Here") { app.newTerminal(at: session.cwd) }
            Button("Close") { app.terminals.close(session.id) }
        }
        .buttonStyle(GridButtonStyle(compact: true))
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(theme.bg2)
        .overlay(alignment: .top) { Rectangle().fill(theme.line).frame(height: Metrics.hairline) }
    }
}
