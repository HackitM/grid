import XCTest
@testable import GridCore

/// The outline's sorting and filtering shortcuts must not change what it shows.
final class FileOutlineReviewTests: XCTestCase {
    private func entry(_ path: String, dir: Bool = false, size: Int64? = nil, kind: String? = nil, modified: Date? = nil) -> FileEntry {
        let url = URL(fileURLWithPath: path)
        return FileEntry(url: url, name: url.lastPathComponent, isDirectory: dir, isPackage: false, isSymlink: false,
                         isBrokenSymlink: false, isHidden: false, size: size, modified: modified,
                         kind: kind ?? (dir ? "Folder" : "Document"), typeIdentifier: nil, isRegularFile: !dir)
    }

    func testSortFallsBackToNameOnlyForTies() {
        let t0 = Date(timeIntervalSince1970: 1_000), t1 = Date(timeIntervalSince1970: 2_000)
        let items = [
            entry("/r/b.txt", size: 10, kind: "Text", modified: t1),
            entry("/r/a.txt", size: 10, kind: "Text", modified: t0),
            entry("/r/c.png", size: 5, kind: "Image", modified: t1),
            entry("/r/dir", dir: true),
            entry("/r/file10", size: 1), entry("/r/file2", size: 1),
        ]
        func names(_ key: FileSortKey, _ asc: Bool) -> [String] { FileListing.sorted(items, by: key, ascending: asc).map(\.name) }
        // Folders first; numeric-aware names.
        XCTAssertEqual(names(.name, true), ["dir", "a.txt", "b.txt", "c.png", "file2", "file10"])
        XCTAssertEqual(names(.name, false), ["dir", "file10", "file2", "c.png", "b.txt", "a.txt"])
        // Equal sizes fall back to the name; folders (no size) stay first.
        XCTAssertEqual(names(.size, true), ["dir", "file2", "file10", "c.png", "a.txt", "b.txt"])
        // Equal kinds fall back to the name.
        XCTAssertEqual(names(.kind, true), ["dir", "file2", "file10", "c.png", "a.txt", "b.txt"])
        // Equal dates fall back to the name; items without a date sort as oldest.
        XCTAssertEqual(names(.modified, true), ["dir", "file2", "file10", "a.txt", "b.txt", "c.png"])
    }

    func testSortingSortedInputIsUnchanged() {
        let items = (0..<200).map { entry("/r/item \($0)", size: Int64($0 % 7)) }
        for key in FileSortKey.allCases {
            for asc in [true, false] {
                let once = FileListing.sorted(items, by: key, ascending: asc)
                XCTAssertEqual(FileListing.sorted(once, by: key, ascending: asc), once, "\(key) \(asc)")
            }
        }
    }

    /// The filter runs before the sort; the rows must be exactly those of sorting first.
    func testFilteredOutlineMatchesSortThenFilter() {
        let roots = [entry("/r/zeta", dir: true), entry("/r/alpha.txt"), entry("/r/beta", dir: true), entry("/r/Alphabet.md"), entry("/r/gamma.txt")]
        let kids: [String: FileTreeChildren] = [
            "/r/zeta": .loaded([entry("/r/zeta/alpha-notes.txt"), entry("/r/zeta/other.txt")]),
            "/r/beta": .loaded([entry("/r/beta/nothing.txt")]),
        ]
        let rows = FileTree.flatten(roots: roots, children: kids, expanded: ["/r/zeta", "/r/beta"], sortKey: .name, ascending: true, query: "alpha")
        // "beta" is open but holds no match, so it is hidden; "zeta" stays for its matching child.
        XCTAssertEqual(rows.map(\.id), ["/r/zeta", "/r/zeta/alpha-notes.txt", "/r/alpha.txt", "/r/Alphabet.md"])
        XCTAssertEqual(rows.map(\.depth), [0, 1, 0, 0])

        let all = FileTree.flatten(roots: roots, children: kids, expanded: ["/r/zeta", "/r/beta"], sortKey: .name, ascending: true)
        let expectedOrder = all.map(\.id).filter { Set(rows.map(\.id)).contains($0) }
        XCTAssertEqual(rows.map(\.id), expectedOrder)
    }

    func testFilterKeepsPlaceholdersOnlyUnderMatchingFolders() {
        let roots = [entry("/r/logs", dir: true), entry("/r/src", dir: true)]
        let kids: [String: FileTreeChildren] = ["/r/logs": .loading, "/r/src": .failed("No permission")]
        let rows = FileTree.flatten(roots: roots, children: kids, expanded: ["/r/logs", "/r/src"], sortKey: .name, ascending: true, query: "log")
        XCTAssertEqual(rows.map(\.id), ["/r/logs", FileTree.loadingID(for: "/r/logs")])
    }
}
