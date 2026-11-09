import AppKit
import GridCore
import SwiftUI

// MARK: - Card content

/// A third-party widget card: approval gate, then the rendered view tree.
struct CustomWidgetView: View {
    @Environment(AppState.self) private var app
    @Environment(\.theme) private var theme
    let widget: WidgetInstance
    private var runtime: WidgetRuntime { app.widgetLibrary.runtime(for: widget.id) }

    private var ref: String { widget.string("package", "") }
    private var settings: [String: String] {
        widget.config.reduce(into: [:]) { d, kv in if kv.key.hasPrefix("s.") { d[String(kv.key.dropFirst(2))] = kv.value } }
    }
    /// Everything that should (re)activate the runtime when it changes.
    private var activationKey: String {
        let lib = app.widgetLibrary
        return "\(ref)|\(lib.status(ref))|\(lib.generation[ref] ?? 0)|\(lib.entry(ref)?.package?.digest ?? "")|\(settings.sorted { $0.key < $1.key })|\(widget.expanded)"
    }

    var body: some View {
        let lib = app.widgetLibrary
        let status = lib.status(ref)
        VStack(alignment: .leading, spacing: 6) {
            switch status {
            case .missing:
                block("✕", theme.danger, "Widget not found", "Its package was removed from the Widgets folder.")
            case .invalid(let why):
                block("✕", theme.danger, "Can't load this widget", why)
            case .needsApproval, .changed:
                block("△", theme.warn, status == .changed ? "Widget changed" : "Needs your approval",
                      status == .changed ? "Its files or permissions changed since you approved it. Review before it runs again."
                                         : "Review what it can access before it runs.")
                Button("Review…") { WidgetApprovalRequest.review(ref, app: app) }
                    .buttonStyle(GridButtonStyle(prominent: true, compact: true))
            case .disabled:
                block("◇", theme.textMute, "Disabled", "Enable it in Settings › Widgets.")
            case .ready:
                content
            }
        }
        .onAppear {
            #if DEBUG
            runtime.registerForQA()
            #endif
            runtime.activate(app: app, ref: ref, settings: settings, expanded: widget.expanded)
        }
        .onChange(of: activationKey) { _, _ in runtime.activate(app: app, ref: ref, settings: settings, expanded: widget.expanded) }
        .onDisappear { runtime.deactivate() }
    }

    @ViewBuilder private var content: some View {
        switch runtime.phase {
        case .idle, .starting:
            if let t = runtime.tree { WidgetNodeView(node: t, perform: runtime.perform) }
            else { Text("Starting…").font(GridFont.small).foregroundStyle(theme.textMute) }
        case .running:
            if let t = runtime.tree { WidgetNodeView(node: t, perform: runtime.perform) }
            else { Text("Rendering…").font(GridFont.small).foregroundStyle(theme.textMute) }
        case .error(let e):
            if let t = runtime.tree { WidgetNodeView(node: t, perform: runtime.perform).opacity(0.5) }
            block("✕", theme.danger, "Widget error", e)
            Button("Reload") { runtime.restart() }.buttonStyle(GridButtonStyle(compact: true))
        case .suspended(let why):
            block("△", theme.warn, "Paused", why + " Restarting shortly.")
        case .stopped(let why):
            block("■", theme.warn, "Stopped after repeated problems", why)
            Button("Restart") { runtime.restart() }.buttonStyle(GridButtonStyle(compact: true))
        }
    }

    private func block(_ glyph: String, _ color: Color, _ title: String, _ message: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(glyph).font(GridFont.small).foregroundStyle(color)
                Text(title).font(GridFont.bodyStrong).foregroundStyle(theme.text)
            }
            Text(message).font(GridFont.small).foregroundStyle(theme.textDim).fixedSize(horizontal: false, vertical: true).lineLimit(6)
        }
        .padding(.leading, 6)
        .overlay(alignment: .leading) { Rectangle().fill(color).frame(width: 2) }
    }
}

// MARK: - Settings face

/// The manifest's settings, rendered natively. Secrets go to the Keychain and are never shown again.
struct CustomWidgetSettings: View {
    @Environment(AppState.self) private var app
    @Environment(\.theme) private var theme
    let widget: WidgetInstance

    var body: some View {
        let ref = widget.string("package", "")
        let lib = app.widgetLibrary
        let m = lib.entry(ref)?.package?.manifest
        VStack(alignment: .leading, spacing: 8) {
            if let m {
                Text("\(m.name) \(m.version)" + (m.author.map { " · \($0)" } ?? "")).font(GridFont.small).foregroundStyle(theme.textDim)
                ForEach(m.settings ?? [], id: \.key) { spec in
                    SettingField(spec: spec, ref: ref, widget: widget)
                }
                if (m.settings ?? []).isEmpty {
                    Text("This widget has no options.").font(GridFont.small).foregroundStyle(theme.textMute)
                }
            } else {
                Text("Package unavailable.").font(GridFont.small).foregroundStyle(theme.textMute)
            }
            HStack(spacing: 6) {
                Button("Permissions & Logs…") { app.show(.settings) }.buttonStyle(GridButtonStyle(compact: true))
            }
        }
    }
}

private struct SettingField: View {
    @Environment(AppState.self) private var app
    @Environment(\.theme) private var theme
    let spec: WidgetSettingSpec
    let ref: String
    let widget: WidgetInstance
    @State private var text = ""
    @State private var secretDraft = ""

    private var key: String { "s." + spec.key }
    private var current: String {
        widget.config[key] ?? app.widgetLibrary.entry(ref)?.package?.manifest.defaultSettings[spec.key] ?? ""
    }

    var body: some View {
        let store = app.widgets
        HStack(spacing: 8) {
            Text(spec.label).font(GridFont.small).foregroundStyle(theme.textDim).frame(width: 90, alignment: .leading).lineLimit(2)
            switch spec.type {
            case "bool":
                Toggle(isOn: Binding(get: { current == "true" }, set: { store.set(widget.id, key, $0 ? "true" : "false") })) { EmptyView() }
                    .toggleStyle(GridToggleStyle())
            case "choice":
                Picker("", selection: Binding(get: { current }, set: { store.set(widget.id, key, $0) })) {
                    ForEach(spec.options ?? [], id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().fixedSize()
            case "secret":
                let isSet = app.widgetLibrary.hasSecret(ref, spec.key)
                SecureField(isSet ? "•••••• (saved in Keychain)" : "Not set", text: $secretDraft)
                    .textFieldStyle(.plain).font(GridFont.small)
                    .padding(4).background(theme.bg1).overlay(Rectangle().stroke(theme.line, lineWidth: Metrics.hairline))
                    .onSubmit { save() }
                Button(secretDraft.isEmpty ? (isSet ? "Clear" : "Save") : "Save") {
                    if secretDraft.isEmpty && isSet { app.widgetLibrary.setSecret(ref, spec.key, nil) } else { save() }
                }
                .buttonStyle(GridButtonStyle(compact: true))
                .help("Only sent to " + (spec.hosts ?? []).joined(separator: ", ") + ". The widget's script never sees it.")
            default:
                TextField("", text: $text)
                    .textFieldStyle(.plain).font(GridFont.small)
                    .padding(4).background(theme.bg1).overlay(Rectangle().stroke(theme.line, lineWidth: Metrics.hairline))
                    .onAppear { text = current }
                    .onSubmit { commit() }
                    .onChange(of: text) { _, _ in commit() }
            }
        }
    }

    private func save() {
        guard !secretDraft.isEmpty else { return }
        app.widgetLibrary.setSecret(ref, spec.key, secretDraft)
        secretDraft = ""
        app.widgets.set(widget.id, "s.__secrets", UUID().uuidString)   // re-render with the new value
    }

    private func commit() {
        guard let v = spec.normalize(text), v != current else { return }
        app.widgets.set(widget.id, key, v)
    }
}

// MARK: - Gallery section

struct CustomWidgetGallery: View {
    @Environment(AppState.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        let lib = app.widgetLibrary
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                SectionLabel("your widgets", color: theme.accent)
                TerminatedRule()
            }
            .padding(.top, 8)
            ForEach(lib.entries) { e in
                HStack(spacing: 8) {
                    Image(systemName: "puzzlepiece.extension").font(.system(size: 11)).foregroundStyle(theme.accent).frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            Text(e.name.uppercased()).font(GridFont.label).tracking(1.2).foregroundStyle(theme.text).lineLimit(1)
                            Tag(e.isDev ? "DEV" : "3RD", color: e.isDev ? theme.warn : theme.textMute)
                        }
                        Text(e.package?.manifest.description ?? e.error ?? "").font(GridFont.small).foregroundStyle(e.error == nil ? theme.textDim : theme.danger)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                    Button("+") { add(e) }.buttonStyle(.plain).font(GridFont.bodyStrong).foregroundStyle(theme.accent)
                        .disabled(e.package == nil).help("Add to deck")
                }
                .padding(.vertical, 4).padding(.horizontal, 6)
            }
            HStack(spacing: 6) {
                Button("New Widget…") { WidgetActions.newWidget(app) }
                Button("Install…") { WidgetActions.install(app) }
                Button("Manage…") { app.show(.settings) }
            }
            .buttonStyle(GridButtonStyle(compact: true))
            .padding(.top, 4)
        }
    }

    private func add(_ e: WidgetLibrary.Entry) {
        let id = app.widgets.add(.custom, config: ["package": e.ref])
        _ = id
        if app.widgetLibrary.status(e.ref) != .ready { WidgetApprovalRequest.review(e.ref, app: app) }
    }
}

// MARK: - Install / New

@MainActor
enum WidgetActions {
    static func newWidget(_ app: AppState) {
        do {
            let ref = try app.widgetLibrary.scaffold(name: "My Widget")
            _ = app.widgets.add(.custom, config: ["package": ref])
            app.deckVisible = true
            if let folder = app.widgetLibrary.entry(ref)?.folder {
                app.flash(.info, "Created \(folder.lastPathComponent). Edit widget.js; GRID reloads on save.", actionLabel: "Reveal") {
                    NSWorkspace.shared.activateFileViewerSelecting([folder.appendingPathComponent("widget.js")])
                }
            }
        } catch {
            app.flash(.error, "Couldn't create a widget: \(error.localizedDescription)")
        }
    }

    static func install(_ app: AppState) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Review"
        panel.message = "Choose a widget folder (it contains manifest.json). Nothing runs until you approve it."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        switch WidgetLibrary.inspect(url) {
        case .failure(let e):
            app.flash(.error, (e as? WidgetPackage.LoadError)?.description ?? e.localizedDescription)
        case .success(let pkg):
            app.widgetApproval = WidgetApprovalRequest(package: pkg, isDev: false, installing: true) { [weak app] in
                guard let app else { return }
                do {
                    let ref = try app.widgetLibrary.install(pkg)
                    if !app.widgets.widgets.contains(where: { $0.string("package", "") == ref }) {
                        _ = app.widgets.add(.custom, config: ["package": ref])
                    }
                    app.deckVisible = true
                    app.flash(.info, "Installed \(pkg.manifest.name)")
                } catch {
                    app.flash(.error, "Install failed: \(error.localizedDescription)")
                }
            }
        }
    }
}

// MARK: - Approval

struct WidgetApprovalRequest: Identifiable {
    let id = UUID()
    let package: WidgetPackage
    let isDev: Bool
    var installing = false
    let onApprove: () -> Void

    @MainActor static func review(_ ref: String, app: AppState) {
        guard let e = app.widgetLibrary.entry(ref), let p = e.package else { return }
        app.widgetApproval = WidgetApprovalRequest(package: p, isDev: e.isDev) { [weak app] in app?.widgetLibrary.approve(ref, reviewedDigest: p.digest) }
    }
}

/// "Allow this widget?" — drawn by GRID itself (never inside a card), listing exactly what the
/// widget can do, most sensitive first, with a tier mark for every command.
struct WidgetApprovalOverlay: View {
    @Environment(AppState.self) private var app
    @Environment(\.theme) private var theme
    let request: WidgetApprovalRequest

    var body: some View {
        let m = request.package.manifest
        let lines = WidgetPermissionText.lines(m.permissions, settings: m.settings ?? [])
        let warnings = WidgetPermissionText.warnings(m)
        let secrets = (m.settings ?? []).filter { $0.type == "secret" }
        let worst = lines.map(\.risk).max() ?? 0
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text("◇").foregroundStyle(theme.accent)
                    SectionLabel("WIDGET.APPROVE", color: theme.accent)
                    TerminatedRule()
                    Tag(request.isDev ? "DEV" : "3RD", color: request.isDev ? theme.warn : theme.textMute)
                }
                Text("Allow “\(m.name)”?").font(GridFont.title).foregroundStyle(theme.text)
                Text("\(m.version) · \(m.author ?? "unknown author") · \(m.id)").font(GridFont.small).foregroundStyle(theme.textMute)
                    .lineLimit(1).truncationMode(.middle)
                if let d = m.description { Text(d).font(GridFont.small).foregroundStyle(theme.textDim).lineLimit(3) }
                if request.installing, FileManager.default.fileExists(atPath: WidgetLibrary.installedDir.appendingPathComponent(m.id).path) {
                    Text("△ Replaces the installed widget with this id. If it's a different package, its saved data and secrets are cleared.")
                        .font(GridFont.small).foregroundStyle(theme.warn).fixedSize(horizontal: false, vertical: true)
                }
                TerminatedRule()
                SectionLabel(lines.isEmpty ? "no access" : "it will be able to")
                // Sized to its content; scrolls only when the list is long.
                ViewThatFits(in: .vertical) {
                    capabilityList(lines: lines, secrets: secrets, warnings: warnings)
                    ScrollView { capabilityList(lines: lines, secrets: secrets, warnings: warnings) }
                }
                .frame(maxHeight: 300)
                Text("Commands run without a shell in a sandbox (no network or file writes unless listed); commands that change things run only after a click. Copying, opening links or files, and inserting paths happen only when you click. Widgets can't type into your terminal or read its contents. "
                     + (request.isDev ? "Code edits reload; new permissions ask again." : "Any change to its files will ask again."))
                    .font(.system(size: 9.5, design: .monospaced)).foregroundStyle(theme.textMute).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Text(request.package.folder.path).font(.system(size: 9, design: .monospaced)).foregroundStyle(theme.textMute)
                        .lineLimit(1).truncationMode(.head)
                    Spacer()
                    Button("Cancel") { app.widgetApproval = nil }
                        .keyboardShortcut(.cancelAction).buttonStyle(GridButtonStyle())
                    Button(worst == 2 ? "Approve Anyway" : (request.installing ? "Install" : "Approve")) {
                        app.widgetApproval = nil
                        request.onApprove()
                    }
                    .buttonStyle(GridButtonStyle(prominent: worst < 2))
                }
            }
            .padding(18)
            .frame(width: 520)
            .background(theme.bg1)
            .clipShape(ClippedRect(cut: 10))
            .overlay(ClippedRect(cut: 10).stroke(worst == 2 ? theme.warn : theme.lineStrong, lineWidth: Metrics.hairline))
        }
        .accessibilityAddTraits(.isModal)
    }

    private func capabilityList(lines: [(risk: Int, text: String)], secrets: [WidgetSettingSpec], warnings: [String]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if lines.isEmpty {
                Text("Nothing beyond drawing its card: no files, terminal, commands or network.")
                    .font(GridFont.small).foregroundStyle(theme.textDim)
            }
            ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(l.risk == 2 ? "✕" : (l.risk == 1 ? "△" : "·")).font(GridFont.small)
                        .foregroundStyle(l.risk == 2 ? theme.danger : (l.risk == 1 ? theme.warn : theme.textMute))
                        .frame(width: 10)
                    Text(l.text).font(GridFont.small).foregroundStyle(theme.text).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            ForEach(secrets, id: \.key) { s in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("·").font(GridFont.small).foregroundStyle(theme.textMute).frame(width: 10)
                    Text("Use the secret “\(s.label)” only in requests to \((s.hosts ?? []).joined(separator: ", ")) (stored in your Keychain; the script never sees it)")
                        .font(GridFont.small).foregroundStyle(theme.text).fixedSize(horizontal: false, vertical: true)
                }
            }
            if !warnings.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(warnings, id: \.self) { w in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("△").font(GridFont.small).foregroundStyle(theme.warn).frame(width: 10)
                            Text(w).font(GridFont.small).foregroundStyle(theme.warn).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Settings › Widgets

struct WidgetsSettingsSection: View {
    @Environment(AppState.self) private var app
    @Environment(\.theme) private var theme
    @State private var logsFor: String?

    var body: some View {
        let lib = app.widgetLibrary
        VStack(alignment: .leading, spacing: 10) {
            Text("Widgets are folders with a manifest and JavaScript. They run in a separate sandboxed process and can only use what you approve. See docs/WIDGETS.md.")
                .font(GridFont.small).foregroundStyle(theme.textMute).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Button("New Widget…") { WidgetActions.newWidget(app) }
                Button("Install…") { WidgetActions.install(app) }
                Button("Open Widgets Folder") { NSWorkspace.shared.open(WidgetLibrary.widgetsDir) }
            }
            .buttonStyle(GridButtonStyle(compact: true))
            if lib.entries.isEmpty {
                Text("No widget packages yet.").font(GridFont.small).foregroundStyle(theme.textDim)
            }
            ForEach(lib.entries) { e in row(e, lib) }
        }
    }

    private func row(_ e: WidgetLibrary.Entry, _ lib: WidgetLibrary) -> some View {
        let status = lib.status(e.ref)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Tag(e.isDev ? "DEV" : "3RD", color: e.isDev ? theme.warn : theme.textMute)
                Text(e.name).font(GridFont.bodyStrong).foregroundStyle(theme.text)
                if let m = e.package?.manifest { Text("\(m.version) · \(m.id)").font(GridFont.small).foregroundStyle(theme.textMute).lineLimit(1) }
                Spacer()
                Text(label(status)).font(GridFont.label).tracking(1.2).foregroundStyle(color(status))
            }
            if let err = e.error { Text("✕ " + err).font(GridFont.small).foregroundStyle(theme.danger).fixedSize(horizontal: false, vertical: true) }
            if let p = e.package, status == .ready || status == .disabled {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(WidgetPermissionText.lines(p.manifest.permissions, settings: p.manifest.settings ?? []).enumerated()), id: \.offset) { _, l in
                        Text((l.risk == 2 ? "✕ " : (l.risk == 1 ? "△ " : "· ")) + l.text).font(GridFont.small)
                            .foregroundStyle(l.risk == 0 ? theme.textDim : (l.risk == 1 ? theme.warn : theme.danger))
                    }
                }
            }
            HStack(spacing: 6) {
                switch status {
                case .needsApproval, .changed: Button("Review…") { WidgetApprovalRequest.review(e.ref, app: app) }
                case .ready: Button("Disable") { lib.setDisabled(e.ref, true) }
                case .disabled: Button("Enable") { lib.setDisabled(e.ref, false) }
                default: EmptyView()
                }
                if e.package != nil && !app.widgets.widgets.contains(where: { $0.string("package", "") == e.ref }) {
                    Button("Add to Deck") { _ = app.widgets.add(.custom, config: ["package": e.ref]); app.deckVisible = true }
                }
                Button(logsFor == e.ref ? "Hide Logs" : "Logs (\(lib.logs[e.ref]?.count ?? 0))") { logsFor = logsFor == e.ref ? nil : e.ref }
                Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([e.folder]) }
                if status == .ready { Button("Revoke") { lib.revoke(e.ref) } }
                Button("Remove…") {
                    _ = app.present(Confirmation(code: "WIDGET.REMOVE", title: "Remove “\(e.name)”?",
                                                 message: "Moves its folder to the Trash and deletes its saved data and Keychain secrets.",
                                                 confirmLabel: "Remove", destructive: true, onConfirm: {
                        for w in app.widgets.widgets where w.string("package", "") == e.ref { app.widgets.remove(w.id) }
                        lib.remove(e.ref)
                    }))
                }
            }
            .buttonStyle(GridButtonStyle(compact: true))
            if logsFor == e.ref { WidgetLogView(ref: e.ref) }
        }
        .padding(10)
        .background(theme.bg2.opacity(0.4))
        .overlay(Rectangle().stroke(theme.line, lineWidth: Metrics.hairline))
    }

    private func label(_ s: WidgetLibrary.Status) -> String {
        switch s {
        case .ready: "✓ APPROVED"; case .needsApproval: "△ NEEDS APPROVAL"; case .changed: "△ CHANGED"
        case .disabled: "■ DISABLED"; case .invalid: "✕ INVALID"; case .missing: "✕ MISSING"
        }
    }

    private func color(_ s: WidgetLibrary.Status) -> Color {
        switch s {
        case .ready: theme.ok; case .needsApproval, .changed, .disabled: theme.warn; case .invalid, .missing: theme.danger
        }
    }
}

private struct WidgetLogView: View {
    @Environment(AppState.self) private var app
    @Environment(\.theme) private var theme
    let ref: String

    var body: some View {
        let lines = app.widgetLibrary.logs[ref] ?? []
        VStack(alignment: .leading, spacing: 4) {
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    if lines.isEmpty { Text("No output yet.").foregroundStyle(theme.textMute) }
                    ForEach(lines.suffix(200)) { l in
                        Text(Self.time.string(from: l.date) + "  " + l.text)
                            .foregroundStyle(l.level == "error" ? theme.danger : (l.level == "warn" ? theme.warn : theme.textDim))
                            .textSelection(.enabled)
                    }
                }
                .font(.system(size: 10, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 140)
            .padding(6).background(theme.bg0)
            .overlay(Rectangle().stroke(theme.line, lineWidth: Metrics.hairline))
            Button("Clear") { app.widgetLibrary.clearLogs(ref) }.buttonStyle(GridButtonStyle(compact: true))
        }
    }

    static let time: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()
}
