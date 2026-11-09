import AppKit
import GridCore
import SwiftUI

struct SettingsPanel: View {
    @Environment(AppState.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        @Bindable var s = app.settings
        Panel(index: "05", title: "Settings", suffix: "sys") {
            Text("stored locally · UserDefaults").font(GridFont.small).foregroundStyle(theme.textMute)
        } content: {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    group("05.1", "Appearance") {
                        HStack(spacing: 10) {
                            ForEach(ThemeID.allCases) { t in ThemeCard(id: t, selected: s.theme == t) { app.setTheme(t) } }
                        }
                    }
                    group("05.2", "Effects") {
                        toggle("Edge glow on focused panels", $s.glow)
                        toggle("Motion (transitions)", $s.motion,
                               note: s.reduceMotion ? "Off: macOS Reduce Motion is enabled." : nil)
                        toggle("Grid backdrop (static, very faint)", $s.gridBackdrop)
                        Text("No scanlines, flicker, or boot sequences. Everything works with all effects off.")
                            .font(GridFont.small).foregroundStyle(theme.textMute)
                    }
                    group("05.3", "Terminal") {
                        row("Font") {
                            Picker("", selection: $s.terminalFontName) {
                                Text("System Monospaced (SF Mono)").tag("")
                                ForEach(Settings.monospaceFamilies, id: \.self) { Text($0).tag($0) }
                            }
                            .labelsHidden().frame(width: 260)
                        }
                        row("Size") {
                            Stepper(value: $s.terminalFontSize, in: 9...28, step: 1) {
                                Text("\(Int(s.terminalFontSize)) pt").font(GridFont.body).foregroundStyle(theme.text)
                            }
                        }
                        toggle("Option key sends Meta (Esc+)", $s.optionAsMeta,
                               note: "Off lets Option type special characters (é, ∑).")
                        toggle("Confirm before closing a session with a running program", $s.confirmCloseBusy)
                        row("Scrollback") {
                            Picker("", selection: $s.scrollback) {
                                ForEach([1_000, 5_000, 10_000, 50_000, 100_000], id: \.self) { Text("\($0.formatted()) lines").tag($0) }
                            }.labelsHidden().frame(width: 160)
                            Text("applies to new sessions").font(GridFont.small).foregroundStyle(theme.textMute)
                        }
                        ShellRow()
                    }
                    .onChange(of: s.terminalFontName) { _, _ in app.terminals.applyAppearance() }
                    .onChange(of: s.terminalFontSize) { _, _ in app.terminals.applyAppearance() }
                    .onChange(of: s.optionAsMeta) { _, _ in app.terminals.applyAppearance() }

                    group("05.4", "Keyboard") {
                        row("Command palette") {
                            Picker("", selection: $s.paletteShortcut) {
                                ForEach(PaletteShortcut.allCases) { Text($0.label).tag($0) }
                            }.labelsHidden().frame(width: 140)
                            if s.paletteShortcut == .cmdK {
                                Text("⌘K no longer clears the terminal").font(GridFont.small).foregroundStyle(theme.warn)
                            }
                        }
                        ShortcutTable()
                    }
                    group("05.5", "Privacy & permissions") {
                        VStack(alignment: .leading, spacing: 6) {
                            bullet("No telemetry, accounts, cloud services, or AI features. Nothing leaves this Mac.")
                            bullet("Terminal contents and paths are not logged or stored by GRID (scrollback lives in memory only).")
                            bullet("GRID is not sandboxed: like Terminal.app, a shell must reach your files. macOS still asks before any process started here reads Desktop, Documents, Downloads, removable volumes, etc.")
                            bullet("Full Disk Access is optional and only needed if you want shell tools to read protected data (e.g. Mail). Grant it yourself in System Settings if you choose.")
                        }
                        HStack {
                            Button("Open Privacy & Security") {
                                if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") { NSWorkspace.shared.open(u) }
                            }
                        }.buttonStyle(GridButtonStyle(compact: true))
                    }
                    group("05.6", "About") {
                        Text("GRID \(GridInfo.version) · terminal: SwiftTerm (MIT) · see LICENSES.md")
                            .font(GridFont.small).foregroundStyle(theme.textDim)
                    }
                }
                .padding(16)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func group<C: View>(_ index: String, _ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(index).font(GridFont.label).foregroundStyle(theme.accent)
                SectionLabel(title, color: theme.text)
                TerminatedRule()
            }
            content().padding(.leading, 4)
        }
    }

    private func row<C: View>(_ label: String, @ViewBuilder _ c: () -> C) -> some View {
        HStack(spacing: 12) {
            Text(label).font(GridFont.body).foregroundStyle(theme.textDim).frame(width: 150, alignment: .leading)
            c()
            Spacer()
        }
    }

    private func toggle(_ label: String, _ b: Binding<Bool>, note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(isOn: b) { Text(label).font(GridFont.body).foregroundStyle(theme.text) }
                .toggleStyle(GridToggleStyle())
            if let note { Text(note).font(GridFont.small).foregroundStyle(theme.textMute).padding(.leading, 30) }
        }
    }

    private func bullet(_ t: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("▪").foregroundStyle(theme.accent)
            Text(t).foregroundStyle(theme.textDim).fixedSize(horizontal: false, vertical: true)
        }.font(GridFont.small)
    }
}

/// Square check-style toggle: [■] on / [ ] off, plus the label (state is shape + text, not color only).
struct GridToggleStyle: ToggleStyle {
    @Environment(\.theme) private var theme
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 10) {
                ZStack {
                    Rectangle().stroke(configuration.isOn ? theme.lineStrong : theme.line, lineWidth: Metrics.hairline)
                    if configuration.isOn { Rectangle().fill(theme.accent).padding(3) }
                }
                .frame(width: 14, height: 14)
                configuration.label
                Text(configuration.isOn ? "ON" : "OFF").font(GridFont.label)
                    .foregroundStyle(configuration.isOn ? theme.accent : theme.textMute)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? "on" : "off")
    }
}

private struct ThemeCard: View {
    let id: ThemeID
    let selected: Bool
    let action: () -> Void

    var body: some View {
        let t = Theme.make(id)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Rectangle().fill(t.accent).frame(width: 18, height: 6)
                    Rectangle().fill(t.accent.opacity(0.4)).frame(width: 8, height: 6)
                    Spacer()
                    if selected { Text("ACTIVE").font(GridFont.label).foregroundStyle(t.accent) }
                }
                Text("~/grid $ ls").font(GridFont.small).foregroundStyle(t.text)
                Text("README.md  src/").font(GridFont.small).foregroundStyle(t.textDim)
                Text(id.label).font(GridFont.label).tracking(1.2).foregroundStyle(selected ? t.accent : t.textDim)
            }
            .padding(10)
            .frame(width: 170, alignment: .leading)
            .background(t.bg1)
            .clipShape(ClippedRect(cut: 7))
            .overlay(ClippedRect(cut: 7).stroke(selected ? t.lineStrong : t.line, lineWidth: selected ? 1.5 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Theme \(id.label)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct ShellRow: View {
    @Environment(AppState.self) private var app
    @Environment(\.theme) private var theme
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        let s = app.settings
        let resolved = ShellEnvironment.resolveShell(override: s.shellOverride)
        let invalid = !draft.isEmpty && !FileManager.default.isExecutableFile(atPath: draft)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Text("Shell").font(GridFont.body).foregroundStyle(theme.textDim).frame(width: 150, alignment: .leading)
                GridField(placeholder: "default: your login shell", text: $draft, focus: $focused) {
                    if !invalid { s.shellOverride = draft }
                }
                .frame(width: 260)
                Button("Apply") { if !invalid { s.shellOverride = draft } }
                    .buttonStyle(GridButtonStyle(compact: true)).disabled(invalid)
            }
            Text(invalid ? "✕ not an executable file" : "using \(resolved) as a login shell · applies to new sessions")
                .font(GridFont.small).foregroundStyle(invalid ? theme.danger : theme.textMute)
                .padding(.leading, 162)
        }
        .onAppear { draft = s.shellOverride }
    }
}

private struct ShortcutTable: View {
    @Environment(AppState.self) private var app
    @Environment(\.theme) private var theme
    var body: some View {
        let rows: [(String, String)] = [
            (app.settings.paletteShortcut.label, "Command palette"),
            ("⌘T / ⌘W", "New / close terminal session"),
            ("⌘1 … ⌘9", "Select terminal session"),
            ("⇧⌘[ / ⇧⌘]", "Previous / next session"),
            ("⌥⌘1 … ⌥⌘4", "Terminal · Files · Apps · Web"),
            ("⌘B / ⌘I", "Files sidebar / inspector"),
            ("⌥⌘T", "Open terminal in current Files folder"),
            ("⇧⌘J", "Show terminal directory in Files"),
            ("⌘[ ⌘] ⌘↑", "Files: back · forward · up"),
            ("⌘L / ⌘F", "Files: edit path / filter"),
            ("⇧⌘.", "Show hidden files"),
            ("⌘C / ⌘V", "Copy / paste (terminal selection)"),
        ]
        VStack(alignment: .leading, spacing: 3) {
            ForEach(rows, id: \.1) { k, v in
                HStack(spacing: 12) {
                    KeyCap(k).frame(width: 150, alignment: .leading)
                    Text(v).font(GridFont.small).foregroundStyle(theme.textDim)
                }
            }
        }
    }
}
