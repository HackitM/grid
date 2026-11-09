import AppKit
import GridCore
import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let theme = app.settings.themeValue
        let fx = app.settings.effects
        ZStack {
            theme.bg0.ignoresSafeArea()
            if fx.gridBackdrop { GridBackdrop().ignoresSafeArea() }
            VStack(spacing: 0) {
                TopBar()
                HStack(spacing: 0) {
                    NavRail()
                    Group {
                        switch app.panel {
                        case .terminal: TerminalPanel()
                        case .files: FilesPanel()
                        case .apps: AppsPanel()
                        case .web: WebPanel()
                        case .settings: SettingsPanel()
                        }
                    }
                    .padding(Metrics.gutter)
                    // No cross-fade (two pages double-exposed looked muddy): the old page leaves
                    // at once and the new page's panels build on (BuildOn in Panel).
                    .transition(.identity)
                }
                StatusBar()
            }
            .ignoresSafeArea(edges: .top)

            // GRID drag tracking: the single drop highlight and the label that follows the pointer.
            DockDragOverlay().ignoresSafeArea()

            if app.paletteOpen {
                Color.black.opacity(0.35).ignoresSafeArea()
                    .onTapGesture { app.paletteOpen = false }
                VStack {
                    CommandPalette().padding(.top, 70)
                    Spacer()
                }
            }
            if let c = app.confirmation {
                ConfirmationOverlay(confirmation: c)
            }
        }
        .environment(\.theme, theme)
        .environment(\.effects, fx)
        .animation(fx.motion ? .easeOut(duration: 0.12) : nil, value: app.panel)
        .preferredColorScheme(.dark)
        .tint(theme.accent)
        .frame(minWidth: 820, minHeight: 480)
        .onChange(of: app.panel) { _, p in if p == .terminal { app.focusTerminal() } }
    }
}

/// Title strip. Leaves room for the standard traffic-light buttons (normal window management).
private struct TopBar: View {
    @Environment(AppState.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: 70)
            Text("GRID").font(.system(size: 11, weight: .heavy, design: .monospaced)).tracking(3).foregroundStyle(theme.accent)
            Rectangle().fill(theme.line).frame(width: 1, height: 12)
            SectionLabel("\(app.panel.index) \(app.panel.title)", color: theme.textDim)
            TerminatedRule().frame(maxWidth: 260)
            Spacer()
            Button { app.paletteOpen.toggle() } label: {
                HStack(spacing: 6) {
                    SectionLabel("command")
                    if !app.shortcuts.display(.palette).isEmpty { KeyCap(app.shortcuts.display(.palette)) }
                }
            }
            .buttonStyle(.plain)
            .help("Command palette")
        }
        .padding(.trailing, 12)
        .frame(height: 30)
        .background(theme.bg0)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.line).frame(height: Metrics.hairline) }
    }
}

private struct NavRail: View {
    @Environment(AppState.self) private var app
    @Environment(\.theme) private var theme
    /// The active-item bar slides between rail items (an Ares-style selector).
    @Namespace private var selector

    var body: some View {
        VStack(spacing: 2) {
            ForEach([PanelID.terminal, .files, .apps, .web]) { p in RailItem(panel: p, selector: selector) }
            Spacer()
            RailItem(panel: .settings, selector: selector)
        }
        .padding(.vertical, 8)
        .frame(width: Metrics.railWidth)
        .background(theme.bg0)
        .overlay(alignment: .trailing) { Rectangle().fill(theme.line).frame(width: Metrics.hairline) }
    }
}

private struct RailItem: View {
    @Environment(AppState.self) private var app
    @Environment(\.theme) private var theme
    let panel: PanelID
    let selector: Namespace.ID
    @State private var hover = false

    private var railCommand: GridCommand {
        switch panel { case .terminal: .showTerminal; case .files: .showFiles; case .apps: .showApps; case .web: .showWeb; case .settings: .settings }
    }

    var body: some View {
        let active = app.panel == panel
        let badge = panel == .terminal && app.terminals.sessions.contains { $0.unseenCompletion }
        Button { app.show(panel) } label: {
            VStack(spacing: 3) {
                Text(panel.index).font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundStyle(active ? theme.accent : theme.textMute)
                Image(systemName: panel.symbol).font(.system(size: 14, weight: .regular))
                    .foregroundStyle(active ? theme.accent : (hover ? theme.text : theme.textDim))
                Text(panel.label).font(.system(size: 8, weight: .semibold, design: .monospaced)).tracking(1)
                    .foregroundStyle(active ? theme.text : theme.textMute)
            }
            .frame(width: Metrics.railWidth - 8, height: 54)
            .background(active ? theme.accentSoft : (hover ? theme.bg2 : .clear))
            .overlay(alignment: .leading) {
                if active {
                    Rectangle().fill(theme.accent).frame(width: 2)
                        .matchedGeometryEffect(id: "rail.active", in: selector)
                }
            }
            .overlay(alignment: .topTrailing) {
                if badge { Rectangle().fill(theme.accent).frame(width: 5, height: 5).padding(5).accessibilityLabel("job finished") }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(panel.title + app.shortcuts.hint(railCommand))
        .accessibilityLabel(panel.title)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// Real, measured information only.
private struct StatusBar: View {
    @Environment(AppState.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            if let s = app.terminals.active {
                cell("TTY-\(String(format: "%02d", s.number))", strong: true)
                cell((s.shellPath as NSString).lastPathComponent)
                cell(s.cwd.map { PathResolver.abbreviate($0) } ?? "—", grow: true)
                if s.isBusy {
                    HStack(spacing: 5) {
                        Text("◆").font(.system(size: 7))
                        Text("RUN \(s.foregroundName ?? "")")
                    }
                    .font(GridFont.label).foregroundStyle(theme.accent)
                    .padding(.horizontal, 10)
                } else if s.exited {
                    cell("EXITED \(s.exitCode.map(String.init) ?? "")")
                } else {
                    cell("IDLE")
                }
                if s.columns > 0 { cell("\(s.columns)×\(s.rows)") }
            } else {
                cell("NO SESSION", grow: true)
            }
            Spacer(minLength: 0)
            if let n = app.notice {
                HStack(spacing: 6) {
                    Text(n.tone == .error ? "✕" : "✓")
                    // Ares text band: the notice types on behind a sweeping highlight.
                    TypeOnText(text: n.text, font: GridFont.small, color: n.tone == .error ? theme.danger : theme.ok, duration: 0.24)
                        .lineLimit(1)
                    if let label = n.actionLabel, let action = n.action {
                        Button(label) { app.notice = nil; action() }
                            .buttonStyle(GridButtonStyle(compact: true))
                    }
                }
                .font(GridFont.small)
                .foregroundStyle(n.tone == .error ? theme.danger : theme.ok)
                .padding(.horizontal, 10)
                .frame(maxHeight: .infinity)
                .background(n.tone == .error ? theme.danger.opacity(0.10) : theme.ok.opacity(0.08))
                .transition(.opacity)
                .accessibilityLabel((n.tone == .error ? "Error: " : "") + n.text)
            }
            #if DEBUG
            if DebugHooks.enabled {
                Text("△ QA HOOKS").font(GridFont.label).foregroundStyle(theme.warn)
                    .padding(.horizontal, 10).help("Debug build launched with --qa: local automation socket is open")
            }
            #endif
            cell("\(app.terminals.sessions.count) SESSION\(app.terminals.sessions.count == 1 ? "" : "S")")
            cell(app.settings.theme.label)
        }
        .frame(height: Metrics.statusHeight)
        .background(theme.bg0)
        .overlay(alignment: .top) { Rectangle().fill(theme.line).frame(height: Metrics.hairline) }
        .animation(.easeOut(duration: 0.15), value: app.notice)
    }

    private func cell(_ text: String, strong: Bool = false, grow: Bool = false) -> some View {
        Text(text)
            .font(strong ? GridFont.label : GridFont.small)
            .tracking(strong ? 1.2 : 0)
            .foregroundStyle(strong ? theme.accent : theme.textDim)
            .lineLimit(1).truncationMode(.head)
            .padding(.horizontal, 10)
            .frame(maxWidth: grow ? 520 : nil, alignment: .leading)
            .frame(maxHeight: .infinity)
            .overlay(alignment: .trailing) { Rectangle().fill(theme.line).frame(width: Metrics.hairline) }
    }
}

private struct ConfirmationOverlay: View {
    @Environment(AppState.self) private var app
    @Environment(\.theme) private var theme
    let confirmation: Confirmation
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text("△").foregroundStyle(theme.warn)
                    SectionLabel(confirmation.code, color: theme.warn)
                    TerminatedRule()
                }
                Text(confirmation.title).font(GridFont.title).foregroundStyle(theme.text)
                Text(confirmation.message).font(GridFont.body).foregroundStyle(theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Spacer()
                    Button(confirmation.cancelLabel) { dismiss(confirm: false) }
                        .keyboardShortcut(.cancelAction)
                        .buttonStyle(GridButtonStyle())
                    if let alt = confirmation.alternateLabel {
                        Button(alt) {
                            app.confirmation = nil
                            confirmation.onAlternate()
                        }
                        .buttonStyle(GridButtonStyle())
                    }
                    Button(confirmation.confirmLabel) { dismiss(confirm: true) }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(GridButtonStyle(prominent: true))
                }
            }
            .padding(18)
            .frame(width: 440)
            .background(theme.bg1)
            .clipShape(ClippedRect(cut: 10))
            .overlay(ClippedRect(cut: 10).stroke(theme.lineStrong, lineWidth: Metrics.hairline))
            .focusable()
            .focused($focused)
            .onAppear { focused = true }
        }
        .accessibilityAddTraits(.isModal)
    }

    private func dismiss(confirm: Bool) {
        app.confirmation = nil
        if confirm { confirmation.onConfirm() } else { confirmation.onCancel() }
        if app.panel == .terminal { app.focusTerminal() }
    }
}
