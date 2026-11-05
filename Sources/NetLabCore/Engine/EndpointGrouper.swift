import Foundation

struct GroupingRules: Codable {
    var forced: [String: Bool] = [:]
    var splits: [String: SplitRule] = [:]
    var variation: [String: [String]] = [:]
}

struct GroupedPath {
    var key: EndpointKey
    var segments: [PathSegment]
    var ids: [String]
}

final class EndpointGrouper {
    static let variationThreshold = 3
    static let variationLimit = 20

    var rules = GroupingRules() {
        didSet { revision += 1 }
    }
    private(set) var revision = 0

    func group(_ request: RecordedRequest) -> GroupedPath {
        let host = request.url.host ?? ""
        let method = request.method
        let values = Self.segments(of: request.url.path)
        let shapeIDs = values.map(Self.looksLikeID)

        var segments: [PathSegment] = []
        for (index, value) in values.enumerated() {
            let positionKey = Self.positionKey(host: host, method: method, values: values, shapeIDs: shapeIDs, index: index)
            if !shapeIDs[index] { recordVariation(value, for: positionKey) }
            let byVariation = !shapeIDs[index] && isVariableByVariation(positionKey)
            let variable = rules.forced[positionKey] ?? (shapeIDs[index] || byVariation)
            segments.append(PathSegment(value: value, isVariable: variable))
        }

        let template = "/" + segments.map { $0.isVariable ? "{id}" : $0.value }.joined(separator: "/")
        var key = EndpointKey(host: host, method: method, template: template)
        key.discriminator = discriminator(for: request, baseID: key.baseID)
        return GroupedPath(key: key, segments: segments, ids: segments.filter(\.isVariable).map(\.value))
    }

    func positionKey(for request: RecordedRequest, index: Int) -> String {
        let values = Self.segments(of: request.url.path)
        return Self.positionKey(host: request.url.host ?? "", method: request.method, values: values, shapeIDs: values.map(Self.looksLikeID), index: index)
    }

    private func recordVariation(_ value: String, for positionKey: String) {
        var seen = rules.variation[positionKey] ?? []
        guard !seen.contains(value), seen.count < Self.variationLimit else { return }
        seen.append(value)
        let crossesThreshold = seen.count == Self.variationThreshold
        let current = revision
        rules.variation[positionKey] = seen
        revision = crossesThreshold ? current + 1 : current
    }

    private func isVariableByVariation(_ positionKey: String) -> Bool {
        guard let seen = rules.variation[positionKey], seen.count >= Self.variationThreshold else { return false }
        return !seen.allSatisfy(Self.looksLikeWord)
    }

    private func discriminator(for request: RecordedRequest, baseID: String) -> String? {
        if let rule = rules.splits[baseID] {
            switch rule {
            case let .query(name):
                return URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value.map { "\(name)=\($0)" }
            case let .bodyField(name):
                guard let body = request.body, let json = try? JSONValue(data: body) else { return nil }
                let path = name.split(separator: ".").map { PointerComponent.key(String($0)) }
                return JSONPatch.value(at: path, in: json)?.scalarText.map { "\(name)=\($0)" }
            }
        }
        if let body = request.body, let json = try? JSONValue(data: body), case let .string(operation)? = json["operationName"], json["query"] != nil {
            return operation
        }
        return nil
    }

    static func segments(of path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    static func positionKey(host: String, method: String, values: [String], shapeIDs: [Bool], index: Int) -> String {
        let pattern = values.enumerated().map { position, value in
            position == index ? "*" : (shapeIDs[position] ? "{id}" : value)
        }.joined(separator: "/")
        return "\(host)|\(method)|\(pattern)"
    }

    static func looksLikeID(_ segment: String) -> Bool {
        if segment.isEmpty { return false }
        if segment.allSatisfy(\.isNumber) { return true }
        if UUID(uuidString: segment) != nil { return true }
        if segment.count >= 16, segment.allSatisfy(\.isHexDigit) { return true }
        let digits = segment.filter(\.isNumber).count
        let letters = segment.filter(\.isLetter).count
        if segment.count >= 5, digits >= 2, letters >= 1 { return true }
        if segment.count >= 24, segment.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) { return true }
        return false
    }

    static func looksLikeWord(_ segment: String) -> Bool {
        segment.allSatisfy { ($0.isLetter && $0.isLowercase) || $0 == "-" || $0 == "_" }
    }
}
