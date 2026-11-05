@testable import NetLabCore
import XCTest

final class InterceptionTests: XCTestCase {
    private let host = "netlab.test"

    override func setUp() {
        super.setUp()
        NetLabEngine.shared.startIntercepting()
    }

    func testReplacedResponseNeverReachesTheNetwork() async throws {
        let key = EndpointKey(host: host, method: "GET", template: "/v1/items")
        let body = Data(#"{"ok":true}"#.utf8)
        NetLabEngine.shared.perform(.arm(key, Override(title: "Stub", action: .replace(statusCode: 201, headers: ["Content-Type": "application/json"], body: body))))

        let session = URLSession(configuration: .ephemeral)
        let (data, response) = try await session.data(from: URL(string: "https://\(host)/v1/items")!)

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 201)
        XCTAssertEqual(data, body)
        XCTAssertEqual((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Length"), String(body.count))
    }

    func testOfflineFailsWithTheSystemError() async {
        let key = EndpointKey(host: host, method: "GET", template: "/v1/offline")
        NetLabEngine.shared.perform(.arm(key, Override(title: "Offline", action: .failure(.offline))))

        do {
            _ = try await URLSession.shared.data(from: URL(string: "https://\(host)/v1/offline")!)
            XCTFail("Expected the request to fail")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .notConnectedToInternet)
        } catch {
            XCTFail("Unexpected error \(error)")
        }
        let call = NetLabEngine.shared.snapshot.calls.first { $0.endpoint == key }
        XCTAssertEqual(call?.errorCode, "notConnectedToInternet")
        XCTAssertEqual(call?.report?.title, "Offline")
    }
}
