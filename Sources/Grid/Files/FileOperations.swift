import AppKit
import GridCore
import Observation

/// File operations with Finder-like semantics: never deletes permanently unless explicitly asked
/// (and confirmed), resolves name conflicts with the user, and records undo for every change.
@Observable
@MainActor
final class FileOperations {
    /// One reversible change on disk.
    enum Step {
        case created(URL)                        // undo: move to Trash
        case renamed(from: URL, to: URL)         // undo: rename back
        case moved(from: URL, to: URL)           // undo: move back
        case copied(URL)                         // undo: move copy to Trash
        case trashed(original: URL, inTrash: URL) // undo: put back
    }

    struct Record {
        let label: String
        let steps: [Step]
    }

    private(set) var busy: String?               // e.g. "Copying 3 items…" (shown in Files status)
    private(set) var undoStack: [Record] = []
    var canUndo: Bool { !undoStack.isEmpty && busy == nil }
    var undoLabel: String? { undoStack.last.map { "Undo \($0.label)" } }

    @ObservationIgnored private unowned let files: FileBrowserModel
    @ObservationIgnored weak var app: AppState?

    init(files: FileBrowserModel) { self.files = files }

    // MARK: Create / rename

    func newFolder() {
        let dir = files.currentURL
        let name = FileNaming.uniqueName(for: "untitled folder", isDirectory: true) {
            FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path)
        }
        let url = dir.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            record("New Folder", [.created(url)])
            files.pendingSelection = [url.path]
            files.renamingID = url.path
            files.reload()
        } catch {
            fail("Could not create a folder in \(PathResolver.abbreviate(dir.path))", error)
        }
    }

    /// Returns an error message to show inline, or nil on success.
    func rename(_ entry: FileEntry, to newName: String) -> String? {
        if newName == entry.name { return nil }
        if let problem = FileNaming.validate(newName) { return problem }
        let dest = entry.url.deletingLastPathComponent().appendingPathComponent(newName)
        // Case-only renames on case-insensitive volumes report the destination as existing.
        let caseOnly = newName.lowercased() == entry.name.lowercased()
        if !caseOnly && FileManager.default.fileExists(atPath: dest.path) {
            return "“\(newName)” already exists here."
        }
        do {
            try FileManager.default.moveItem(at: entry.url, to: dest)
            record("Rename", [.renamed(from: entry.url, to: dest)])
            files.pendingSelection = [dest.path]
            files.reload()
            return nil
        } catch {
            return (error as NSError).localizedDescription
        }
    }

    // MARK: Trash / delete

    func trash(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        run(label: "Move to Trash", progress: "Moving \(count(urls)) to Trash…") { log in
            for u in urls {
                var out: NSURL?
                try FileManager.default.trashItem(at: u, resultingItemURL: &out)
                if let t = out as URL? { log(.trashed(original: u, inTrash: t)) }
            }
        } done: { [weak self] steps in
            self?.notice("Moved \(self?.count(urls) ?? "") to Trash", undo: !steps.isEmpty)
        }
    }

    /// Permanent deletion: only after an explicit confirmation that says it can't be undone.
    func requestDeleteImmediately(_ urls: [URL]) {
        guard !urls.isEmpty, let app else { return }
        let what = urls.count == 1 ? "“\(urls[0].lastPathComponent)”" : "\(urls.count) items"
        app.present(Confirmation(
            code: "DELETE.PERMANENT", title: "Delete \(what) immediately?",
            message: "This permanently deletes \(what) without using the Trash. It can't be undone.",
            confirmLabel: "Delete", destructive: true,
            onConfirm: { [weak self] in self?.deleteNow(urls) }))
    }

    private func deleteNow(_ urls: [URL]) {
        run(label: nil, progress: "Deleting \(count(urls))…") { _ in
            for u in urls { try FileManager.default.removeItem(at: u) }
        } done: { [weak self] _ in
            self?.notice("Deleted \(self?.count(urls) ?? "") permanently", undo: false)
        }
    }

    // MARK: Duplicate / copy / move

    func duplicate(_ urls: [URL]) {
        transfer(urls, into: files.currentURL, move: false)
    }

    /// ⌘C: puts file URLs (for Finder and other apps) and plain paths on the pasteboard.
    func copyToPasteboard(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls.map { $0 as NSURL })
        app?.flash(.info, "Copied \(count(urls))")
    }

    func pasteFromPasteboard(into dir: URL, move: Bool) {
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = (NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: opts) as? [URL]) ?? []
        guard !urls.isEmpty else { app?.flash(.error, "Nothing to paste: copy files first (⌘C)."); return }
        transfer(urls, into: dir, move: move)
    }

    /// Copies or moves `sources` into `dir`, asking once how to handle name conflicts.
    func transfer(_ sources: [URL], into dir: URL, move: Bool) {
        let fm = FileManager.default
        var plain: [(URL, URL)] = []
        var conflicts: [(URL, URL)] = []
        var autoKeepBoth: [URL] = []
        for src in sources {
            let srcDir = src.deletingLastPathComponent().standardizedFileURL
            if move && srcDir.path == dir.standardizedFileURL.path { continue }          // already here
            var isDir: ObjCBool = false
            fm.fileExists(atPath: src.path, isDirectory: &isDir)
            if isDir.boolValue && FileNaming.isSameOrInside(dir, src) {
                app?.flash(.error, "Can't \(move ? "move" : "copy") “\(src.lastPathComponent)” into itself.")
                return
            }
            let dst = dir.appendingPathComponent(src.lastPathComponent)
            if fm.fileExists(atPath: dst.path) {
                if !move && srcDir.path == dir.standardizedFileURL.path { autoKeepBoth.append(src) } // duplicate
                else { conflicts.append((src, dst)) }
            } else {
                plain.append((src, dst))
            }
        }
        let go: (_ replace: Bool, _ keepBoth: Bool) -> Void = { [weak self] replace, keepBoth in
            var jobs = plain.map { ($0.0, $0.1, false) }
            jobs += autoKeepBoth.map { ($0, Self.uniqueDestination(for: $0, in: dir), false) }
            for (src, dst) in conflicts {
                if replace { jobs.append((src, dst, true)) }
                else if keepBoth { jobs.append((src, Self.uniqueDestination(for: src, in: dir), false)) }
            }
            self?.perform(jobs, move: move, into: dir)
        }
        guard !conflicts.isEmpty else { go(false, false); return }
        let names = conflicts.prefix(3).map { "“\($0.0.lastPathComponent)”" }.joined(separator: ", ")
            + (conflicts.count > 3 ? " and \(conflicts.count - 3) more" : "")
        app?.present(Confirmation(
            code: "NAME.CONFLICT",
            title: conflicts.count == 1 ? "An item with this name already exists" : "\(conflicts.count) items already exist",
            message: "\(names) already exist\(conflicts.count == 1 ? "s" : "") in \(PathResolver.abbreviate(dir.path)). Replace moves the existing items to the Trash first (undoable).",
            confirmLabel: "Replace", destructive: true,
            onConfirm: { go(true, false) },
            onCancel: { if !plain.isEmpty || !autoKeepBoth.isEmpty { go(false, false) } },
            alternateLabel: "Keep Both", onAlternate: { go(false, true) },
            cancelLabel: plain.isEmpty && autoKeepBoth.isEmpty ? "Cancel" : "Skip These"))
    }

    nonisolated static func uniqueDestination(for src: URL, in dir: URL) -> URL {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: src.path, isDirectory: &isDir)
        let name = FileNaming.uniqueName(for: src.lastPathComponent, isDirectory: isDir.boolValue) {
            FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path)
        }
        return dir.appendingPathComponent(name)
    }

    private func perform(_ jobs: [(URL, URL, Bool)], move: Bool, into dir: URL) {
        guard !jobs.isEmpty else { return }
        let verb = move ? "Move" : "Copy"
        let urls = jobs.map(\.0)
        run(label: verb, progress: "\(move ? "Moving" : "Copying") \(count(urls))…") { log in
            let fm = FileManager.default
            for (src, dst, replace) in jobs {
                if replace {
                    var out: NSURL?
                    try fm.trashItem(at: dst, resultingItemURL: &out)
                    if let t = out as URL? { log(.trashed(original: dst, inTrash: t)) }
                }
                if move {
                    try fm.moveItem(at: src, to: dst)
                    log(.moved(from: src, to: dst))
                } else {
                    try fm.copyItem(at: src, to: dst)
                    log(.copied(dst))
                }
            }
        } done: { [weak self] steps in
            guard let self else { return }
            let landed = steps.compactMap { step -> String? in
                switch step { case .moved(_, let to): to.path; case .copied(let u): u.path; default: nil }
            }
            if dir.standardizedFileURL.path == self.files.currentURL.standardizedFileURL.path { self.files.pendingSelection = landed }
            self.notice("\(move ? "Moved" : "Copied") \(self.count(urls)) to \(PathResolver.abbreviate(dir.path))", undo: true)
        }
    }

    // MARK: Undo

    func undo() {
        guard canUndo, let rec = undoStack.popLast() else { return }
        let steps = rec.steps
        run(label: nil, progress: "Undoing \(rec.label)…") { _ in
            let fm = FileManager.default
            for step in steps.reversed() {
                switch step {
                case .created(let u), .copied(let u):
                    var out: NSURL?
                    try fm.trashItem(at: u, resultingItemURL: &out)
                case .renamed(let from, let to), .moved(let from, let to):
                    try fm.moveItem(at: to, to: from)
                case .trashed(let original, let inTrash):
                    try fm.moveItem(at: inTrash, to: original)
                }
            }
        } done: { [weak self] _ in
            self?.app?.flash(.info, "Undid \(rec.label)")
        }
    }

    // MARK: Plumbing

    /// Runs filesystem work off the main thread. Steps that succeed are recorded for undo even
    /// if a later item fails, so a partial operation can still be reversed.
    private func run(label: String?, progress: String,
                     _ work: @escaping @Sendable (_ log: (Step) -> Void) throws -> Void,
                     done: @escaping ([Step]) -> Void) {
        guard busy == nil else { app?.flash(.error, "Another file operation is still running."); return }
        busy = progress
        Task { [weak self] in
            let (steps, failure) = await Task.detached(priority: .userInitiated) { () -> ([Step], String?) in
                var steps: [Step] = []
                do {
                    try work { steps.append($0) }
                    return (steps, nil)
                } catch {
                    return (steps, (error as NSError).localizedDescription)
                }
            }.value
            guard let self else { return }
            self.busy = nil
            if let label, !steps.isEmpty { self.record(label, steps) }
            self.files.reload()
            if let failure {
                self.app?.flash(.error, failure + (steps.isEmpty ? "" : " (completed items can be undone with ⌘Z)"))
            } else {
                done(steps)
            }
        }
    }

    private func record(_ label: String, _ steps: [Step]) {
        undoStack.append(Record(label: label, steps: steps))
        if undoStack.count > 30 { undoStack.removeFirst() }
    }

    private func notice(_ text: String, undo: Bool) {
        guard let app else { return }
        if undo, canUndo {
            app.flash(.info, text, actionLabel: "Undo ⌘Z") { [weak self] in self?.undo() }
        } else {
            app.flash(.info, text)
        }
    }

    private func fail(_ what: String, _ error: Error) {
        app?.flash(.error, "\(what): \((error as NSError).localizedDescription)")
    }

    private func count(_ urls: [URL]) -> String {
        urls.count == 1 ? "“\(urls[0].lastPathComponent)”" : "\(urls.count) items"
    }
}
