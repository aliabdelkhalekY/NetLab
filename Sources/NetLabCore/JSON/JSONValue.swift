import Foundation

public enum JSONKind: String, CaseIterable, Hashable, Identifiable {
    case string = "String"
    case number = "Number"
    case bool = "Bool"
    case null = "Null"
    case object = "Object"
    case array = "Array"

    public var id: String { rawValue }

    public init(_ value: JSONValue) {
        switch value {
        case .string: self = .string
        case .int, .double: self = .number
        case .bool: self = .bool
        case .null: self = .null
        case .object: self = .object
        case .array: self = .array
        }
    }

    public func value(from text: String) -> JSONValue? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch self {
        case .string:
            return .string(text)
        case .number:
            if let value = Int(trimmed) { return .int(value) }
            if let value = Double(trimmed), value.isFinite { return .double(value) }
            return nil
        case .bool:
            if trimmed == "true" { return .bool(true) }
            if trimmed == "false" { return .bool(false) }
            return nil
        case .null:
            return .null
        case .object:
            return .object([:])
        case .array:
            return .array([])
        }
    }
}

public enum JSONValue: Hashable, Codable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(data: Data) throws {
        let any = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        self = JSONValue(any: any)
    }

    public init(any: Any) {
        switch any {
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if CFNumberIsFloatType(number as CFNumber) {
                let value = number.doubleValue
                if value.rounded() == value, abs(value) < 1e15 {
                    self = .int(Int(value))
                } else {
                    self = .double(value)
                }
            } else {
                self = .int(number.intValue)
            }
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            self = .array(array.map(JSONValue.init(any:)))
        case let dictionary as [String: Any]:
            self = .object(dictionary.mapValues(JSONValue.init(any:)))
        default:
            self = .null
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .int(value): try container.encode(value)
        case let .double(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }

    public var anyValue: Any {
        switch self {
        case .null: return NSNull()
        case let .bool(value): return value
        case let .int(value): return value
        case let .double(value): return value
        case let .string(value): return value
        case let .array(value): return value.map(\.anyValue)
        case let .object(value): return value.mapValues(\.anyValue)
        }
    }

    public func data(pretty: Bool = false) -> Data {
        var options: JSONSerialization.WritingOptions = [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]
        if pretty { options.insert(.prettyPrinted) }
        return (try? JSONSerialization.data(withJSONObject: anyValue, options: options)) ?? Data("null".utf8)
    }

    public func text(pretty: Bool = true) -> String {
        String(decoding: data(pretty: pretty), as: UTF8.self)
    }

    public var typeName: String {
        switch self {
        case .null: return "null"
        case .bool: return "bool"
        case .int, .double: return "number"
        case .string: return "string"
        case .array: return "array"
        case .object: return "object"
        }
    }

    public var scalarText: String? {
        switch self {
        case .null: return "null"
        case let .bool(value): return value ? "true" : "false"
        case let .int(value): return String(value)
        case let .double(value): return String(value)
        case let .string(value): return value
        case .array, .object: return nil
        }
    }

    public var isContainer: Bool {
        switch self {
        case .array, .object: return true
        default: return false
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case let .object(object) = self { return object[key] }
        return nil
    }

    public static func parseScalar(_ text: String, like previous: JSONValue) -> JSONValue {
        switch previous {
        case .bool:
            if text == "true" { return .bool(true) }
            if text == "false" { return .bool(false) }
        case .int:
            if let value = Int(text) { return .int(value) }
            if let value = Double(text) { return .double(value) }
        case .double:
            if let value = Double(text) { return .double(value) }
        case .null:
            if text == "null" { return .null }
        default:
            break
        }
        return .string(text)
    }
}
