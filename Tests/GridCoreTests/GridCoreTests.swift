import XCTest
@testable import GridCore

final class ShellQuotingTests: XCTestCase {
    func testSafePathUnchanged() {
        XCTAssertEqual(ShellQuoting.quote("/usr/local/bin"), "/usr/local/bin")
    }

    func testSpacesAndUnicodeAreSingleQuoted() {
        XCTAssertEqual(ShellQuoting.quote("/tmp/My Folder/résumé ✓.txt"), "'/tmp/My Folder/résumé ✓.txt'")
    }

    func testSingleQuoteEscaped() {
        XCTAssertEqual(ShellQuoting.quote("/tmp/it's"), "'/tmp/it'\\''s'")
    }

    func testShellMetacharactersAreInert() {
        let q = ShellQuoting.quote("/tmp/$(rm -rf ~); `x` & | > *")
        XCTAssertTrue(q.hasPrefix("'") && q.hasSuffix("'"))
    }

    func testNewlineNeverEmittedRaw() {
        let q = ShellQuoting.quote("/tmp/evil\nrm -rf ~")
        XCTAssertFalse(q.contains("\n"))
        XCTAssertEqual(q, "$'/tmp/evil\\nrm -rf ~'")
    }

    func testEscapeAndC1ControlsEscaped() {
        let q = ShellQuoting.quote("/tmp/a\u{1b}[31mb\u{9b}c")
        XCTAssertFalse(q.unicodeScalars.contains { $0.value < 0x20 || (0x80...0x9F).contains($0.value) })
        XCTAssertTrue(q.contains("\\x1b"))
        XCTAssertTrue(q.contains("\\u009b"))
    }

    func testLeadingDashQuoted() {
        XCTAssertEqual(ShellQuoting.quote("-rf"), "'-rf'")
    }

    func testInsertionTextHasNoNewlineAndTrailingSpace() {
        let t = ShellQuoting.insertionText(forPaths: ["/a b", "/c"])
        XCTAssertEqual(t, "'/a b' /c ")
    }

    /// Round-trip through a real zsh to prove quoting yields the exact original word.
    func testRoundTripThroughZsh() throws {
        let samples = ["/tmp/My Folder", "/tmp/it's here", "/tmp/日本語 ファイル", "/tmp/a\nb", "/tmp/$HOME `x`", "/tmp/tab\there", "/tmp/back\\slash"]
        for s in samples {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-f", "-c", "printf %s \(ShellQuoting.quote(s))"]
            let pipe = Pipe()
            p.standardOutput = pipe
            try p.run()
            p.waitUntilExit()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
            XCTAssertEqual(out, s, "round trip failed for \(s.debugDescription)")
        }
    }
}

final class FuzzyMatchTests: XCTestCase {
    func testOrdering() {
        let exact = FuzzyMatch.score("safari", in: "Safari")!
        let prefix = FuzzyMatch.score("saf", in: "Safari")!
        let word = FuzzyMatch.score("code", in: "Visual Studio Code")!
        let initials = FuzzyMatch.score("vsc", in: "Visual Studio Code")!
        let contains = FuzzyMatch.score("ari", in: "Safari")!
        XCTAssertGreaterThan(exact, prefix)
        XCTAssertGreaterThan(prefix, word)
        XCTAssertGreaterThan(word, initials)
        XCTAssertGreaterThan(initials, contains)
        XCTAssertNil(FuzzyMatch.score("zzz", in: "Safari"))
        XCTAssertNotNil(FuzzyMatch.score("sfr", in: "Safari"))
    }
}

final class PathResolverTests: XCTestCase {
    let home = URL(fileURLWithPath: "/Users/test")
    let base = URL(fileURLWithPath: "/Users/test/Projects")

    func testTilde() {
        XCTAssertEqual(PathResolver.resolve("~", relativeTo: base, home: home)?.path, "/Users/test")
        XCTAssertEqual(PathResolver.resolve("~/Docs", relativeTo: base, home: home)?.path, "/Users/test/Docs")
    }

    func testRelativeAndDotDot() {
        XCTAssertEqual(PathResolver.resolve("../Downloads", relativeTo: base, home: home)?.path, "/Users/test/Downloads")
        XCTAssertEqual(PathResolver.resolve("sub dir", relativeTo: base, home: home)?.path, "/Users/test/Projects/sub dir")
    }

    func testQuotedPasteAccepted() {
        XCTAssertEqual(PathResolver.resolve("'/tmp/a b'", relativeTo: base, home: home)?.path, "/tmp/a b")
    }

    func testAbbreviate() {
        XCTAssertEqual(PathResolver.abbreviate("/Users/test/x", home: "/Users/test"), "~/x")
        XCTAssertEqual(PathResolver.abbreviate("/Users/tester", home: "/Users/test"), "/Users/tester")
    }

    func testAncestors() {
        XCTAssertEqual(PathResolver.ancestors(of: URL(fileURLWithPath: "/a/b")).map(\.path), ["/", "/a", "/a/b"])
    }
}

final class WebAddressTests: XCTestCase {
    func testAccepts() {
        XCTAssertEqual(WebAddress.normalize("example.com")?.absoluteString, "https://example.com")
        XCTAssertEqual(WebAddress.normalize("https://example.com/a?b=1")?.absoluteString, "https://example.com/a?b=1")
        XCTAssertEqual(WebAddress.normalize("localhost:3000")?.absoluteString, "http://localhost:3000")
        XCTAssertEqual(WebAddress.normalize("docs.swift.org/x")?.absoluteString, "https://docs.swift.org/x")
    }

    func testRejectsNonWebSchemes() {
        XCTAssertNil(WebAddress.normalize("javascript:alert(1)"))
        XCTAssertNil(WebAddress.normalize("file:///etc/passwd"))
        XCTAssertNil(WebAddress.normalize("data:text/html,hi"))
        XCTAssertNil(WebAddress.normalize("ftp://example.com"))
        XCTAssertNil(WebAddress.normalize("hello world"))
        XCTAssertNil(WebAddress.normalize("Safari"))
    }
}

final class PaletteGrammarTests: XCTestCase {
    func testVerbs() {
        XCTAssertEqual(PaletteGrammar.parse("app Safari"), .app("Safari"))
        XCTAssertEqual(PaletteGrammar.parse("grid files ~/Projects"), .files("~/Projects"))
        XCTAssertEqual(PaletteGrammar.parse("web example.com"), .web("example.com"))
        XCTAssertEqual(PaletteGrammar.parse("term ~/a b"), .term("~/a b"))
        XCTAssertEqual(PaletteGrammar.parse("theme ares"), .theme("ares"))
    }

    func testBareVerbIsFreeText() {
        XCTAssertEqual(PaletteGrammar.parse("files"), .freeText("files"))
        XCTAssertEqual(PaletteGrammar.parse("Safari"), .freeText("Safari"))
    }
}

final class ShellEnvironmentTests: XCTestCase {
    func testStripsForeignTerminalIdentity() {
        let env = ShellEnvironment.build(shell: "/bin/zsh", inherited: [
            "TERM": "dumb", "TERM_PROGRAM": "iTerm.app", "ITERM_SESSION_ID": "x", "CLAUDECODE": "1",
            "CLAUDE_CODE_ENTRYPOINT": "cli", "CLAUDE_CODE_USE_BEDROCK": "1", "SSH_AUTH_SOCK": "/tmp/s", "PATH": "/x",
        ], appVersion: "0.1")
        let dict = Dictionary(uniqueKeysWithValues: env.map { kv -> (String, String) in
            let i = kv.firstIndex(of: "=")!
            return (String(kv[..<i]), String(kv[kv.index(after: i)...]))
        })
        XCTAssertEqual(dict["TERM"], "xterm-256color")
        XCTAssertEqual(dict["TERM_PROGRAM"], "Grid")
        XCTAssertEqual(dict["COLORTERM"], "truecolor")
        XCTAssertNil(dict["ITERM_SESSION_ID"])
        XCTAssertNil(dict["CLAUDECODE"])
        XCTAssertNil(dict["CLAUDE_CODE_ENTRYPOINT"])
        XCTAssertEqual(dict["CLAUDE_CODE_USE_BEDROCK"], "1")
        XCTAssertEqual(dict["SSH_AUTH_SOCK"], "/tmp/s")
        XCTAssertEqual(dict["PATH"], "/x")
        XCTAssertNotNil(dict["HOME"])
        XCTAssertNotNil(dict["LANG"])
    }

    func testResolveShellFallsBack() {
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: ShellEnvironment.resolveShell(override: "/nonexistent")))
    }
}

final class FileListingTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("grid-tests-\(UUID().uuidString)/Dir With Spaces ✦ 日本")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(count: 10).write(to: dir.appendingPathComponent("b.txt"))
        try Data(count: 2000).write(to: dir.appendingPathComponent("a10.bin"))
        try Data(count: 5).write(to: dir.appendingPathComponent("a2.bin"))
        try Data().write(to: dir.appendingPathComponent(".hidden"))
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("zfolder"), withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("link-to-folder"), withDestinationURL: dir.appendingPathComponent("zfolder"))
        try FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent("broken").path, withDestinationPath: "/nonexistent/target")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir.deletingLastPathComponent())
    }

    func testListingHiddenToggleAndUnicodePath() throws {
        let visible = try FileListing.list(dir, showHidden: false)
        XCTAssertFalse(visible.contains { $0.name == ".hidden" })
        let all = try FileListing.list(dir, showHidden: true)
        XCTAssertTrue(all.contains { $0.name == ".hidden" })
    }

    func testRegularFileFlag() throws {
        let fifo = dir.appendingPathComponent("pipe")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let items = try FileListing.list(dir, showHidden: false)
        XCTAssertEqual(items.first { $0.name == "pipe" }?.isRegularFile, false)
        XCTAssertEqual(items.first { $0.name == "b.txt" }?.isRegularFile, true)
        XCTAssertEqual(items.first { $0.name == "zfolder" }?.isRegularFile, false)
    }

    func testSymlinks() throws {
        let items = try FileListing.list(dir, showHidden: false)
        let link = try XCTUnwrap(items.first { $0.name == "link-to-folder" })
        XCTAssertTrue(link.isSymlink)
        XCTAssertTrue(link.isNavigableFolder)
        let broken = try XCTUnwrap(items.first { $0.name == "broken" })
        XCTAssertTrue(broken.isBrokenSymlink)
    }

    func testSortingFinderLike() throws {
        let items = try FileListing.list(dir, showHidden: false)
        let byName = FileListing.sorted(items, by: .name, ascending: true).map(\.name)
        // Folders first, then numeric-aware names (a2 before a10).
        XCTAssertEqual(Array(byName.prefix(2)).sorted(), ["link-to-folder", "zfolder"])
        XCTAssertLessThan(byName.firstIndex(of: "a2.bin")!, byName.firstIndex(of: "a10.bin")!)
        let bySize = FileListing.sorted(items, by: .size, ascending: false, foldersFirst: false).map(\.name)
        XCTAssertEqual(bySize.first, "a10.bin")
    }

    func testErrors() {
        XCTAssertThrowsError(try FileListing.list(URL(fileURLWithPath: "/definitely/not/here"), showHidden: false)) {
            XCTAssertEqual($0 as? ListingError, .notFound("/definitely/not/here"))
        }
        XCTAssertThrowsError(try FileListing.list(dir.appendingPathComponent("b.txt"), showHidden: false)) {
            guard case .notADirectory = $0 as? ListingError else { return XCTFail("expected notADirectory") }
        }
    }

    func testPermissionDenied() throws {
        let locked = dir.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        XCTAssertThrowsError(try FileListing.list(locked, showHidden: false)) {
            guard case .permissionDenied = $0 as? ListingError else { return XCTFail("expected permissionDenied, got \($0)") }
        }
    }

    func testChildPathsKeepRequestedPrefix() throws {
        // /tmp is a symlink to /private/tmp; children must keep the /tmp form we asked for.
        let d = URL(fileURLWithPath: "/tmp/grid-prefix-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: d) }
        try Data().write(to: d.appendingPathComponent("a b.txt"))
        let items = try FileListing.list(d, showHidden: false)
        XCTAssertEqual(items.map(\.url.path), [d.path + "/a b.txt"])
    }

    func testPermissionString() {
        XCTAssertEqual(FileListing.permissionString(0o755, isDirectory: true, isSymlink: false), "drwxr-xr-x")
        XCTAssertEqual(FileListing.permissionString(0o640, isDirectory: false, isSymlink: false), "-rw-r-----")
    }
}

final class AppDiscoveryTests: XCTestCase {
    func testScanFindsSystemApps() {
        let apps = AppDiscovery.scan(roots: AppDiscovery.standardRoots())
        XCTAssertTrue(apps.contains { $0.bundleID == "com.apple.finder" }, "Finder should be discovered")
        XCTAssertTrue(apps.contains { $0.bundleID == "com.apple.Terminal" }, "Terminal should be discovered")
        XCTAssertEqual(Set(apps.map(\.path)).count, apps.count, "no duplicate paths")
    }

    func testDisambiguators() {
        let recs = [
            AppRecord(name: "Foo", bundleID: "a", path: "/Applications/Foo.app", version: "1"),
            AppRecord(name: "Foo", bundleID: "b", path: "/Users/x/Applications/Foo.app", version: "2"),
            AppRecord(name: "Bar", bundleID: "c", path: "/Applications/Bar.app", version: nil),
        ]
        let d = AppDiscovery.disambiguators(for: recs)
        XCTAssertEqual(d.count, 2)
        XCTAssertNil(d["/Applications/Bar.app"])
    }

    func testRankFavoritesBreakTies() {
        let recs = [
            AppRecord(name: "Notes", bundleID: nil, path: "/a/Notes.app", version: nil),
            AppRecord(name: "Numbers", bundleID: nil, path: "/a/Numbers.app", version: nil),
        ]
        let r = AppDiscovery.rank(recs, query: "n", favorites: ["/a/Numbers.app"], recents: [])
        XCTAssertEqual(r.first?.name, "Numbers")
    }
}

final class ProcessInspectorTests: XCTestCase {
    func testOwnProcess() {
        let pid = getpid()
        XCTAssertEqual(ProcessInspector.currentDirectory(pid: pid), FileManager.default.currentDirectoryPath)
        XCTAssertNotNil(ProcessInspector.name(pid: pid))
        XCTAssertTrue(ProcessInspector.isAlive(pid))
    }

    func testIdentityDistinguishesReusedPIDs() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["5"]
        try p.run()
        let id = try XCTUnwrap(ProcessInspector.identity(of: p.processIdentifier))
        XCTAssertEqual(ProcessInspector.identity(of: p.processIdentifier), id)
        // A forged identity with the same PID but a different start time must not be signalled.
        let forged = ProcessInspector.Identity(pid: id.pid, startSec: id.startSec &+ 1, startUsec: id.startUsec)
        XCTAssertFalse(ProcessInspector.signalIfSame(forged, SIGTERM))
        XCTAssertTrue(ProcessInspector.isAlive(p.processIdentifier))
        XCTAssertTrue(ProcessInspector.signalIfSame(id, SIGTERM))
        p.waitUntilExit()
        XCTAssertFalse(ProcessInspector.signalIfSame(id, SIGTERM), "exited process must not match")
    }

    func testGroupMembers() {
        XCTAssertTrue(ProcessInspector.members(ofGroup: getpgrp()).contains(getpid()))
        XCTAssertEqual(ProcessInspector.members(ofGroup: 0), [])
        XCTAssertEqual(ProcessInspector.members(ofGroup: 1), [])
    }

    func testChildCwdIsTracked() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["5"]
        p.currentDirectoryURL = URL(fileURLWithPath: "/private/tmp")
        try p.run()
        defer { p.terminate() }
        usleep(100_000)
        XCTAssertEqual(ProcessInspector.currentDirectory(pid: p.processIdentifier), "/private/tmp")
        XCTAssertTrue(ProcessInspector.children(of: getpid()).contains(p.processIdentifier))
    }
}

final class FileNamingTests: XCTestCase {
    func testUniqueName() {
        let taken: Set<String> = ["report.pdf", "report 2.pdf", "untitled folder", "a.tar.gz", "notes 7"]
        XCTAssertEqual(FileNaming.uniqueName(for: "new.txt") { taken.contains($0) }, "new.txt")
        XCTAssertEqual(FileNaming.uniqueName(for: "report.pdf") { taken.contains($0) }, "report 3.pdf")
        XCTAssertEqual(FileNaming.uniqueName(for: "untitled folder", isDirectory: true) { taken.contains($0) }, "untitled folder 2")
        XCTAssertEqual(FileNaming.uniqueName(for: "notes 7") { taken.contains($0) }, "notes 8")
        XCTAssertEqual(FileNaming.uniqueName(for: "a.tar.gz") { taken.contains($0) }, "a.tar 2.gz")
        XCTAssertEqual(FileNaming.uniqueName(for: "my.app.dir", isDirectory: true) { $0 == "my.app.dir" }, "my.app.dir 2")
    }

    func testValidate() {
        XCTAssertNil(FileNaming.validate("ok name ✓.txt"))
        XCTAssertNotNil(FileNaming.validate(""))
        XCTAssertNotNil(FileNaming.validate("   "))
        XCTAssertNotNil(FileNaming.validate("a/b"))
        XCTAssertNotNil(FileNaming.validate(".."))
        XCTAssertNotNil(FileNaming.validate("bad\nname"))
        XCTAssertNotNil(FileNaming.validate(String(repeating: "x", count: 256)))
    }

    func testIsSameOrInside() {
        XCTAssertTrue(FileNaming.isSameOrInside(URL(fileURLWithPath: "/a/b/c"), URL(fileURLWithPath: "/a/b")))
        XCTAssertTrue(FileNaming.isSameOrInside(URL(fileURLWithPath: "/a/b"), URL(fileURLWithPath: "/a/b")))
        XCTAssertFalse(FileNaming.isSameOrInside(URL(fileURLWithPath: "/a/bc"), URL(fileURLWithPath: "/a/b")))
        XCTAssertFalse(FileNaming.isSameOrInside(URL(fileURLWithPath: "/a"), URL(fileURLWithPath: "/a/b")))
    }
}

final class GitStatusTests: XCTestCase {
    func testParse() {
        let out = """
        # branch.oid 1234abcd
        # branch.head main
        # branch.upstream origin/main
        # branch.ab +2 -1
        1 M. N... 100644 100644 100644 aaa bbb staged.swift
        1 .M N... 100644 100644 100644 aaa bbb modified.swift
        1 MM N... 100644 100644 100644 aaa bbb both.swift
        2 R. N... 100644 100644 100644 aaa bbb R100 new.swift\told.swift
        u UU N... 100644 100644 100644 100644 a b c conflict.swift
        ? untracked file.txt
        ? other.txt
        """
        let s = GitStatus.parse(porcelainV2: out)
        XCTAssertEqual(s.branch, "main")
        XCTAssertEqual(s.upstream, "origin/main")
        XCTAssertEqual(s.ahead, 2)
        XCTAssertEqual(s.behind, 1)
        XCTAssertEqual(s.staged, 3)
        XCTAssertEqual(s.modified, 2)
        XCTAssertEqual(s.conflicted, 1)
        XCTAssertEqual(s.untracked, 2)
        XCTAssertFalse(s.isClean)
    }

    func testCleanDetached() {
        let s = GitStatus.parse(porcelainV2: "# branch.oid abc\n# branch.head (detached)\n")
        XCTAssertEqual(s.branch, "(detached)")
        XCTAssertTrue(s.isClean)
        XCTAssertNil(s.upstream)
    }

    /// Runs the real git on this repository to make sure the format we ask for parses.
    func testAgainstRealGit() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/git") else { throw XCTSkip("no git") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", FileManager.default.currentDirectoryPath, "status", "--porcelain=v2", "--branch"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw XCTSkip("not a git checkout") }
        let s = GitStatus.parse(porcelainV2: String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        XCTAssertFalse(s.branch.isEmpty)
    }
}

final class SplitTreeTests: XCTestCase {
    let a = UUID(), b = UUID(), c = UUID(), d = UUID()

    private func fractions(_ t: SplitTree) -> [Double] {
        if case .split(_, _, _, let f) = t { return f }
        return []
    }

    func testSameAxisSplitJoinsParent() {
        let t = SplitTree.leaf(a).splitting(a, axis: .horizontal, with: b).splitting(b, axis: .horizontal, with: c)
        XCTAssertEqual(t.leaves, [a, b, c])
        guard case .split(_, .horizontal, let children, let f) = t else { return XCTFail() }
        XCTAssertEqual(children.count, 3)
        XCTAssertEqual(f, [0.5, 0.25, 0.25])
        XCTAssertEqual(f.reduce(0, +), 1, accuracy: 1e-9)
    }

    func testMixedAxisNests() {
        let t = SplitTree.leaf(a).splitting(a, axis: .horizontal, with: b).splitting(b, axis: .vertical, with: c)
        XCTAssertEqual(t.leaves, [a, b, c])
        guard case .split(_, .horizontal, let children, _) = t, case .split(_, .vertical, let inner, _) = children[1] else { return XCTFail() }
        XCTAssertEqual(inner.count, 2)
    }

    func testRemoveCollapsesAndGivesShareToNeighbour() {
        let t = SplitTree.leaf(a).splitting(a, axis: .horizontal, with: b).splitting(b, axis: .horizontal, with: c)
        let r = t.removing(b)!
        XCTAssertEqual(r.leaves, [a, c])
        XCTAssertEqual(fractions(r), [0.75, 0.25])
        XCTAssertEqual(r.removing(a)!.removing(c), nil)
        XCTAssertEqual(r.removing(a), .leaf(c))
    }

    func testRemoveFlattensSameAxis() {
        // a | (b / (c | d)) → remove b → a | c | d (inner horizontal flattened into root)
        let t = SplitTree.leaf(a).splitting(a, axis: .horizontal, with: b)
            .splitting(b, axis: .vertical, with: c).splitting(c, axis: .horizontal, with: d)
        let r = t.removing(b)!
        guard case .split(_, .horizontal, let children, let f) = r else { return XCTFail() }
        XCTAssertEqual(children, [.leaf(a), .leaf(c), .leaf(d)])
        XCTAssertEqual(f.reduce(0, +), 1, accuracy: 1e-9)
    }

    func testResizeClampsAndEqualize() {
        let t = SplitTree.leaf(a).splitting(a, axis: .horizontal, with: b)
        guard case .split(let sid, _, _, _) = t else { return XCTFail() }
        let moved = fractions(t.resizing(splitID: sid, divider: 0, by: 0.2))
        XCTAssertEqual(moved[0], 0.7, accuracy: 1e-9)
        XCTAssertEqual(moved[1], 0.3, accuracy: 1e-9)
        let clamped = fractions(t.resizing(splitID: sid, divider: 0, by: 0.9, minFraction: 0.15))
        XCTAssertEqual(clamped[1], 0.15, accuracy: 1e-9)
        XCTAssertEqual(fractions(t.resizing(splitID: sid, divider: 0, by: 0.3).equalizing(splitID: sid)), [0.5, 0.5])
    }
}

final class KeyBindingTests: XCTestCase {
    func testDisplayOrder() {
        XCTAssertEqual(KeyBinding("d", [.shift, .command]).display, "⇧⌘D")
        XCTAssertEqual(KeyBinding("right", [.command, .option, .control]).display, "⌃⌥⌘→")
        XCTAssertEqual(KeyBinding("f5", []).display, "F5")
    }

    func testRules() {
        XCTAssertNil(KeyBinding("d", [.command]).problem)
        XCTAssertNil(KeyBinding("f6", []).problem, "function keys are allowed without ⌘")
        XCTAssertNotNil(KeyBinding("c", [.control]).problem, "⌃C must stay with the terminal")
        XCTAssertNotNil(KeyBinding("left", [.option]).problem)
        XCTAssertNotNil(KeyBinding("q", [.command]).problem)
        XCTAssertNotNil(KeyBinding("v", [.command]).problem)
        XCTAssertNotNil(KeyBinding("3", [.command]).problem, "⌘1–9 switch tabs")
        XCTAssertNil(KeyBinding("3", [.command, .option]).problem)
    }

    func testCodableAndNormalizes() throws {
        let b = KeyBinding("D", [.command, .shift])
        XCTAssertEqual(b.key, "d")
        let round = try JSONDecoder().decode(KeyBinding.self, from: JSONEncoder().encode(b))
        XCTAssertEqual(round, b)
    }
}

final class SplitTreeMoveTests: XCTestCase {
    let a = UUID(), b = UUID(), c = UUID(), d = UUID(), e = UUID()

    private func fractions(_ t: SplitTree) -> [Double] {
        if case .split(_, _, _, let f) = t { return f }
        return []
    }

    private func children(_ t: SplitTree) -> [SplitTree] {
        if case .split(_, _, let c, _) = t { return c }
        return []
    }

    private func axis(_ t: SplitTree) -> SplitAxis? {
        if case .split(_, let a, _, _) = t { return a }
        return nil
    }

    private func allNodeIDs(_ t: SplitTree) -> [UUID] {
        [t.nodeID] + children(t).flatMap(allNodeIDs)
    }

    /// Every split: positive fractions summing to 1 within 1e-9 (tighter than `isValid`).
    private func assertFractionsTight(_ t: SplitTree, file: StaticString = #filePath, line: UInt = #line) {
        let f = fractions(t)
        if !f.isEmpty {
            XCTAssertTrue(f.allSatisfy { $0 > 0 && $0.isFinite }, "non-positive fraction \(f)", file: file, line: line)
            XCTAssertEqual(f.reduce(0, +), 1, accuracy: 1e-9, file: file, line: line)
        }
        for child in children(t) { assertFractionsTight(child, file: file, line: line) }
    }

    // MARK: DropEdge

    func testDropEdgeAxisAndLeading() {
        XCTAssertEqual(DropEdge.left.axis, .horizontal)
        XCTAssertEqual(DropEdge.right.axis, .horizontal)
        XCTAssertEqual(DropEdge.top.axis, .vertical)
        XCTAssertEqual(DropEdge.bottom.axis, .vertical)
        XCTAssertTrue(DropEdge.left.isLeading)
        XCTAssertTrue(DropEdge.top.isLeading)
        XCTAssertFalse(DropEdge.right.isLeading)
        XCTAssertFalse(DropEdge.bottom.isLeading)
        XCTAssertEqual(DropEdge.allCases.count, 4)
    }

    // MARK: node(_:)

    func testNodeLookup() {
        let t = SplitTree.leaf(a).splitting(a, axis: .horizontal, with: b).splitting(b, axis: .vertical, with: c)
        XCTAssertEqual(t.node(a), .leaf(a))
        XCTAssertEqual(t.node(t.nodeID), t)
        XCTAssertEqual(t.node(children(t)[1].nodeID), children(t)[1])
        XCTAssertNil(t.node(d))
    }

    // MARK: inserting

    func testInsertEachEdgeOnLeafRoot() {
        for edge in DropEdge.allCases {
            let t = SplitTree.leaf(a).inserting(b, at: a, edge: edge, share: 0.3)
            XCTAssertTrue(t.isValid)
            XCTAssertEqual(axis(t), edge.axis)
            XCTAssertEqual(t.leaves, edge.isLeading ? [b, a] : [a, b], "\(edge)")
            let f = fractions(t)
            XCTAssertEqual(f[edge.isLeading ? 0 : 1], 0.3, accuracy: 1e-12)
            XCTAssertEqual(f[edge.isLeading ? 1 : 0], 0.7, accuracy: 1e-12)
            XCTAssertNotEqual(t.nodeID, a, "wrapping split gets a fresh id")
        }
    }

    func testInsertInsideSameAxisParentLeading() {
        // a | b (0.5 / 0.5), drop c on the left edge of b → a | c | b
        let t = SplitTree.leaf(a).splitting(a, axis: .horizontal, with: b)
        let r = t.inserting(c, at: b, edge: .left, share: 0.25)
        XCTAssertTrue(r.isValid)
        XCTAssertEqual(r.nodeID, t.nodeID, "same split keeps its id")
        XCTAssertEqual(r.leaves, [a, c, b])
        let f = fractions(r)
        XCTAssertEqual(f[0], 0.5, accuracy: 1e-12)
        XCTAssertEqual(f[1], 0.125, accuracy: 1e-12, "c takes `share` of b's fraction")
        XCTAssertEqual(f[2], 0.375, accuracy: 1e-12, "b keeps the rest")
        assertFractionsTight(r)
    }

    func testInsertInsideSameAxisParentTrailing() {
        // a | b, drop c on the right edge of a → a | c | b
        let t = SplitTree.leaf(a).splitting(a, axis: .horizontal, with: b)
        let r = t.inserting(c, at: a, edge: .right, share: 0.5)
        XCTAssertTrue(r.isValid)
        XCTAssertEqual(r.leaves, [a, c, b])
        XCTAssertEqual(fractions(r), [0.25, 0.25, 0.5])
        XCTAssertEqual(children(r).count, 3, "no nesting")
    }

    func testInsertInsideOtherAxisParentWraps() {
        // a | b, drop c on top of b → a | (c / b)
        let t = SplitTree.leaf(a).splitting(a, axis: .horizontal, with: b)
        let r = t.inserting(c, at: b, edge: .top, share: 0.4)
        XCTAssertTrue(r.isValid)
        XCTAssertEqual(r.leaves, [a, c, b])
        XCTAssertEqual(fractions(r), [0.5, 0.5], "outer fractions untouched")
        let inner = children(r)[1]
        XCTAssertEqual(axis(inner), .vertical)
        XCTAssertEqual(inner.leaves, [c, b])
        XCTAssertEqual(fractions(inner)[0], 0.4, accuracy: 1e-12)
        XCTAssertEqual(fractions(inner)[1], 0.6, accuracy: 1e-12)

        let r2 = t.inserting(c, at: b, edge: .bottom)
        XCTAssertEqual(children(r2)[1].leaves, [b, c])
        XCTAssertEqual(fractions(children(r2)[1]), [0.5, 0.5])
    }

    func testInsertAtSplitRootOtherAxisWraps() {
        // (a | b), drop c on top of the root → c / (a | b)
        let t = SplitTree.leaf(a).splitting(a, axis: .horizontal, with: b)
        let r = t.inserting(c, at: t.nodeID, edge: .top, share: 0.2)
        XCTAssertTrue(r.isValid)
        XCTAssertEqual(axis(r), .vertical)
        XCTAssertEqual(r.leaves, [c, a, b])
        XCTAssertEqual(fractions(r)[0], 0.2, accuracy: 1e-12)
        XCTAssertEqual(fractions(r)[1], 0.8, accuracy: 1e-12)
        XCTAssertEqual(children(r)[1], t, "the old root is kept intact as a child")
    }

    func testInsertAtSplitRootSameAxisExtendsIt() {
        // (a | b), drop c on the right edge of the root → a | b | c, flat
        let t = SplitTree.leaf(a).splitting(a, axis: .horizontal, with: b)
        let r = t.inserting(c, at: t.nodeID, edge: .right, share: 0.5)
        XCTAssertTrue(r.isValid)
        XCTAssertEqual(r.leaves, [a, b, c])
        XCTAssertEqual(children(r).count, 3, "no same-axis nesting")
        XCTAssertEqual(fractions(r), [0.25, 0.25, 0.5])
        XCTAssertEqual(r.nodeID, t.nodeID)

        let l = t.inserting(c, at: t.nodeID, edge: .left, share: 0.5)
        XCTAssertEqual(l.leaves, [c, a, b])
        XCTAssertEqual(fractions(l), [0.5, 0.25, 0.25])
    }

    func testInsertAtNestedSplitID() {
        // a | (b / c): drop d on the right edge of the inner split → a | (b / c) | d
        let t = SplitTree.leaf(a).splitting(a, axis: .horizontal, with: b).splitting(b, axis: .vertical, with: c)
        let inner = children(t)[1]
        let r = t.inserting(d, at: inner.nodeID, edge: .right, share: 0.5)
        XCTAssertTrue(r.isValid)
        XCTAssertEqual(r.leaves, [a, b, c, d])
        XCTAssertEqual(children(r).count, 3)
        XCTAssertEqual(children(r)[1], inner)
        XCTAssertEqual(fractions(r), [0.5, 0.25, 0.25])

        // Drop e on the bottom of the inner split → a | (b / c / e), inner keeps its id.
        let r2 = t.inserting(e, at: inner.nodeID, edge: .bottom, share: 0.5)
        XCTAssertTrue(r2.isValid)
        XCTAssertEqual(r2.leaves, [a, b, c, e])
        XCTAssertEqual(children(r2)[1].nodeID, inner.nodeID)
        XCTAssertEqual(children(r2)[1].leaves, [b, c, e])
        XCTAssertEqual(fractions(children(r2)[1]), [0.25, 0.25, 0.5])
    }

    func testInsertNoOps() {
        let t = SplitTree.leaf(a).splitting(a, axis: .horizontal, with: b)
        XCTAssertEqual(t.inserting(c, at: d, edge: .left), t, "unknown target")
        XCTAssertEqual(t.inserting(b, at: a, edge: .left), t, "new already a leaf")
        XCTAssertEqual(t.inserting(t.nodeID, at: a, edge: .left), t, "new collides with a split id")
    }

    func testInsertBadShareFallsBackToHalf() {
        for share in [0.0, 1.0, -0.5, 2.0, Double.nan, Double.infinity] {
            let r = SplitTree.leaf(a).inserting(b, at: a, edge: .right, share: share)
            XCTAssertEqual(fractions(r), [0.5, 0.5], "\(share)")
            XCTAssertTrue(r.isValid)
        }
    }

    // MARK: moving

    func testMoveLeafToEachEdgeOfSibling() {
        // a | b | c
        let t = SplitTree.leaf(a).splitting(a, axis: .horizontal, with: b).splitting(b, axis: .horizontal, with: c)
        XCTAssertEqual(fractions(t), [0.5, 0.25, 0.25])

        let left = t.moving(c, to: a, edge: .left)
        XCTAssertTrue(left.isValid)
        XCTAssertEqual(left.leaves, [c, a, b])
        // c's share went to b (0.5); a's 0.5 is split in half with c.
        XCTAssertEqual(fractions(left), [0.25, 0.25, 0.5])

        let right = t.moving(a, to: b, edge: .right)
        XCTAssertTrue(right.isValid)
        XCTAssertEqual(right.leaves, [b, a, c])
        // a was first, so its share went to the next sibling b (0.75); a takes half of that.
        XCTAssertEqual(fractions(right), [0.375, 0.375, 0.25])

        let top = t.moving(c, to: a, edge: .top)
        XCTAssertTrue(top.isValid)
        XCTAssertEqual(top.leaves, [c, a, b])
        XCTAssertEqual(axis(children(top)[0]), .vertical)
        XCTAssertEqual(children(top)[0].leaves, [c, a])
        XCTAssertEqual(fractions(top), [0.5, 0.5])

        let bottom = t.moving(a, to: c, edge: .bottom)
        XCTAssertTrue(bottom.isValid)
        XCTAssertEqual(bottom.leaves, [b, c, a])
        XCTAssertEqual(children(bottom)[1].leaves, [c, a])
        XCTAssertEqual(axis(children(bottom)[1]), .vertical)
        assertFractionsTight(bottom)
    }

    func testMoveWithinSameSplitReorders() {
        // a | b | c → move a after c → b | c | a; still one flat split with the same id.
        let t = SplitTree.leaf(a).splitting(a, axis: .horizontal, with: b).splitting(b, axis: .horizontal, with: c)
        let r = t.moving(a, to: c, edge: .right)
        XCTAssertTrue(r.isValid)
        XCTAssertEqual(r.leaves, [b, c, a])
        XCTAssertEqual(children(r).count, 3)
        XCTAssertEqual(r.nodeID, t.nodeID)
        XCTAssertEqual(fractions(r), [0.75, 0.125, 0.125])
        assertFractionsTight(r)
    }

    func testMoveCollapsesSplit() {
        // a | (b / c): move b to the left of a → b | a | c (vertical split collapsed to c).
        let t = SplitTree.leaf(a).splitting(a, axis: .horizontal, with: b).splitting(b, axis: .vertical, with: c)
        let r = t.moving(b, to: a, edge: .left)
        XCTAssertTrue(r.isValid)
        XCTAssertEqual(r.leaves, [b, a, c])
        XCTAssertEqual(children(r), [.leaf(b), .leaf(a), .leaf(c)])
        XCTAssertEqual(fractions(r), [0.25, 0.25, 0.5])
    }

    func testMoveOntoContainingSplitThatSurvives() {
        // (a | b | c): move a to the left edge of the root split → a | b | c with a at 0.5.
        let t = SplitTree.leaf(a).splitting(a, axis: .horizontal, with: b).splitting(b, axis: .horizontal, with: c)
        let r = t.moving(a, to: t.nodeID, edge: .left)
        XCTAssertTrue(r.isValid)
        XCTAssertEqual(r.leaves, [a, b, c])
        XCTAssertEqual(r.nodeID, t.nodeID)
        XCTAssertEqual(fractions(r)[0], 0.5, accuracy: 1e-12)
        XCTAssertEqual(fractions(r)[1], 0.375, accuracy: 1e-12)
        XCTAssertEqual(fractions(r)[2], 0.125, accuracy: 1e-12)

        // Move a to the bottom of the root → (b | c) / a
        let r2 = t.moving(a, to: t.nodeID, edge: .bottom)
        XCTAssertTrue(r2.isValid)
        XCTAssertEqual(axis(r2), .vertical)
        XCTAssertEqual(r2.leaves, [b, c, a])
        XCTAssertEqual(children(r2)[0].nodeID, t.nodeID)
    }

    func testMoveNoOps() {
        let t = SplitTree.leaf(a).splitting(a, axis: .horizontal, with: b).splitting(b, axis: .vertical, with: c)
        let inner = children(t)[1]
        XCTAssertEqual(t.moving(a, to: a, edge: .left), t, "id == target")
        XCTAssertEqual(t.moving(d, to: a, edge: .left), t, "id not in tree")
        XCTAssertEqual(t.moving(inner.nodeID, to: a, edge: .left), t, "id is a split, not a leaf")
        XCTAssertEqual(t.moving(a, to: d, edge: .left), t, "target not found")
        XCTAssertEqual(SplitTree.leaf(a).moving(a, to: a, edge: .left), .leaf(a))
        // Removing b would collapse the inner split, so its id disappears: no-op, no crash.
        XCTAssertEqual(t.moving(b, to: inner.nodeID, edge: .left), t, "target split vanishes after removal")
        XCTAssertEqual(t.moving(c, to: inner.nodeID, edge: .bottom), t)
        // Single-leaf tree: moving the only leaf anywhere is a no-op (nothing to target).
        XCTAssertEqual(SplitTree.leaf(a).moving(a, to: b, edge: .left), .leaf(a))
    }

    // MARK: Randomized invariants

    /// SplitMix64, so the random walk is deterministic across runs.
    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    func testRandomMovesPreserveLeavesAndFractions() {
        var rng = SeededGenerator(state: 0xC0FF_EE42)
        var moved = 0, noOps = 0
        for iteration in 0..<500 {
            // Random tree with 1–8 leaves via splitting (exercises deep and flat shapes).
            var tree = SplitTree.leaf(UUID())
            let extra = Int.random(in: 0...7, using: &rng)
            for _ in 0..<extra {
                let target = tree.leaves.randomElement(using: &rng)!
                let axis: SplitAxis = Bool.random(using: &rng) ? .horizontal : .vertical
                tree = tree.splitting(target, axis: axis, with: UUID())
            }
            XCTAssertTrue(tree.isValid, "iteration \(iteration): random tree invalid")
            let original = Set(tree.leaves)
            let count = tree.leaves.count

            for step in 0..<6 {
                let id = tree.leaves.randomElement(using: &rng)!
                // Target: any node id, occasionally an unknown id.
                let candidates = allNodeIDs(tree) + [UUID()]
                let target = candidates.randomElement(using: &rng)!
                let edge = DropEdge.allCases.randomElement(using: &rng)!
                let share = Double.random(in: 0.1...0.9, using: &rng)
                let next = tree.moving(id, to: target, edge: edge, share: share)
                if next == tree { noOps += 1 } else { moved += 1 }

                let context = "iteration \(iteration) step \(step)"
                XCTAssertTrue(next.isValid, "\(context): invalid tree after move")
                XCTAssertEqual(next.leaves.count, count, "\(context): leaf count changed")
                XCTAssertEqual(Set(next.leaves), original, "\(context): leaves not a permutation")
                assertFractionsTight(next)
                XCTAssertEqual(Set(allNodeIDs(next)).count, allNodeIDs(next).count, "\(context): duplicate node id")
                tree = next
            }
        }
        XCTAssertGreaterThan(moved, 1000, "the walk should actually move panes most of the time")
        XCTAssertGreaterThan(noOps, 0, "and hit some no-op cases too")
    }

    // MARK: Codable

    func testCodableRoundTrip() throws {
        // a | (b / (c | d)), with uneven fractions in the innermost split.
        let base = SplitTree.leaf(a).splitting(a, axis: .horizontal, with: b)
            .splitting(b, axis: .vertical, with: c).splitting(c, axis: .horizontal, with: d)
        let innermost = children(children(base)[1])[1]
        let t = base.resizing(splitID: innermost.nodeID, divider: 0, by: 0.1)
        XCTAssertNotEqual(t, base, "resize should have changed the fractions")
        let data = try JSONEncoder().encode(t)
        let back = try JSONDecoder().decode(SplitTree.self, from: data)
        XCTAssertEqual(back, t)
        XCTAssertTrue(back.isValid)

        let leafData = try JSONEncoder().encode(SplitTree.leaf(a))
        XCTAssertEqual(try JSONDecoder().decode(SplitTree.self, from: leafData), .leaf(a))
    }

    func testCodableShape() throws {
        let t = SplitTree.leaf(a).splitting(a, axis: .vertical, with: b)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(t)) as! [String: Any]
        XCTAssertEqual(json["split"] as? String, t.nodeID.uuidString)
        XCTAssertEqual(json["axis"] as? String, "vertical")
        XCTAssertEqual(json["fractions"] as? [Double], [0.5, 0.5])
        let kids = json["children"] as! [[String: Any]]
        XCTAssertEqual(kids.map { $0["leaf"] as? String }, [a.uuidString, b.uuidString])
    }

    private func decode(_ json: String) throws -> SplitTree {
        try JSONDecoder().decode(SplitTree.self, from: Data(json.utf8))
    }

    private func assertRejects(_ json: String, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try decode(json), message, file: file, line: line) { error in
            guard case DecodingError.dataCorrupted = error else {
                return XCTFail("\(message): expected dataCorrupted, got \(error)", file: file, line: line)
            }
        }
    }

    private func splitJSON(children: [String], fractions: [Double], axis: String = "horizontal") -> String {
        let f = fractions.map { String($0) }.joined(separator: ",")
        return #"{"split":"\#(UUID().uuidString)","axis":"\#(axis)","children":[\#(children.joined(separator: ","))],"fractions":[\#(f)]}"#
    }

    private func leafJSON(_ id: UUID) -> String { #"{"leaf":"\#(id.uuidString)"}"# }

    func testDecodeRejectsTooFewChildren() {
        assertRejects(splitJSON(children: [leafJSON(a)], fractions: [1]), "one child")
        assertRejects(splitJSON(children: [], fractions: []), "no children")
    }

    func testDecodeRejectsFractionCountMismatch() {
        assertRejects(splitJSON(children: [leafJSON(a), leafJSON(b)], fractions: [1]), "too few fractions")
        assertRejects(splitJSON(children: [leafJSON(a), leafJSON(b)], fractions: [0.3, 0.3, 0.4]), "too many fractions")
    }

    func testDecodeRejectsBadFractions() {
        assertRejects(splitJSON(children: [leafJSON(a), leafJSON(b)], fractions: [0, 1]), "zero fraction")
        assertRejects(splitJSON(children: [leafJSON(a), leafJSON(b)], fractions: [-0.5, 1.5]), "negative fraction")
        assertRejects(splitJSON(children: [leafJSON(a), leafJSON(b)], fractions: [1e400, 0.5]), "non-finite fraction")
    }

    func testDecodeRejectsDuplicateLeaves() {
        assertRejects(splitJSON(children: [leafJSON(a), leafJSON(a)], fractions: [0.5, 0.5]), "sibling duplicate")
        let nested = splitJSON(children: [leafJSON(a), leafJSON(b)], fractions: [0.5, 0.5], axis: "vertical")
        assertRejects(splitJSON(children: [leafJSON(a), nested], fractions: [0.5, 0.5]), "duplicate across levels")
        assertRejects(#"{"axis":"horizontal"}"#, "neither leaf nor split")
    }

    func testDecodeNormalizesFractions() throws {
        let t = try decode(splitJSON(children: [leafJSON(a), leafJSON(b)], fractions: [1, 3]))
        XCTAssertEqual(fractions(t), [0.25, 0.75])
        XCTAssertTrue(t.isValid)
        XCTAssertEqual(t.leaves, [a, b])

        let nested = splitJSON(children: [leafJSON(b), leafJSON(c)], fractions: [2, 2], axis: "vertical")
        let t2 = try decode(splitJSON(children: [leafJSON(a), nested], fractions: [0.2, 0.2]))
        XCTAssertEqual(fractions(t2), [0.5, 0.5])
        XCTAssertEqual(fractions(children(t2)[1]), [0.5, 0.5])
        XCTAssertTrue(t2.isValid)
    }

    // MARK: isValid

    func testIsValidCatchesBrokenTrees() {
        XCTAssertTrue(SplitTree.leaf(a).isValid)
        XCTAssertTrue(SplitTree.leaf(a).splitting(a, axis: .horizontal, with: b).isValid)
        XCTAssertFalse(SplitTree.split(id: UUID(), axis: .horizontal, children: [.leaf(a)], fractions: [1]).isValid, "one child")
        XCTAssertFalse(SplitTree.split(id: UUID(), axis: .horizontal, children: [.leaf(a), .leaf(b)], fractions: [1]).isValid, "count mismatch")
        XCTAssertFalse(SplitTree.split(id: UUID(), axis: .horizontal, children: [.leaf(a), .leaf(b)], fractions: [0, 1]).isValid, "zero fraction")
        XCTAssertFalse(SplitTree.split(id: UUID(), axis: .horizontal, children: [.leaf(a), .leaf(b)], fractions: [0.5, 0.6]).isValid, "sum != 1")
        XCTAssertFalse(SplitTree.split(id: UUID(), axis: .horizontal, children: [.leaf(a), .leaf(b)], fractions: [.nan, 1]).isValid, "nan")
        XCTAssertFalse(SplitTree.split(id: UUID(), axis: .horizontal, children: [.leaf(a), .leaf(a)], fractions: [0.5, 0.5]).isValid, "duplicate leaves")
        let nestedDup = SplitTree.split(id: UUID(), axis: .horizontal, children: [
            .leaf(a), .split(id: UUID(), axis: .vertical, children: [.leaf(a), .leaf(b)], fractions: [0.5, 0.5]),
        ], fractions: [0.5, 0.5])
        XCTAssertFalse(nestedDup.isValid, "duplicate across levels")
    }
}

final class SplitTreeBalanceTests: XCTestCase {
    func testBalancedRaisesSmallShares() {
        let a = UUID(), b = UUID(), c = UUID()
        let t = SplitTree.split(id: UUID(), axis: .horizontal, children: [.leaf(a), .leaf(b), .leaf(c)], fractions: [0.09, 0.09, 0.82])
        guard case .split(_, _, _, let f) = t.balanced(minFraction: 0.2) else { return XCTFail() }
        XCTAssertEqual(f[0], 0.2, accuracy: 1e-9)
        XCTAssertEqual(f[1], 0.2, accuracy: 1e-9)
        XCTAssertEqual(f[2], 0.6, accuracy: 1e-9)
        XCTAssertTrue(t.balanced(minFraction: 0.2).isValid)
    }

    func testBalancedCapsAtEqualShare() {
        let ids = (0..<6).map { _ in UUID() }
        let t = SplitTree.split(id: UUID(), axis: .vertical, children: ids.map { .leaf($0) }, fractions: [0.01, 0.01, 0.01, 0.01, 0.01, 0.95])
        guard case .split(_, _, _, let f) = t.balanced(minFraction: 0.5) else { return XCTFail() }
        for v in f { XCTAssertEqual(v, 1.0 / 6, accuracy: 1e-9) }
    }
}

final class SplitTreeBalanceIdempotenceTests: XCTestCase {
    /// Regression (found in review): balanced() could oscillate between two nearly equal trees.
    func testBalancedIsIdempotent() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<5000 {
            let n = Int.random(in: 2...5, using: &rng)
            var f = (0..<n).map { _ in Double.random(in: 0.01...1, using: &rng) }
            let sum = f.reduce(0, +); f = f.map { $0 / sum }
            let t = SplitTree.split(id: UUID(), axis: .horizontal, children: (0..<n).map { _ in .leaf(UUID()) }, fractions: f)
            let once = t.balanced(minFraction: 0.2)
            XCTAssertEqual(once.balanced(minFraction: 0.2), once)
            XCTAssertTrue(once.isValid)
        }
        // The exact oscillating input from the review.
        let t = SplitTree.split(id: UUID(), axis: .horizontal, children: [.leaf(UUID()), .leaf(UUID()), .leaf(UUID())],
                                fractions: [0.5300000000000036, 0.20000000000000004, 0.26999999999999635])
        XCTAssertEqual(t.balanced(minFraction: 0.2).balanced(minFraction: 0.2), t.balanced(minFraction: 0.2))
    }
}

final class SplitTreeFitTests: XCTestCase {
    private func fractions(_ t: SplitTree) -> [Double] {
        if case .split(_, _, _, let f) = t { return f }
        return []
    }

    func testFitLeavesSatisfiedSharesAlone() {
        let f = SplitTree.fit(fractions: [0.25, 0.5, 0.25], minimums: [100, 200, 100], total: 1000)
        XCTAssertEqual(f, [0.25, 0.5, 0.25])
    }

    func testFitRaisesSqueezedChildToItsMinimum() {
        // Files 55 % / terminal 17 % / deck 28 % in 1000 pt: the terminal needs 360.
        let f = SplitTree.fit(fractions: [0.55, 0.17, 0.28], minimums: [220, 360, 240], total: 1000)
        XCTAssertEqual(f[1] * 1000, 360, accuracy: 1e-6)
        XCTAssertEqual(f.reduce(0, +), 1, accuracy: 1e-9)
        // The deficit comes from the others in proportion to their shares, so the order holds.
        XCTAssertGreaterThan(f[0], f[2])
        XCTAssertGreaterThanOrEqual(f[2] * 1000, 240 - 1e-6)
    }

    func testFitCascadesWhenBorrowingPushesAnotherUnder() {
        // Taking from the deck for the terminal would push the deck under 240, so it is pinned too.
        let f = SplitTree.fit(fractions: [0.6, 0.15, 0.25], minimums: [220, 360, 240], total: 1000)
        XCTAssertEqual(f[1] * 1000, 360, accuracy: 1e-6)
        XCTAssertEqual(f[2] * 1000, 240, accuracy: 1e-6)
        XCTAssertEqual(f[0] * 1000, 400, accuracy: 1e-6)
    }

    func testFitTooSmallScalesMinimumsNoZeroWidths() {
        let f = SplitTree.fit(fractions: [0.9, 0.05, 0.05], minimums: [220, 360, 240], total: 400)
        XCTAssertEqual(f, [220.0 / 820, 360.0 / 820, 240.0 / 820])
        XCTAssertTrue(f.allSatisfy { $0 > 0 })
    }

    func testFitIsIdempotent() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<2000 {
            let n = Int.random(in: 2...4, using: &rng)
            var f = (0..<n).map { _ in Double.random(in: 0.01...1, using: &rng) }
            let s = f.reduce(0, +); f = f.map { $0 / s }
            let mins = (0..<n).map { _ in Double.random(in: 50...400, using: &rng) }
            let total = Double.random(in: 300...2000, using: &rng)
            let once = SplitTree.fit(fractions: f, minimums: mins, total: total)
            XCTAssertEqual(once.reduce(0, +), 1, accuracy: 1e-9)
            let twice = SplitTree.fit(fractions: once, minimums: mins, total: total)
            for (a, b) in zip(once, twice) { XCTAssertEqual(a, b, accuracy: 1e-9) }
            if mins.reduce(0, +) < total {
                for (v, m) in zip(once, mins) { XCTAssertGreaterThanOrEqual(v * total, m - 1e-6) }
            }
        }
    }

    func testFitIgnoresBadInput() {
        XCTAssertEqual(SplitTree.fit(fractions: [0.5, 0.5], minimums: [1], total: 100), [0.5, 0.5], "count mismatch")
        XCTAssertEqual(SplitTree.fit(fractions: [0.5, 0.5], minimums: [10, 10], total: 0), [0.5, 0.5], "no size yet")
        XCTAssertEqual(SplitTree.fit(fractions: [0.5, 0.5], minimums: [.nan, -5], total: 100), [0.5, 0.5], "junk minimums")
    }

    func testMinimumLengthSumsAlongAxisAndMaxesAcross() {
        let a = UUID(), b = UUID(), c = UUID()
        let sizes = [a: CGSize(width: 220, height: 160), b: CGSize(width: 360, height: 220), c: CGSize(width: 240, height: 160)]
        let min: (UUID) -> CGSize = { sizes[$0]! }
        // H[a | V[b / c]]
        let t = SplitTree.split(id: UUID(), axis: .horizontal, children: [
            .leaf(a), .split(id: UUID(), axis: .vertical, children: [.leaf(b), .leaf(c)], fractions: [0.5, 0.5]),
        ], fractions: [0.3, 0.7])
        XCTAssertEqual(t.minimumLength(along: .horizontal, divider: 8, leafMinimum: min), 220 + 8 + 360)
        XCTAssertEqual(t.minimumLength(along: .vertical, divider: 8, leafMinimum: min), 220 + 8 + 160)
        XCTAssertEqual(SplitTree.leaf(b).minimumLength(along: .horizontal, divider: 8, leafMinimum: min), 360)
    }

    func testFittedRepairsNestedSplitsForTheirOwnRegion() {
        let a = UUID(), b = UUID(), c = UUID()
        let sizes = [a: CGSize(width: 220, height: 160), b: CGSize(width: 360, height: 220), c: CGSize(width: 240, height: 160)]
        let min: (UUID) -> CGSize = { sizes[$0]! }
        // H[a 0.6 | H[b 0.5 | c 0.5] 0.4] in 1208 pt: the inner split needs 360 + 8 + 240 = 608.
        let inner = SplitTree.split(id: UUID(), axis: .horizontal, children: [.leaf(b), .leaf(c)], fractions: [0.5, 0.5])
        let t = SplitTree.split(id: UUID(), axis: .horizontal, children: [.leaf(a), inner], fractions: [0.6, 0.4])
        let r = t.fitted(in: CGSize(width: 1208, height: 600), divider: 8, leafMinimum: min)
        XCTAssertTrue(r.isValid)
        XCTAssertEqual(r.leaves, t.leaves)
        let outer = fractions(r)
        XCTAssertEqual(outer[1] * 1200, 608, accuracy: 1e-6)
        guard case .split(_, _, let kids, _) = r, case .split(_, _, _, let innerF) = kids[1] else { return XCTFail() }
        XCTAssertEqual(innerF[0] * 600, 360, accuracy: 1e-6)
        XCTAssertEqual(innerF[1] * 600, 240, accuracy: 1e-6)
        // Already-fitting trees come back unchanged (so the model does not churn on every resize).
        XCTAssertEqual(r.fitted(in: CGSize(width: 1208, height: 600), divider: 8, leafMinimum: min), r)
        XCTAssertEqual(SplitTree.leaf(a).fitted(in: CGSize(width: 10, height: 10), divider: 8, leafMinimum: min), .leaf(a))
    }

    func testShareAndEnsuring() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        let t = SplitTree.split(id: UUID(), axis: .horizontal, children: [.leaf(a), .leaf(b), .leaf(c)], fractions: [0.55, 0.17, 0.28])
        XCTAssertEqual(t.share(of: b), 0.17)
        XCTAssertNil(t.share(of: d))
        XCTAssertNil(SplitTree.leaf(a).share(of: a), "root leaf has no parent")
        let r = t.ensuring(b, atLeast: 0.5)
        XCTAssertTrue(r.isValid)
        let f = fractions(r)
        XCTAssertEqual(f[1], 0.5, accuracy: 1e-9)
        XCTAssertEqual(f[0] / f[2], 0.55 / 0.28, accuracy: 1e-9, "siblings keep their ratio")
        XCTAssertEqual(r.ensuring(b, atLeast: 0.5), r, "already there")
        XCTAssertEqual(t.ensuring(b, atLeast: 0.1), t, "never shrinks")
        XCTAssertEqual(t.ensuring(d, atLeast: 0.5), t, "missing leaf")
        XCTAssertEqual(t.ensuring(b, atLeast: 1), t, "nothing left for siblings")
        // Nested: the leaf's own parent split is the one adjusted.
        let n = SplitTree.split(id: UUID(), axis: .vertical, children: [.leaf(d), t], fractions: [0.5, 0.5])
        let rn = n.ensuring(b, atLeast: 0.5)
        XCTAssertEqual(fractions(rn), [0.5, 0.5])
        XCTAssertEqual(rn.share(of: b)!, 0.5, accuracy: 1e-9)
    }

    func testReweightingSplitContainingLeaf() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        let w = [a: 1.0, b: 3.0, c: 1.0, d: 1.0]
        let weight: (SplitTree) -> Double = { $0.leaves.map { w[$0]! }.max()! }
        let t = SplitTree.split(id: UUID(), axis: .horizontal, children: [.leaf(a), .leaf(b), .leaf(c)], fractions: [0.4, 0.42, 0.18])
        let r = t.reweighting(splitContaining: b, weight: weight)
        XCTAssertTrue(r.isValid)
        for (x, y) in zip(fractions(r), [0.2, 0.6, 0.2]) { XCTAssertEqual(x, y, accuracy: 1e-9) }
        XCTAssertEqual(t.reweighting(splitContaining: d, weight: weight), t, "missing leaf")
        XCTAssertEqual(SplitTree.leaf(b).reweighting(splitContaining: b, weight: weight), .leaf(b), "root leaf")
        XCTAssertEqual(t.reweighting(splitContaining: b) { _ in 0 }, t, "bad weights")
        // Nested: only the parent of `b` changes; a split sibling counts by its heaviest leaf.
        let n = SplitTree.split(id: UUID(), axis: .vertical, children: [.leaf(d), t], fractions: [0.7, 0.3])
        let rn = n.reweighting(splitContaining: b, weight: weight)
        XCTAssertEqual(fractions(rn), [0.7, 0.3])
        XCTAssertEqual(rn.share(of: b)!, 0.6, accuracy: 1e-9)
        let col = SplitTree.split(id: UUID(), axis: .horizontal, children: [.leaf(b), .split(id: UUID(), axis: .vertical, children: [.leaf(a), .leaf(c)], fractions: [0.5, 0.5])], fractions: [0.5, 0.5])
        for (x, y) in zip(fractions(col.reweighting(splitContaining: b, weight: weight)), [0.75, 0.25]) { XCTAssertEqual(x, y, accuracy: 1e-9) }
    }
}

final class FileTreeTests: XCTestCase {
    private func entry(_ path: String, dir: Bool = false, package: Bool = false, broken: Bool = false, size: Int64? = nil) -> FileEntry {
        FileEntry(url: URL(fileURLWithPath: path), name: (path as NSString).lastPathComponent, isDirectory: dir, isPackage: package,
                  isSymlink: broken, isBrokenSymlink: broken, isHidden: false, size: size, modified: nil,
                  kind: dir ? "Folder" : "Document", typeIdentifier: nil, isRegularFile: !dir && !broken)
    }

    private let roots: [FileEntry] = [
        FileEntry(url: URL(fileURLWithPath: "/r/zeta.txt"), name: "zeta.txt", isDirectory: false, isPackage: false, isSymlink: false,
                  isBrokenSymlink: false, isHidden: false, size: 3, modified: nil, kind: "Document", typeIdentifier: nil, isRegularFile: true),
        FileEntry(url: URL(fileURLWithPath: "/r/src"), name: "src", isDirectory: true, isPackage: false, isSymlink: false,
                  isBrokenSymlink: false, isHidden: false, size: nil, modified: nil, kind: "Folder", typeIdentifier: nil),
        FileEntry(url: URL(fileURLWithPath: "/r/App.app"), name: "App.app", isDirectory: true, isPackage: true, isSymlink: false,
                  isBrokenSymlink: false, isHidden: false, size: nil, modified: nil, kind: "Application", typeIdentifier: nil),
        FileEntry(url: URL(fileURLWithPath: "/r/docs"), name: "docs", isDirectory: true, isPackage: false, isSymlink: false,
                  isBrokenSymlink: false, isHidden: false, size: nil, modified: nil, kind: "Folder", typeIdentifier: nil),
    ]

    private func names(_ rows: [FileTreeRow]) -> [String] {
        rows.map { String(repeating: " ", count: $0.depth) + ($0.entry?.name ?? ($0.kind == .loading ? "…" : "!")) }
    }

    func testCollapsedIsFlatAndSortedFoldersFirst() {
        let rows = FileTree.flatten(roots: roots, children: [:], expanded: [], sortKey: .name, ascending: true)
        XCTAssertEqual(names(rows), ["docs", "src", "App.app", "zeta.txt"])
        XCTAssertTrue(rows.allSatisfy { $0.depth == 0 && $0.parentID == nil && !$0.isExpanded })
    }

    func testExpandedChildrenAreIndentedUnderTheirFolder() {
        let kids: [String: FileTreeChildren] = ["/r/src": .loaded([entry("/r/src/main.swift"), entry("/r/src/lib", dir: true), entry("/r/src/a.swift")]),
                                                "/r/src/lib": .loaded([entry("/r/src/lib/x.c")])]
        let rows = FileTree.flatten(roots: roots, children: kids, expanded: ["/r/src", "/r/src/lib"], sortKey: .name, ascending: true)
        XCTAssertEqual(names(rows), ["docs", "src", " lib", "  x.c", " a.swift", " main.swift", "App.app", "zeta.txt"])
        let src = rows[1], lib = rows[2], x = rows[3]
        XCTAssertTrue(src.isExpanded && lib.isExpanded)
        XCTAssertEqual(lib.parentID, "/r/src")
        XCTAssertEqual(x.parentID, "/r/src/lib")
        XCTAssertEqual(x.depth, 2)
        // Sort order applies per level, including descending.
        let desc = FileTree.flatten(roots: roots, children: kids, expanded: ["/r/src"], sortKey: .name, ascending: false)
        XCTAssertEqual(names(desc), ["src", " lib", " main.swift", " a.swift", "docs", "zeta.txt", "App.app"])
    }

    func testCollapsedAncestorHidesButKeepsDescendantState() {
        let kids: [String: FileTreeChildren] = ["/r/src": .loaded([entry("/r/src/lib", dir: true)]), "/r/src/lib": .loaded([entry("/r/src/lib/x.c")])]
        let expanded: Set<String> = ["/r/src/lib"]   // parent collapsed
        let rows = FileTree.flatten(roots: roots, children: kids, expanded: expanded, sortKey: .name, ascending: true)
        XCTAssertEqual(names(rows), ["docs", "src", "App.app", "zeta.txt"])
        // Reopening the parent shows lib already open.
        let reopened = FileTree.flatten(roots: roots, children: kids, expanded: expanded.union(["/r/src"]), sortKey: .name, ascending: true)
        XCTAssertEqual(names(reopened), ["docs", "src", " lib", "  x.c", "App.app", "zeta.txt"])
    }

    func testPackagesAndBrokenLinksNeverExpand() {
        XCTAssertFalse(FileTree.isExpandable(roots[2]))
        XCTAssertFalse(FileTree.isExpandable(entry("/r/dead", dir: true, broken: true)))
        XCTAssertTrue(FileTree.isExpandable(roots[1]))
        let kids: [String: FileTreeChildren] = ["/r/App.app": .loaded([entry("/r/App.app/Contents", dir: true)])]
        let rows = FileTree.flatten(roots: roots, children: kids, expanded: ["/r/App.app"], sortKey: .name, ascending: true)
        XCTAssertEqual(names(rows), ["docs", "src", "App.app", "zeta.txt"])
        XCTAssertFalse(rows[2].isExpanded)
    }

    func testLoadingAndErrorPlaceholders() {
        let kids: [String: FileTreeChildren] = ["/r/src": .loading, "/r/docs": .failed("No permission to read this folder")]
        let rows = FileTree.flatten(roots: roots, children: kids, expanded: ["/r/src", "/r/docs"], sortKey: .name, ascending: true)
        XCTAssertEqual(names(rows), ["docs", " !", "src", " …", "App.app", "zeta.txt"])
        XCTAssertEqual(rows[1].kind, .error("No permission to read this folder"))
        XCTAssertEqual(rows[1].id, FileTree.errorID(for: "/r/docs"))
        XCTAssertEqual(rows[3].id, FileTree.loadingID(for: "/r/src"))
        XCTAssertTrue(rows[1].isPlaceholder && rows[3].isPlaceholder)
        // Not yet requested (nil): the folder shows open with nothing under it.
        let pending = FileTree.flatten(roots: roots, children: [:], expanded: ["/r/src"], sortKey: .name, ascending: true)
        XCTAssertEqual(names(pending), ["docs", "src", "App.app", "zeta.txt"])
        XCTAssertTrue(pending[1].isExpanded)
    }

    func testFilterKeepsNestedMatchesWithAncestors() {
        let kids: [String: FileTreeChildren] = [
            "/r/src": .loaded([entry("/r/src/main.swift"), entry("/r/src/lib", dir: true), entry("/r/src/README")]),
            "/r/src/lib": .loaded([entry("/r/src/lib/Core.swift"), entry("/r/src/lib/notes.txt")]),
            "/r/docs": .loaded([entry("/r/docs/guide.md")]),
        ]
        let all: Set<String> = ["/r/src", "/r/src/lib", "/r/docs"]
        let rows = FileTree.flatten(roots: roots, children: kids, expanded: all, sortKey: .name, ascending: true, query: "swift")
        XCTAssertEqual(names(rows), ["src", " lib", "  Core.swift", " main.swift"], "docs has no match and is hidden; ancestors of matches stay")
        XCTAssertTrue(rows[0].isExpanded && rows[1].isExpanded)
        // A folder matching by name is shown even if nothing inside matches.
        let byName = FileTree.flatten(roots: roots, children: kids, expanded: all, sortKey: .name, ascending: true, query: "doc")
        XCTAssertEqual(names(byName), ["docs"])
        // Collapsed folders are matched by name only (their children are not loaded into the view).
        let collapsed = FileTree.flatten(roots: roots, children: kids, expanded: [], sortKey: .name, ascending: true, query: "swift")
        XCTAssertEqual(names(collapsed), [])
        // Placeholders are hidden while filtering unless the folder itself matches.
        let loading = FileTree.flatten(roots: roots, children: ["/r/src": .loading], expanded: ["/r/src"], sortKey: .name, ascending: true, query: "zeta")
        XCTAssertEqual(names(loading), ["zeta.txt"])
    }

    func testReachableFollowsOnlyExpandedFolders() {
        let kids: [String: FileTreeChildren] = ["/r/src": .loaded([entry("/r/src/lib", dir: true)]), "/r/src/lib": .loaded([entry("/r/src/lib/x.c")]),
                                                "/r/docs": .loaded([entry("/r/docs/guide.md")])]
        let index = FileTree.reachable(roots: roots, children: kids, expanded: ["/r/src"])
        XCTAssertEqual(Set(index.keys), ["/r/zeta.txt", "/r/src", "/r/App.app", "/r/docs", "/r/src/lib"])
        XCTAssertNil(index["/r/src/lib/x.c"], "lib is not expanded")
        XCTAssertNil(index["/r/docs/guide.md"], "docs is not expanded")
        XCTAssertEqual(FileTree.reachable(roots: roots, children: kids, expanded: ["/r/src", "/r/src/lib"])["/r/src/lib/x.c"]?.name, "x.c")
    }
}
