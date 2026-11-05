@testable import NetLabCore
import XCTest

final class EndpointGrouperTests: XCTestCase {
    private func request(_ path: String) -> RecordedRequest {
        request("GET", path)
    }

    private func request(_ method: String, _ path: String, body: String? = nil) -> RecordedRequest {
        RecordedRequest(method: method, url: URL(string: "https://api.example.com\(path)")!, headers: [:], body: body.map { Data($0.utf8) })
    }

    func testIDShapesBecomePlaceholders() {
        let grouper = EndpointGrouper()
        XCTAssertEqual(grouper.group(request("/v1/payments/tx_8F21/status")).key.template, "/v1/payments/{id}/status")
        XCTAssertEqual(grouper.group(request("/v1/orders/48213")).key.template, "/v1/orders/{id}")
        XCTAssertEqual(grouper.group(request("/v1/users/3F2504E0-4F89-11D3-9A0C-0305E82C3301")).key.template, "/v1/users/{id}")
        XCTAssertEqual(grouper.group(request("/v2/oauth2/token")).key.template, "/v2/oauth2/token")
    }

    func testVariationPromotesWordLikeIDs() {
        let grouper = EndpointGrouper()
        _ = grouper.group(request("/orders/ABCD/items"))
        _ = grouper.group(request("/orders/EFGH/items"))
        let third = grouper.group(request("/orders/IJKL/items"))
        XCTAssertEqual(third.key.template, "/orders/{id}/items")
    }

    func testLowercaseWordsAreNotMerged() {
        let grouper = EndpointGrouper()
        _ = grouper.group(request("/payments/tx_1234/status"))
        _ = grouper.group(request("/payments/tx_1234/refunds"))
        let third = grouper.group(request("/payments/tx_1234/receipt"))
        XCTAssertEqual(third.key.template, "/payments/{id}/receipt")
    }

    func testForcedSegment() {
        let grouper = EndpointGrouper()
        let sample = request("/v1/countries/dz/methods")
        grouper.rules.forced[grouper.positionKey(for: sample, index: 2)] = true
        XCTAssertEqual(grouper.group(sample).key.template, "/v1/countries/{id}/methods")
    }

    func testGraphQLOperationsAreSplit() {
        let grouper = EndpointGrouper()
        let key = grouper.group(request("POST", "/graphql", body: #"{"operationName":"Checkout","query":"mutation Checkout { id }"}"#)).key
        XCTAssertEqual(key.discriminator, "Checkout")
    }

    func testSplitByQueryParameter() {
        let grouper = EndpointGrouper()
        let sample = request("/v1/search?type=card&q=1")
        let base = grouper.group(sample).key
        grouper.rules.splits[base.baseID] = .query("type")
        XCTAssertEqual(grouper.group(sample).key.discriminator, "type=card")
    }
}
