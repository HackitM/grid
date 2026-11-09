import AppKit
import GridCore
import SwiftUI

struct PaletteItem: Identifiable {
    let id: String
    let section: String
    let title: String
    var subtitle: String = ""
    var glyph: String = "›"
    var icon: NSImage? = nil
    var shortcut: String = ""
    var enabled = true
    let action: () -> Void
}

/// Builds palette results. Application commands only: nothing here is ever sent to a shell.
@MainActor
enum PaletteBuilder {
    static func commands(_ app: AppState) -> [PaletteItem] {
        var c: [PaletteItem] = [
            .init(id: "new-term", section: "COMMAND", title: "New Terminal Session", glyph: "+", shortcut: "⌘T") { app.newTerminal() },
            .init(id: "go-term", section: "COMMAND", title: "Go to Terminal", glyph: "01", shortcut: "⌥⌘1") { app.show(.terminal); app.focusTerminal() },
            .init(id: "go-files", section: "COMMAND", title: "Go to Files", glyph: "02", shortcut: "⌥⌘2") { app.show(.files) },
            .init(id: "go-apps", section: "COMMAND", title: "Go to Applications", glyph: "03", shortcut: "⌥⌘3") { app.show(.apps) },
            .init(id: "go-web", section: "COMMAND", title: "Go to Web", glyph: "04", shortcut: "⌥⌘4") { app.show(.web) },
            .init(id: "settings", section: "COMMAND", title: "Settings", glyph: "05", shortcut: "⌘,") { app.show(.settings) },
            .init(id: "cwd-files", section: "COMMAND", title: "Show Terminal Directory in Files", subtitle: app.terminals.active?.cwd.map { PathResolver.abbreviate($0) } ?? "", glyph: "⇄", shortcut: "⇧⌘J") { app.revealTerminalDirectoryInFiles() },
            .init(id: "term-here", section: "COMMAND", title: "Open Terminal Here", subtitle: PathResolver.abbreviate(app.files.currentURL.path), glyph: "⇄", shortcut: "⌥⌘T") { app.openTerminalHere() },
            .init(id: "sidebar", section: "COMMAND", title: "Toggle Files Sidebar", glyph: "▤", shortcut: "⌘B") { app.filesSidebar.toggle() },
            .init(id: "inspector", section: "COMMAND", title: "Toggle Inspector", glyph: "▥", shortcut: "⌘I") { app.inspectorVisible.toggle() },
            .init(id: "hidden", section: "COMMAND", title: app.files.showHidden ? "Hide Hidden Files" : "Show Hidden Files", glyph: "◌", shortcut: "⇧⌘.") { app.files.showHidden.toggle() },
            .init(id: "rescan", section: "COMMAND", title: "Rescan Applications", glyph: "↻") { app.apps.rescan(); app.flash(.info, "Rescanning applications") },
            .init(id: "copy-cwd", section: "COMMAND", title: "Copy Terminal Directory Path", glyph: "⧉") {
                if let d = app.terminals.active?.cwd { app.files.copyPaths([URL(fileURLWithPath: d)]); app.flash(.info, "Copied \(PathResolver.abbreviate(d))") }
            },
            .init(id: "fx-glow", section: "COMMAND", title: app.settings.glow ? "Disable Glow" : "Enable Glow", glyph: "✧") { app.settings.glow.toggle() },
            .init(id: "fx-motion", section: "COMMAND", title: app.settings.motion ? "Disable Motion" : "Enable Motion", glyph: "≈") { app.settings.motion.toggle() },
            .init(id: "fx-grid", section: "COMMAND", title: app.settings.gridBackdrop ? "Hide Grid Backdrop" : "Show Grid Backdrop", glyph: "#") { app.settings.gridBackdrop.toggle() },
        ]
        for t in ThemeID.allCases {
            c.append(.init(id: "theme-\(t.rawValue)", section: "COMMAND", title: "Theme: \(t.label)", glyph: t == app.settings.theme ? "●" : "○") { app.setTheme(t) })
        }
        for s in app.terminals.sessions {
            c.append(.init(id: "session-\(s.id)", section: "SESSION", title: "Session \(String(format: "%02d", s.number)) · \(s.displayTitle)",
                           subtitle: s.cwd.map { PathResolver.abbreviate($0) } ?? "", glyph: s.isBusy ? "◆" : "▸") {
                app.terminals.select(s.id); app.show(.terminal); app.focusTerminal()
            })
        }
        return c
    }

    static func appItems(_ app: AppState, _ q: String, limit: Int) -> [PaletteItem] {
        app.apps.ranked(q).prefix(limit).map { r in
            PaletteItem(id: "app-\(r.path)", section: "LAUNCH", title: r.name,
                        subtitle: app.apps.disambiguators[r.path] ?? (r.bundleID ?? ""), icon: app.apps.icon(for: r.path)) {
                app.apps.launch(r)
            }
        }
    }

    static func pathItems(_ app: AppState, _ raw: String, terminalOnly: Bool = false) -> [PaletteItem] {
        guard let url = PathResolver.resolve(raw, relativeTo: app.files.currentURL) else { return [] }
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        let shown = PathResolver.abbreviate(url.path)
        guard exists else {
            return [PaletteItem(id: "path-missing", section: "PATH", title: "No such file or folder", subtitle: shown, glyph: "✕", enabled: false) {}]
        }
        let folder = isDir.boolValue ? url : url.deletingLastPathComponent()
        var items: [PaletteItem] = []
        if !terminalOnly {
            items.append(PaletteItem(id: "path-files", section: "PATH", title: isDir.boolValue ? "Show Folder in Files" : "Show File in Files", subtitle: shown, glyph: "▸") {
                if isDir.boolValue { app.files.navigate(to: url) } else { app.files.navigate(to: folder); app.files.selectionID = url.path }
                app.show(.files)
            })
        }
        items.append(PaletteItem(id: "path-term", section: "PATH", title: "New Terminal Session Here", subtitle: PathResolver.abbreviate(folder.path), glyph: "+") {
            app.newTerminal(at: folder.path)
        })
        if !isDir.boolValue && !terminalOnly {
            items.append(PaletteItem(id: "path-open", section: "PATH", title: "Open with Default App", subtitle: shown, glyph: "↗") { app.files.open(url) })
        }
        return items
    }

    static func webItems(_ app: AppState, _ raw: String) -> [PaletteItem] {
        guard let url = WebAddress.normalize(raw) else {
            return [PaletteItem(id: "web-bad", section: "WEB", title: "Not an http(s) address", subtitle: raw, glyph: "✕", enabled: false) {}]
        }
        return [PaletteItem(id: "web-open", section: "WEB", title: "Open in Default Browser", subtitle: url.absoluteString, glyph: "↗") {
            app.openURL(url.absoluteString)
        }]
    }

    static func build(_ app: AppState, query: String) -> [PaletteItem] {
        switch PaletteGrammar.parse(query) {
        case .app(let q): return appItems(app, q, limit: 12)
        case .files(let p): return pathItems(app, p)
        case .term(let p): return pathItems(app, p, terminalOnly: true)
        case .web(let u): return webItems(app, u)
        case .theme(let t):
            return ThemeID.allCases.filter { FuzzyMatch.score(t, in: $0.rawValue + " " + $0.label) != nil }.map { th in
                PaletteItem(id: "theme-\(th.rawValue)", section: "THEME", title: th.label, glyph: th == app.settings.theme ? "●" : "○") { app.setTheme(th) }
            }
        case .freeText(let q):
            let all = commands(app)
            if q.isEmpty { return all }
            var out: [PaletteItem] = []
            if PaletteGrammar.looksLikePath(q) { out += pathItems(app, q) }
            if WebAddress.normalize(q) != nil, !PaletteGrammar.looksLikePath(q) { out += webItems(app, q) }
            let scored = all.compactMap { i -> (PaletteItem, Int)? in
                FuzzyMatch.score(q, in: i.title).map { (i, $0) }
            }.sorted { $0.1 > $1.1 }.map(\.0)
            out += scored.prefix(8)
            out += appItems(app, q, limit: 6)
            return out
        }
    }
}

struct CommandPalette: View {
    @Environment(AppState.self) private var app
    @Environment(\.theme) private var theme
    @Environment(\.effects) private var effects
    @State private var query = ""
    @State private var selected = 0
    @State private var appeared = false
    @FocusState private var focused: Bool

    var body: some View {
        let items = PaletteBuilder.build(app, query: query)
        VStack(spacing: 0) {
            // Header: Ares-style double rule with terminators + label.
            HStack(spacing: 8) {
                SectionLabel("grid // command", color: theme.accent)
                TerminatedRule(strong: true)
                SectionLabel("esc")
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8)
            .scaleEffect(x: appeared || !effects.motion ? 1 : 0.4, y: 1, anchor: .leading)

            HStack(spacing: 8) {
                Text("[GRID]>>").font(GridFont.bodyStrong).foregroundStyle(theme.accent)
                TextField("", text: $query, prompt: Text("command, app, path, or web address").foregroundStyle(theme.textMute))
                    .textFieldStyle(.plain)
                    .font(GridFont.mono(14))
                    .foregroundStyle(theme.text)
                    .focused($focused)
                    .onSubmit { run(items) }
                    .onKeyPress(.downArrow) { move(1, items.count); return .handled }
                    .onKeyPress(.upArrow) { move(-1, items.count); return .handled }
                    .onExitCommand { close() }
            }
            .padding(.horizontal, 12).padding(.bottom, 6)
            HStack(spacing: 10) {
                ForEach(["app ‹name›", "files ‹path›", "term ‹path›", "web ‹url›", "theme ‹name›"], id: \.self) { hint in
                    Text(hint).font(GridFont.small).foregroundStyle(theme.textMute)
                }
                Spacer()
                Text("↑↓ ⏎").font(GridFont.small).foregroundStyle(theme.textMute)
            }
            .padding(.horizontal, 12).padding(.bottom, 8)
            Rectangle().fill(theme.line).frame(height: Metrics.hairline)

            if items.isEmpty {
                Text("No matching command, application, or path.")
                    .font(GridFont.small).foregroundStyle(theme.textMute)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                                if i == 0 || items[i - 1].section != item.section {
                                    SectionLabel(item.section, color: theme.textMute)
                                        .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 3)
                                }
                                PaletteRow(item: item, selected: i == selected)
                                    .id(i)
                                    .onTapGesture { selected = i; run(items) }
                            }
                        }
                        .padding(.bottom, 6)
                    }
                    .frame(maxHeight: 380)
                    .onChange(of: selected) { _, s in proxy.scrollTo(s) }
                }
            }
        }
        .frame(width: 640)
        .background(theme.bg1)
        .clipShape(ClippedRect(cut: 12, topRight: true, bottomLeft: true))
        .overlay(ClippedRect(cut: 12, topRight: true, bottomLeft: true)
            .stroke(theme.lineStrong, lineWidth: Metrics.hairline)
            .shadow(color: effects.glow ? theme.glow.opacity(0.5) : .clear, radius: 8))
        .shadow(color: .black.opacity(0.6), radius: 30, y: 10)
        .opacity(appeared || !effects.motion ? 1 : 0)
        .onAppear {
            focused = true
            withAnimation(effects.motion ? .easeOut(duration: 0.14) : nil) { appeared = true }
        }
        .onChange(of: query) { _, _ in selected = 0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Command palette")
    }

    private func move(_ d: Int, _ n: Int) {
        guard n > 0 else { return }
        selected = (selected + d + n) % n
    }

    private func run(_ items: [PaletteItem]) {
        guard items.indices.contains(selected), items[selected].enabled else { return }
        let action = items[selected].action
        close()
        action()
    }

    private func close() {
        app.paletteOpen = false
        if app.panel == .terminal { app.focusTerminal() }
    }
}

private struct PaletteRow: View {
    @Environment(\.theme) private var theme
    let item: PaletteItem
    let selected: Bool
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let icon = item.icon {
                    Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                } else {
                    Text(item.glyph).font(GridFont.label).foregroundStyle(selected ? theme.accent : theme.textMute)
                }
            }
            .frame(width: 22)
            Text(item.title)
                .font(GridFont.body)
                .foregroundStyle(item.enabled ? theme.text : theme.textMute)
                .lineLimit(1)
            if !item.subtitle.isEmpty {
                Text(item.subtitle).font(GridFont.small).foregroundStyle(theme.textMute)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if !item.shortcut.isEmpty { KeyCap(item.shortcut) }
        }
        .padding(.horizontal, 12)
        .frame(height: 26)
        .gridRowBackground(selected: selected, hovered: hover, theme: theme)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}
