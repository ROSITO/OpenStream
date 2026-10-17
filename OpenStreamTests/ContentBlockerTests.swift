import XCTest
@testable import OpenStream

final class ContentBlockerTests: XCTestCase {
    @MainActor
    func testBundledRulesJSONIsValidArray() throws {
        let json = try ContentBlocker.loadRulesJSON()
        let data = Data(json.utf8)
        let object = try JSONSerialization.jsonObject(with: data)
        let rules = try XCTUnwrap(object as? [[String: Any]])
        XCTAssertGreaterThan(rules.count, 20)
        for rule in rules {
            XCTAssertNotNil(rule["trigger"])
            XCTAssertNotNil(rule["action"])
        }
    }
}
