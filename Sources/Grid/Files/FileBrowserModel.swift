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

    var sortKey: FileSortKey = .name { didSet { recomputeVisible() } }
    var ascending = true { didSet { recomputeVisible() } }
    var query = "" { didSet { if mode == .deep { scheduleDeepSearch() }; recomputeVisible() } }
    var mode: FileSearchMode = .here { didSet { if mode == .deep { scheduleDeepSearch() } else { cancelDeepSearch() }; recomputeVisible() } }

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
        set { settings.showHiddenFiles = newValue; load() }
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var canGoUp: Bool { currentURL.path != "/" }

    /// Rows currently shown: filtered folder listing, or recursive results. Cached: recomputed
    /// only when entries, sort, query, or mode change (it used to re-sort on every access).
    private(set) var visible: [FileEntry] = []

    private func recomputeVisible() {
        if mode == .deep && !query.trimmingCharacters(in: .whitespaces).isEmpty {
            visible = deepResults
        } else {
            visible = FileListing.sorted(FileListing.filter(entries, query: query), by: sortKey, ascending: ascending)
        }
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
        return visible.first { $0.id == id } ?? entries.first { $0.id == id }
    }

    // MARK: Navigation

    func navigate(to url: URL, recordHistory: Bool = true) {
        let target = url.standardizedFileURL
        if recordHistory && target.path != currentURL.path {
            backStack.append(currentURL)
            forwardStack.removeAll()
        }
        let previous = currentURL
        currentURL = target
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
        let url = currentURL, hidden = settings.showHiddenFiles
        loadTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> Result<[FileEntry], ListingError> in
                do { return .success(try FileListing.list(url, showHidden: hidden)) }
                catch let e as ListingError { return .failure(e) }
                catch { return .failure(.other(url.path, error.localizedDescription)) }
            }.value
            guard let self, !Task.isCancelled, self.currentURL == url else { return }
            self.loading = false
            switch result {
            case .success(let items):
                self.entries = items
                self.error = nil
                let ids = Set(items.map(\.id))
                if let sel = self.selectionID, !ids.contains(sel) {
                    self.selectionID = nil
                } else if !self.selectedIDs.isSubset(of: ids) {
                    self.setSelection(self.selectedIDs.intersection(ids), cursor: self.selectionID, keepAnchor: true)
                }
                if let pending = self.pendingSelection, pending.allSatisfy(ids.contains) {
                    self.select(paths: pending)
                    self.pendingSelection = nil
                }
                self.watch(url)
            case .failure(let e):
                self.entries = []
                self.error = e
                self.unwatch()
            }
        }
    }

    // MARK: Watching (refresh when the folder changes on disk)

    private func watch(_ url: URL) {
        unwatch()
        let fd = Darwin.open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        src.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.debouncedReload() }
        }
        src.setCancelHandler { Darwin.close(fd) }
        src.resume()
        watcher = src
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
                                             "dev.warp.Warp-Stable", "co.zeit.hyper"]

    /// Non-nil when "opening" this file would execute it (Finder semantics), with a short reason.
    func runReason(_ url: URL) -> String? {
        // Apps and other bundles are launched deliberately; that is what opening them means.
        if NSWorkspace.shared.isFilePackage(atPath: url.path) { return nil }
        if let app = defaultApp(for: url), let bid = Bundle(url: app)?.bundleIdentifier, Self.executingApps.contains(bid) {
            return "Its default app is \(app.deletingPathExtension().lastPathComponent), which runs it as a program."
        }
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType, type.conforms(to: .unixExecutable) {
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
