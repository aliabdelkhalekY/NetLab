@testable import NetLabCore
import XCTest

final class JSONPatchTests: XCTestCase {
    private func json(_ text: String) throws -> JSONValue {
        try JSONValue(data: Data(text.utf8))
    }

    func testKindParsesTheChosenType() {
        XCTAssertEqual(JSONKind.number.value(from: "12"), .int(12))
        XCTAssertEqual(JSONKind.number.value(from: " 12.5 "), .double(12.5))
        XCTAssertNil(JSONKind.number.value(from: "abc"))
        XCTAssertEqual(JSONKind.string.value(from: "12"), .string("12"))
        XCTAssertEqual(JSONKind.bool.value(from: "true"), .bool(true))
        XCTAssertNil(JSONKind.bool.value(from: "yes"))
        XCTAssertEqual(JSONKind.null.value(from: "anything"), .null)
        XCTAssertEqual(JSONKind.object.value(from: ""), .object([:]))
        XCTAssertEqual(JSONKind.array.value(from: ""), .array([]))
    }

    func testAddedNumberStaysANumberInTheBody() throws {
        let base = try json(#"{"data":{"payUrl":"x"}}"#)
        let edited = try json(#"{"data":{"payUrl":"x","statusCode":12}}"#)

        let result = JSONPatch.apply(JSONPatch.diff(from: base, to: edited), to: base)

        XCTAssertEqual(result.value["data"]?["statusCode"], .int(12))
    }

    func testChangedFieldIsAppliedToAFreshResponse() throws {
        let cached = try json(#"{"id":"tx_1","status":"PAID","amount":100}"#)
        let edited = try json(#"{"id":"tx_1","status":"DECLINED","amount":100}"#)
        let fresh = try json(#"{"id":"tx_2","status":"PAID","amount":250}"#)

        let operations = JSONPatch.diff(from: cached, to: edited)
        let result = JSONPatch.apply(operations, to: fresh)

        XCTAssertEqual(operations.count, 1)
        XCTAssertEqual(result.value, try json(#"{"id":"tx_2","status":"DECLINED","amount":250}"#))
        XCTAssertTrue(result.skipped.isEmpty)
    }

    func testAddAndRemoveFields() throws {
        let cached = try json(#"{"status":"PAID","receipt":{"number":"R1"}}"#)
        let edited = try json(#"{"status":"PAID","reason":"cib_declined"}"#)
        let fresh = try json(#"{"status":"PAID","receipt":{"number":"R9"}}"#)

        let result = JSONPatch.apply(JSONPatch.diff(from: cached, to: edited), to: fresh)

        XCTAssertEqual(result.value, try json(#"{"status":"PAID","reason":"cib_declined"}"#))
    }

    func testMissingFieldIsReportedAsSkipped() throws {
        let cached = try json(#"{"status":"PAID","receipt":{"number":"R1"}}"#)
        let edited = try json(#"{"status":"PAID","receipt":{"number":"R2"}}"#)
        let fresh = try json(#"{"status":"PAID"}"#)

        let result = JSONPatch.apply(JSONPatch.diff(from: cached, to: edited), to: fresh)

        XCTAssertEqual(result.applied.count, 0)
        XCTAssertEqual(result.skipped.count, 1)
        XCTAssertEqual(result.value, fresh)
    }

    func testArrayItemsAreMatchedByID() throws {
        let cached = try json(#"{"methods":[{"id":"card","enabled":true},{"id":"cash","enabled":true}]}"#)
        let edited = try json(#"{"methods":[{"id":"card","enabled":false},{"id":"cash","enabled":true}]}"#)
        let fresh = try json(#"{"methods":[{"id":"wallet","enabled":true},{"id":"card","enabled":true},{"id":"cash","enabled":true}]}"#)

        let result = JSONPatch.apply(JSONPatch.diff(from: cached, to: edited), to: fresh)

        XCTAssertEqual(result.value, try json(#"{"methods":[{"id":"wallet","enabled":true},{"id":"card","enabled":false},{"id":"cash","enabled":true}]}"#))
    }

    func testEmptyingAListRemovesEveryItem() throws {
        let cached = try json(#"{"methods":[{"id":"card"},{"id":"cash"}]}"#)
        let edited = try json(#"{"methods":[]}"#)

        let result = JSONPatch.apply(JSONPatch.diff(from: cached, to: edited), to: cached)

        XCTAssertEqual(result.value, edited)
    }

    func testPositionalArraysWithoutIDs() throws {
        let cached = try json(#"[1,2,3]"#)
        let edited = try json(#"[1,5]"#)

        let result = JSONPatch.apply(JSONPatch.diff(from: cached, to: edited), to: cached)

        XCTAssertEqual(result.value, edited)
    }

    func testIntegersStayIntegers() throws {
        let value = try json(#"{"amount":1250,"rate":0.5,"ok":true}"#)
        XCTAssertEqual(value["amount"], .int(1250))
        XCTAssertEqual(value["rate"], .double(0.5))
        XCTAssertEqual(value["ok"], .bool(true))
    }
}
