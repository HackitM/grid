import AppKit
import Darwin
import GridCore
import Observation
import UniformTypeIdentifiers

enum FileSearchMode: String, CaseIterable {
    case here, deep
    var label: String { self == .here ? "THIS FOLDER" : "RECURSIVE" }
}

@Observable
@MainActor
final class FileBrowserModel {
    private(set) var currentURL: URL
    private(set) var entries: [FileEntry] = [] { didSet { recomputeVisible() } }
    private(set) var error: ListingError?
    private(set) var loading = false
    private var backStack: [URL] = []
    private var forwardStack: [URL] = []

    // Each of these re-flattens (and re-sorts) the outline, so they only react to a real change:
    // navigating resets `query` and `mode` every time, which used to sort the old folder twice.
    var sortKey: FileSortKey = .name { didSet { if sortKey != oldValue { recomputeVisible() } } }
    var ascending = true { didSet { if ascending != oldValue { recomputeVisible() } } }
    var query = "" {
        didSet {
            guard query != oldValue else { return }
            if mode == .deep { scheduleDeepSearch() }
            recomputeVisible()
        }
    }
    var mode: FileSearchMode = .here {
        didSet {
            guard mode != oldValue else { return }
            if mode == .deep { scheduleDeepSearch() } else { cancelDeepSearch() }
            recomputeVisible()
        }
    }

    /// Primary ("cursor") selection: drives the inspector and keyboard movement. Setting it
    /// directly makes it the only selected item.
    var selectionID: String? {
        didSet { if !extendingSelection { selectedIDs = selectionID.map { [$0] } ?? []; anchorID = selectionID } }
    }
    /// Full selection (multi-select with ⌘/⇧).
    private(set) var selectedIDs: Set<String> = []
    @ObservationIgnored private var anchorID: String?
    @ObservationIgnored private var extendingSelection = false
    /// Row currently being renamed inline.
    var renamingID: String?

    // Outline (expandable folders). Expansion is remembered per root folder for the session;
    // children listings are cached by path and refreshed by their own directory watchers.
    /// Folders expanded in the current root (paths). Descendants of a collapsed folder stay in
    /// the set so reopening it restores them, like Finder.
    private(set) var expanded: Set<String> = []
    @ObservationIgnored private var expandedByRoot: [String: Set<String>] = [:]
    private(set) var children: [String: FileTreeChildren] = [:]
    /// Flattened outline rows in display order (entries and inline placeholders). Cached like `visible`.
    private(set) var rows: [FileTreeRow] = []
    /// Number of expanded folder rows currently shown.
    private(set) var expandedVisibleCount = 0
    /// Entries reachable through expanded folders (unfiltered), for selection lookups.
    @ObservationIgnored private var entryIndex: [String: FileEntry] = [:]
    @ObservationIgnored private var childTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var childWatchers: [String: DispatchSourceFileSystemObject] = [:]
    @ObservationIgnored private var childReloadWork: [String: DispatchWorkItem] = [:]
    /// Folders whose children should be expanded too once loaded (⌥→), with levels remaining.
    @ObservationIgnored private var recursivePending: [String: Int] = [:]

    // Recursive search state (real counts, not decoration)
    private(set) var deepResults: [FileEntry] = [] { didSet { if mode == .deep { recomputeVisible() } } }
    private(set) var deepScanned = 0
    private(set) var deepSkipped = 0
    private(set) var deepRunning = false
    private(set) var deepTruncated = false
    static let deepLimit = 1000

    @ObservationIgnored private let settings: Settings
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var deepTask: Task<Void, Never>?
    @ObservationIgnored private var watcher: DispatchSourceFileSystemObject?
    /// Paths to select once they appear in the listing (after create/paste/rename).
    @ObservationIgnored var pendingSelection: [String]?
    @ObservationIgnored var onError: ((String) -> Void)?
    @ObservationIgnored var onNavigate: ((URL) -> Void)?
    /// Asked before opening something that would *run* rather than display. Call the closure
    /// to proceed. If unset, such files are refused.
    @ObservationIgnored var confirmRun: ((URL, _ reason: String, _ proceed: @escaping () -> Void) -> Void)?

    init(settings: Settings) {
        self.settings = settings
        currentURL = FileManager.default.homeDirectoryForCurrentUser
        load()
    }

    var showHidden: Bool {
        get { settings.showHiddenFiles }
        set { settings.showHiddenFiles = newValue; children.removeAll(); load() }
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var canGoUp: Bool { currentURL.path != "/" }

    /// Rows currently shown: filtered folder listing, or recursive results. Cached: recomputed
    /// only when entries, sort, query, or mode change (it used to re-sort on every access).
    private(set) var visible: [FileEntry] = []

    /// Entries at any depth that the current view can resolve (roots plus children of expanded folders).
    var loadedCount: Int { entryIndex.count }

    private func recomputeVisible() {
        if mode == .deep && !query.trimmingCharacters(in: .whitespaces).isEmpty {
            visible = deepResults
            rows = deepResults.map { FileTreeRow(id: $0.id, kind: .entry($0), depth: 0, parentID: nil, isExpanded: false) }
            expandedVisibleCount = 0
        } else {
            rows = FileTree.flatten(roots: entries, children: children, expanded: expanded,
                                    sortKey: sortKey, ascending: ascending, query: query)
            visible = rows.compactMap(\.entry)
            expandedVisibleCount = rows.reduce(0) { $0 + ($1.isExpanded ? 1 : 0) }
        }
        entryIndex = FileTree.reachable(roots: entries, children: children, expanded: expanded)
        syncChildWatchers()
    }

    /// Selected entries in display order.
    var selectedEntries: [FileEntry] {
        guard !selectedIDs.isEmpty else { return [] }
        return visible.filter { selectedIDs.contains($0.id) }
    }

    // MARK: Selection

    /// Mouse click with Finder semantics: ⌘ toggles, ⇧ extends a range from the anchor.
    func click(_ id: String, command: Bool, shift: Bool) {
        if shift, let anchor = anchorID, let a = visible.firstIndex(where: { $0.id == anchor }),
           let b = visible.firstIndex(where: { $0.id == id }) {
            setSelection(Set(visible[min(a, b)...max(a, b)].map(\.id)), cursor: id, keepAnchor: true)
        } else if command {
            var set = selectedIDs
            if set.contains(id) { set.remove(id) } else { set.insert(id) }
            setSelection(set, cursor: set.contains(id) ? id : set.first, keepAnchor: false)
        } else {
            selectionID = id
        }
    }

    func selectAll() {
        setSelection(Set(visible.map(\.id)), cursor: selectionID ?? visible.first?.id, keepAnchor: true)
    }

    /// ⇧↑ / ⇧↓: grow or shrink the range from the anchor.
    func extendSelection(_ delta: Int) {
        guard !visible.isEmpty else { return }
        let cursor = visible.firstIndex { $0.id == selectionID } ?? 0
        let next = max(0, min(visible.count - 1, cursor + delta))
        let anchor = anchorID.flatMap { id in visible.firstIndex { $0.id == id } } ?? cursor
        setSelection(Set(visible[min(anchor, next)...max(anchor, next)].map(\.id)), cursor: visible[next].id, keepAnchor: true)
    }

    private func setSelection(_ ids: Set<String>, cursor: String?, keepAnchor: Bool) {
        extendingSelection = true
        selectionID = cursor
        extendingSelection = false
        selectedIDs = ids
        if !keepAnchor { anchorID = cursor }
    }

    /// Selects specific paths after an operation (e.g. pasted items).
    func select(paths: [String]) {
        let set = Set(paths)
        setSelection(set, cursor: paths.first, keepAnchor: false)
    }

    var selectedEntry: FileEntry? {
        guard let id = selectionID else { return nil }
        return entryIndex[id] ?? visible.first { $0.id == id }
    }

    /// Entry for a row id at any loaded depth.
    func entry(for id: String) -> FileEntry? { entryIndex[id] }

    // MARK: Navigation

    func navigate(to url: URL, recordHistory: Bool = true) {
        let target = url.standardizedFileURL
        if recordHistory && target.path != currentURL.path {
            backStack.append(currentURL)
            forwardStack.removeAll()
        }
        let previous = currentURL
        expandedByRoot[previous.path] = expanded
        currentURL = target
        expanded = expandedByRoot[target.path] ?? []
        recursivePending.removeAll()
        onNavigate?(target)
        query = ""
        mode = .here
        // Going up selects the folder we came from, like Finder.
        selectionID = previous.deletingLastPathComponent().standardizedFileURL.path == target.path ? previous.path : nil
        load()
    }

    func goBack() {
        guard let u = backStack.popLast() else { return }
        forwardStack.append(currentURL)
        navigate(to: u, recordHistory: false)
    }

    func goForward() {
        guard let u = forwardStack.popLast() else { return }
        backStack.append(currentURL)
        navigate(to: u, recordHistory: false)
    }

    func goUp() {
        guard canGoUp else { return }
        navigate(to: currentURL.deletingLastPathComponent())
    }

    /// Path field submit. Returns an error message for inline display, or nil on success.
    func go(toTyped input: String) -> String? {
        guard let url = PathResolver.resolve(input, relativeTo: currentURL) else { return "Enter a path" }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return "No such file or folder: \(PathResolver.abbreviate(url.path))"
        }
        if isDir.boolValue && !NSWorkspace.shared.isFilePackage(atPath: url.path) {
            navigate(to: url)
        } else {
            navigate(to: url.deletingLastPathComponent())
            selectionID = url.path
        }
        return nil
    }

    func reload() { load() }

    private func load() {
        loadTask?.cancel()
        loading = true
        let url = currentURL, hidden = settings.showHiddenFiles, key = sortKey, asc = ascending
        loadTask = Task { [weak self] in
            let result = await Self.listing(of: url, showHidden: hidden, sortKey: key, ascending: asc)
            guard let self, !Task.isCancelled, self.currentURL == url else { return }
            self.loading = false
            switch result {
            case .success(let items):
                // A newly opened folder's rows cascade in (Legacy build); reloads only animate new rows.
                if self.entries.isEmpty || self.entries.first?.url.deletingLastPathComponent() != items.first?.url.deletingLastPathComponent() {
                    CascadeClock.shared.start()
                }
                self.entries = items
                self.error = nil
                // Expanded folders may have changed too (file ops reload the root); refresh them
                // silently from cache so the outline stays consistent.
                for id in self.expanded where self.entryIndex[id] != nil { self.loadChildren(of: id, silent: self.children[id] != nil) }
                self.pruneSelection()
                self.applyPendingSelection()
                self.watch(url)
            case .failure(let e):
                self.entries = []
                self.error = e
                self.unwatch()
            }
        }
    }

    /// Lists one folder off the main thread, already in the current sort order. The outline is
    /// flattened (and sorted per level) on the main thread; handing it sorted input turns that
    /// sort into a single confirming pass, which is what keeps opening a folder with tens of
    /// thousands of items from stalling the UI.
    nonisolated private static func listing(of url: URL, showHidden: Bool, sortKey: FileSortKey,
                                            ascending: Bool) async -> Result<[FileEntry], ListingError> {
        await Task.detached(priority: .userInitiated) {
            do {
                let items = try FileListing.list(url, showHidden: showHidden)
                return .success(FileListing.sorted(items, by: sortKey, ascending: ascending))
            } catch let e as ListingError {
                return .failure(e)
            } catch {
                return .failure(.other(url.path, error.localizedDescription))
            }
        }.value
    }

    /// Drops selected ids that no longer resolve to a loaded entry.
    private func pruneSelection() {
        if let sel = selectionID, entryIndex[sel] == nil {
            selectionID = nil
        } else if !selectedIDs.allSatisfy({ entryIndex[$0] != nil }) {
            setSelection(selectedIDs.filter { entryIndex[$0] != nil }, cursor: selectionID, keepAnchor: true)
        }
    }

    private func applyPendingSelection() {
        guard let pending = pendingSelection, pending.allSatisfy({ entryIndex[$0] != nil }) else { return }
        select(paths: pending)
        pendingSelection = nil
    }

    // MARK: Outline (expand / collapse)

    func isExpanded(_ id: String) -> Bool { expanded.contains(id) }

    func canExpand(_ id: String) -> Bool { entryIndex[id].map(FileTree.isExpandable) ?? false }

    /// Shows a folder's children under it. `recursive` (⌥) also opens the folders inside, a few
    /// levels deep and only while the outline stays reasonably small.
    func expand(_ id: String, recursive: Bool = false) {
        guard let e = entryIndex[id], FileTree.isExpandable(e) else { return }
        expanded.insert(id)
        expandedByRoot[currentURL.path] = expanded
        if recursive { recursivePending[id] = FileTree.recursiveDepth }
        let cached = children[id]?.entries != nil
        loadChildren(of: id, silent: cached)
        recomputeVisible()
        if cached { applyRecursion(id) }
    }

    func collapse(_ id: String) {
        guard expanded.contains(id) else { return }
        expanded.remove(id)
        expandedByRoot[currentURL.path] = expanded
        recursivePending.removeValue(forKey: id)
        recomputeVisible()
        // A selection inside the collapsed subtree moves to the folder (Finder).
        let inside = { (p: String) in p.hasPrefix(id + "/") }
        if let sel = selectionID, inside(sel) {
            selectionID = id
        } else if selectedIDs.contains(where: inside) {
            var set = selectedIDs.filter { !inside($0) }
            set.insert(id)
            setSelection(set, cursor: selectionID, keepAnchor: true)
        }
    }

    func toggleExpanded(_ id: String, recursive: Bool = false) {
        if expanded.contains(id) && !recursive { collapse(id) } else { expand(id, recursive: recursive) }
    }

    /// → key: expand a collapsed folder; if it is already open, step to its first child.
    func expandOrDescend(option: Bool = false) {
        guard let e = selectedEntry, FileTree.isExpandable(e) else { return }
        if option { expand(e.id, recursive: true); return }
        guard expanded.contains(e.id) else { expand(e.id); return }
        if let i = rows.firstIndex(where: { $0.id == e.id }), i + 1 < rows.count, rows[i + 1].parentID == e.id,
           let child = rows[i + 1].entry {
            selectionID = child.id
        }
    }

    /// ← key: collapse an open folder; otherwise select the parent row, or go up a folder at the top level.
    func collapseOrAscend() {
        if let e = selectedEntry {
            if expanded.contains(e.id) && FileTree.isExpandable(e) { collapse(e.id); return }
            if let row = rows.first(where: { $0.id == e.id }), let parent = row.parentID { selectionID = parent; return }
        }
        goUp()
    }

    private func loadChildren(of id: String, silent: Bool) {
        guard let e = entryIndex[id] else { return }
        childTasks[id]?.cancel()
        let url = e.url, hidden = settings.showHiddenFiles, key = sortKey, asc = ascending
        if !silent {
            // Only show the inline "loading…" row if the listing is actually slow.
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(150))
                guard let self, self.childTasks[id] != nil, self.children[id] == nil else { return }
                self.children[id] = .loading
                self.recomputeVisible()
            }
        }
        childTasks[id] = Task { [weak self] in
            let result = await Self.listing(of: url, showHidden: hidden, sortKey: key, ascending: asc)
            guard let self, !Task.isCancelled else { return }
            self.childTasks[id] = nil
            switch result {
            case .success(let items): self.children[id] = .loaded(items)
            case .failure(let err): self.children[id] = .failed(Self.describe(err))
            }
            self.recomputeVisible()
            self.pruneSelection()
            self.applyPendingSelection()
            self.applyRecursion(id)
        }
    }

    private static func describe(_ e: ListingError) -> String {
        switch e {
        case .permissionDenied: return "No permission to read this folder"
        case .notFound: return "Folder not found"
        case .notADirectory: return "Not a folder"
        case .other(_, let msg): return msg
        }
    }

    /// Continues a recursive expansion once `id`'s children are known.
    private func applyRecursion(_ id: String) {
        guard let left = recursivePending.removeValue(forKey: id), left > 0, let kids = children[id]?.entries else { return }
        var budget = FileTree.recursiveRowLimit - rows.count
        var changed = false
        for k in kids where FileTree.isExpandable(k) && !expanded.contains(k.id) {
            let known = children[k.id]?.entries
            budget -= known?.count ?? 1
            guard budget > 0 else { break }
            expanded.insert(k.id)
            changed = true
            if left > 1 { recursivePending[k.id] = left - 1 }
            loadChildren(of: k.id, silent: known != nil)
        }
        guard changed else { return }
        expandedByRoot[currentURL.path] = expanded
        recomputeVisible()
        for k in kids where recursivePending[k.id] != nil && children[k.id]?.entries != nil { applyRecursion(k.id) }
    }

    // MARK: Watching expanded folders

    private func syncChildWatchers() {
        let wanted = Set(rows.lazy.filter(\.isExpanded).map(\.id))
        for (path, src) in childWatchers where !wanted.contains(path) {
            src.cancel()
            childWatchers[path] = nil
            childReloadWork[path]?.cancel()
            childReloadWork[path] = nil
        }
        for path in wanted where childWatchers[path] == nil {
            childWatchers[path] = Self.makeWatcher(path: path) { [weak self] in self?.debouncedChildReload(path) }
        }
    }

    /// Watches one folder for changes (event-only descriptor: it does not keep a volume from
    /// unmounting and reads nothing). Nil when the folder can't be opened, e.g. no permission.
    private static func makeWatcher(path: String, onChange: @escaping @MainActor () -> Void) -> DispatchSourceFileSystemObject? {
        let fd = Darwin.open(path, O_EVTONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        src.setEventHandler { MainActor.assumeIsolated { onChange() } }
        src.setCancelHandler { Darwin.close(fd) }
        src.resume()
        return src
    }

    private func debouncedChildReload(_ path: String) {
        childReloadWork[path]?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.childReloadWork[path] = nil
            self.loadChildren(of: path, silent: true)
        }
        childReloadWork[path] = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: w)
    }

    // MARK: Watching (refresh when the folder changes on disk)

    private func watch(_ url: URL) {
        unwatch()
        watcher = Self.makeWatcher(path: url.path) { [weak self] in self?.debouncedReload() }
    }

    private func unwatch() {
        watcher?.cancel()
        watcher = nil
    }

    @ObservationIgnored private var reloadWork: DispatchWorkItem?
    private func debouncedReload() {
        reloadWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.load() }
        reloadWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: w)
    }

    // MARK: Recursive search

    private func scheduleDeepSearch() {
        cancelDeepSearch()
        let q = query.trimmingCharacters(in: .whitespaces)
        deepResults = []
        deepScanned = 0
        deepSkipped = 0
        deepTruncated = false
        guard !q.isEmpty else { return }
        deepRunning = true
        let root = currentURL, hidden = settings.showHiddenFiles, limit = Self.deepLimit
        deepTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))  // debounce typing
            guard !Task.isCancelled else { return }
            let stream = AsyncStream<(batch: [FileEntry], scanned: Int, skipped: Int, done: Bool, truncated: Bool)> { cont in
                let worker = Task.detached(priority: .utility) {
                    var skipped = 0
                    var opts: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
                    if !hidden { opts.insert(.skipsHiddenFiles) }
                    let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                            options: opts, errorHandler: { _, _ in skipped += 1; return true })
                    var batch: [FileEntry] = []
                    var scanned = 0, found = 0
                    var lastFlush = Date()
                    while let url = en?.nextObject() as? URL {
                        if Task.isCancelled { break }
                        scanned += 1
                        if url.lastPathComponent.localizedCaseInsensitiveContains(q) {
                            batch.append(FileListing.entry(for: url))
                            found += 1
                            if found >= limit {
                                cont.yield((batch, scanned, skipped, true, true)); cont.finish(); return
                            }
                        }
                        if Date().timeIntervalSince(lastFlush) > 0.12 {
                            cont.yield((batch, scanned, skipped, false, false)); batch = []; lastFlush = Date()
                        }
                    }
                    cont.yield((batch, scanned, skipped, true, false))
                    cont.finish()
                }
                cont.onTermination = { _ in worker.cancel() }
            }
            for await update in stream {
                guard let self, !Task.isCancelled else { return }
                self.deepResults.append(contentsOf: update.batch)
                self.deepScanned = update.scanned
                self.deepSkipped = update.skipped
                if update.done {
                    self.deepRunning = false
                    self.deepTruncated = update.truncated
                }
            }
        }
    }

    func cancelDeepSearch() {
        deepTask?.cancel()
        deepTask = nil
        deepRunning = false
    }

    // MARK: Actions

    func activate(_ e: FileEntry) {
        if e.isBrokenSymlink {
            onError?("“\(e.name)” is a broken link; its target no longer exists.")
        } else if e.isNavigableFolder {
            navigate(to: e.url)
        } else {
            open(e.url)
        }
    }

    func open(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            onError?("“\(url.lastPathComponent)” no longer exists.")
            reload()
            return
        }
        if let reason = runReason(url) {
            if let confirmRun { confirmRun(url, reason) { [weak self] in self?.launch(url) } }
            else { onError?("Refused to run “\(url.lastPathComponent)”.") }
            return
        }
        launch(url)
    }

    /// Terminal-like apps that execute the file they are asked to open.
    static let executingApps: Set<String> = ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty",
                                             "net.kovidgoyal.kitty", "com.github.wez.wezterm", "io.alacritty",
                                             "dev.warp.Warp-Stable", "co.zeit.hyper",
                                             // Runs a .jar as a program.
                                             "com.apple.JarLauncher"]

    /// Non-nil when "opening" this file would execute it (Finder semantics), with a short reason.
    ///
    /// A symlink is judged by what it points at: the link's own type is just "alias", so a link
    /// to a script or binary would otherwise be run without the question.
    func runReason(_ url: URL) -> String? {
        let target = url.resolvingSymlinksInPath()
        // Apps and other bundles are launched deliberately; that is what opening them means.
        if NSWorkspace.shared.isFilePackage(atPath: target.path) { return nil }
        for candidate in target == url ? [url] : [url, target] {
            if let app = defaultApp(for: candidate), let bid = Bundle(url: app)?.bundleIdentifier, Self.executingApps.contains(bid) {
                return "Its default app is \(app.deletingPathExtension().lastPathComponent), which runs it as a program."
            }
        }
        if let type = try? target.resourceValues(forKeys: [.contentTypeKey]).contentType, type.conforms(to: .unixExecutable) {
            return "It is an executable program."
        }
        return nil
    }

    /// "Open With": a specific app. Still asks first if that app would execute the file.
    func open(_ url: URL, with appURL: URL) {
        let report = onError
        let go = {
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration()) { _, err in
                if let err { DispatchQueue.main.async { report?("Could not open “\(url.lastPathComponent)”: \(err.localizedDescription)") } }
            }
        }
        if let bid = Bundle(url: appURL)?.bundleIdentifier, Self.executingApps.contains(bid) {
            let reason = "\(appURL.deletingPathExtension().lastPathComponent) runs files as programs."
            if let confirmRun { confirmRun(url, reason, go) } else { onError?("Refused to run “\(url.lastPathComponent)”.") }
            return
        }
        go()
    }

    private func launch(_ url: URL) {
        // Standard LaunchServices open: the user's default app for this file type.
        NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, err in
            if let err {
                DispatchQueue.main.async { self?.onError?("Could not open “\(url.lastPathComponent)”: \(err.localizedDescription)") }
            }
        }
    }

    func defaultApp(for url: URL) -> URL? { NSWorkspace.shared.urlForApplication(toOpen: url) }

    func reveal(_ urls: [URL]) { NSWorkspace.shared.activateFileViewerSelecting(urls) }

    func copyPaths(_ urls: [URL]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
    }

    func moveSelection(_ delta: Int) {
        let rows = visible
        guard !rows.isEmpty else { return }
        let i = rows.firstIndex { $0.id == selectionID } ?? (delta > 0 ? -1 : rows.count)
        selectionID = rows[max(0, min(rows.count - 1, i + delta))].id
    }

    func toggleSort(_ key: FileSortKey) {
        if sortKey == key { ascending.toggle() } else { sortKey = key; ascending = key == .name || key == .kind }
    }
}
