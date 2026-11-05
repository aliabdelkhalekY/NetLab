import Combine
import Foundation
import NetLabCore

public final class MockBackend: NetLabBackend {
    private let subject: CurrentValueSubject<NetLabSnapshot, Never>
    private let eventSubject = PassthroughSubject<NetLabEvent, Never>()

    public init(snapshot: NetLabSnapshot = MockBackend.sample) {
        subject = CurrentValueSubject(snapshot)
    }

    public var snapshot: NetLabSnapshot { subject.value }
    public var updates: AnyPublisher<NetLabSnapshot, Never> { subject.eraseToAnyPublisher() }
    public var events: AnyPublisher<NetLabEvent, Never> { eventSubject.eraseToAnyPublisher() }

    public func perform(_ action: NetLabAction) {
        var snapshot = subject.value
        switch action {
        case let .arm(key, override):
            if let index = snapshot.queues.firstIndex(where: { $0.endpoint == key }) {
                snapshot.queues[index].steps.append(override)
            } else {
                snapshot.queues.append(OverrideQueue(endpoint: key, steps: [override]))
            }
        case let .saveOverride(key, override):
            snapshot.saved.removeAll { $0.endpoint == key && $0.override.hasSameContent(as: override) }
            snapshot.saved.insert(SavedOverride(endpoint: key, override: override.freshCopy()), at: 0)
        case let .armSaved(id):
            if let item = snapshot.saved.first(where: { $0.id == id }) {
                if let index = snapshot.queues.firstIndex(where: { $0.endpoint == item.endpoint }) {
                    snapshot.queues[index].steps.append(item.override.freshCopy())
                } else {
                    snapshot.queues.append(OverrideQueue(endpoint: item.endpoint, steps: [item.override.freshCopy()]))
                }
            }
        case let .deleteSaved(id):
            snapshot.saved.removeAll { $0.id == id }
        case let .updateStep(key, override):
            if let queue = snapshot.queues.firstIndex(where: { $0.endpoint == key }), let step = snapshot.queues[queue].steps.firstIndex(where: { $0.id == override.id }) {
                snapshot.queues[queue].steps[step] = override
            }
        case let .removeStep(key, id):
            if let queue = snapshot.queues.firstIndex(where: { $0.endpoint == key }) {
                snapshot.queues[queue].steps.removeAll { $0.id == id }
            }
            snapshot.queues.removeAll { $0.steps.isEmpty }
        case let .setRepeatLast(key, value):
            if let queue = snapshot.queues.firstIndex(where: { $0.endpoint == key }) { snapshot.queues[queue].repeatLast = value }
        case let .clearQueue(key):
            snapshot.queues.removeAll { $0.endpoint == key }
        case .clearTraffic:
            snapshot.calls = []
        case .clearLearned:
            snapshot.endpoints = []
        case let .setStorage(value):
            snapshot.storage = value
        case let .setRedaction(value):
            snapshot.redaction = value
        case let .savePreset(name):
            snapshot.presets.insert(Preset(name: name, queues: snapshot.queues), at: 0)
        case let .deletePreset(id):
            snapshot.presets.removeAll { $0.id == id }
        case let .setSwitch(name, value):
            if let index = snapshot.switches.firstIndex(where: { $0.name == name }) { snapshot.switches[index].value = value }
        case .moveSteps, .setSegment, .setSplit, .loadPreset:
            break
        }
        subject.send(snapshot)
    }

    public func curl(for call: Call, raw: Bool) -> String { "curl -X \(call.request.method) '\(call.request.url.absoluteString)'" }
    public func exportHAR(_ calls: [Call]) throws -> URL { throw CocoaError(.featureUnsupported) }
    public func exportLearnedAPI() throws -> URL { throw CocoaError(.featureUnsupported) }
    public func importLearnedAPI(from url: URL) throws {}
    public func exportPreset(_ id: UUID) throws -> URL { throw CocoaError(.featureUnsupported) }
    public func importPreset(from url: URL) throws {}
}

extension MockBackend {
    public static var sample: NetLabSnapshot {
        let host = "api.example.com"
        let methods = EndpointKey(host: host, method: "GET", template: "/v1/payment-methods")
        let pay = EndpointKey(host: host, method: "POST", template: "/v1/payments")
        let status = EndpointKey(host: host, method: "GET", template: "/v1/payments/{id}/status")

        let methodsBody = json(["methods": [["id": "card", "name": "Card"], ["id": "wallet", "name": "Wallet"], ["id": "cash", "name": "Cash"]]])
        let payBody = json(["transactionId": "tx_8F21", "status": "PROCESSING", "amount": 1250, "currency": "USD"])
        let paidBody = json(["transactionId": "tx_8F21", "status": "PAID", "amount": 1250, "currency": "USD", "receipt": ["number": "R-1042"]])
        let declineBody = json(["error": ["code": "card_declined", "message": "Your card was declined."]])
        let jsonHeaders = ["Content-Type": "application/json"]

        func request(_ method: String, _ path: String, body: Data? = nil) -> RecordedRequest {
            RecordedRequest(method: method, url: URL(string: "https://\(host)\(path)")!, headers: ["Authorization": "Bearer eyJhbGciOi", "Accept": "application/json"], body: body)
        }

        let now = Date()
        let calls = [
            Call(startedAt: now.addingTimeInterval(-4), duration: 0.176, endpoint: status, request: request("GET", "/v1/payments/tx_8F21/status"),
                 response: RecordedResponse(statusCode: 200, headers: jsonHeaders, body: json(["transactionId": "tx_8F21", "status": "DECLINED", "amount": 1250, "currency": "USD"])),
                 report: OverrideReport(overrideID: UUID(), title: "/status: \"PAID\" → \"DECLINED\"", applied: ["/status: \"PAID\" → \"DECLINED\""], skipped: ["remove /receipt"])),
            Call(startedAt: now.addingTimeInterval(-6), duration: 0.388, endpoint: pay, request: request("POST", "/v1/payments", body: json(["amount": 1250, "method": "card"])),
                 response: RecordedResponse(statusCode: 200, headers: jsonHeaders, body: payBody)),
            Call(startedAt: now.addingTimeInterval(-9), duration: 0.003, endpoint: pay, request: request("POST", "/v1/payments", body: json(["amount": 1250, "method": "card"])),
                 errorCode: "notConnectedToInternet", report: OverrideReport(overrideID: UUID(), title: "Offline", applied: ["Offline"])),
            Call(startedAt: now.addingTimeInterval(-12), duration: 0.214, endpoint: methods, request: request("GET", "/v1/payment-methods"),
                 response: RecordedResponse(statusCode: 200, headers: jsonHeaders, body: methodsBody))
        ]

        var statusSchema = SchemaNode()
        for value in ["PAID", "PENDING", "PROCESSING"] {
            if let parsed = try? JSONValue(data: json(["transactionId": "tx_8F21", "status": value, "amount": 1250, "currency": "USD"])) { statusSchema.merge(parsed) }
        }

        let endpoints = [
            EndpointInfo(key: methods, callCount: 3, lastStatus: 200, lastError: nil, lastSeen: now, variants: [Variant(statusCode: 200, headers: jsonHeaders, body: methodsBody)], idsSeen: [], samplePath: "/v1/payment-methods",
                         segments: [PathSegment(value: "v1", isVariable: false), PathSegment(value: "payment-methods", isVariable: false)]),
            EndpointInfo(key: pay, callCount: 4, lastStatus: 200, lastError: nil, lastSeen: now, variants: [Variant(statusCode: 200, headers: jsonHeaders, body: payBody), Variant(statusCode: 402, headers: jsonHeaders, body: declineBody)], idsSeen: [], samplePath: "/v1/payments",
                         segments: [PathSegment(value: "v1", isVariable: false), PathSegment(value: "payments", isVariable: false)]),
            EndpointInfo(key: status, callCount: 7, lastStatus: 200, lastError: nil, lastSeen: now, variants: [Variant(statusCode: 200, headers: jsonHeaders, body: paidBody)], idsSeen: ["tx_8F21", "tx_9A02", "tx_77B3"], samplePath: "/v1/payments/tx_8F21/status",
                         segments: [PathSegment(value: "v1", isVariable: false), PathSegment(value: "payments", isVariable: false), PathSegment(value: "tx_8F21", isVariable: true), PathSegment(value: "status", isVariable: false)])
        ]

        let queues = [
            OverrideQueue(endpoint: status, steps: [
                Override(title: "/status → \"PENDING\"", action: .changes([PatchOperation(kind: .replace, path: [.key("status")], value: .string("PENDING"), oldValue: .string("PAID"))], statusCode: nil), duration: .next(2)),
                Override(title: "/status → \"PAID\"", action: .changes([], statusCode: nil))
            ])
        ]

        return NetLabSnapshot(
            calls: calls,
            endpoints: endpoints,
            schemas: [NetLabSnapshot.schemaID(status, "2xx"): statusSchema],
            queues: queues,
            presets: [Preset(name: "Pending then paid", queues: queues)],
            storage: .memory,
            redaction: .default,
            switches: [.choice("Token refresh", ["Succeed", "Fail", "Hang"])],
            isIntercepting: true
        )
    }

    private static func json(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }
}
