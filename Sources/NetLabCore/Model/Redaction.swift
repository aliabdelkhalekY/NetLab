import Foundation

public struct Redaction: Hashable, Codable {
    public static let mask = "••••••"

    public static let `default` = Redaction(
        headers: ["Authorization", "Proxy-Authorization", "Cookie", "Set-Cookie", "X-Api-Key", "Api-Key"],
        jsonKeys: ["token", "password", "secret", "cardNumber", "pan", "cvv", "cvc", "iban"]
    )

    public var headers: [String]
    public var jsonKeys: [String]

    public init(headers: [String], jsonKeys: [String]) {
        self.headers = headers
        self.jsonKeys = jsonKeys
    }

    public func adding(headers: [String] = [], jsonKeys: [String] = []) -> Redaction {
        Redaction(headers: self.headers + headers, jsonKeys: self.jsonKeys + jsonKeys)
    }

    public func isSensitiveHeader(_ name: String) -> Bool {
        headers.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    public func isSensitiveKey(_ key: String) -> Bool {
        let normalized = Self.normalize(key)
        return jsonKeys.contains { normalized.contains(Self.normalize($0)) }
    }

    public func redact(headers: [String: String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: headers.map { ($0.key, isSensitiveHeader($0.key) ? Self.mask : $0.value) })
    }

    public func redact(json: JSONValue) -> JSONValue {
        switch json {
        case let .object(object):
            return .object(Dictionary(uniqueKeysWithValues: object.map { key, value in
                (key, isSensitiveKey(key) && !value.isContainer ? .string(Self.mask) : redact(json: value))
            }))
        case let .array(array):
            return .array(array.map { redact(json: $0) })
        default:
            return json
        }
    }

    public func redact(body: Data?) -> Data? {
        guard let body, let json = try? JSONValue(data: body) else { return body }
        return redact(json: json).data()
    }

    public func redact(_ request: RecordedRequest) -> RecordedRequest {
        var copy = request
        copy.headers = redact(headers: request.headers)
        copy.body = redact(body: request.body)
        return copy
    }

    public func redact(_ response: RecordedResponse) -> RecordedResponse {
        var copy = response
        copy.headers = redact(headers: response.headers)
        copy.body = redact(body: response.body)
        return copy
    }

    public func redact(_ call: Call) -> Call {
        var copy = call
        copy.request = redact(call.request)
        copy.response = call.response.map(redact)
        return copy
    }

    static func normalize(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
