import AppKit
import GridCore
import SwiftUI

struct FileBrowserView: View {
    @Environment(AppState.self) private var app
    @Environment(\.theme) private var theme
    /// Compact = sidebar beside the terminal (no columns, no inspector).
    let compact: Bool

    @FocusState private var listFocused: Bool
    @FocusState private var filterFocused: Bool
    @FocusState private var pathFocused: Bool

    var body: some View {
        let m = app.files
        Panel(index: "02", title: "Files", suffix: compact ? "nav" : "browse",
              focused: listFocused || filterFocused || pathFocused) {
            HStack(spacing: 2) {
                IconButton(symbol: m.showHidden ? "eye" : "eye.slash", label: "Show hidden files (⇧⌘.)", active: m.showHidden) {
                    m.showHidden.toggle()
                }
                IconButton(symbol: "terminal", label: "Open terminal here (⌥⌘T)") { app.openTerminalHere() }
                if !compact {
                    IconButton(symbol: "sidebar.right", label: "Toggle inspector (⌘I)", active: app.inspectorVisible) {
                        app.inspectorVisible.toggle()
                    }
                }
            }
        } content: {
            VStack(spacing: 0) {
                NavBar(pathFocused: $pathFocused)
                FilterBar(filterFocused: $filterFocused, compact: compact, onDown: { listFocused = true; m.moveSelection(1) })
                Rectangle().fill(theme.line).frame(height: Metrics.hairline)
                if !compact { ColumnHeader() }
                content(m)
                StatusLine(compact: compact)
            }
        }
        .onAppear { m.onError = { msg in app.flash(.error, msg) } }
        .onReceive(NotificationCenter.default.publisher(for: .gridFocusFileFilter)) { _ in filterFocused = true }
        .onReceive(NotificationCenter.default.publisher(for: .gridFocusPathField)) { _ in pathFocused = true }
    }

    @ViewBuilder
    private func content(_ m: FileBrowserModel) -> some View {
        if let err = m.error {
            ScrollView { errorView(err).padding(14) }
        } else if m.visible.isEmpty && !m.loading && !m.deepRunning {
            VStack {
                StateBlock(code: m.query.isEmpty ? "EMPTY" : "NO.MATCH",
                           title: m.query.isEmpty ? "This folder is empty" : "No matches",
                           message: m.query.isEmpty
                               ? (m.showHidden ? "Nothing here, including hidden items." : "Hidden items are not shown. Press ⇧⌘. to show them.")
                               : (m.mode == .here ? "Nothing in this folder matches “\(m.query)”. Switch to RECURSIVE to search subfolders." : "No file or folder under this location matches “\(m.query)”."))
                    .padding(14)
                Spacer()
            }
        } else {
            FileList(compact: compact, listFocused: $listFocused)
        }
    }

    @ViewBuilder
    private func errorView(_ e: ListingError) -> some View {
        switch e {
        case .permissionDenied(let p):
            StateBlock(tone: .warning, code: "ACCESS.DENIED", title: "No permission to read this folder",
                       message: "\(PathResolver.abbreviate(p))\n\nmacOS privacy protection or file permissions block access. For protected locations (Desktop, Documents, Mail, etc.), macOS asks once; you can change it in System Settings › Privacy & Security. GRID never bypasses these protections.") {
                Button("Go Up") { app.files.goUp() }
                Button("Privacy Settings") {
                    if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") { NSWorkspace.shared.open(u) }
                }
                Button("Reveal in Finder") { app.files.reveal([URL(fileURLWithPath: p)]) }
            }
        case .notFound(let p):
            StateBlock(tone: .error, code: "NOT.FOUND", title: "Folder not found",
                       message: "\(PathResolver.abbreviate(p)) does not exist. It may have been moved or deleted.") {
                Button("Go Up") { app.files.goUp() }
                Button("Home") { app.files.navigate(to: FileManager.default.homeDirectoryForCurrentUser) }
            }
        case .notADirectory(let p):
            StateBlock(tone: .error, code: "NOT.FOLDER", title: "Not a folder", message: PathResolver.abbreviate(p)) {
                Button("Go Up") { app.files.goUp() }
            }
        case .other(let p, let msg):
            StateBlock(tone: .error, code: "READ.ERROR", title: "Could not read folder", message: "\(PathResolver.abbreviate(p))\n\(msg)") {
                Button("Retry") { app.files.reload() }
                Button("Go Up") { app.files.goUp() }
            }
        }
    }
}

extension Notification.Name {
    static let gridFocusFileFilter = Notification.Name("grid.focusFileFilter")
    static let gridFocusPathField = Notification.Name("grid.focusPathField")
}

// MARK: - Navigation bar: back / forward / up + breadcrumbs (click to edit path)

private struct NavBar: View {
    @Environment(AppState.self) private var app
    @Environment(\.theme) private var theme
    var pathFocused: FocusState<Bool>.Binding
    @State private var editing = false
    @State private var draft = ""
    @State private var pathError: String?

    var body: some View {
        let m = app.files
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 2) {
                IconButton(symbol: "chevron.left", label: "Back (⌘[)", disabled: !m.canGoBack) { m.goBack() }
                IconButton(symbol: "chevron.right", label: "Forward (⌘])", disabled: !m.canGoForward) { m.goForward() }
                IconButton(symbol: "arrow.up", label: "Enclosing folder (⌘↑)", disabled: !m.canGoUp) { m.goUp() }
                if editing || pathFocused.wrappedValue {
                    GridField(placeholder: "path, ~/… or relative", text: $draft, focus: pathFocused) {
                        if let err = m.go(toTyped: draft) { pathError = err } else { pathError = nil; editing = false; pathFocused.wrappedValue = false }
                    }
                    .onExitCommand { editing = false; pathFocused.wrappedValue = false; pathError = nil }
                    .onChange(of: pathFocused.wrappedValue) { _, f in if !f { editing = false; pathError = nil } }
                } else {
                    Breadcrumbs()
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { beginEdit() }
                    IconButton(symbol: "character.cursor.ibeam", label: "Edit path (⌘L)") { beginEdit() }
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            if let pathError {
                HStack(spacing: 6) {
                    Text("✕").foregroundStyle(theme.danger)
                    Text(pathError).foregroundStyle(theme.textDim)
                }
                .font(GridFont.small)
                .padding(.horizontal, 10).padding(.bottom, 4)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .gridFocusPathField)) { _ in beginEdit() }
    }

    private func beginEdit() {
        draft = PathResolver.abbreviate(app.files.currentURL.path)
        editing = true
        DispatchQueue.main.async { pathFocused.wrappedValue = true }
    }
}

private struct Breadcrumbs: View {
    @Environment(AppState.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        let chain = PathResolver.ancestors(of: app.files.currentURL)
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(chain.enumerated()), id: \.element.path) { i, url in
                        let last = i == chain.count - 1
                        Button {
                            app.files.navigate(to: url)
                        } label: {
                            Text(crumbName(url))
                                .font(last ? GridFont.bodyStrong : GridFont.body)
                                .foregroundStyle(last ? theme.text : theme.textDim)
                                .padding(.horizontal, 3)
                        }
                        .buttonStyle(.plain)
                        .id(url.path)
                        if !last && url.path != "/" { Text("/").font(GridFont.body).foregroundStyle(theme.textMute) }
                    }
                }
            }
            .onAppear { proxy.scrollTo(app.files.currentURL.path, anchor: .trailing) }
            .onChange(of: app.files.currentURL) { _, u in proxy.scrollTo(u.path, anchor: .trailing) }
        }
        .frame(height: 22)
    }

    private func crumbName(_ u: URL) -> String {
        if u.path == "/" { return "/" }
        if u.path == NSHomeDirectory() { return "~" }
        return u.lastPathComponent
    }
}

// MARK: - Filter / search

private struct FilterBar: View {
    @Environment(AppState.self) private var app
    @Environment(\.theme) private var theme
    var filterFocused: FocusState<Bool>.Binding
    let compact: Bool
    let onDown: () -> Void

    var body: some View {
        @Bindable var m = app.files
        HStack(spacing: 6) {
            GridField(placeholder: m.mode == .here ? "filter this folder  ⌘F" : "search all subfolders",
                      text: $m.query, prompt: m.mode == .here ? "⌕" : "⌕⌕", focus: filterFocused) { onDown() }
                .onExitCommand { m.query = ""; filterFocused.wrappedValue = false }
                .onKeyPress(.downArrow) { onDown(); return .handled }
            // Explicit mode switch: filtering this folder vs recursive search are different operations.
            HStack(spacing: 0) {
                ForEach(FileSearchMode.allCases, id: \.self) { mode in
                    Button { m.mode = mode } label: {
                        Text(compact ? (mode == .here ? "HERE" : "DEEP") : mode.label)
                            .font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(0.8)
                            .padding(.horizontal, 6).frame(height: 24)
                            .foregroundStyle(m.mode == mode ? theme.textOnAccent : theme.textDim)
                            .background(m.mode == mode ? theme.accent : theme.bg2)
                    }
                    .buttonStyle(.plain)
                    .help(mode == .here ? "Filter names in the current folder only" : "Search names in all subfolders (recursive)")
                }
            }
            .overlay(Rectangle().stroke(theme.line, lineWidth: Metrics.hairline))
        }
        .padding(.horizontal, 6).padding(.bottom, 6)
    }
}

private struct ColumnHeader: View {
    @Environment(AppState.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            column(.name).frame(maxWidth: .infinity, alignment: .leading)
            column(.kind).frame(width: 130, alignment: .leading)
            column(.size).frame(width: 80, alignment: .trailing)
            column(.modified).frame(width: 130, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .frame(height: 20)
        .background(theme.bg2.opacity(0.4))
        .overlay(alignment: .bottom) { Rectangle().fill(theme.line).frame(height: Metrics.hairline) }
    }

    private func column(_ key: FileSortKey) -> some View {
        let m = app.files
        let active = m.sortKey == key
        return Button { m.toggleSort(key) } label: {
            HStack(spacing: 3) {
                SectionLabel(key.label, color: active ? theme.accent : theme.textMute)
                if active { Text(m.ascending ? "▲" : "▼").font(.system(size: 7)).foregroundStyle(theme.accent) }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sort by \(key.label.lowercased())")
    }
}

// MARK: - List

/// Pasteboard type carrying all dragged paths (an NSItemProvider holds a single file URL, so
/// multi-item drags into the terminal use this JSON array alongside the first URL).
extension NSPasteboard.PasteboardType {
    static let gridPaths = NSPasteboard.PasteboardType("local.grid.paths")
}

private struct FileList: View {
    @Environment(AppState.self) private var app
    @Environment(\.theme) private var theme
    let compact: Bool
    var listFocused: FocusState<Bool>.Binding
    @State private var dropTargeted = false
    /// When the disclosure triangle was last clicked. The row's own tap gesture fires at the same
    /// time (it is simultaneous by design, so single clicks never wait for a double); it checks
    /// this to leave the selection alone, and a quick double click on the triangle must not
    /// navigate into the folder.
    @State private var triangleClickAt = Date.distantPast

    var body: some View {
        let m = app.files
        let rows = m.rows
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                        if let e = row.entry {
                            FileRow(entry: e, depth: row.depth, expandable: FileTree.isExpandable(e), expanded: row.isExpanded,
                                    compact: compact, selected: m.selectedIDs.contains(e.id),
                                    isCursor: e.id == m.selectionID, renaming: m.renamingID == e.id,
                                    showParent: m.mode == .deep && !m.query.isEmpty, root: m.currentURL) { recursive in
                                triangleClickAt = Date()
                                m.toggleExpanded(e.id, recursive: recursive)
                            }
                            .id(e.id)
                            .cascadeIn(i)
                            .onTapGesture(count: 2) {
                                guard Date().timeIntervalSince(triangleClickAt) > 0.4 else { return }
                                m.activate(e)
                            }
                            .simultaneousGesture(TapGesture().onEnded {
                                let mods = NSEvent.modifierFlags
                                // Deferred so the triangle's button action (if that is what was hit) has run.
                                DispatchQueue.main.async {
                                    guard Date().timeIntervalSince(triangleClickAt) > 0.2 else { return }
                                    m.click(e.id, command: mods.contains(.command), shift: mods.contains(.shift))
                                    listFocused.wrappedValue = true
                                }
                            })
                            .onDrag { dragProvider(for: e, m) }
                            .contextMenu { FileContextMenu(entry: e) }
                        } else {
                            TreePlaceholderRow(row: row).id(row.id)
                        }
                    }
                }
            }
            .focusable()
            .focusEffectDisabled()
            .focused(listFocused)
            .onChange(of: m.selectionID) { _, id in
                if let id { withAnimation(nil) { proxy.scrollTo(id) } }
                QuickLook.shared.update(m.selectedEntries.map(\.url))
            }
            .onKeyPress(phases: .down) { press in handle(press, m) }
            .onCopyCommand { m.selectedEntries.map { NSItemProvider(object: $0.url as NSURL) } }
            .onPasteCommand(of: [.fileURL]) { _ in app.fileOps.pasteFromPasteboard(into: m.currentURL, move: false) }
            // Dropping files from Finder (or another GRID folder) copies them here.
            .dropDestination(for: URL.self) { urls, _ in
                let files = urls.filter(\.isFileURL)
                guard !files.isEmpty, !files.allSatisfy({ $0.deletingLastPathComponent().standardizedFileURL == m.currentURL.standardizedFileURL }) else { return false }
                app.fileOps.transfer(files, into: m.currentURL, move: false)
                return true
            } isTargeted: { dropTargeted = $0 }
            .overlay { if dropTargeted { Rectangle().stroke(theme.accent, lineWidth: 1.5).allowsHitTesting(false) } }
        }
    }

    private func dragProvider(for e: FileEntry, _ m: FileBrowserModel) -> NSItemProvider {
        // Drag the whole selection if the row is part of it; otherwise just this row.
        let urls = m.selectedIDs.contains(e.id) ? m.selectedEntries.map(\.url) : [e.url]
        let provider = NSItemProvider(object: (urls.first ?? e.url) as NSURL)
        if let data = try? JSONEncoder().encode(urls.map(\.path)) {
            provider.registerDataRepresentation(forTypeIdentifier: NSPasteboard.PasteboardType.gridPaths.rawValue, visibility: .ownProcess) { done in
                done(data, nil); return nil
            }
        }
        return provider
    }

    private func handle(_ press: KeyPress, _ m: FileBrowserModel) -> KeyPress.Result {
        if m.renamingID != nil { return .ignored }
        let cmd = press.modifiers.contains(.command)
        let shift = press.modifiers.contains(.shift)
        let opt = press.modifiers.contains(.option)
        let ops = app.fileOps
        switch press.key {
        case .downArrow:
            if cmd, let e = m.selectedEntry { m.activate(e) } else if shift { m.extendSelection(1) } else { m.moveSelection(1) }
            return .handled
        case .upArrow:
            if cmd { m.goUp() } else if shift { m.extendSelection(-1) } else { m.moveSelection(-1) }
            return .handled
        case .return:
            if let e = m.selectedEntry { m.activate(e) }
            return .handled
        case .space:
            QuickLook.shared.toggle(m.selectedEntries.map(\.url))
            return .handled
        case .leftArrow where !cmd:
            m.collapseOrAscend(); return .handled
        case .rightArrow where !cmd:
            m.expandOrDescend(option: opt); return .handled
        case .home: if let f = m.visible.first { m.selectionID = f.id }; return .handled
        case .end: if let l = m.visible.last { m.selectionID = l.id }; return .handled
        case .pageDown: m.moveSelection(15); return .handled
        case .pageUp: m.moveSelection(-15); return .handled
        case .delete where cmd:
            let urls = m.selectedEntries.map(\.url)
            if opt { ops.requestDeleteImmediately(urls) } else { ops.trash(urls) }
            return .handled
        default:
            break
        }
        guard cmd else { return .ignored }
        switch press.characters.lowercased() {
        case "a": m.selectAll(); return .handled
        case "z" where !shift: ops.undo(); return .handled
        case "v" where opt: ops.pasteFromPasteboard(into: m.currentURL, move: true); return .handled
        case "c" where !opt: ops.copyToPasteboard(m.selectedEntries.map(\.url)); return .handled
        case "v": ops.pasteFromPasteboard(into: m.currentURL, move: false); return .handled
        default: return .ignored
        }
    }
}

/// Indent step per outline level.
private let treeIndent: CGFloat = 14

/// Faint vertical guides, one per ancestor level, aligned under the parent's disclosure triangle.
private struct TreeGuides: View {
    @Environment(\.theme) private var theme
    let depth: Int

    var body: some View {
        if depth > 0 {
            HStack(spacing: 0) {
                ForEach(0..<depth, id: \.self) { _ in
                    Rectangle().fill(theme.line).frame(width: 1)
                        .padding(.leading, 6)
                        .frame(width: treeIndent, alignment: .leading)
                }
            }
            .frame(height: Metrics.rowHeight)
            .accessibilityHidden(true)
        }
    }
}

/// Inline "loading…" / error row under an expanded folder (never a modal).
private struct TreePlaceholderRow: View {
    @Environment(\.theme) private var theme
    let row: FileTreeRow

    var body: some View {
        HStack(spacing: 7) {
            TreeGuides(depth: row.depth)
            switch row.kind {
            case .error(let msg):
                Text("!").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(theme.warn).frame(width: 14)
                Text(msg).font(GridFont.small).foregroundStyle(theme.warn).lineLimit(1).truncationMode(.middle)
            default:
                ProgressView().controlSize(.mini).tint(theme.accent).frame(width: 14)
                Text("loading…").font(GridFont.small).foregroundStyle(theme.textMute)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: Metrics.rowHeight)
        .accessibilityElement(children: .combine)
    }
}

private struct FileRow: View {
    @Environment(AppState.self) private var app
    @Environment(\.theme) private var theme
    @Environment(\.effects) private var effects
    let entry: FileEntry
    let depth: Int
    let expandable: Bool
    let expanded: Bool
    let compact: Bool
    let selected: Bool
    let isCursor: Bool
    let renaming: Bool
    let showParent: Bool
    let root: URL
    /// Disclosure triangle clicked (`recursive` when ⌥ is held).
    let onToggle: (_ recursive: Bool) -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 0) {
            TreeGuides(depth: depth)
            HStack(spacing: 7) {
                glyphView.frame(width: 14)
                if renaming {
                    RenameField(entry: entry)
                } else {
                    Text(entry.name)
                        .font(GridFont.body)
                        .foregroundStyle(entry.isBrokenSymlink ? theme.textMute : (entry.isHidden ? theme.textDim : theme.text))
                        .strikethrough(entry.isBrokenSymlink, color: theme.textMute)
                        .lineLimit(1).truncationMode(.middle)
                }
                if entry.isSymlink { Text("→").font(GridFont.small).foregroundStyle(theme.textMute).help("Symbolic link") }
                if showParent {
                    Text(relativeParent)
                        .font(GridFont.small).foregroundStyle(theme.textMute)
                        .lineLimit(1).truncationMode(.head)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !compact {
                Text(entry.kind).font(GridFont.small).foregroundStyle(theme.textDim)
                    .lineLimit(1).frame(width: 130, alignment: .leading)
                Text(entry.size.map(Formatters.size) ?? "—").font(GridFont.small).foregroundStyle(theme.textDim)
                    .frame(width: 80, alignment: .trailing)
                Text(entry.modified.map(Formatters.date) ?? "—").font(GridFont.small).foregroundStyle(theme.textDim)
                    .frame(width: 130, alignment: .trailing)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: Metrics.rowHeight)
        .gridRowBackground(selected: selected, hovered: hover, theme: theme)
        .overlay(alignment: .leading) {
            // Keyboard cursor inside a multi-selection: a brighter, taller bar.
            if isCursor && app.files.selectedIDs.count > 1 { Rectangle().fill(theme.text).frame(width: 2) }
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.isNavigableFolder ? "Folder" : entry.kind), \(entry.name)\(depth > 0 ? ", level \(depth + 1)" : "")")
        .accessibilityValue(expandable ? (expanded ? "expanded" : "collapsed") : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Disclosure triangle for folders (rotates open); a static glyph for everything else.
    @ViewBuilder private var glyphView: some View {
        if expandable {
            Button {
                onToggle(NSEvent.modifierFlags.contains(.option))
            } label: {
                Text("▸")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(theme.accent)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .animation(effects.motion ? GridMotion.quick : nil, value: expanded)
                    .frame(width: 14, height: Metrics.rowHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? "Collapse (←)" : "Expand (→, ⌥ for all levels)")
            .accessibilityLabel("\(expanded ? "Collapse" : "Expand") \(entry.name)")
        } else {
            Text(glyph)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(entry.isNavigableFolder ? theme.accent : theme.textMute)
        }
    }

    private var glyph: String {
        if entry.isBrokenSymlink { return "!" }
        if entry.isNavigableFolder { return "▸" }
        if entry.isPackage { return "◆" }
        return "·"
    }

    private var relativeParent: String {
        let parent = entry.url.deletingLastPathComponent().path
        if parent == root.path { return "./" }
        if parent.hasPrefix(root.path + "/") { return "./" + parent.dropFirst(root.path.count + 1) }
        return PathResolver.abbreviate(parent)
    }
}

/// Inline rename: Return commits, Esc cancels; the name stem is preselected like Finder.
private struct RenameField: View {
    @Environment(AppState.self) private var app
    @Environment(\.theme) private var theme
    let entry: FileEntry
    @State private var text = ""
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(GridFont.body)
                .foregroundStyle(theme.text)
                .padding(.horizontal, 4)
                .background(theme.bg3)
                .overlay(Rectangle().stroke(error == nil ? theme.lineStrong : theme.danger, lineWidth: 1))
                .focused($focused)
                .onSubmit(commit)
                .onExitCommand { app.files.renamingID = nil }
                .onChange(of: focused) { _, f in if !f && app.files.renamingID == entry.id { commit() } }
            if let error { Text("✕ \(error)").font(GridFont.small).foregroundStyle(theme.danger).lineLimit(1) }
        }
        .onAppear {
            text = entry.name
            DispatchQueue.main.async { focused = true }
        }
    }

    private func commit() {
        guard app.files.renamingID == entry.id else { return }
        if let problem = app.fileOps.rename(entry, to: text) {
            error = problem
            focused = true
        } else {
            app.files.renamingID = nil
        }
    }
}

struct FileContextMenu: View {
    @Environment(AppState.self) private var app
    let entry: FileEntry

    /// Right-clicking inside the selection acts on all of it; outside, on just this item.
    private var targets: [FileEntry] {
        app.files.selectedIDs.contains(entry.id) ? app.files.selectedEntries : [entry]
    }

    var body: some View {
        let urls = targets.map(\.url)
        let multi = urls.count > 1
        Button(entry.isNavigableFolder ? "Open Folder" : "Open") { app.files.activate(entry) }
        if !entry.isNavigableFolder && !multi { OpenWithMenu(url: entry.url) }
        if FileTree.isExpandable(entry) && !multi {
            let open = app.files.isExpanded(entry.id)
            Button(open ? "Collapse" : "Expand") { app.files.toggleExpanded(entry.id) }
            if !open { Button("Expand All Levels") { app.files.expand(entry.id, recursive: true) } }
        }
        Button("Quick Look") { QuickLook.shared.show(urls) }
        Divider()
        if entry.isNavigableFolder {
            Button("Open Terminal Here") { app.openTerminalHere(entry.url) }
        } else {
            Button("Open Terminal in Enclosing Folder") { app.openTerminalHere(entry.url.deletingLastPathComponent()) }
        }
        Button(multi ? "Insert \(urls.count) Paths in Terminal" : "Insert Path in Terminal") { app.insertPathsIntoTerminal(urls) }
        Divider()
        if !multi { Button("Rename") { app.files.selectionID = entry.id; app.files.renamingID = entry.id } }
        Button("Duplicate") { app.fileOps.duplicate(urls) }
        Button("Copy") { app.fileOps.copyToPasteboard(urls) }
        Button("Paste Into Current Folder") { app.fileOps.pasteFromPasteboard(into: app.files.currentURL, move: false) }
        if entry.isNavigableFolder && !multi {
            Button("Paste Into “\(entry.name)”") { app.fileOps.pasteFromPasteboard(into: entry.url, move: false) }
        }
        Button("Copy Path\(multi ? "s" : "")") { app.files.copyPaths(urls); app.flash(.info, "Copied path\(multi ? "s" : "")") }
        Button("Reveal in Finder") { app.files.reveal(urls) }
        Divider()
        Button("Move to Trash") { app.fileOps.trash(urls) }
        Button("Delete Immediately…") { app.fileOps.requestDeleteImmediately(urls) }
    }
}

/// "Open With ▸" listing the apps LaunchServices says can open the file.
struct OpenWithMenu: View {
    @Environment(AppState.self) private var app
    let url: URL

    var body: some View {
        let appsForFile = NSWorkspace.shared.urlsForApplications(toOpen: url)
        let defaultApp = app.files.defaultApp(for: url)
        Menu("Open With") {
            ForEach(appsForFile, id: \.self) { appURL in
                Button(appURL.deletingPathExtension().lastPathComponent + (appURL == defaultApp ? " (default)" : "")) {
                    app.files.open(url, with: appURL)
                }
            }
            if appsForFile.isEmpty { Text("No applications found") }
        }
    }
}

private struct StatusLine: View {
    @Environment(AppState.self) private var app
    @Environment(\.theme) private var theme
    let compact: Bool

    var body: some View {
        let m = app.files
        HStack(spacing: 8) {
            if let busy = app.fileOps.busy {
                ProgressView().controlSize(.mini).tint(theme.accent)
                Text(busy).foregroundStyle(theme.text)
                Spacer()
            } else if m.mode == .deep && !m.query.isEmpty {
                if m.deepRunning { ProgressView().controlSize(.mini).tint(theme.accent) }
                Text("\(m.deepResults.count)\(m.deepTruncated ? "+" : "") found · \(m.deepScanned) scanned")
                if m.deepSkipped > 0 { Text("· \(m.deepSkipped) unreadable skipped").foregroundStyle(theme.warn) }
                Spacer()
                if m.deepRunning { Button("Stop") { m.cancelDeepSearch() }.buttonStyle(GridButtonStyle(compact: true)) }
            } else {
                Text("\(m.visible.count) item\(m.visible.count == 1 ? "" : "s")")
                if m.expandedVisibleCount > 0 { Text("· \(m.expandedVisibleCount) expanded").foregroundStyle(theme.textDim) }
                if m.selectedIDs.count > 1 {
                    let bytes = m.selectedEntries.compactMap(\.size).reduce(0, +)
                    Text("· \(m.selectedIDs.count) selected\(bytes > 0 ? " · " + Formatters.size(bytes) : "")").foregroundStyle(theme.textDim)
                }
                if !m.query.isEmpty { Text("· filtered from \(m.loadedCount)") }
                if m.showHidden && !compact { Text("· hidden shown") }
                Spacer()
                if m.loading { ProgressView().controlSize(.mini).tint(theme.accent) }
            }
        }
        .font(GridFont.small)
        .foregroundStyle(theme.textMute)
        .padding(.horizontal, 10)
        .frame(height: 22)
        .overlay(alignment: .top) { Rectangle().fill(theme.line).frame(height: Metrics.hairline) }
    }
}

enum Formatters {
    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()
    static func date(_ d: Date) -> String { dateFormatter.string(from: d) }
}
