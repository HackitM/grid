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

struct TerminalPanel: View {
    @Environment(AppState.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        let tm = app.terminals
        HStack(spacing: 0) {
            if app.filesSidebar {
                FileBrowserView(compact: true)
                    .frame(width: app.layout.sidebarWidth)
                ResizeHandle(width: Binding(get: { app.layout.sidebarWidth }, set: { app.layout.sidebarWidth = $0 }),
                             range: 220...560, defaultValue: 300, edge: .leading)
            }
            Panel(index: "01", title: "Terminal", suffix: tm.active.map { "tty-\(String(format: "%02d", $0.number))" } ?? "idle",
                  focused: tm.active?.hasFocus ?? false) {
                HStack(spacing: 2) {
                    IconButton(symbol: "sidebar.left", label: "Toggle Files sidebar (⌘B)", active: app.filesSidebar) {
                        app.filesSidebar.toggle()
                    }
                    IconButton(symbol: "folder.badge.gearshape", label: "Show terminal directory in Files (⇧⌘J)",
                               disabled: tm.active == nil) { app.revealTerminalDirectoryInFiles() }
                    IconButton(symbol: "rectangle.split.2x1", label: "Split right (⌘D)",
                               disabled: (tm.activeTab?.panes.count ?? 0) >= TerminalManager.maxPanesPerTab) { app.split(.horizontal) }
                    IconButton(symbol: "rectangle.split.1x2", label: "Split down (⇧⌘D)",
                               disabled: (tm.activeTab?.panes.count ?? 0) >= TerminalManager.maxPanesPerTab) { app.split(.vertical) }
                    IconButton(symbol: "plus", label: "New tab (⌘T)") { app.newTerminal() }
                    IconButton(symbol: "square.grid.2x2", label: "Toggle widget deck (⌘J)", active: app.deckVisible) {
                        app.deckVisible.toggle()
                    }
                }
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
                            Button("New Session  ⌘T") { app.newTerminal() }
                        }
                        Spacer()
                    }
                }
            }
            if app.deckVisible {
                ResizeHandle(width: Binding(get: { app.layout.deckWidth }, set: { app.layout.deckWidth = $0 }),
                             range: 240...520, defaultValue: 300, edge: .trailing)
                WidgetDeck().frame(width: app.layout.deckWidth)
            }
        }
    }
}

/// The panes of one tab, separated by hairlines. Equal sizes.
private struct PaneLayout: View {
    @Environment(AppState.self) private var app
    @Environment(\.theme) private var theme
    let tab: TerminalTab

    var body: some View {
        let multi = tab.panes.count > 1
        let layout = tab.axis == .horizontal ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
        layout {
            ForEach(Array(tab.panes.enumerated()), id: \.element.id) { i, s in
                if i > 0 {
                    Rectangle().fill(theme.line)
                        .frame(width: tab.axis == .horizontal ? Metrics.hairline : nil,
                               height: tab.axis == .vertical ? Metrics.hairline : nil)
                }
                PaneView(session: s, focusedPane: s.id == tab.focusedPaneID, showMarker: multi)
            }
        }
    }
}

private struct PaneView: View {
    @Environment(AppState.self) private var app
    @Environment(\.theme) private var theme
    let session: TerminalSession
    let focusedPane: Bool
    let showMarker: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            Color(nsColor: theme.termBackground)
            TerminalHostView(session: session, wantsFocus: focusedPane)
                .padding(.leading, 8).padding(.top, showMarker ? 18 : 4).padding(.trailing, 2)
                .accessibilityLabel("Terminal session \(session.number)")
            if showMarker {
                // Pane header: which pane is focused, by bar + label (not color alone).
                VStack(spacing: 0) {
                    HStack(spacing: 6) {
                        Text(String(format: "%02d", session.number)).font(GridFont.label)
                            .foregroundStyle(focusedPane ? theme.accent : theme.textMute)
                        Text(session.displayTitle).font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(focusedPane ? theme.textDim : theme.textMute).lineLimit(1)
                        if session.isBusy { Text("◆").font(.system(size: 6)).foregroundStyle(theme.accent) }
                        if session.bellPending { Tag("bell", color: theme.warn) }
                        Spacer()
                        if focusedPane { SectionLabel("active", color: theme.accent) }
                    }
                    .padding(.horizontal, 8).frame(height: 16)
                    .background(focusedPane ? theme.accentSoft : Color.clear)
                    Rectangle().fill(focusedPane ? theme.accent : theme.line).frame(height: focusedPane ? 1.5 : Metrics.hairline)
                    Spacer()
                }
                .allowsHitTesting(false)
            }
            if session.exited { ExitedBar(session: session) }
        }
        .contentShape(Rectangle())
    }
}

private struct TabStrip: View {
    @Environment(AppState.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(Array(app.terminals.tabs.enumerated()), id: \.element.id) { i, t in
                    TabItem(tab: t, position: i, active: t.id == app.terminals.activeTabID)
                }
            }
        }
        .frame(height: 26)
        .background(theme.bg1)
    }
}

private struct TabItem: View {
    @Environment(AppState.self) private var app
    @Environment(\.theme) private var theme
    let tab: TerminalTab
    let position: Int
    let active: Bool
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
            if tab.hasUnseenCompletion { Tag("done") }
            if tab.hasBell { Tag("bell", color: theme.warn) }
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
        .overlay(alignment: .top) { if active { Rectangle().fill(theme.accent).frame(height: 2) } }
        .overlay(alignment: .trailing) { Rectangle().fill(theme.line).frame(width: Metrics.hairline) }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { beginRename() }
        .simultaneousGesture(TapGesture().onEnded {
            app.terminals.selectTab(tab.id)
            app.focusTerminal()
        })
        .onHover { hover = $0 }
        .contextMenu {
            Button("Rename Tab…") { beginRename() }
            if tab.customTitle != nil { Button("Use Automatic Name") { tab.customTitle = nil } }
            Divider()
            Button("Close Tab") { app.requestCloseTab(tab.id) }
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
