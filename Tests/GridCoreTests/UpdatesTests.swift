import XCTest
@testable import GridCore

final class SemanticVersionTests: XCTestCase {
    func v(_ s: String) -> SemanticVersion { SemanticVersion(s)! }

    func testParsing() {
        XCTAssertEqual(v("v0.5.0").description, "0.5.0")
        XCTAssertEqual(v("0.5").description, "0.5.0")
        XCTAssertEqual(v("1").description, "1.0.0")
        XCTAssertEqual(v("1.2.3-beta.1+build.7").description, "1.2.3-beta.1")
        for bad in ["", "v", "1.2.3.4", "1..2", "a.b.c", "1.2.-3", "1.2.3-", "1.2.3-be ta", "1.2.3-α", "99999999999.0.0", "1.2.3-a..b"] {
            XCTAssertNil(SemanticVersion(bad), bad)
        }
    }

    func testOrdering() {
        XCTAssertLessThan(v("0.4.0"), v("0.5.0"))
        XCTAssertLessThan(v("0.5.0"), v("0.10.0"))           // numeric, not lexical
        XCTAssertLessThan(v("0.9.9"), v("1.0.0"))
        XCTAssertLessThan(v("1.0.0-beta.1"), v("1.0.0"))     // pre-release below release
        XCTAssertLessThan(v("1.0.0-alpha"), v("1.0.0-alpha.1"))
        XCTAssertLessThan(v("1.0.0-alpha.1"), v("1.0.0-alpha.beta"))
        XCTAssertLessThan(v("1.0.0-beta.2"), v("1.0.0-beta.11"))
        XCTAssertLessThan(v("1.0.0-rc.1"), v("1.0.1-alpha"))
        XCTAssertEqual(v("v0.5"), v("0.5.0"))
        XCTAssertFalse(v("0.5.0") < v("0.5.0"))
    }
}

final class GitHubReleaseTests: XCTestCase {
    let feed = UpdateFeed.grid

    func release(_ tag: String, prerelease: Bool = false, draft: Bool = false, host: String = "github.com",
                 repo: String = "HackitM/grid", extraAssets: String = "") -> String {
        let ver = SemanticVersion(tag)?.description ?? tag
        return """
        {"tag_name":"\(tag)","name":"GRID \(ver)","html_url":"https://\(host)/\(repo)/releases/tag/\(tag)",
         "published_at":"2026-11-09T21:00:29Z","body":"## What's new\\n- a","draft":\(draft),"prerelease":\(prerelease),
         "assets":[
          {"name":"GRID-\(ver)-macOS.zip","size":5340317,"browser_download_url":"https://\(host)/\(repo)/releases/download/\(tag)/GRID-\(ver)-macOS.zip"},
          {"name":"GRID-\(ver)-macOS.zip.sha256","size":87,"browser_download_url":"https://\(host)/\(repo)/releases/download/\(tag)/GRID-\(ver)-macOS.zip.sha256"}
          \(extraAssets)]}
        """
    }

    func testLatestObject() throws {
        let r = try XCTUnwrap(feed.newest(from: Data(release("v0.5.0").utf8), includePrereleases: false))
        XCTAssertEqual(r.version, SemanticVersion("0.5.0"))
        XCTAssertEqual(r.appAsset?.name, "GRID-0.5.0-macOS.zip")
        XCTAssertEqual(r.checksumAsset?.name, "GRID-0.5.0-macOS.zip.sha256")
        XCTAssertEqual(r.appAsset?.size, 5340317)
        XCTAssertNotNil(r.publishedAt)
    }

    func testListPicksNewestAndRespectsPrereleases() throws {
        let list = "[" + [release("v0.5.0"), release("v0.6.0-beta.1", prerelease: true), release("v0.4.0"), release("v0.7.0", draft: true)].joined(separator: ",") + "]"
        let stable = try XCTUnwrap(feed.newest(from: Data(list.utf8), includePrereleases: false))
        XCTAssertEqual(stable.tagName, "v0.5.0")
        let pre = try XCTUnwrap(feed.newest(from: Data(list.utf8), includePrereleases: true))
        XCTAssertEqual(pre.tagName, "v0.6.0-beta.1")
    }

    func testRejectsForeignLinks() throws {
        XCTAssertNil(try feed.newest(from: Data(release("v9.0.0", host: "evil.example").utf8), includePrereleases: false))
        XCTAssertNil(try feed.newest(from: Data(release("v9.0.0", repo: "someone/else").utf8), includePrereleases: false))
        // A foreign asset link is dropped; the release (and its genuine assets) stays.
        let extra = #",{"name":"GRID-0.5.0-macOS.zip","size":1,"browser_download_url":"https://evil.example/x.zip"}"#
        let r = try XCTUnwrap(feed.newest(from: Data(release("v0.5.0", extraAssets: extra).utf8), includePrereleases: false))
        XCTAssertEqual(r.assets.count, 2)
        XCTAssertEqual(r.appAsset?.downloadURL.host, "github.com")
        XCTAssertFalse(feed.isRepositoryURL(URL(string: "http://github.com/HackitM/grid/releases")!))
        XCTAssertFalse(feed.isRepositoryURL(URL(string: "https://user@github.com/HackitM/grid/releases")!))
    }

    func testMissingAssetsAndMalformedJSON() throws {
        let noAssets = #"{"tag_name":"v0.6.0","html_url":"https://github.com/HackitM/grid/releases/tag/v0.6.0","assets":[]}"#
        let r = try XCTUnwrap(feed.newest(from: Data(noAssets.utf8), includePrereleases: false))
        XCTAssertNil(r.appAsset)
        XCTAssertNil(r.checksumAsset)
        XCTAssertThrowsError(try feed.newest(from: Data("{not json".utf8), includePrereleases: false))
        XCTAssertThrowsError(try feed.newest(from: Data(#"{"message":"API rate limit exceeded"}"#.utf8), includePrereleases: false))
        let badTag = #"{"tag_name":"latest","html_url":"https://github.com/HackitM/grid/releases/tag/latest","assets":[]}"#
        XCTAssertNil(try feed.newest(from: Data(badTag.utf8), includePrereleases: false))
    }
}

final class ChecksumFileTests: XCTestCase {
    let sum = "74cfc8aa169dd1108b400597c5cbdd9a91b30524465d7d7f2bc85c4418e6d9ef"

    func testParsesShasumOutput() throws {
        let f = try XCTUnwrap(ChecksumFile("\(sum)  GRID-0.5.0-macOS.zip\n"))
        XCTAssertEqual(f.digest(for: "GRID-0.5.0-macOS.zip"), sum)
        let binary = try XCTUnwrap(ChecksumFile("\(sum.uppercased()) *GRID-0.5.0-macOS.zip"))
        XCTAssertEqual(binary.digest(for: "GRID-0.5.0-macOS.zip"), sum)
    }

    func testRejectsGarbage() {
        XCTAssertNil(ChecksumFile(""))
        XCTAssertNil(ChecksumFile("not a checksum"))
        XCTAssertNil(ChecksumFile("abc  GRID.zip"))
        XCTAssertNil(ChecksumFile(String(repeating: "z", count: 64) + "  GRID.zip"))
        XCTAssertNil(ChecksumFile(sum + "  ../GRID.zip"))
    }

    func testComparison() {
        XCTAssertTrue(ChecksumFile.matches(sum, sum.uppercased()))
        XCTAssertFalse(ChecksumFile.matches(sum, String(sum.dropLast()) + "0"))
        XCTAssertFalse(ChecksumFile.matches(sum, "abc"))
    }
}

final class UpdatePolicyTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func v(_ s: String) -> SemanticVersion { SemanticVersion(s)! }

    func testNothingChecksUntilOptedIn() {
        XCTAssertFalse(UpdatePolicy().isCheckDue(now: now))
        XCTAssertFalse(UpdatePolicy(checkDaily: false).isCheckDue(now: now))
        XCTAssertTrue(UpdatePolicy(checkDaily: true).isCheckDue(now: now))
    }

    func testDailyInterval() {
        var p = UpdatePolicy(checkDaily: true)
        p.lastCheck = now.addingTimeInterval(-3600)
        XCTAssertFalse(p.isCheckDue(now: now))
        p.lastCheck = now.addingTimeInterval(-23.5 * 3600)
        XCTAssertTrue(p.isCheckDue(now: now))
        p.lastCheck = now.addingTimeInterval(3600)   // clock moved back
        XCTAssertTrue(p.isCheckDue(now: now))
    }

    func testNotifyRules() {
        var p = UpdatePolicy(checkDaily: true)
        XCTAssertTrue(p.shouldNotify(v("0.6.0"), current: v("0.5.0"), now: now))
        XCTAssertFalse(p.shouldNotify(v("0.5.0"), current: v("0.5.0"), now: now))
        XCTAssertFalse(p.shouldNotify(v("0.4.0"), current: v("0.5.0"), now: now))
        p.skip(v("0.6.0"))
        XCTAssertFalse(p.shouldNotify(v("0.6.0"), current: v("0.5.0"), now: now))
        XCTAssertTrue(p.shouldNotify(v("0.6.1"), current: v("0.5.0"), now: now))   // newer than the skipped one
        p = UpdatePolicy(checkDaily: true)
        p.later(now: now)
        XCTAssertFalse(p.shouldNotify(v("0.6.0"), current: v("0.5.0"), now: now.addingTimeInterval(6 * 86400)))
        XCTAssertTrue(p.shouldNotify(v("0.6.0"), current: v("0.5.0"), now: now.addingTimeInterval(8 * 86400)))
        p = UpdatePolicy(checkDaily: true)
        p.noticed = "0.6.0"
        XCTAssertFalse(p.shouldNotify(v("0.6.0"), current: v("0.5.0"), now: now))
    }

    func testCodableRoundTrip() throws {
        var p = UpdatePolicy(checkDaily: true)
        p.skipped = "0.6.0"; p.lastCheck = now
        let back = try JSONDecoder().decode(UpdatePolicy.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(back, p)
    }
}

final class UpdateDownloadHostTests: XCTestCase {
    func testOnlyGitHubHTTPSHostsAreFollowed() {
        func ok(_ s: String) -> Bool { UpdateFeed.isTrustedDownloadHost(URL(string: s)!) }
        XCTAssertTrue(ok("https://github.com/HackitM/grid/releases/download/v1.0.0/GRID-1.0.0-macOS.zip"))
        XCTAssertTrue(ok("https://objects.githubusercontent.com/github-production-release-asset/1/abc?sig=x"))
        XCTAssertTrue(ok("https://release-assets.githubusercontent.com/github-production-release-asset/1/abc"))
        XCTAssertTrue(ok("https://GitHub.com/x"))
        XCTAssertTrue(ok("https://github.com:443/x"))

        XCTAssertFalse(ok("http://github.com/HackitM/grid/releases/download/v1.0.0/a.zip"))       // not HTTPS
        XCTAssertFalse(ok("https://github.com.evil.example/a.zip"))
        XCTAssertFalse(ok("https://evilgithub.com/a.zip"))
        XCTAssertFalse(ok("https://githubusercontent.com.evil.example/a.zip"))
        XCTAssertFalse(ok("https://notgithubusercontent.com/a.zip"))
        XCTAssertFalse(ok("https://user@github.com/a.zip"))
        XCTAssertFalse(ok("https://github.com:8443/a.zip"))
        XCTAssertFalse(ok("https://example.com/a.zip"))
        XCTAssertFalse(ok("file:///tmp/a.zip"))
    }
}
