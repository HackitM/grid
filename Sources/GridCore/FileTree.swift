import Foundation

/// What is known about a folder's contents in the outline (keyed by the folder's path).
public enum FileTreeChildren: Equatable, Sendable {
    /// Listing has been running long enough to show an inline "loading…" row.
    case loading
    case loaded([FileEntry])
    /// Listing failed; `message` is shown inline, indented under the folder.
    case failed(String)

    public var entries: [FileEntry]? {
        if case .loaded(let e) = self { return e }
        return nil
    }
}

/// One row of the flattened outline: a file entry at some depth, or an inline placeholder
/// ("loading…" / error) under an expanded folder.
public struct FileTreeRow: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case entry(FileEntry)
        case loading
        case error(String)
    }

    public let id: String
    public let kind: Kind
    /// 0 for items of the current folder, 1 for their children, and so on.
    public let depth: Int
    /// Path of the enclosing expanded folder row, nil at the top level.
    public let parentID: String?
    /// True for a folder row whose children are shown below it.
    public let isExpanded: Bool

    public init(id: String, kind: Kind, depth: Int, parentID: String?, isExpanded: Bool) {
        self.id = id; self.kind = kind; self.depth = depth; self.parentID = parentID; self.isExpanded = isExpanded
    }

    public var entry: FileEntry? {
        if case .entry(let e) = kind { return e }
        return nil
    }
    public var isPlaceholder: Bool { entry == nil }
}

/// Pure outline logic for the file browser: flattens a root listing plus a cache of children
/// into ordered rows with depth. The model owns loading and expansion state; this only arranges.
public enum FileTree {
    /// ⌥→ / ⌥-click expands this many levels below the folder…
    public static let recursiveDepth = 3
    /// …but stops adding folders once the outline would exceed this many rows.
    public static let recursiveRowLimit = 500

    /// Folders can be opened in place; packages (.app etc.) and broken links cannot.
    public static func isExpandable(_ e: FileEntry) -> Bool { e.isNavigableFolder && !e.isBrokenSymlink }

    public static func loadingID(for folder: String) -> String { folder + "/\u{0}loading" }
    public static func errorID(for folder: String) -> String { folder + "/\u{0}error" }

    /// Flattens the outline.
    ///
    /// - Each level is sorted with `sortKey`/`ascending` (folders first).
    /// - A folder in `expanded` shows its children directly below, one level deeper. A folder
    ///   whose children are not in the map yet contributes no placeholder (the listing is quick
    ///   most of the time); `.loading` and `.failed` contribute one indented placeholder row.
    /// - Expansion state of folders that are hidden (because an ancestor is collapsed) is kept
    ///   in `expanded` untouched, so reopening the ancestor restores it (Finder-like).
    /// - A non-empty `query` keeps rows whose name matches at any loaded level together with
    ///   their ancestors; folders with no match (by name or below) are hidden.
    public static func flatten(roots: [FileEntry], children: [String: FileTreeChildren], expanded: Set<String>,
                               sortKey: FileSortKey, ascending: Bool, query: String = "") -> [FileTreeRow] {
        let q = query.trimmingCharacters(in: .whitespaces)
        var out: [FileTreeRow] = []
        walk(roots, depth: 0, parent: nil, into: &out, children: children, expanded: expanded,
             sortKey: sortKey, ascending: ascending, query: q)
        return out
    }

    private static func walk(_ entries: [FileEntry], depth: Int, parent: String?, into out: inout [FileTreeRow],
                             children: [String: FileTreeChildren], expanded: Set<String>,
                             sortKey: FileSortKey, ascending: Bool, query q: String) {
        for e in FileListing.sorted(entries, by: sortKey, ascending: ascending) {
            let matches = q.isEmpty || e.name.localizedCaseInsensitiveContains(q)
            let open = expanded.contains(e.id) && isExpandable(e)
            guard open else {
                if matches { out.append(FileTreeRow(id: e.id, kind: .entry(e), depth: depth, parentID: parent, isExpanded: false)) }
                continue
            }
            var sub: [FileTreeRow] = []
            switch children[e.id] {
            case .loaded(let kids)?:
                walk(kids, depth: depth + 1, parent: e.id, into: &sub, children: children, expanded: expanded,
                     sortKey: sortKey, ascending: ascending, query: q)
            case .loading?:
                if matches { sub.append(FileTreeRow(id: loadingID(for: e.id), kind: .loading, depth: depth + 1, parentID: e.id, isExpanded: false)) }
            case .failed(let msg)?:
                if matches { sub.append(FileTreeRow(id: errorID(for: e.id), kind: .error(msg), depth: depth + 1, parentID: e.id, isExpanded: false)) }
            case nil:
                break
            }
            if matches || !sub.isEmpty {
                out.append(FileTreeRow(id: e.id, kind: .entry(e), depth: depth, parentID: parent, isExpanded: true))
                out.append(contentsOf: sub)
            }
        }
    }

    /// Every entry reachable through expanded folders (unfiltered), keyed by path. Used for
    /// selection lookups so a selected row that the filter hides still resolves.
    public static func reachable(roots: [FileEntry], children: [String: FileTreeChildren], expanded: Set<String>) -> [String: FileEntry] {
        var index: [String: FileEntry] = [:]
        var stack = roots
        while let e = stack.popLast() {
            index[e.id] = e
            if expanded.contains(e.id), isExpandable(e), let kids = children[e.id]?.entries { stack.append(contentsOf: kids) }
        }
        return index
    }
}
