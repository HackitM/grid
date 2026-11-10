import XCTest
@testable import GridCore

/// Hardening tests for the widget platform's untrusted inputs (manifests, view trees, globs).
final class WidgetHardeningTests: XCTestCase {
    // MARK: Numbers from manifests

    func testHugeNumberDefaultDoesNotTrap() throws {
        let json = #"""
        {"api":1,"id":"com.example.big","name":"Big","version":"1.0","entry":"widget.js",
         "settings":[{"key":"n","type":"number","label":"N","default":1e300},
                     {"key":"m","type":"number","label":"M","default":5},
                     {"key":"f","type":"number","label":"F","default":2.5}]}
        """#
        let m = try JSONDecoder().decode(WidgetManifest.self, from: Data(json.utf8))
        let d = m.defaultSettings
        XCTAssertEqual(d["m"], "5", "whole numbers have no fraction")
        XCTAssertEqual(d["f"], "2.5")
        XCTAssertEqual(d["n"], String(1e300), "too large for Int: kept as a Double, no trap")
    }

    func testNormalizeWithHugeBoundsDoesNotTrap() {
        let spec = WidgetSettingSpec(key: "n", type: "number", label: "N", default: nil, min: -1e300, max: 1e300,
                                     maxLength: nil, options: nil, hosts: nil)
        XCTAssertEqual(spec.normalize("1e200"), String(1e200))
        XCTAssertEqual(spec.normalize("42"), "42")
        XCTAssertNil(spec.normalize("nan"))
        XCTAssertNil(spec.normalize("inf"))
    }

    // MARK: Globs

    func testGlobSemanticsUnchanged() {
        XCTAssertTrue(PathRule.globMatch(pattern: "/a/**", path: "/a"))
        XCTAssertTrue(PathRule.globMatch(pattern: "/a/**", path: "/a/b/c"))
        XCTAssertTrue(PathRule.globMatch(pattern: "/a/**/c", path: "/a/c"))
        XCTAssertTrue(PathRule.globMatch(pattern: "/a/**/c", path: "/a/x/y/c"))
        XCTAssertFalse(PathRule.globMatch(pattern: "/a/**/c", path: "/a/x/y/d"))
        XCTAssertTrue(PathRule.globMatch(pattern: "/a/*.txt", path: "/a/n.txt"))
        XCTAssertFalse(PathRule.globMatch(pattern: "/a/*.txt", path: "/a/b/n.txt"))
        XCTAssertFalse(PathRule.globMatch(pattern: "/a/*", path: "/a"))
        XCTAssertTrue(PathRule.globMatch(pattern: "", path: ""))
        XCTAssertFalse(PathRule.globMatch(pattern: "", path: "/a"))
    }

    /// Plain backtracking takes longer than the age of the universe on this; the table is instant.
    func testManyDoubleStarsMatchInPolynomialTime() {
        let pattern = "/" + Array(repeating: "**", count: 24).joined(separator: "/") + "/nope"
        let path = "/" + Array(repeating: "d", count: 60).joined(separator: "/")
        let start = Date()
        XCTAssertFalse(PathRule.globMatch(pattern: pattern, path: path))
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }

    func testPrecomputedSensitiveRootsGiveTheSameAnswer() {
        let home = NSHomeDirectory()
        let ctx = WidgetCallContext(cwd: nil, selection: [], settings: [:])
        let roots = PathRule.canonicalSensitiveRoots(home: home)
        for path in [home + "/.ssh/id_ed25519", home + "/Documents/a.txt", "/usr/bin/true"] {
            for patterns in [["~/**"], ["~/.ssh/**"], ["/usr/**"]] {
                XCTAssertEqual(PathRule.allows(path, patterns: patterns, context: ctx, home: home),
                               PathRule.allows(path, patterns: patterns, context: ctx, home: home, sensitiveRoots: roots),
                               "\(path) under \(patterns)")
            }
        }
        XCTAssertFalse(PathRule.allows(home + "/.ssh/id_ed25519", patterns: ["~/**"], context: ctx, home: home, sensitiveRoots: roots))
    }

    // MARK: View tree equality

    private func tree(_ json: String) throws -> WidgetNode {
        WidgetTreeParser.parse(try JSONDecoder().decode(WidgetJSON.self, from: Data(json.utf8))).0
    }

    func testNodeEqualityComparesEveryField() throws {
        let base = #"""
        {"type":"stack","axis":"v","gap":4,"children":[
          {"type":"text","text":"a","style":"mono","tone":"warn","lines":2},
          {"type":"kv","rows":[["k","v"],["k2","v2"]]},
          {"type":"list","items":[{"title":"t","subtitle":"s","action":{"kind":"copy","value":"x"}}]},
          {"type":"button","title":"Go","action":{"kind":"custom","value":"go","payload":{"n":1}}},
          {"type":"sparkline","values":[1,2,3],"max":5},
          {"type":"bar","value":0.5,"tone":"ok"},
          {"type":"progress"},
          {"type":"spacer"},{"type":"divider"}
        ]}
        """#
        XCTAssertEqual(try tree(base), try tree(base))
        let variants = [
            ("\"text\":\"a\"", "\"text\":\"b\""), ("\"lines\":2", "\"lines\":3"), ("[\"k2\",\"v2\"]", "[\"k2\",\"v3\"]"),
            ("\"subtitle\":\"s\"", "\"subtitle\":\"z\""), ("\"value\":\"x\"", "\"value\":\"y\""), ("{\"n\":1}", "{\"n\":2}"),
            ("[1,2,3]", "[1,2,4]"), ("\"max\":5", "\"max\":6"), ("\"value\":0.5", "\"value\":0.6"), ("\"gap\":4", "\"gap\":5"),
            ("{\"type\":\"spacer\"}", "{\"type\":\"divider\"}"), ("{\"type\":\"progress\"}", "{\"type\":\"progress\",\"value\":0.2}"),
        ]
        for (from, to) in variants {
            XCTAssertTrue(base.contains(from), from)
            XCTAssertNotEqual(try tree(base), try tree(base.replacingOccurrences(of: from, with: to)), "\(from) → \(to)")
        }
    }

    // MARK: Deck layout

    func testLinesSurviveDegenerateWidths() {
        XCTAssertEqual(DeckRows.lines(count: 3, width: .infinity, minWidth: 200, spacing: 8), [3])
        XCTAssertEqual(DeckRows.lines(count: 3, width: .nan, minWidth: 200, spacing: 8), [3])
        XCTAssertEqual(DeckRows.lines(count: 3, width: 100, minWidth: 0, spacing: 0), [3])
        XCTAssertEqual(DeckRows.lines(count: 2, width: 0, minWidth: 200, spacing: 8), [1, 1])
        XCTAssertEqual(DeckRows.lines(count: 2, width: 1e300, minWidth: 1, spacing: 0), [2])
    }
}
