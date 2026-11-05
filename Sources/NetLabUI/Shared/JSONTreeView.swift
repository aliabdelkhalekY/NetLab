import NetLabCore
import SwiftUI

struct JSONTreeView: View {
    let value: JSONValue

    var body: some View {
        JSONNodeView(label: nil, value: value, depth: 0)
    }
}

struct JSONNodeView: View {
    let label: String?
    let value: JSONValue
    let depth: Int

    @State private var isExpanded: Bool

    init(label: String?, value: JSONValue, depth: Int) {
        self.label = label
        self.value = value
        self.depth = depth
        _isExpanded = State(initialValue: depth < 2)
    }

    var body: some View {
        switch value {
        case let .object(object):
            DisclosureGroup(isExpanded: $isExpanded) {
                ForEach(object.keys.sorted(), id: \.self) { key in
                    JSONNodeView(label: key, value: object[key] ?? .null, depth: depth + 1)
                }
            } label: {
                ContainerLabel(label: label ?? "Body", summary: "\(object.count) fields")
            }
        case let .array(items):
            DisclosureGroup(isExpanded: $isExpanded) {
                ForEach(items.indices, id: \.self) { index in
                    JSONNodeView(label: "[\(index)]", value: items[index], depth: depth + 1)
                }
            } label: {
                ContainerLabel(label: label ?? "Body", summary: "\(items.count) items")
            }
        default:
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(label ?? "Value").font(.subheadline).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                ScalarText(value: value)
            }
        }
    }
}

struct ContainerLabel: View {
    let label: String
    let summary: String

    var body: some View {
        HStack {
            Text(label).font(.subheadline.weight(.medium))
            Spacer()
            Text(summary).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct ScalarText: View {
    let value: JSONValue

    var body: some View {
        Text(display)
            .font(.footnote.monospaced())
            .foregroundStyle(color)
            .multilineTextAlignment(.trailing)
            .textSelection(.enabled)
    }

    private var display: String {
        if case let .string(text) = value { return "\"\(text)\"" }
        return value.scalarText ?? ""
    }

    private var color: Color {
        switch value {
        case .string: return .primary
        case .int, .double: return .blue
        case .bool: return .purple
        default: return .secondary
        }
    }
}
