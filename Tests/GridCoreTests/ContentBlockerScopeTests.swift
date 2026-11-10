import XCTest
@testable import GridCore

/// A filter whose sites can't all be expressed must never end up applying to more sites than
/// written (the `kat.*` filter once blocked first-party scripts everywhere, breaking YouTube).
final class ContentBlockerScopeTests: XCTestCase {
    private func rules(_ text: String, kind: ContentRuleChunk.Kind) -> [[String: Any]] {
        ContentBlockerCompiler.compile([FilterList(name: "test", text: text)]).ruleLists.filter { $0.kind == kind }.flatMap {
            (try? JSONSerialization.jsonObject(with: Data($0.json.utf8))) as? [[String: Any]] ?? []
        }
    }

    func testNetworkFilterWithOnlyEntityInclusionsIsSkipped() {
        // Real uBO filter shape: valid exclusions plus `name.*` inclusions GRID can't express.
        let r = rules("*$script,1p,domain=~kat.ai|~kat.pink|kat.*|kickass.*", kind: .network)
        XCTAssertTrue(r.isEmpty, "must not become 'block first-party scripts everywhere except kat.ai': \(r)")
    }

    func testNetworkFilterKeepsItsExpressibleInclusions() {
        let r = rules("||ads.example^$script,domain=good.com|kat.*", kind: .network)
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual((r.first?["trigger"] as? [String: Any])?["if-domain"] as? [String], ["*good.com"])
    }

    func testCosmeticFilterWithOnlyEntityInclusionsIsSkipped() {
        let generic = rules("kat.*,~kat.ai##.banner", kind: .cosmeticGeneric)
        let specific = rules("kat.*,~kat.ai##.banner", kind: .cosmeticSpecific)
        XCTAssertTrue(generic.isEmpty && specific.isEmpty, "must not hide .banner on every site: \(generic) \(specific)")
    }

    func testCosmeticFilterKeepsItsExpressibleInclusions() {
        let specific = rules("good.com,kat.*##.banner", kind: .cosmeticSpecific)
        XCTAssertEqual(specific.count, 1)
    }
}
