import AppKit
import GridCore
import SwiftUI

/// Hosts a session's long-lived NSView. Terminal views are owned by their session, not by
/// SwiftUI, so switching tabs/panels never destroys scrollback or restarts the shell.
struct TerminalHostView: NSViewRepresentable {
    let session: TerminalSession

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

    func makeNSView(context: Context) -> Container { Container() }

    func updateNSView(_ c: Container, context: Context) {
        let changed = c.hosted !== session.view
        c.host(session.view)
        if changed {
            let v = session.view
            DispatchQueue.main.async { v.window?.makeFirstResponder(v) }
        }
    }

    static func dismantleNSView(_ c: Container, coordinator: ()) {
        if let h = c.hosted, h.superview === c { h.removeFromSuperview() }
    }
}

struct TerminalPanel: View {
    @Environment(AppState.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        let tm = app.terminals
        HStack(spacing: Metrics.gutter) {
            if app.filesSidebar {
                FileBrowserView(compact: true)
                    .frame(minWidth: 240, idealWidth: 300, maxWidth: 380)
            }
            Panel(index: "01", title: "Terminal", suffix: tm.active.map { "tty-\(String(format: "%02d", $0.number))" } ?? "idle",
                  focused: tm.active?.hasFocus ?? false) {
                HStack(spacing: 2) {
                    IconButton(symbol: "sidebar.left", label: "Toggle Files sidebar (⌘B)", active: app.filesSidebar) {
                        app.filesSidebar.toggle()
                    }
                    IconButton(symbol: "folder.badge.gearshape", label: "Show terminal directory in Files (⇧⌘J)",
                               disabled: tm.active == nil) { app.revealTerminalDirectoryInFiles() }
                    IconButton(symbol: "plus", label: "New session (⌘T)") { app.newTerminal() }
                }
            } content: {
                VStack(spacing: 0) {
                    TabStrip()
                    Rectangle().fill(theme.line).frame(height: Metrics.hairline)
                    if let s = tm.active {
                        ZStack(alignment: .bottom) {
                            Color(nsColor: theme.termBackground)
                            TerminalHostView(session: s)
                                .padding(.leading, 8).padding(.top, 4).padding(.trailing, 2)
                                .accessibilityLabel("Terminal session \(s.number)")
                            if s.exited { ExitedBar(session: s) }
                        }
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
        }
    }
}

private struct TabStrip: View {
    @Environment(AppState.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(Array(app.terminals.sessions.enumerated()), id: \.element.id) { i, s in
                    TabItem(session: s, position: i, active: s.id == app.terminals.activeID)
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
    let session: TerminalSession
    let position: Int
    let active: Bool
    @State private var hover = false

    var body: some View {
        HStack(spacing: 6) {
            Text(String(format: "%02d", session.number))
                .font(GridFont.label)
                .foregroundStyle(active ? theme.accent : theme.textMute)
            if session.isBusy {
                // Busy: filled diamond + name of the running program (shape and text, not just color).
                Text("◆").font(.system(size: 7)).foregroundStyle(theme.accent)
                    .accessibilityLabel("running")
            }
            Text(session.displayTitle)
                .font(GridFont.small)
                .foregroundStyle(session.exited ? theme.textMute : (active ? theme.text : theme.textDim))
                .lineLimit(1)
                .frame(maxWidth: 160, alignment: .leading)
            if session.unseenCompletion { Tag("done") }
            if session.exited { Tag("exit \(session.exitCode.map(String.init) ?? "?")", color: theme.textMute) }
            Button {
                app.requestCloseTerminal(session.id)
            } label: {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                    .frame(width: 14, height: 14)
                    .foregroundStyle(theme.textDim)
            }
            .buttonStyle(.plain)
            .opacity(hover || active ? 1 : 0)
            .help("Close session (⌘W)")
            .accessibilityLabel("Close session \(session.number)")
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(active ? theme.bg2 : (hover ? theme.bg2.opacity(0.5) : .clear))
        .overlay(alignment: .top) { if active { Rectangle().fill(theme.accent).frame(height: 2) } }
        .overlay(alignment: .trailing) { Rectangle().fill(theme.line).frame(width: Metrics.hairline) }
        .contentShape(Rectangle())
        .onTapGesture {
            app.terminals.select(session.id)
            app.focusTerminal()
        }
        .onHover { hover = $0 }
        .help(session.cwd.map { PathResolver.abbreviate($0) } ?? "")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(active ? [.isSelected, .isButton] : .isButton)
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
