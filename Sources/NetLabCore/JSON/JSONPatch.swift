import Foundation

public enum PointerComponent: Hashable, Codable {
    case key(String)
    case index(Int)
    case match(key: String, value: String)
    case append

    var text: String {
        switch self {
        case let .key(key): return "/" + key
        case let .index(index): return "/\(index)"
        case let .match(key, value): return "[\(key)=\(value)]"
        case .append: return "/-"
        }
    }
}

public struct PatchOperation: Hashable, Codable, Identifiable {
    public enum Kind: String, Hashable, Codable {
        case add
        case remove
        case replace
    }

    public var id = UUID()
    public var kind: Kind
    public var path: [PointerComponent]
    public var value: JSONValue?
    public var oldValue: JSONValue?

    public init(kind: Kind, path: [PointerComponent], value: JSONValue? = nil, oldValue: JSONValue? = nil) {
        self.kind = kind
        self.path = path
        self.value = value
        self.oldValue = oldValue
    }

    public var pathText: String {
        path.isEmpty ? "/" : path.map(\.text).joined()
    }

    public var summary: String {
        switch kind {
        case .add: return "add \(pathText) = \(Self.short(value))"
        case .remove: return "remove \(pathText)"
        case .replace: return "\(pathText): \(Self.short(oldValue)) → \(Self.short(value))"
        }
    }

    static func short(_ value: JSONValue?) -> String {
        guard let value else { return "—" }
        if let scalar = value.scalarText {
            if case .string = value { return "\"\(scalar)\"" }
            return scalar
        }
        if case let .array(items) = value { return "[\(items.count) items]" }
        return "{…}"
    }
}

public enum JSONPatch {
    static let idKeys = ["id", "uuid", "_id", "key"]

    public static func diff(from original: JSONValue, to edited: JSONValue) -> [PatchOperation] {
        var operations: [PatchOperation] = []
        diff(original, edited, at: [], into: &operations)
        return operations
    }

    public struct Result {
        public var value: JSONValue
        public var applied: [PatchOperation]
        public var skipped: [PatchOperation]
    }

    public static func apply(_ operations: [PatchOperation], to value: JSONValue) -> Result {
        var result = value
        var applied: [PatchOperation] = []
        var skipped: [PatchOperation] = []
        for operation in operations {
            if apply(operation, to: &result) {
                applied.append(operation)
            } else {
                skipped.append(operation)
            }
        }
        return Result(value: result, applied: applied, skipped: skipped)
    }

    private static func diff(_ a: JSONValue, _ b: JSONValue, at path: [PointerComponent], into operations: inout [PatchOperation]) {
        if a == b { return }
        switch (a, b) {
        case let (.object(x), .object(y)):
            for key in y.keys.sorted() {
                if let old = x[key], let new = y[key] {
                    diff(old, new, at: path + [.key(key)], into: &operations)
                } else {
                    operations.append(PatchOperation(kind: .add, path: path + [.key(key)], value: y[key]))
                }
            }
            for key in x.keys.sorted() where y[key] == nil {
                operations.append(PatchOperation(kind: .remove, path: path + [.key(key)], oldValue: x[key]))
            }
        case let (.array(x), .array(y)):
            if let idKey = commonIDKey(x, y) {
                diffByID(x, y, idKey: idKey, at: path, into: &operations)
            } else {
                diffByPosition(x, y, at: path, into: &operations)
            }
        default:
            operations.append(PatchOperation(kind: .replace, path: path, value: b, oldValue: a))
        }
    }

    private static func diffByID(_ x: [JSONValue], _ y: [JSONValue], idKey: String, at path: [PointerComponent], into operations: inout [PatchOperation]) {
        let oldByID = Dictionary(x.compactMap { item in item[idKey]?.scalarText.map { ($0, item) } }, uniquingKeysWith: { first, _ in first })
        let newIDs = Set(y.compactMap { $0[idKey]?.scalarText })
        for item in y {
            guard let id = item[idKey]?.scalarText else { continue }
            if let old = oldByID[id] {
                diff(old, item, at: path + [.match(key: idKey, value: id)], into: &operations)
            } else {
                operations.append(PatchOperation(kind: .add, path: path + [.append], value: item))
            }
        }
        for item in x {
            guard let id = item[idKey]?.scalarText, !newIDs.contains(id) else { continue }
            operations.append(PatchOperation(kind: .remove, path: path + [.match(key: idKey, value: id)], oldValue: item))
        }
    }

    private static func diffByPosition(_ x: [JSONValue], _ y: [JSONValue], at path: [PointerComponent], into operations: inout [PatchOperation]) {
        let shared = min(x.count, y.count)
        for index in 0..<shared {
            diff(x[index], y[index], at: path + [.index(index)], into: &operations)
        }
        if y.count > x.count {
            for index in shared..<y.count {
                operations.append(PatchOperation(kind: .add, path: path + [.index(index)], value: y[index]))
            }
        } else if x.count > y.count {
            for index in (shared..<x.count).reversed() {
                operations.append(PatchOperation(kind: .remove, path: path + [.index(index)], oldValue: x[index]))
            }
        }
    }

    private static func commonIDKey(_ x: [JSONValue], _ y: [JSONValue]) -> String? {
        guard !x.isEmpty, !y.isEmpty else { return nil }
        return idKeys.first { key in
            uniqueIDs(x, key) && uniqueIDs(y, key)
        }
    }

    private static func uniqueIDs(_ items: [JSONValue], _ key: String) -> Bool {
        var seen = Set<String>()
        for item in items {
            guard let value = item[key], !value.isContainer, let text = value.scalarText, seen.insert(text).inserted else { return false }
        }
        return true
    }

    private static func apply(_ operation: PatchOperation, to root: inout JSONValue) -> Bool {
        guard let last = operation.path.last else {
            guard operation.kind == .replace, let value = operation.value else { return false }
            root = value
            return true
        }
        return modify(&root, path: operation.path.dropLast()) { parent in
            switch parent {
            case var .object(object):
                guard case let .key(key) = last else { return false }
                switch operation.kind {
                case .add:
                    guard let value = operation.value else { return false }
                    object[key] = value
                case .replace:
                    guard object[key] != nil, let value = operation.value else { return false }
                    object[key] = value
                case .remove:
                    guard object.removeValue(forKey: key) != nil else { return false }
                }
                parent = .object(object)
                return true
            case var .array(array):
                switch (operation.kind, last) {
                case (.add, .append):
                    guard let value = operation.value else { return false }
                    array.append(value)
                case let (.add, .index(index)):
                    guard let value = operation.value, index >= 0 else { return false }
                    array.insert(value, at: min(index, array.count))
                case let (.replace, .index(index)):
                    guard array.indices.contains(index), let value = operation.value else { return false }
                    array[index] = value
                case let (.remove, .index(index)):
                    guard array.indices.contains(index) else { return false }
                    array.remove(at: index)
                case let (.replace, .match(key, id)):
                    guard let index = array.firstIndex(where: { $0[key]?.scalarText == id }), let value = operation.value else { return false }
                    array[index] = value
                case let (.remove, .match(key, id)):
                    guard let index = array.firstIndex(where: { $0[key]?.scalarText == id }) else { return false }
                    array.remove(at: index)
                default:
                    return false
                }
                parent = .array(array)
                return true
            default:
                return false
            }
        }
    }

    private static func modify(_ value: inout JSONValue, path: ArraySlice<PointerComponent>, _ body: (inout JSONValue) -> Bool) -> Bool {
        guard let first = path.first else { return body(&value) }
        let rest = path.dropFirst()
        switch (first, value) {
        case (let .key(key), var .object(object)):
            guard var child = object[key] else { return false }
            guard modify(&child, path: rest, body) else { return false }
            object[key] = child
            value = .object(object)
            return true
        case (let .index(index), var .array(array)):
            guard array.indices.contains(index) else { return false }
            var child = array[index]
            guard modify(&child, path: rest, body) else { return false }
            array[index] = child
            value = .array(array)
            return true
        case (let .match(key, id), var .array(array)):
            guard let index = array.firstIndex(where: { $0[key]?.scalarText == id }) else { return false }
            var child = array[index]
            guard modify(&child, path: rest, body) else { return false }
            array[index] = child
            value = .array(array)
            return true
        default:
            return false
        }
    }

    public static func value(at path: [PointerComponent], in root: JSONValue) -> JSONValue? {
        var current = root
        for component in path {
            switch (component, current) {
            case let (.key(key), .object(object)):
                guard let next = object[key] else { return nil }
                current = next
            case let (.index(index), .array(array)):
                guard array.indices.contains(index) else { return nil }
                current = array[index]
            case let (.match(key, id), .array(array)):
                guard let next = array.first(where: { $0[key]?.scalarText == id }) else { return nil }
                current = next
            default:
                return nil
            }
        }
        return current
    }

    public static func pointer(_ text: String) -> [PointerComponent] {
        text.split(separator: "/").map { part in
            if let index = Int(part) { return .index(index) }
            return .key(String(part))
        }
    }
}
