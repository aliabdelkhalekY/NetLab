import NetLabCore
import SwiftUI

struct FieldEditorView: View {
    @Environment(\.dismiss) private var dismiss

    private let isNew: Bool
    private let existingNames: Set<String>
    private let schema: SchemaNode?
    private let onSave: (String, JSONValue) -> Void

    @State private var name: String
    @State private var kind: JSONKind
    @State private var text: String

    init(name: String, value: JSONValue, schema: SchemaNode?, onSave: @escaping (JSONValue) -> Void) {
        isNew = false
        existingNames = []
        self.schema = schema
        self.onSave = { _, newValue in onSave(newValue) }
        _name = State(initialValue: name)
        _kind = State(initialValue: JSONKind(value))
        if case .null = value {
            _text = State(initialValue: "")
        } else {
            _text = State(initialValue: value.scalarText ?? "")
        }
    }

    init(existingNames: Set<String>, onSave: @escaping (String, JSONValue) -> Void) {
        isNew = true
        self.existingNames = existingNames
        schema = nil
        self.onSave = onSave
        _name = State(initialValue: "")
        _kind = State(initialValue: .string)
        _text = State(initialValue: "")
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var nameTaken: Bool { isNew && existingNames.contains(trimmedName) }
    private var parsedValue: JSONValue? { kind.value(from: text) }
    private var canSave: Bool { parsedValue != nil && !trimmedName.isEmpty && !nameTaken }

    var body: some View {
        NavigationStack {
            Form {
                if isNew {
                    Section {
                        TextField("Name", text: $name)
                            .font(.body.monospaced())
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        if nameTaken {
                            Text("This object already has a field with this name.").font(.footnote).foregroundStyle(.red)
                        }
                    } header: {
                        Text("Field")
                    }
                }
                Section("Type") {
                    Picker("Type", selection: Binding(get: { kind }, set: selectKind)) {
                        ForEach(JSONKind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.menu)
                }
                valueSection
                if let values = schema?.values, !values.isEmpty, kind != .object, kind != .array, kind != .null {
                    Section("Values seen") {
                        ForEach(values, id: \.self) { option in
                            Button(option) { text = option }
                                .font(.footnote.monospaced())
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "New field" : name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let parsedValue else { return }
                        onSave(trimmedName, parsedValue)
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
        }
    }

    @ViewBuilder
    private var valueSection: some View {
        switch kind {
        case .string:
            Section("Value") {
                TextEditor(text: $text)
                    .font(.footnote.monospaced())
                    .frame(minHeight: 260)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
        case .number:
            Section("Value") {
                TextField("Number", text: $text)
                    .font(.body.monospacedDigit())
                    .keyboardType(.numbersAndPunctuation)
                    .autocorrectionDisabled()
                if parsedValue == nil {
                    Text("Enter a number, for example 12 or 12.5.").font(.footnote).foregroundStyle(.red)
                }
            }
        case .bool:
            Section("Value") {
                Picker("Value", selection: $text) {
                    Text("true").tag("true")
                    Text("false").tag("false")
                }
                .pickerStyle(.segmented)
            }
        case .null:
            Section {
                Text("The value is null.").foregroundStyle(.secondary)
            }
        case .object, .array:
            Section {
                Text(kind == .object ? "Starts empty. Add its fields from the list after saving." : "Starts empty. Add its items from the list after saving.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func selectKind(_ newKind: JSONKind) {
        kind = newKind
        if newKind == .bool, text != "true", text != "false" {
            text = "false"
        }
    }
}
