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
