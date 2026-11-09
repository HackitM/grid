import AppKit
import GridCore
import SwiftUI

struct AppsPanel: View {
    @Environment(AppState.self) private var app
    @Environment(\.theme) private var theme
    @State private var query = ""
    @State private var selection: String?
    @FocusState private var searchFocused: Bool

    private struct Section: Identifiable {
        let id: String
        let rows: [AppRecord]
    }

    private var sections: [Section] {
        let c = app.apps
        if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            return [Section(id: "results", rows: c.ranked(query))]
        }
        let pinned = c.favorites.compactMap { p in c.record(forPath: p) ?? missingRecord(p) }
        let recent = c.recents.filter { !c.favorites.contains($0) }.compactMap { c.record(forPath: $0) }.prefix(6)
        var out: [Section] = []
        if !pinned.isEmpty { out.append(Section(id: "pinned", rows: pinned)) }
        if !recent.isEmpty { out.append(Section(id: "recent", rows: Array(recent))) }
        out.append(Section(id: "all", rows: c.records))
        return out
    }

    private func missingRecord(_ path: String) -> AppRecord {
        AppRecord(name: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent, bundleID: nil, path: path, version: nil)
    }

    /// Flattened rows in display order, keyed "section/path" so an app can appear in two sections.
    private var flat: [(key: String, record: AppRecord)] {
        sections.flatMap { s in s.rows.map { ("\(s.id)/\($0.path)", $0) } }
    }

    var body: some View {
        let c = app.apps
        Panel(index: "03", title: "Applications", suffix: "launch", focused: searchFocused) {
            HStack(spacing: 8) {
                if c.scanning { ProgressView().controlSize(.mini).tint(theme.accent) }
                Text("\(c.records.count) found").font(GridFont.small).foregroundStyle(theme.textMute)
                IconButton(symbol: "arrow.clockwise", label: "Rescan applications (⌘R)") { c.rescan() }
                    .keyboardShortcut("r", modifiers: .command)
            }
        } content: {
            VStack(spacing: 0) {
                GridField(placeholder: "search applications — ↑↓ to move, ⏎ to launch", text: $query, prompt: "▶", focus: $searchFocused) {
                    launchSelected()
                }
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .onKeyPress(.pageDown) { move(10); return .handled }
                .onKeyPress(.pageUp) { move(-10); return .handled }
                .onExitCommand { query = "" }
                .padding(8)
                Rectangle().fill(theme.line).frame(height: Metrics.hairline)

                if c.records.isEmpty && !c.scanning {
                    StateBlock(tone: .warning, code: "NO.APPS", title: "No applications found",
                               message: "Scanned /Applications, /System/Applications, ~/Applications and CoreServices.") {
                        Button("Rescan") { c.rescan() }
                    }.padding(14)
                    Spacer()
                } else if flat.isEmpty {
                    StateBlock(code: "NO.MATCH", title: "No application matches “\(query)”",
                               message: "Search matches app names, word starts and initials (e.g. “vsc”).").padding(14)
                    Spacer()
                } else {
                    list
                }
            }
        }
        .onAppear {
            c.onError = { m in app.flash(.error, m) }
            DispatchQueue.main.async { searchFocused = true }
        }
        .onChange(of: query) { _, _ in
            CascadeClock.shared.start()
            selection = flat.first?.key
        }
        .onReceive(NotificationCenter.default.publisher(for: .gridFocusAppSearch)) { _ in searchFocused = true }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(sections) { s in
                        SwiftUI.Section {
                            ForEach(Array(s.rows.enumerated()), id: \.element.id) { i, r in
                                let key = "\(s.id)/\(r.path)"
                                AppRow(record: r, selected: selection == key,
                                       hint: app.apps.disambiguators[r.path],
                                       missing: app.apps.isMissing(r.path))
                                    .id(key)
                                    .cascadeIn(i)
                                    .onTapGesture(count: 2) { app.apps.launch(r) }
                                    .simultaneousGesture(TapGesture().onEnded { selection = key })
                                    .contextMenu { menu(r) }
                            }
                        } header: {
                            HStack {
                                SectionLabel(header(s), color: theme.accent)
                                Rectangle().fill(theme.line).frame(height: Metrics.hairline)
                            }
                            .padding(.horizontal, 10).frame(height: 22)
                            .background(theme.bg1)
                        }
                    }
                }
            }
            .onChange(of: selection) { _, k in if let k { proxy.scrollTo(k) } }
        }
    }

    private func header(_ s: Section) -> String {
        switch s.id {
        case "pinned": "Pinned · \(s.rows.count)"
        case "recent": "Recent"
        case "results": "Results · \(s.rows.count)"
        default: "All applications · A–Z"
        }
    }

    @ViewBuilder private func menu(_ r: AppRecord) -> some View {
        Button("Open") { app.apps.launch(r) }
        Button(app.apps.isFavorite(r) ? "Unpin" : "Pin") { app.apps.toggleFavorite(r) }
        Divider()
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([r.url]) }
        Button("Show in Files") { app.files.navigate(to: r.url.deletingLastPathComponent()); app.files.selectionID = r.path; app.show(.files) }
        Button("Copy Path") { app.files.copyPaths([r.url]) }
        if app.apps.isMissing(r.path) && app.apps.isFavorite(r) {
            Divider()
            Button("Remove Missing Pin") { app.apps.removeFavorite(path: r.path) }
        }
    }

    private func move(_ d: Int) {
        let keys = flat.map(\.key)
        guard !keys.isEmpty else { return }
        let i = keys.firstIndex { $0 == selection } ?? (d > 0 ? -1 : keys.count)
        selection = keys[max(0, min(keys.count - 1, i + d))]
    }

    private func launchSelected() {
        let rows = flat
        guard let r = rows.first(where: { $0.key == selection })?.record ?? rows.first?.record else { return }
        app.apps.launch(r)
    }
}

extension Notification.Name {
    static let gridFocusAppSearch = Notification.Name("grid.focusAppSearch")
}

private struct AppRow: View {
    @Environment(AppState.self) private var app
    @Environment(\.theme) private var theme
    let record: AppRecord
    let selected: Bool
    let hint: String?
    let missing: Bool
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: app.apps.icon(for: record.path))
                .resizable().frame(width: 18, height: 18)
                .opacity(missing ? 0.3 : 1)
                .saturation(selected ? 1 : 0.85)
            Text(record.name)
                .font(GridFont.ui)
                .foregroundStyle(missing ? theme.textMute : theme.text)
                .lineLimit(1)
            if let hint { Text(hint).font(GridFont.small).foregroundStyle(theme.textMute).lineLimit(1) }
            if missing { Tag("missing", color: theme.warn) }
            Spacer()
            if app.apps.isFavorite(record) {
                Text("◆ PIN").font(GridFont.label).foregroundStyle(theme.accent)
            }
            Text(record.bundleID ?? "").font(GridFont.small).foregroundStyle(theme.textMute)
                .lineLimit(1).frame(maxWidth: 220, alignment: .trailing)
            Button {
                app.apps.toggleFavorite(record)
            } label: {
                Image(systemName: app.apps.isFavorite(record) ? "pin.fill" : "pin")
                    .font(.system(size: 10)).foregroundStyle(theme.textDim).frame(width: 18)
            }
            .buttonStyle(.plain)
            .opacity(hover || selected ? 1 : 0)
            .help(app.apps.isFavorite(record) ? "Unpin" : "Pin")
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .gridRowBackground(selected: selected, hovered: hover, theme: theme)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(record.name + (missing ? ", missing" : ""))
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}
