import Combine
import Foundation

public final class NetLabEngine: NetLabBackend {
    public static let shared = NetLabEngine()

    struct Plan {
        var callID: UUID
        var key: EndpointKey
        var override: Override?
        var startedAt: Date
    }

    struct EndpointState {
        var info: EndpointInfo
        var sample: RecordedRequest
        var schemas: [String: SchemaNode]
    }

    public var maxCalls = 500
    public var maxRecordedBody = 1_000_000

    private let queue = DispatchQueue(label: "NetLab.engine")
    private let grouper = EndpointGrouper()
    private var groupedRevision = 0
    private var calls: [Call] = []
    private var endpoints: [String: EndpointState] = [:]
    private var aliases: [String: EndpointKey] = [:]
    private var queues: [String: OverrideQueue] = [:]
    private var presets: [Preset] = []
    private var saved: [SavedOverride] = []
    private var storage: Storage = .memory
    private var redaction: Redaction = .default
    private var switches: [NetLabSwitch] = []
    private var intercepting = false
    private var publishScheduled = false

    private let snapshotSubject = CurrentValueSubject<NetLabSnapshot, Never>(NetLabSnapshot())
    private let eventSubject = PassthroughSubject<NetLabEvent, Never>()

    init() {}

    public var snapshot: NetLabSnapshot { queue.sync { makeSnapshot() } }
    public var updates: AnyPublisher<NetLabSnapshot, Never> { snapshotSubject.eraseToAnyPublisher() }
    public var events: AnyPublisher<NetLabEvent, Never> { eventSubject.eraseToAnyPublisher() }

    public var isIntercepting: Bool {
        get { queue.sync { intercepting } }
        set { queue.sync { intercepting = newValue; schedulePublish() } }
    }

    public func configure(storage: Storage, redaction: Redaction) {
        queue.sync {
            self.storage = storage
            self.redaction = redaction
            presets = Persistence.read([Preset].self, from: Persistence.presetsFile) ?? []
            saved = Persistence.read([SavedOverride].self, from: Persistence.savedFile) ?? []
            if let pinned = Persistence.read(PinnedQueues.self, from: Persistence.pinnedFile) {
                for queue in pinned.queues { queues[queue.endpoint.id] = queue }
            }
            if storage == .device, let learned = Persistence.read(LearnedAPI.self, from: Persistence.learnedFile) {
                merge(learned)
            }
            schedulePublish()
        }
    }

    public func register(_ item: NetLabSwitch) {
        queue.sync {
            if let index = switches.firstIndex(where: { $0.name == item.name }) {
                switches[index].options = item.options
            } else {
                switches.append(item)
            }
            schedulePublish()
        }
    }

    public func value(of switchName: String) -> String? {
        queue.sync { switches.first { $0.name == switchName }?.value }
    }

    // MARK: Interception

    func begin(_ request: RecordedRequest) -> Plan {
        queue.sync {
            var grouped = grouper.group(request)
            if grouper.revision != groupedRevision {
                regroup()
                grouped = grouper.group(request)
            }
            let key = grouped.key
            var state = endpoints[key.id] ?? EndpointState(
                info: EndpointInfo(key: key, callCount: 0, lastStatus: nil, lastError: nil, lastSeen: Date(), variants: [], idsSeen: [], samplePath: request.url.path, segments: grouped.segments),
                sample: request,
                schemas: [:]
            )
            state.info.callCount += 1
            state.info.lastSeen = Date()
            state.info.samplePath = request.url.path
            state.info.segments = grouped.segments
            state.sample = request
            for id in grouped.ids where !state.info.idsSeen.contains(id) && state.info.idsSeen.count < 50 {
                state.info.idsSeen.append(id)
            }
            endpoints[key.id] = state

            let override = reserveOverride(for: key, request: request)
            let call = Call(endpoint: key, request: truncated(request))
            calls.append(call)
            if calls.count > maxCalls { calls.removeFirst(calls.count - maxCalls) }
            schedulePublish()
            return Plan(callID: call.id, key: key, override: override, startedAt: call.startedAt)
        }
    }

    func learn(_ plan: Plan, response: RecordedResponse) {
        queue.sync {
            guard var state = endpoints[plan.key.id] else { return }
            let variant = Variant(statusCode: response.statusCode, headers: response.headers, body: response.body)
            if let index = state.info.variants.firstIndex(where: { $0.id == variant.id }) {
                state.info.variants[index] = variant
            } else {
                state.info.variants.append(variant)
                state.info.variants.sort { $0.statusCode < $1.statusCode }
            }
            if let body = response.body, let json = try? JSONValue(data: body) {
                let id = NetLabSnapshot.schemaID(plan.key, variant.id)
                var schema = state.schemas[id] ?? SchemaNode()
                schema.merge(json)
                state.schemas[id] = schema
            }
            endpoints[plan.key.id] = state
            persistLearned()
        }
    }

    func release(_ plan: Plan) {
        queue.sync {
            guard let override = plan.override, var queue = queues[plan.key.id], let index = queue.steps.firstIndex(where: { $0.id == override.id }) else { return }
            queue.steps[index].used = max(queue.steps[index].used - 1, 0)
            queues[plan.key.id] = queue
            schedulePublish()
        }
    }

    func finish(_ plan: Plan, response: RecordedResponse?, errorCode: String?, report: OverrideReport?) {
        var appliedTitle: String?
        queue.sync {
            if let index = calls.firstIndex(where: { $0.id == plan.callID }) {
                calls[index].duration = Date().timeIntervalSince(plan.startedAt)
                calls[index].response = response.map(truncated)
                calls[index].errorCode = errorCode
                calls[index].report = report
            }
            if var state = endpoints[plan.key.id] {
                state.info.lastStatus = response?.statusCode
                state.info.lastError = errorCode
                endpoints[plan.key.id] = state
            }
            if let report, !report.notApplied, var queue = queues[plan.key.id], let index = queue.steps.firstIndex(where: { $0.id == report.overrideID }) {
                queue.steps[index].appliedCount += 1
                queues[plan.key.id] = queue
                appliedTitle = "\(plan.key.title) · \(report.title)"
            }
            pruneUsedSteps(plan.key)
            schedulePublish()
        }
        if let appliedTitle {
            DispatchQueue.main.async { self.eventSubject.send(.overrideApplied(appliedTitle)) }
        }
    }

    private func reserveOverride(for key: EndpointKey, request: RecordedRequest) -> Override? {
        guard var queue = queues[key.id] else { return nil }
        let searchable = request.url.absoluteString + (request.body.map { String(decoding: $0, as: UTF8.self) } ?? "")
        func matches(_ step: Override) -> Bool {
            guard let condition = step.condition, !condition.isEmpty else { return true }
            return searchable.localizedCaseInsensitiveContains(condition)
        }
        if let index = queue.steps.firstIndex(where: { $0.isEnabled && !$0.isUsedUp && matches($0) }) {
            queue.steps[index].used += 1
            queues[key.id] = queue
            return queue.steps[index]
        }
        if queue.repeatLast, let last = queue.steps.last, last.isEnabled, matches(last) {
            return last
        }
        return nil
    }

    private func pruneUsedSteps(_ key: EndpointKey) {
        guard var queue = queues[key.id] else { return }
        let lastID = queue.steps.last?.id
        queue.steps.removeAll { $0.isUsedUp && !(queue.repeatLast && $0.id == lastID) }
        queues[key.id] = queue.steps.isEmpty ? nil : queue
        persistPinned()
    }

    private func truncated(_ request: RecordedRequest) -> RecordedRequest {
        var copy = request
        if let body = request.body, body.count > maxRecordedBody { copy.body = body.prefix(maxRecordedBody) }
        return copy
    }

    private func truncated(_ response: RecordedResponse) -> RecordedResponse {
        var copy = response
        if let body = response.body, body.count > maxRecordedBody {
            copy.body = body.prefix(maxRecordedBody)
            copy.bodyTruncated = true
        }
        return copy
    }

    // MARK: Grouping

    private func resolve(_ key: EndpointKey) -> EndpointKey {
        if endpoints[key.id] != nil { return key }
        return aliases[key.id] ?? key
    }

    private func regroup() {
        groupedRevision = grouper.revision
        var regrouped: [String: EndpointState] = [:]
        for (oldID, state) in endpoints {
            let grouped = grouper.group(state.sample)
            let newKey = grouped.key
            if oldID != newKey.id { aliases[oldID] = newKey }
            var moved = state
            moved.info.key = newKey
            moved.info.segments = grouped.segments
            moved.schemas = Dictionary(uniqueKeysWithValues: state.schemas.map { id, node in
                (NetLabSnapshot.schemaID(newKey, String(id.split(separator: "#").last ?? "")), node)
            })
            if var existing = regrouped[newKey.id] {
                existing.info.callCount += moved.info.callCount
                if moved.info.lastSeen > existing.info.lastSeen {
                    existing.info.lastSeen = moved.info.lastSeen
                    existing.info.lastStatus = moved.info.lastStatus
                    existing.info.lastError = moved.info.lastError
                    existing.sample = moved.sample
                    existing.info.samplePath = moved.info.samplePath
                }
                for variant in moved.info.variants {
                    if let index = existing.info.variants.firstIndex(where: { $0.id == variant.id }) {
                        if variant.capturedAt > existing.info.variants[index].capturedAt { existing.info.variants[index] = variant }
                    } else {
                        existing.info.variants.append(variant)
                    }
                }
                existing.info.variants.sort { $0.statusCode < $1.statusCode }
                for id in moved.info.idsSeen where !existing.info.idsSeen.contains(id) && existing.info.idsSeen.count < 50 {
                    existing.info.idsSeen.append(id)
                }
                for (id, node) in moved.schemas {
                    var merged = existing.schemas[id] ?? SchemaNode()
                    merged.merge(node)
                    existing.schemas[id] = merged
                }
                regrouped[newKey.id] = existing
            } else {
                regrouped[newKey.id] = moved
            }
        }
        endpoints = regrouped
        var movedQueues: [String: OverrideQueue] = [:]
        for (id, queue) in queues {
            var queue = queue
            let target = aliases[id] ?? queue.endpoint
            queue.endpoint = target
            if var existing = movedQueues[target.id] {
                existing.steps += queue.steps
                movedQueues[target.id] = existing
            } else {
                movedQueues[target.id] = queue
            }
        }
        queues = movedQueues
        for index in saved.indices {
            saved[index].endpoint = aliases[saved[index].endpoint.id] ?? saved[index].endpoint
        }
        Persistence.write(saved, to: Persistence.savedFile)
        persistLearned()
    }

    // MARK: Actions

    public func perform(_ action: NetLabAction) {
        queue.sync {
            switch action {
            case let .arm(rawKey, override):
                let key = resolve(rawKey)
                var queue = queues[key.id] ?? OverrideQueue(endpoint: key)
                queue.steps.append(override)
                queues[key.id] = queue
                persistPinned()
            case let .saveOverride(rawKey, override):
                let key = resolve(rawKey)
                saved.removeAll { $0.endpoint == key && $0.override.hasSameContent(as: override) }
                saved.insert(SavedOverride(endpoint: key, override: override.freshCopy()), at: 0)
                Persistence.write(saved, to: Persistence.savedFile)
            case let .armSaved(id):
                if let item = saved.first(where: { $0.id == id }) {
                    let key = resolve(item.endpoint)
                    var queue = queues[key.id] ?? OverrideQueue(endpoint: key)
                    queue.steps.append(item.override.freshCopy())
                    queues[key.id] = queue
                    persistPinned()
                }
            case let .deleteSaved(id):
                saved.removeAll { $0.id == id }
                Persistence.write(saved, to: Persistence.savedFile)
            case let .updateStep(rawKey, override):
                let key = resolve(rawKey)
                if var queue = queues[key.id], let index = queue.steps.firstIndex(where: { $0.id == override.id }) {
                    queue.steps[index] = override
                    queues[key.id] = queue
                    persistPinned()
                }
            case let .removeStep(rawKey, id):
                let key = resolve(rawKey)
                if var queue = queues[key.id] {
                    queue.steps.removeAll { $0.id == id }
                    queues[key.id] = queue.steps.isEmpty ? nil : queue
                    persistPinned()
                }
            case let .moveSteps(rawKey, source, destination):
                let key = resolve(rawKey)
                if var queue = queues[key.id] {
                    queue.steps = Self.move(queue.steps, from: source, to: destination)
                    queues[key.id] = queue
                    persistPinned()
                }
            case let .setRepeatLast(rawKey, value):
                let key = resolve(rawKey)
                if var queue = queues[key.id] {
                    queue.repeatLast = value
                    queues[key.id] = queue
                }
            case let .clearQueue(key):
                queues[resolve(key).id] = nil
                persistPinned()
            case let .setSegment(key, index, variable):
                if let state = endpoints[resolve(key).id] {
                    let positionKey = grouper.positionKey(for: state.sample, index: index)
                    grouper.rules.forced[positionKey] = variable
                    regroup()
                }
            case let .setSplit(rawKey, rule):
                let key = resolve(rawKey)
                grouper.rules.splits[key.baseID] = rule
                regroup()
            case .clearTraffic:
                calls.removeAll()
            case .clearLearned:
                endpoints.removeAll()
                aliases.removeAll()
                grouper.rules = GroupingRules()
                groupedRevision = grouper.revision
                Persistence.remove(Persistence.learnedFile)
            case let .setStorage(value):
                storage = value
                if value == .device { persistLearned() } else { Persistence.remove(Persistence.learnedFile) }
            case let .setRedaction(value):
                redaction = value
                persistLearned()
            case let .savePreset(name):
                let saved = queues.values.map { queue -> OverrideQueue in
                    var copy = queue
                    copy.steps = queue.steps.map { step in
                        var fresh = step
                        fresh.used = 0
                        fresh.appliedCount = 0
                        return fresh
                    }
                    return copy
                }
                presets.insert(Preset(name: name, queues: saved.sorted { $0.endpoint.id < $1.endpoint.id }), at: 0)
                Persistence.write(presets, to: Persistence.presetsFile)
            case let .loadPreset(id):
                if let preset = presets.first(where: { $0.id == id }) { load(preset) }
            case let .deletePreset(id):
                presets.removeAll { $0.id == id }
                Persistence.write(presets, to: Persistence.presetsFile)
            case let .setSwitch(name, value):
                if let index = switches.firstIndex(where: { $0.name == name }) { switches[index].value = value }
            }
            schedulePublish()
        }
    }

    private func load(_ preset: Preset) {
        for queue in preset.queues {
            var copy = queue
            copy.endpoint = resolve(queue.endpoint)
            copy.steps = queue.steps.map { step in
                var fresh = step
                fresh.id = UUID()
                fresh.used = 0
                fresh.appliedCount = 0
                return fresh
            }
            queues[copy.endpoint.id] = copy
        }
        persistPinned()
    }

    static func move<T>(_ items: [T], from source: IndexSet, to destination: Int) -> [T] {
        let moving = source.sorted().map { items[$0] }
        var remaining = items.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        let insertAt = destination - source.filter { $0 < destination }.count
        remaining.insert(contentsOf: moving, at: min(max(insertAt, 0), remaining.count))
        return remaining
    }

    // MARK: Export and import

    public func curl(for call: Call, raw: Bool) -> String {
        let redaction = queue.sync { self.redaction }
        return Export.curl(raw ? call : redaction.redact(call))
    }

    public func exportHAR(_ calls: [Call]) throws -> URL {
        let redaction = queue.sync { self.redaction }
        let url = Persistence.exportDirectory.appendingPathComponent("NetLab-\(Self.stamp()).har")
        try Export.har(calls.map { redaction.redact($0) }).write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    public func exportLearnedAPI() throws -> URL {
        let learned = queue.sync { learnedAPI(redacted: true) }
        return try Persistence.export(learned, named: "NetLab-learned-\(Self.stamp()).json")
    }

    public func importLearnedAPI(from url: URL) throws {
        let data = try Self.readSecurityScoped(url)
        let learned = try Persistence.decoder.decode(LearnedAPI.self, from: data)
        queue.sync {
            merge(learned)
            persistLearned()
            schedulePublish()
        }
    }

    public func exportPreset(_ id: UUID) throws -> URL {
        guard let preset = queue.sync(execute: { presets.first { $0.id == id } }) else { throw CocoaError(.fileNoSuchFile) }
        let safeName = preset.name.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: "-")
        return try Persistence.export(preset, named: "NetLab-preset-\(safeName.isEmpty ? "untitled" : safeName).json")
    }

    public func importPreset(from url: URL) throws {
        let data = try Self.readSecurityScoped(url)
        var preset = try Persistence.decoder.decode(Preset.self, from: data)
        preset.id = UUID()
        queue.sync {
            presets.insert(preset, at: 0)
            Persistence.write(presets, to: Persistence.presetsFile)
            schedulePublish()
        }
    }

    static func readSecurityScoped(_ url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try Data(contentsOf: url)
    }

    static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    // MARK: Persistence

    private func learnedAPI(redacted: Bool) -> LearnedAPI {
        LearnedAPI(endpoints: endpoints.values.map { state in
            guard redacted else { return StoredEndpoint(info: state.info, sample: state.sample, schemas: state.schemas) }
            var info = state.info
            info.variants = info.variants.map { variant in
                var copy = variant
                copy.headers = redaction.redact(headers: variant.headers)
                copy.body = redaction.redact(body: variant.body)
                return copy
            }
            return StoredEndpoint(info: info, sample: redaction.redact(state.sample), schemas: state.schemas)
        }, rules: grouper.rules)
    }

    private func merge(_ learned: LearnedAPI) {
        var rules = grouper.rules
        rules.forced.merge(learned.rules.forced) { current, _ in current }
        rules.splits.merge(learned.rules.splits) { current, _ in current }
        for (key, values) in learned.rules.variation {
            var merged = rules.variation[key] ?? []
            for value in values where !merged.contains(value) && merged.count < EndpointGrouper.variationLimit { merged.append(value) }
            rules.variation[key] = merged
        }
        grouper.rules = rules
        for stored in learned.endpoints where endpoints[stored.info.key.id] == nil {
            endpoints[stored.info.key.id] = EndpointState(info: stored.info, sample: stored.sample, schemas: stored.schemas)
        }
        regroup()
    }

    private func persistLearned() {
        guard storage == .device else { return }
        Persistence.write(learnedAPI(redacted: true), to: Persistence.learnedFile)
    }

    private func persistPinned() {
        let pinned = queues.values.compactMap { queue -> OverrideQueue? in
            var copy = queue
            copy.steps = queue.steps.filter(\.isPinned)
            return copy.steps.isEmpty ? nil : copy
        }
        if pinned.isEmpty {
            Persistence.remove(Persistence.pinnedFile)
        } else {
            Persistence.write(PinnedQueues(queues: pinned), to: Persistence.pinnedFile)
        }
    }

    // MARK: Snapshot

    private func makeSnapshot() -> NetLabSnapshot {
        var schemas: [String: SchemaNode] = [:]
        for state in endpoints.values { schemas.merge(state.schemas) { current, _ in current } }
        return NetLabSnapshot(
            calls: calls.reversed(),
            endpoints: endpoints.values.map(\.info).sorted { ($0.key.host, $0.key.template, $0.key.method) < ($1.key.host, $1.key.template, $1.key.method) },
            schemas: schemas,
            queues: queues.values.sorted { $0.endpoint.id < $1.endpoint.id },
            presets: presets,
            saved: saved,
            storage: storage,
            redaction: redaction,
            switches: switches,
            isIntercepting: intercepting
        )
    }

    private func schedulePublish() {
        guard !publishScheduled else { return }
        publishScheduled = true
        queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            self.publishScheduled = false
            let snapshot = self.makeSnapshot()
            DispatchQueue.main.async { self.snapshotSubject.send(snapshot) }
        }
    }
}
