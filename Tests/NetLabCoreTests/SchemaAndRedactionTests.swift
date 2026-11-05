@testable import NetLabCore
import XCTest

final class SchemaAndRedactionTests: XCTestCase {
    func testSchemaCollectsValuesAndOptionalFields() throws {
        var schema = SchemaNode()
        schema.merge(try JSONValue(data: Data(#"{"status":"PAID","receipt":{"number":"R1"}}"#.utf8)))
        schema.merge(try JSONValue(data: Data(#"{"status":"PENDING"}"#.utf8)))

        XCTAssertEqual(schema.properties["status"]?.values, ["PAID", "PENDING"])
        XCTAssertTrue(schema.isOptional("receipt"))
        XCTAssertFalse(schema.isOptional("status"))
    }

    func testRedactionMasksHeadersAndNestedKeys() throws {
        let redaction = Redaction.default.adding(headers: ["X-Session-Token"], jsonKeys: ["pin"])
        let headers = redaction.redact(headers: ["Authorization": "Bearer abc", "x-session-token": "x", "Accept": "application/json"])
        XCTAssertEqual(headers["Authorization"], Redaction.mask)
        XCTAssertEqual(headers["x-session-token"], Redaction.mask)
        XCTAssertEqual(headers["Accept"], "application/json")

        let body = try JSONValue(data: Data(#"{"card":{"card_number":"4242","expiry":"12/30"},"access_token":"t","pin":"1234","amount":5}"#.utf8))
        let redacted = redaction.redact(json: body)
        XCTAssertEqual(redacted["card"]?["card_number"], .string(Redaction.mask))
        XCTAssertEqual(redacted["card"]?["expiry"], .string("12/30"))
        XCTAssertEqual(redacted["access_token"], .string(Redaction.mask))
        XCTAssertEqual(redacted["pin"], .string(Redaction.mask))
        XCTAssertEqual(redacted["amount"], .int(5))
    }
}
