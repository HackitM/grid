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
                    IconButton(symbol: "sidebar.left", label: "Toggle Files sidebar" + app.shortcuts.hint(.toggleSidebar), active: app.filesSidebar) {
                        app.filesSidebar.toggle()
                    }
                    IconButton(symbol: "folder.badge.gearshape", label: "Show terminal directory in Files" + app.shortcuts.hint(.revealTerminalDirectory),
                               disabled: tm.active == nil) { app.revealTerminalDirectoryInFiles() }
                    IconButton(symbol: "rectangle.split.2x1", label: "Split right" + app.shortcuts.hint(.splitRight),
                               disabled: (tm.activeTab?.panes.count ?? 0) >= TerminalManager.maxPanesPerTab) { app.split(.horizontal) }
                    IconButton(symbol: "rectangle.split.1x2", label: "Split down" + app.shortcuts.hint(.splitDown),
                               disabled: (tm.activeTab?.panes.count ?? 0) >= TerminalManager.maxPanesPerTab) { app.split(.vertical) }
                    IconButton(symbol: "plus", label: "New tab" + app.shortcuts.hint(.newTab)) { app.newTerminal() }
                    IconButton(symbol: "square.grid.2x2", label: "Toggle widget deck" + app.shortcuts.hint(.toggleDeck), active: app.deckVisible) {
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

/// The panes of one tab, laid out by its split tree. Dividers can be dragged; double-click one
/// to give its split equal shares again.
private struct PaneLayout: View {
    let tab: TerminalTab
    var body: some View {
        PaneTreeView(node: tab.layout, tab: tab, multi: tab.panes.count > 1)
    }
}

private struct PaneTreeView: View {
    let node: SplitTree
    let tab: TerminalTab
    let multi: Bool

    var body: some View {
        switch node {
        case .leaf(let id):
            if let s = tab.session(id) {
                PaneView(session: s, focusedPane: s.id == tab.focusedPaneID, showMarker: multi)
            }
        case .split(let sid, let axis, let children, let fractions):
            SplitContainer(splitID: sid, axis: axis, children: children, fractions: fractions, tab: tab, multi: multi)
        }
    }
}

private struct SplitContainer: View {
    @Environment(\.theme) private var theme
    let splitID: UUID
    let axis: SplitAxis
    let children: [SplitTree]
    let fractions: [Double]
    let tab: TerminalTab
    let multi: Bool

    static let divider: CGFloat = 6
    static let minPane: CGFloat = 120

    var body: some View {
        GeometryReader { geo in
            let horizontal = axis == .horizontal
            let total = max((horizontal ? geo.size.width : geo.size.height) - Self.divider * CGFloat(children.count - 1), 1)
            let layout = horizontal ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            layout {
                ForEach(Array(children.enumerated()), id: \.element.nodeID) { i, child in
                    if i > 0 {
                        PaneDivider(axis: axis, total: total, minFraction: min(Double(Self.minPane / total), 0.45)) { delta, minF in
                            tab.resize(split: splitID, divider: i - 1, by: delta, minFraction: minF)
                        } reset: {
                            tab.equalize(split: splitID)
                        }
                    }
                    PaneTreeView(node: child, tab: tab, multi: multi)
                        .frame(width: horizontal ? total * CGFloat(fractions[i]) : nil,
                               height: horizontal ? nil : total * CGFloat(fractions[i]))
                }
            }
        }
    }
}

/// A draggable gutter between two panes.
private struct PaneDivider: View {
    @Environment(\.theme) private var theme
    let axis: SplitAxis
    let total: CGFloat
    let minFraction: Double
    let onDrag: (_ delta: Double, _ minFraction: Double) -> Void
    let reset: () -> Void
    @State private var last: CGFloat = 0
    @State private var dragging = false
    @State private var hover = false

    var body: some View {
        let horizontal = axis == .horizontal
        Rectangle()
            .fill(theme.bg1)
            .frame(width: horizontal ? SplitContainer.divider : nil, height: horizontal ? nil : SplitContainer.divider)
            .overlay(
                Rectangle()
                    .fill(dragging ? theme.accent : (hover ? theme.lineStrong : theme.line))
                    .frame(width: horizontal ? 1 : nil, height: horizontal ? nil : 1)
            )
            .contentShape(Rectangle())
            .onHover { inside in
                hover = inside
                if inside { (horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { v in
                        let t = horizontal ? v.translation.width : v.translation.height
                        if !dragging { dragging = true; last = 0 }
                        let step = t - last
                        last = t
                        onDrag(Double(step / total), minFraction)
                    }
                    .onEnded { _ in dragging = false; last = 0 }
            )
            .onTapGesture(count: 2) { reset() }
            .help("Drag to resize panes · double-click to even them out")
            .accessibilityElement()
            .accessibilityLabel("Pane divider")
            .accessibilityAdjustableAction { dir in
                onDrag(dir == .increment ? 0.05 : -0.05, minFraction)
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
