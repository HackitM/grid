import XCTest
@testable import GridCore

/// Existence and folder checks used before moving, copying or replacing files: they must look
/// at the item itself, never at what a symlink points to.
final class FileNamingReviewTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("grid-review-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testDanglingLinkStillOccupiesItsName() throws {
        let link = dir.appendingPathComponent("dangling")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: dir.appendingPathComponent("missing").path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: link.path))   // follows the link
        XCTAssertTrue(FileNaming.itemExists(atPath: link.path))
        XCTAssertFalse(FileNaming.itemExists(atPath: dir.appendingPathComponent("nothing").path))
    }

    func testLinkToFolderIsNotARealDirectory() throws {
        let real = dir.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false)
        let link = dir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        XCTAssertTrue(FileNaming.isRealDirectory(atPath: real.path))
        XCTAssertFalse(FileNaming.isRealDirectory(atPath: link.path))
        XCTAssertFalse(FileNaming.isRealDirectory(atPath: dir.appendingPathComponent("nothing").path))
        // Reached through the link, an existing item is still inside the real folder.
        try Data().write(to: real.appendingPathComponent("x"))
        XCTAssertTrue(FileNaming.isSameOrInside(link.appendingPathComponent("x"), real))
    }
}

final class ShellEnvironmentReviewTests: XCTestCase {
    func testShellMustBeAnAbsoluteExecutableFile() {
        XCTAssertTrue(ShellEnvironment.isUsableShell("/bin/sh"))
        XCTAssertFalse(ShellEnvironment.isUsableShell("/bin"))            // a folder is "executable" too
        XCTAssertFalse(ShellEnvironment.isUsableShell("bin/sh"))
        XCTAssertFalse(ShellEnvironment.isUsableShell("sh"))
        XCTAssertFalse(ShellEnvironment.isUsableShell(""))
        XCTAssertFalse(ShellEnvironment.isUsableShell("/etc/hosts"))      // a file, not executable
        XCTAssertFalse(ShellEnvironment.isUsableShell("/no/such/shell"))
        XCTAssertEqual(ShellEnvironment.resolveShell(override: " /bin/sh "), "/bin/sh")
        XCTAssertNotEqual(ShellEnvironment.resolveShell(override: "/bin"), "/bin")
    }
}
