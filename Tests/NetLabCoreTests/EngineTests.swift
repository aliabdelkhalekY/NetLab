@testable import NetLabCore
import XCTest

final class EngineTests: XCTestCase {
    private let key = EndpointKey(host: "api.example.com", method: "GET", template: "/v1/payments/{id}/status")

    private func request(_ id: String = "tx_8F21", query: String = "") -> RecordedRequest {
        RecordedRequest(method: "GET", url: URL(string: "https://api.example.com/v1/payments/\(id)/status\(query)")!, headers: [:], body: nil)
    }

    private func finish(_ engine: NetLabEngine, _ plan: NetLabEngine.Plan) {
        let report = plan.override.map { OverrideReport(overrideID: $0.id, title: $0.title, applied: [$0.title]) }
        engine.finish(plan, response: RecordedResponse(statusCode: 200, headers: [:], body: nil), errorCode: nil, report: report)
    }

    func testNextCallsUseTheOverrideThenPassThrough() {
        let engine = NetLabEngine()
        engine.perform(.arm(key, Override(title: "Offline", action: .failure(.offline), duration: .next(2))))

        let first = engine.begin(request())
        finish(engine, first)
        let second = engine.begin(request("tx_9A02"))
        finish(engine, second)
        let third = engine.begin(request("tx_77B3"))

        XCTAssertEqual(first.key, key)
        XCTAssertNotNil(first.override)
        XCTAssertNotNil(second.override)
        XCTAssertNil(third.override)
        XCTAssertNil(engine.snapshot.queue(for: key))
    }

    func testSavedOverrideCanBeArmedAgainAfterItIsUsedUp() {
        let engine = NetLabEngine()
        let add = PatchOperation(kind: .add, path: [.key("statusCode")], value: .int(12))
        engine.perform(.saveOverride(key, Override(title: "Add status", action: .changes([add], statusCode: nil))))
        guard let saved = engine.snapshot.saved(for: key).first else { return XCTFail("not saved") }

        engine.perform(.armSaved(saved.id))
        finish(engine, engine.begin(request()))
        XCTAssertNil(engine.begin(request()).override)

        engine.perform(.armSaved(saved.id))
        XCTAssertEqual(engine.begin(request()).override?.title, "Add status")
        XCTAssertEqual(engine.snapshot.saved(for: key).count, 1)
    }

    func testSavingTheSameChangesAgainKeepsOneEntry() {
        let engine = NetLabEngine()
        let first = PatchOperation(kind: .add, path: [.key("statusCode")], value: .int(12))
        let again = PatchOperation(kind: .add, path: [.key("statusCode")], value: .int(12))
        let other = PatchOperation(kind: .add, path: [.key("statusCode")], value: .string("12"))

        engine.perform(.saveOverride(key, Override(title: "One", action: .changes([first], statusCode: nil))))
        engine.perform(.saveOverride(key, Override(title: "Two", action: .changes([again], statusCode: nil))))
        engine.perform(.saveOverride(key, Override(title: "Three", action: .changes([other], statusCode: nil))))

        XCTAssertEqual(engine.snapshot.saved(for: key).map(\.override.title), ["Three", "Two"])
    }

    func testDeletedSavedOverrideIsGone() {
        let engine = NetLabEngine()
        engine.perform(.saveOverride(key, Override(title: "Offline", action: .failure(.offline))))
        guard let saved = engine.snapshot.saved(for: key).first else { return XCTFail("not saved") }

        engine.perform(.deleteSaved(saved.id))

        XCTAssertTrue(engine.snapshot.saved(for: key).isEmpty)
    }

    func testStepsAreTakenInOrderAndTheLastCanRepeat() {
        let engine = NetLabEngine()
        engine.perform(.arm(key, Override(title: "Pending", action: .status(200, body: .real))))
        engine.perform(.arm(key, Override(title: "Paid", action: .status(200, body: .real))))
        engine.perform(.setRepeatLast(key, true))

        let titles = (0..<4).map { _ -> String? in
            let plan = engine.begin(request())
            finish(engine, plan)
            return plan.override?.title
        }

        XCTAssertEqual(titles, ["Pending", "Paid", "Paid", "Paid"])
    }

    func testReleasedOverrideStaysArmed() {
        let engine = NetLabEngine()
        engine.perform(.arm(key, Override(title: "Declined", action: .changes([], statusCode: 402))))

        let failed = engine.begin(request())
        engine.release(failed)
        engine.finish(failed, response: nil, errorCode: "notConnectedToInternet", report: OverrideReport(overrideID: failed.override!.id, title: "Declined", notApplied: true))
        let retry = engine.begin(request())

        XCTAssertEqual(retry.override?.id, failed.override?.id)
    }

    func testConditionLimitsWhichCallTakesTheStep() {
        let engine = NetLabEngine()
        engine.perform(.arm(key, Override(title: "Only retry", action: .failure(.timeout), condition: "attempt=2")))

        let first = engine.begin(request(query: "?attempt=1"))
        let second = engine.begin(request(query: "?attempt=2"))

        XCTAssertNil(first.override)
        XCTAssertEqual(second.override?.title, "Only retry")
    }

    func testLearningKeepsVariantsPerStatus() {
        let engine = NetLabEngine()
        let plan = engine.begin(request())
        engine.learn(plan, response: RecordedResponse(statusCode: 200, headers: [:], body: Data(#"{"status":"PAID"}"#.utf8)))
        let second = engine.begin(request("tx_9A02"))
        engine.learn(second, response: RecordedResponse(statusCode: 402, headers: [:], body: Data(#"{"error":"declined"}"#.utf8)))

        let snapshot = engine.snapshot
        XCTAssertEqual(snapshot.endpoint(for: key)?.variants.map(\.statusCode), [200, 402])
        XCTAssertEqual(snapshot.schema(for: key, slot: "2xx")?.properties["status"]?.values, ["PAID"])
        XCTAssertEqual(snapshot.endpoint(for: key)?.idsSeen, ["tx_8F21", "tx_9A02"])
    }

    func testRegroupingMergesEndpointsAndMovesQueues() {
        let engine = NetLabEngine()
        let early = EndpointKey(host: "api.example.com", method: "GET", template: "/orders/ABCD/items")
        _ = engine.begin(RecordedRequest(method: "GET", url: URL(string: "https://api.example.com/orders/ABCD/items")!, headers: [:], body: nil))
        engine.perform(.arm(early, Override(title: "Offline", action: .failure(.offline))))
        _ = engine.begin(RecordedRequest(method: "GET", url: URL(string: "https://api.example.com/orders/EFGH/items")!, headers: [:], body: nil))
        _ = engine.begin(RecordedRequest(method: "GET", url: URL(string: "https://api.example.com/orders/IJKL/items")!, headers: [:], body: nil))

        let merged = EndpointKey(host: "api.example.com", method: "GET", template: "/orders/{id}/items")
        let snapshot = engine.snapshot
        XCTAssertEqual(snapshot.endpoints.map(\.key), [merged])
        XCTAssertEqual(snapshot.endpoint(for: merged)?.callCount, 3)
        XCTAssertNotNil(snapshot.queue(for: merged))
    }

    func testMoveSteps() {
        XCTAssertEqual(NetLabEngine.move(["a", "b", "c", "d"], from: IndexSet(integer: 0), to: 3), ["b", "c", "a", "d"])
        XCTAssertEqual(NetLabEngine.move(["a", "b", "c", "d"], from: IndexSet(integer: 3), to: 0), ["d", "a", "b", "c"])
    }
}
