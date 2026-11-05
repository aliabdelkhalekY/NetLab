import Foundation

public struct SchemaNode: Hashable, Codable {
    static let valueLimit = 12

    public var types: Set<String> = []
    public var seenCount = 0
    public var values: [String] = []
    public var properties: [String: SchemaNode] = [:]
    public var propertyCounts: [String: Int] = [:]
    public var items: [SchemaNode] = []

    public init() {}

    public mutating func merge(_ value: JSONValue) {
        seenCount += 1
        types.insert(value.typeName)
        switch value {
        case let .object(object):
            for (key, child) in object {
                propertyCounts[key, default: 0] += 1
                var node = properties[key] ?? SchemaNode()
                node.merge(child)
                properties[key] = node
            }
        case let .array(array):
            var node = items.first ?? SchemaNode()
            array.forEach { node.merge($0) }
            items = [node]
        case .null:
            break
        default:
            if let text = value.scalarText, !values.contains(text), values.count < Self.valueLimit {
                values.append(text)
            }
        }
    }

    public mutating func merge(_ other: SchemaNode) {
        seenCount += other.seenCount
        types.formUnion(other.types)
        for value in other.values where !values.contains(value) && values.count < Self.valueLimit {
            values.append(value)
        }
        for (key, node) in other.properties {
            var merged = properties[key] ?? SchemaNode()
            merged.merge(node)
            properties[key] = merged
            propertyCounts[key, default: 0] += other.propertyCounts[key, default: 0]
        }
        if let otherItems = other.items.first {
            var merged = items.first ?? SchemaNode()
            merged.merge(otherItems)
            items = [merged]
        }
    }

    public func node(at path: [PointerComponent]) -> SchemaNode? {
        var current = self
        for component in path {
            switch component {
            case let .key(key):
                guard let next = current.properties[key] else { return nil }
                current = next
            case .index, .match, .append:
                guard let next = current.items.first else { return nil }
                current = next
            }
        }
        return current
    }

    public func isOptional(_ key: String) -> Bool {
        propertyCounts[key, default: 0] < seenCount
    }

    public func leafPointers(prefix: [PointerComponent] = []) -> [[PointerComponent]] {
        if properties.isEmpty { return prefix.isEmpty ? [] : [prefix] }
        return properties.keys.sorted().flatMap { key in
            properties[key]!.leafPointers(prefix: prefix + [.key(key)]) + [prefix + [.key(key)]]
        }
    }
}
