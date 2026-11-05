import NetLabCore
import SwiftUI

struct JSONEditNode: View {
    let label: String?
    @Binding var value: JSONValue
    let schema: SchemaNode?
    let depth: Int
    let onDelete: (() -> Void)?

    @State private var isExpanded: Bool
    @State private var addingField = false

    init(label: String?, value: Binding<JSONValue>, schema: SchemaNode?, depth: Int, onDelete: (() -> Void)?) {
        self.label = label
        _value = value
        self.schema = schema
        self.depth = depth
        self.onDelete = onDelete
        _isExpanded = State(initialValue: depth < 2)
    }

    var body: some View {
        switch value {
        case let .object(object):
            DisclosureGroup(isExpanded: $isExpanded) {
                ForEach(object.keys.sorted(), id: \.self) { key in
                    JSONEditNode(
                        label: key,
                        value: Binding(get: { field(key) }, set: { setField(key, $0) }),
                        schema: schema?.properties[key],
                        depth: depth + 1,
                        onDelete: { removeField(key) }
                    )
                }
                addFieldMenu(existing: Set(object.keys))
            } label: {
                ContainerLabel(label: label ?? "Body", summary: "\(object.count) fields")
            }
            .deletable(onDelete)
        case let .array(items):
            DisclosureGroup(isExpanded: $isExpanded) {
                ForEach(items.indices, id: \.self) { index in
                    JSONEditNode(
                        label: "[\(index)]",
                        value: Binding(get: { item(index) }, set: { setItem(index, $0) }),
                        schema: schema?.items.first,
                        depth: depth + 1,
                        onDelete: { removeItem(index) }
                    )
                }
                Button {
                    if case var .array(current) = value {
                        current.append(current.last ?? .string(""))
                        value = .array(current)
                    }
                } label: {
                    Label("Add item", systemImage: "plus")
                }
            } label: {
                ContainerLabel(label: label ?? "Body", summary: "\(items.count) items")
            }
            .deletable(onDelete)
        default:
            ScalarEditRow(label: label ?? "Value", value: $value, schema: schema)
                .deletable(onDelete)
        }
    }

    private func addFieldMenu(existing: Set<String>) -> some View {
        let learned = (schema?.properties.keys.sorted() ?? []).filter { !existing.contains($0) }
        return Menu {
            ForEach(learned, id: \.self) { key in
                Button(key) { setField(key, Self.placeholder(for: schema?.properties[key])) }
            }
            if !learned.isEmpty { Divider() }
            Button("New field…") { addingField = true }
        } label: {
            Label("Add field", systemImage: "plus")
        }
        .sheet(isPresented: $addingField) {
            FieldEditorView(existingNames: existing) { name, newValue in
                setField(name, newValue)
            }
        }
    }

    private func field(_ key: String) -> JSONValue {
        if case let .object(object) = value { return object[key] ?? .null }
        return .null
    }

    private func setField(_ key: String, _ newValue: JSONValue) {
        guard case var .object(object) = value else { return }
        object[key] = newValue
        value = .object(object)
    }

    private func removeField(_ key: String) {
        guard case var .object(object) = value else { return }
        object.removeValue(forKey: key)
        value = .object(object)
    }

    private func item(_ index: Int) -> JSONValue {
        if case let .array(items) = value, items.indices.contains(index) { return items[index] }
        return .null
    }

    private func setItem(_ index: Int, _ newValue: JSONValue) {
        guard case var .array(items) = value, items.indices.contains(index) else { return }
        items[index] = newValue
        value = .array(items)
    }

    private func removeItem(_ index: Int) {
        guard case var .array(items) = value, items.indices.contains(index) else { return }
        items.remove(at: index)
        value = .array(items)
    }

    static func placeholder(for schema: SchemaNode?) -> JSONValue {
        guard let schema else { return .string("") }
        if let first = schema.values.first {
            if schema.types.contains("number") { return JSONValue.parseScalar(first, like: .int(0)) }
            if schema.types.contains("bool") { return JSONValue.parseScalar(first, like: .bool(false)) }
            return .string(first)
        }
        if schema.types.contains("object") { return .object([:]) }
        if schema.types.contains("array") { return .array([]) }
        if schema.types.contains("number") { return .int(0) }
        if schema.types.contains("bool") { return .bool(false) }
        return .string("")
    }
}

struct ScalarEditRow: View {
    let label: String
    @Binding var value: JSONValue
    let schema: SchemaNode?

    @State private var isEditing = false

    var body: some View {
        if case let .bool(flag) = value {
            Toggle(isOn: Binding(get: { flag }, set: { value = .bool($0) })) {
                Text(label)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } else {
            Button {
                isEditing = true
            } label: {
                HStack(spacing: 10) {
                    Text(label)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(value.scalarText ?? "")
                        .font(.footnote.monospaced())
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(JSONKind(value).rawValue)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(.tertiarySystemFill), in: Capsule())
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Edit value and type")
            .sheet(isPresented: $isEditing) {
                FieldEditorView(name: label, value: value, schema: schema) { value = $0 }
            }
        }
    }
}

private extension View {
    @ViewBuilder
    func deletable(_ onDelete: (() -> Void)?) -> some View {
        if let onDelete {
            swipeActions {
                Button(role: .destructive, action: onDelete) {
                    Label("Delete", systemImage: "trash")
                }
            }
        } else {
            self
        }
    }
}
