import JavaScriptCore
import XCTest
@testable import GridCore

final class ScriptletTests: XCTestCase {
    // MARK: Arguments

    func testArgumentSplitting() {
        XCTAssertEqual(ScriptletIndex.parseArgs("set, a.b, undefined"), ["set", "a.b", "undefined"])
        XCTAssertEqual(ScriptletIndex.parseArgs(#"rmnt, script, window\,"fetch""#), ["rmnt", "script", #"window,"fetch""#])
        XCTAssertEqual(ScriptletIndex.parseArgs(#"trusted-rpfr, '"adPlacements"', '"no_ads"', player?"#),
                       ["trusted-rpfr", #""adPlacements""#, #""no_ads""#, "player?"])
        XCTAssertEqual(ScriptletIndex.parseArgs(#"x, /a{2\,4}\//, , last"#), ["x", #"/a{2,4}\//"#, "", "last"])
        XCTAssertEqual(ScriptletIndex.parseArgs("x, 'a, b'"), ["x", "a, b"])
        XCTAssertEqual(ScriptletIndex.parseArgs("x, 'not closed, b"), ["x", "'not closed", "b"])
        XCTAssertEqual(ScriptletIndex.parseArgs("x, ''"), ["x", ""])
        XCTAssertEqual(ScriptletIndex.parseArgs("  "), [])
    }

    func testNamesAndTrust() {
        XCTAssertEqual(ScriptletIndex.parseCall("set.js, a, 1", trusted: false), ["set-constant", "a", "1"])
        XCTAssertEqual(ScriptletIndex.parseCall("nano-stb, [native code], 17000", trusted: false)?.first, "nano-setTimeout-booster")
        XCTAssertNil(ScriptletIndex.parseCall("trusted-rpfr, a, b", trusted: false), "trusted-* only from trusted lists")
        XCTAssertEqual(ScriptletIndex.parseCall("trusted-rpfr, a, b", trusted: true)?.first, "trusted-replace-fetch-response")
        // Scriptlets whose arguments are code are never run.
        XCTAssertNil(ScriptletIndex.parseCall("rpnt, script, x, (()=>{})()", trusted: true))
        XCTAssertNil(ScriptletIndex.parseCall("trusted-rpnt, script, x, y", trusted: true))
        XCTAssertNil(ScriptletIndex.parseCall("trusted-edit-inbound-object, JSON.stringify, 0, x", trusted: true))
    }

    // MARK: Index

    private func index(_ text: String, list: String = "ublock-filters") -> ScriptletIndex {
        ScriptletIndex.build([FilterList(name: list, text: text)])
    }

    func testSiteSpecificRulesOnly() {
        let i = index("""
        ##+js(set, generic, 1)
        *##+js(set, star, 1)
        *,~edu##+js(set, star2, 1)
        youtube.com##+js(set, yt, 1)
        www.youtube.com##+js(set, www, 1)
        google.*##+js(set, entity, 1)
        kissasian.*>>##+js(nowoif)
        /re/##+js(set, regex, 1)
        example.com##+js(rpnt, script, a, b)
        example.com##+js(unknown-thing, a)
        """)
        XCTAssertEqual(i.calls(for: "www.youtube.com").map { $0[1] }, ["yt", "www"])
        XCTAssertEqual(i.calls(for: "youtube.com").map { $0[1] }, ["yt"])
        XCTAssertEqual(i.calls(for: "google.co.uk").map { $0[1] }, ["entity"])
        XCTAssertEqual(i.calls(for: "www.google.de").map { $0[1] }, ["entity"])
        XCTAssertEqual(i.calls(for: "google.evil.example"), [])
        XCTAssertEqual(i.calls(for: "notyoutube.com"), [])
        XCTAssertEqual(i.calls(for: "example.com"), [])
        XCTAssertEqual(i.ruleCount, 3)
    }

    func testExclusionsExceptionsAndDuplicates() {
        let i = index("""
        a.com,b.com,~x.b.com##+js(set, one, 1)
        a.com##+js(set, one, 1)
        b.com##+js(set, two, 1)
        y.b.com#@#+js(set, two, 1)
        c.com##+js(set, three, 1)
        c.com#@#+js()
        #@#+js(set, four, 1)
        d.com##+js(set, four, 1)
        """)
        XCTAssertEqual(i.calls(for: "a.com").map { $0[1] }, ["one"], "duplicate dropped")
        XCTAssertEqual(i.calls(for: "b.com").map { $0[1] }, ["one", "two"])
        XCTAssertEqual(i.calls(for: "x.b.com").map { $0[1] }, ["two"], "excluded subdomain")
        XCTAssertEqual(i.calls(for: "y.b.com").map { $0[1] }, ["one"], "specific exception")
        XCTAssertEqual(i.calls(for: "c.com"), [], "#@#+js() turns all off")
        XCTAssertEqual(i.calls(for: "d.com"), [], "generic exception")
    }

    func testPreprocessorBlocks() {
        let i = index("""
        !#if !cap_html_filtering
        a.com##+js(set, kept, 1)
        !#else
        a.com##+js(set, else, 1)
        !#endif
        !#if env_chromium || (env_firefox && !env_mobile)
        a.com##+js(set, chromium, 1)
        !#if false
        !#endif
        !#endif
        !#if !ext_ubol
        a.com##+js(set, notLite, 1)
        !#endif
        """)
        XCTAssertEqual(i.calls(for: "a.com").map { $0[1] }, ["kept", "notLite"])
        XCTAssertTrue(Preprocessor.evaluate("a && (b || !c)", tokens: ["a", "b"]))
        XCTAssertFalse(Preprocessor.evaluate("a && !b", tokens: ["a", "b"]))
    }

    func testUntrustedListCantUseTrustedScriptlets() {
        let text = "a.com##+js(trusted-set, x, {\"value\": 1})\na.com##+js(set, y, 1)"
        XCTAssertEqual(index(text, list: "easylist").calls(for: "a.com").map { $0[0] }, ["set-constant"])
        XCTAssertEqual(index(text).calls(for: "a.com").map { $0[0] }, ["trusted-set-constant", "set-constant"])
    }

    // MARK: The library

    /// Runs the site script in a bare JavaScriptCore context standing in for the page.
    private func run(_ calls: [[String]], host: String = "www.youtube.com", page: String) -> JSValue? {
        let ctx = JSContext()!
        var failure: String?
        ctx.exceptionHandler = { _, e in failure = e?.toString() }
        ctx.evaluateScript("var location = { hostname: '\(host)', href: 'https://\(host)/' }; var setTimeout = function () {};")
        ctx.evaluateScript(ScriptletLibrary.script(host: "www.youtube.com", calls: calls))
        XCTAssertNil(failure)
        return ctx.evaluateScript(page)
    }

    func testSetConstantAndJSONPrune() {
        let calls = [
            ["set-constant", "ytInitialPlayerResponse.adPlacements", "undefined"],
            ["set-constant", "ytInitialPlayerResponse.playerAds", "undefined"],
            ["set-constant", "flags.enabled", "false"],
            ["set-constant", "bad", "alert(1)"],
            ["json-prune", "adSlots [].ads list.[-].isAd", ""],
        ]
        let result = run(calls, page: """
        var ytInitialPlayerResponse = { adPlacements: [1], playerAds: [2], videoDetails: 'v' };
        var flags = { enabled: true };
        var bad = 'kept';
        var a = JSON.parse('{"adSlots": [1], "keep": 1}');
        var b = JSON.parse('[{"ads": 1, "x": 1}, {"x": 2}]');
        var c = JSON.parse('{"list": [{"isAd": true}, {"id": 2}]}');
        JSON.stringify([ytInitialPlayerResponse.adPlacements === undefined, ytInitialPlayerResponse.playerAds === undefined,
          ytInitialPlayerResponse.videoDetails, flags.enabled, bad, a, b, c]);
        """)
        XCTAssertEqual(result?.toString(),
                       #"[true,true,"v",false,"kept",{"keep":1},[{"x":1},{"x":2}],{"list":[{"id":2}]}]"#)
    }

    func testPatchedFunctionsStillLookNative() {
        let result = run([["json-prune", "ads", ""]], page: """
        [Function.prototype.toString.call(JSON.parse), JSON.parse.toString(), Function.prototype.toString.toString()].join('|')
        """)
        XCTAssertEqual(result?.toString().contains("ProxyObject"), false, result?.toString() ?? "")
        XCTAssertEqual(result?.toString().contains("parse"), true)
    }

    func testOtherHostsAreLeftAlone() {
        let result = run([["set-constant", "x", "true"]], host: "example.com", page: "var x = 5; x")
        XCTAssertEqual(result?.toInt32(), 5)
    }

    func testArgumentsAreDataNotCode() {
        // A hostile argument stays a string: nothing in it is evaluated.
        let script = ScriptletLibrary.script(host: "a.com", calls: [["set-constant", "x\"]);alert(1);//", "</script>"]])
        XCTAssertTrue(script.contains(#"x\"]);alert(1);\/\/"#))
        let ctx = JSContext()!
        ctx.evaluateScript("var location = { hostname: 'a.com' }; var alerted = false; function alert() { alerted = true; }")
        ctx.evaluateScript(script)
        XCTAssertEqual(ctx.evaluateScript("alerted")?.toBool(), false)
    }
}
