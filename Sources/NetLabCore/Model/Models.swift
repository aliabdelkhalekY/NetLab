import Foundation

public struct EndpointKey: Hashable, Codable, Identifiable {
    public var host: String
    public var method: String
    public var template: String
    public var discriminator: String?

    public init(host: String, method: String, template: String, discriminator: String? = nil) {
        self.host = host
        self.method = method
        self.template = template
        self.discriminator = discriminator
    }

    public var id: String { "\(method) \(host)\(template)\(discriminator.map { " · \($0)" } ?? "")" }
    public var title: String { "\(method) \(template)\(discriminator.map { " · \($0)" } ?? "")" }
    var baseID: String { "\(method) \(host)\(template)" }
}

public struct RecordedRequest: Hashable, Codable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data?

    public init(method: String, url: URL, headers: [String: String], body: Data?) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

public struct RecordedResponse: Hashable, Codable {
    public var statusCode: Int
    public var headers: [String: String]
    public var body: Data?
    public var bodyTruncated: Bool

    public init(statusCode: Int, headers: [String: String], body: Data?, bodyTruncated: Bool = false) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
        self.bodyTruncated = bodyTruncated
    }
}

public struct OverrideReport: Hashable, Codable {
    public var overrideID: UUID
    public var title: String
    public var applied: [String]
    public var skipped: [String]
    public var notApplied: Bool

    public init(overrideID: UUID, title: String, applied: [String] = [], skipped: [String] = [], notApplied: Bool = false) {
        self.overrideID = overrideID
        self.title = title
        self.applied = applied
        self.skipped = skipped
        self.notApplied = notApplied
    }

    public var summary: String {
        if notApplied { return "Not applied: the real call failed" }
        if !skipped.isEmpty { return "\(applied.count) of \(applied.count + skipped.count) changes applied" }
        return title
    }
}

public struct Call: Identifiable, Hashable, Codable {
    public var id: UUID
    public var startedAt: Date
    public var duration: TimeInterval?
    public var endpoint: EndpointKey
    public var request: RecordedRequest
    public var response: RecordedResponse?
    public var errorCode: String?
    public var report: OverrideReport?

    public init(id: UUID = UUID(), startedAt: Date = Date(), duration: TimeInterval? = nil, endpoint: EndpointKey, request: RecordedRequest, response: RecordedResponse? = nil, errorCode: String? = nil, report: OverrideReport? = nil) {
        self.id = id
        self.startedAt = startedAt
        self.duration = duration
        self.endpoint = endpoint
        self.request = request
        self.response = response
        self.errorCode = errorCode
        self.report = report
    }

    public var isPending: Bool { response == nil && errorCode == nil }
    public var isFailure: Bool { errorCode != nil || (response?.statusCode ?? 0) >= 400 }
    public var isOverridden: Bool { report.map { !$0.notApplied } ?? false }
}

public struct Variant: Identifiable, Hashable, Codable {
    public var statusCode: Int
    public var headers: [String: String]
    public var body: Data?
    public var capturedAt: Date

    public init(statusCode: Int, headers: [String: String], body: Data?, capturedAt: Date = Date()) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
        self.capturedAt = capturedAt
    }

    public var id: String { Variant.slot(for: statusCode) }

    static func slot(for statusCode: Int) -> String {
        switch statusCode {
        case 200..<300: return "2xx"
        case 500...: return "5xx"
        default: return String(statusCode)
        }
    }
}

public struct PathSegment: Hashable, Codable {
    public var value: String
    public var isVariable: Bool

    public init(value: String, isVariable: Bool) {
        self.value = value
        self.isVariable = isVariable
    }
}

public struct EndpointInfo: Identifiable, Hashable, Codable {
    public var key: EndpointKey
    public var callCount: Int
    public var lastStatus: Int?
    public var lastError: String?
    public var lastSeen: Date
    public var variants: [Variant]
    public var idsSeen: [String]
    public var samplePath: String
    public var segments: [PathSegment]

    public init(key: EndpointKey, callCount: Int, lastStatus: Int?, lastError: String?, lastSeen: Date, variants: [Variant], idsSeen: [String], samplePath: String, segments: [PathSegment]) {
        self.key = key
        self.callCount = callCount
        self.lastStatus = lastStatus
        self.lastError = lastError
        self.lastSeen = lastSeen
        self.variants = variants
        self.idsSeen = idsSeen
        self.samplePath = samplePath
        self.segments = segments
    }

    public var id: String { key.id }
}

public enum SplitRule: Hashable, Codable {
    case query(String)
    case bodyField(String)

    public var title: String {
        switch self {
        case let .query(name): return "Query parameter \(name)"
        case let .bodyField(name): return "Body field \(name)"
        }
    }
}

public enum BrokenBody: Hashable, Codable, CaseIterable {
    case invalidJSON
    case truncated
    case emptyBody

    public var title: String {
        switch self {
        case .invalidJSON: return "Invalid JSON"
        case .truncated: return "Truncated body"
        case .emptyBody: return "Empty body"
        }
    }
}

public enum FailureKind: Hashable, Codable {
    case offline
    case timeout
    case slow(seconds: Double)
    case connectionLost
    case brokenBody(BrokenBody)
    case removeField(String)
    case wrongType(String)

    public var title: String {
        switch self {
        case .offline: return "Offline"
        case .timeout: return "Timeout"
        case let .slow(seconds): return "Slow, \(Int(seconds)) s"
        case .connectionLost: return "Connection lost"
        case let .brokenBody(kind): return kind.title
        case let .removeField(pointer): return "Remove \(pointer)"
        case let .wrongType(pointer): return "Wrong type at \(pointer)"
        }
    }
}

public enum StatusBody: String, Hashable, Codable {
    case real
    case empty
}

public enum OverrideAction: Hashable, Codable {
    case changes([PatchOperation], statusCode: Int?)
    case replace(statusCode: Int, headers: [String: String], body: Data?)
    case status(Int, body: StatusBody)
    case failure(FailureKind)

    var needsRealCall: Bool {
        switch self {
        case .changes: return true
        case .replace: return false
        case let .status(_, body): return body == .real
        case let .failure(kind):
            switch kind {
            case .offline, .timeout: return false
            case .slow, .connectionLost, .brokenBody, .removeField, .wrongType: return true
            }
        }
    }
}

public enum OverrideDuration: Hashable, Codable {
    case next(Int)
    case always

    public var title: String {
        switch self {
        case let .next(count): return count == 1 ? "Next call" : "Next \(count) calls"
        case .always: return "Every call"
        }
    }
}

public struct Override: Identifiable, Hashable, Codable {
    public var id: UUID
    public var title: String
    public var action: OverrideAction
    public var duration: OverrideDuration
    public var delay: Double?
    public var condition: String?
    public var isEnabled: Bool
    public var used: Int
    public var appliedCount: Int
    public var isPinned: Bool

    public init(id: UUID = UUID(), title: String, action: OverrideAction, duration: OverrideDuration = .next(1), delay: Double? = nil, condition: String? = nil, isEnabled: Bool = true, isPinned: Bool = false) {
        self.id = id
        self.title = title
        self.action = action
        self.duration = duration
        self.delay = delay
        self.condition = condition
        self.isEnabled = isEnabled
        self.used = 0
        self.appliedCount = 0
        self.isPinned = isPinned
    }

    public var isUsedUp: Bool {
        if case let .next(count) = duration { return used >= count }
        return false
    }

    public var remainingText: String {
        switch duration {
        case let .next(count): return "\(max(count - used, 0)) of \(count) left"
        case .always: return "Every call"
        }
    }
}

public extension Override {
    var changeSummaries: [String] {
        switch action {
        case let .changes(operations, statusCode):
            return (statusCode.map { ["status \($0)"] } ?? []) + operations.map(\.summary)
        case let .replace(statusCode, _, _):
            return ["Replace with \(statusCode)"]
        case let .status(code, _):
            return ["Status \(code)"]
        case let .failure(kind):
            return [kind.title]
        }
    }

    func hasSameContent(as other: Override) -> Bool {
        Self.normalized(action) == Self.normalized(other.action)
    }

    func freshCopy() -> Override {
        var copy = self
        copy.id = UUID()
        copy.used = 0
        copy.appliedCount = 0
        copy.isEnabled = true
        return copy
    }

    private static var sharedOperationID: UUID { UUID(uuidString: "00000000-0000-0000-0000-000000000000")! }

    private static func normalized(_ action: OverrideAction) -> OverrideAction {
        guard case let .changes(operations, statusCode) = action else { return action }
        let stripped = operations.map { operation -> PatchOperation in
            var copy = PatchOperation(kind: operation.kind, path: operation.path, value: operation.value)
            copy.id = Self.sharedOperationID
            return copy
        }
        return .changes(stripped, statusCode: statusCode)
    }
}

public struct SavedOverride: Identifiable, Hashable, Codable {
    public var id: UUID
    public var endpoint: EndpointKey
    public var override: Override
    public var savedAt: Date

    public init(id: UUID = UUID(), endpoint: EndpointKey, override: Override, savedAt: Date = Date()) {
        self.id = id
        self.endpoint = endpoint
        self.override = override
        self.savedAt = savedAt
    }
}

public struct OverrideQueue: Identifiable, Hashable, Codable {
    public var endpoint: EndpointKey
    public var steps: [Override]
    public var repeatLast: Bool

    public init(endpoint: EndpointKey, steps: [Override] = [], repeatLast: Bool = false) {
        self.endpoint = endpoint
        self.steps = steps
        self.repeatLast = repeatLast
    }

    public var id: String { endpoint.id }
    public var isArmed: Bool { steps.contains { $0.isEnabled && !$0.isUsedUp } || (repeatLast && steps.last?.isEnabled == true) }
}

public struct Preset: Identifiable, Hashable, Codable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var queues: [OverrideQueue]

    public init(id: UUID = UUID(), name: String, createdAt: Date = Date(), queues: [OverrideQueue]) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.queues = queues
    }
}

public enum Storage: String, Hashable, Codable {
    case memory
    case device
}

public struct NetLabSwitch: Identifiable, Hashable, Codable {
    public var name: String
    public var options: [String]
    public var value: String

    public init(name: String, options: [String], value: String? = nil) {
        self.name = name
        self.options = options
        self.value = value ?? options.first ?? ""
    }

    public static func choice(_ name: String, _ options: [String]) -> NetLabSwitch {
        NetLabSwitch(name: name, options: options)
    }

    public var id: String { name }
}

public struct NetLabSnapshot {
    public var calls: [Call]
    public var endpoints: [EndpointInfo]
    public var schemas: [String: SchemaNode]
    public var queues: [OverrideQueue]
    public var presets: [Preset]
    public var saved: [SavedOverride]
    public var storage: Storage
    public var redaction: Redaction
    public var switches: [NetLabSwitch]
    public var isIntercepting: Bool

    public init(calls: [Call] = [], endpoints: [EndpointInfo] = [], schemas: [String: SchemaNode] = [:], queues: [OverrideQueue] = [], presets: [Preset] = [], saved: [SavedOverride] = [], storage: Storage = .memory, redaction: Redaction = .default, switches: [NetLabSwitch] = [], isIntercepting: Bool = false) {
        self.calls = calls
        self.endpoints = endpoints
        self.schemas = schemas
        self.queues = queues
        self.presets = presets
        self.saved = saved
        self.storage = storage
        self.redaction = redaction
        self.switches = switches
        self.isIntercepting = isIntercepting
    }

    public var armedCount: Int { queues.filter(\.isArmed).count }

    public func queue(for key: EndpointKey) -> OverrideQueue? { queues.first { $0.endpoint == key } }
    public func endpoint(for key: EndpointKey) -> EndpointInfo? { endpoints.first { $0.key == key } }
    public func saved(for key: EndpointKey) -> [SavedOverride] { saved.filter { $0.endpoint == key } }
    public func schema(for key: EndpointKey, slot: String) -> SchemaNode? { schemas[NetLabSnapshot.schemaID(key, slot)] }

    public static func schemaID(_ key: EndpointKey, _ slot: String) -> String { "\(key.id)#\(slot)" }

    public func errorShapes(near key: EndpointKey) -> [(EndpointKey, Variant)] {
        endpoints
            .filter { $0.key.host == key.host }
            .flatMap { info in info.variants.filter { (400..<600).contains($0.statusCode) && $0.body != nil }.map { (info.key, $0) } }
    }
}

public enum NetLabAction {
    case arm(EndpointKey, Override)
    case saveOverride(EndpointKey, Override)
    case armSaved(UUID)
    case deleteSaved(UUID)
    case updateStep(EndpointKey, Override)
    case removeStep(EndpointKey, UUID)
    case moveSteps(EndpointKey, IndexSet, Int)
    case setRepeatLast(EndpointKey, Bool)
    case clearQueue(EndpointKey)
    case setSegment(EndpointKey, index: Int, variable: Bool)
    case setSplit(EndpointKey, SplitRule?)
    case clearTraffic
    case clearLearned
    case setStorage(Storage)
    case setRedaction(Redaction)
    case savePreset(String)
    case loadPreset(UUID)
    case deletePreset(UUID)
    case setSwitch(String, String)
}
