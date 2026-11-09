import AppKit
import Darwin
import GridCore
import Observation

enum FileSearchMode: String, CaseIterable {
    case here, deep
    var label: String { self == .here ? "THIS FOLDER" : "RECURSIVE" }
}

@Observable
@MainActor
final class FileBrowserModel {
    private(set) var currentURL: URL
    private(set) var entries: [FileEntry] = []
    private(set) var error: ListingError?
    private(set) var loading = false
    private var backStack: [URL] = []
    private var forwardStack: [URL] = []

    var sortKey: FileSortKey = .name
    var ascending = true
    var query = "" { didSet { if mode == .deep { scheduleDeepSearch() } } }
    var mode: FileSearchMode = .here { didSet { if mode == .deep { scheduleDeepSearch() } else { cancelDeepSearch() } } }
    var selectionID: String?

    // Recursive search state (real counts, not decoration)
    private(set) var deepResults: [FileEntry] = []
    private(set) var deepScanned = 0
    private(set) var deepSkipped = 0
    private(set) var deepRunning = false
    private(set) var deepTruncated = false
    static let deepLimit = 1000

    @ObservationIgnored private let settings: Settings
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var deepTask: Task<Void, Never>?
    @ObservationIgnored private var watcher: DispatchSourceFileSystemObject?
    @ObservationIgnored var onError: ((String) -> Void)?

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

    /// Rows currently shown: filtered folder listing, or recursive results.
    var visible: [FileEntry] {
        if mode == .deep && !query.trimmingCharacters(in: .whitespaces).isEmpty { return deepResults }
        return FileListing.sorted(FileListing.filter(entries, query: query), by: sortKey, ascending: ascending)
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
                if let sel = self.selectionID, !items.contains(where: { $0.id == sel }) { self.selectionID = nil }
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
