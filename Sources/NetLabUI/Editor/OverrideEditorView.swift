import NetLabCore
import SwiftUI

struct OverrideEditorView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case changes = "Edit fields"
        case replace = "Replace response"

        var id: String { rawValue }
    }

    @ObservedObject var store: NetLabStore
    let key: EndpointKey
    private let initialSaved: SavedOverride?
    @Environment(\.dismiss) private var dismiss

    @State private var baseStatus: Int
    @State private var headers: [String: String]
    @State private var baseJSON: JSONValue?
    @State private var edited: JSONValue
    @State private var rawText: String
    @State private var editAsText: Bool
    @State private var rawError: String?
    @State private var mode: Mode
    @State private var statusText: String
    @State private var sourceTitle: String
    @State private var count = 1
    @State private var always = false
    @State private var delay: Double = 0
    @State private var condition = ""
    @State private var pinned = false
    @State private var appliedInitialSaved = false

    static let statusPresets = [200, 201, 204, 400, 401, 402, 403, 404, 409, 422, 429, 500, 502, 503]

    init(store: NetLabStore, request: EditorRequest) {
        self.store = store
        key = request.key
        initialSaved = request.saved
        let json = request.body.flatMap { try? JSONValue(data: $0) }
        _baseStatus = State(initialValue: request.statusCode)
        _headers = State(initialValue: request.headers)
        _baseJSON = State(initialValue: json)
        _edited = State(initialValue: json ?? .object([:]))
        _rawText = State(initialValue: json?.text() ?? request.body.map { String(decoding: $0, as: UTF8.self) } ?? "")
        _editAsText = State(initialValue: false)
        _mode = State(initialValue: json != nil && (200..<300).contains(request.statusCode) ? .changes : .replace)
        _statusText = State(initialValue: String(request.statusCode))
        _sourceTitle = State(initialValue: "Response \(request.statusCode)")
    }

    private var isJSON: Bool { baseJSON != nil }
    private var status: Int? { Int(statusText).flatMap { (100...599).contains($0) ? $0 : nil } }

    private var currentJSON: JSONValue? {
        if editAsText { return try? JSONValue(data: Data(rawText.utf8)) }
        return edited
    }

    private var changes: [PatchOperation] {
        guard let baseJSON, let currentJSON else { return [] }
        return JSONPatch.diff(from: baseJSON, to: currentJSON)
    }

    private var statusChanged: Bool { status != nil && status != baseStatus }

    private var canArm: Bool {
        guard status != nil else { return false }
        switch mode {
        case .changes: return isJSON && currentJSON != nil && (!changes.isEmpty || statusChanged)
        case .replace: return !isJSON || currentJSON != nil
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                sourceSection
                SavedOverridesSection(store: store, key: key, canEdit: canAdjust, onEdit: apply, onArmed: { dismiss() })
                modeSection
                statusSection
                bodySection
                if mode == .changes {
                    changesSection
                }
                DurationSection(count: $count, always: $always, delay: $delay, condition: $condition, pinned: $pinned)
            }
            .navigationTitle("Override next call")
            .onAppear {
                guard !appliedInitialSaved else { return }
                appliedInitialSaved = true
                if let initialSaved { apply(initialSaved) }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Arm", action: arm).disabled(!canArm)
                }
            }
        }
    }

    private var sourceSection: some View {
        Section {
            Text(key.title).font(.footnote.monospaced())
            Menu {
                ForEach(store.snapshot.endpoint(for: key)?.variants ?? []) { variant in
                    Button(Format.variantTitle(variant)) {
                        load(statusCode: variant.statusCode, headers: variant.headers, body: variant.body, title: Format.variantTitle(variant), ownSuccess: (200..<300).contains(variant.statusCode))
                    }
                }
                let shapes = store.snapshot.errorShapes(near: key).filter { $0.0 != key }
                if !shapes.isEmpty {
                    Section("Error shape from another endpoint") {
                        ForEach(shapes.indices, id: \.self) { index in
                            let endpoint = shapes[index].0
                            let variant = shapes[index].1
                            Button("\(endpoint.title) · \(variant.statusCode)") {
                                load(statusCode: variant.statusCode, headers: variant.headers, body: variant.body, title: "Error shape from \(endpoint.title)", ownSuccess: false)
                            }
                        }
                    }
                }
            } label: {
                LabeledContent("Start from", value: sourceTitle)
            }
        } header: {
            Text("Endpoint")
        }
    }

    private var modeSection: some View {
        Section {
            Picker("Mode", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(!isJSON)
        } footer: {
            switch mode {
            case .changes:
                Text("Only the fields you change are applied to the next real response, so IDs and amounts stay current. If the real call fails, the override waits for the next one.")
            case .replace:
                Text("The next call gets exactly this response without reaching the server.")
            }
        }
    }

    private var statusSection: some View {
        Section("Status") {
            HStack {
                TextField("Status code", text: $statusText)
                    .keyboardType(.numberPad)
                    .font(.body.monospacedDigit())
                Menu {
                    ForEach(Self.statusPresets, id: \.self) { code in
                        Button(String(code)) { statusText = String(code) }
                    }
                } label: {
                    Image(systemName: "list.number")
                }
                .accessibilityLabel("Common status codes")
            }
            if status == nil {
                Text("Enter a status code between 100 and 599.").font(.footnote).foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var bodySection: some View {
        Section {
            if isJSON {
                Toggle("Edit as text", isOn: Binding(get: { editAsText }, set: switchTextMode))
                if editAsText {
                    TextEditor(text: $rawText)
                        .font(.caption.monospaced())
                        .frame(minHeight: 220)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if currentJSON == nil {
                        Text("This is not valid JSON yet.").font(.footnote).foregroundStyle(.red)
                    }
                } else {
                    JSONEditNode(label: nil, value: $edited, schema: schema, depth: 0, onDelete: nil)
                }
            } else {
                TextEditor(text: $rawText)
                    .font(.caption.monospaced())
                    .frame(minHeight: 160)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
        } header: {
            Text("Body")
        } footer: {
            if !isJSON {
                Text("This body is not JSON, so it can only be replaced.")
            } else if let rawError {
                Text(rawError).foregroundStyle(.red)
            } else if schema != nil {
                Text("Tap a field to edit its value and type, and to pick values seen in real responses.")
            }
        }
    }

    private var changesSection: some View {
        Section("Changes to apply") {
            if statusChanged, let status {
                Text("status: \(baseStatus) → \(status)").font(.footnote.monospaced())
            }
            if changes.isEmpty && !statusChanged {
                Text("No changes yet. Edit a field above.").foregroundStyle(.secondary)
            }
            ForEach(changes) { change in
                Text(change.summary).font(.footnote.monospaced())
            }
        }
    }

    private var schema: SchemaNode? {
        store.snapshot.schema(for: key, slot: Variant(statusCode: baseStatus, headers: [:], body: nil).id)
    }

    private func switchTextMode(_ on: Bool) {
        if on {
            rawText = edited.text()
            rawError = nil
            editAsText = true
        } else if let parsed = try? JSONValue(data: Data(rawText.utf8)) {
            edited = parsed
            rawError = nil
            editAsText = false
        } else {
            rawError = "Fix the JSON before switching back to fields."
        }
    }

    private func load(statusCode: Int, headers: [String: String], body: Data?, title: String, ownSuccess: Bool) {
        let json = body.flatMap { try? JSONValue(data: $0) }
        baseStatus = statusCode
        self.headers = headers
        baseJSON = json
        edited = json ?? .object([:])
        rawText = json?.text() ?? body.map { String(decoding: $0, as: UTF8.self) } ?? ""
        editAsText = false
        rawError = nil
        statusText = String(statusCode)
        sourceTitle = title
        mode = json != nil && ownSuccess ? .changes : .replace
    }

    private func canAdjust(_ saved: SavedOverride) -> Bool {
        if case .changes = saved.override.action { return isJSON }
        if case .replace = saved.override.action { return true }
        return false
    }

    private func apply(_ saved: SavedOverride) {
        let override = saved.override
        switch override.action {
        case let .changes(operations, statusCode):
            guard let baseJSON else { return }
            let result = JSONPatch.apply(operations, to: baseJSON)
            edited = result.value
            rawText = result.value.text()
            editAsText = false
            rawError = result.skipped.isEmpty ? nil : "\(result.skipped.count) saved changes don't fit this response."
            statusText = String(statusCode ?? baseStatus)
            mode = .changes
        case let .replace(statusCode, headers, body):
            load(statusCode: statusCode, headers: headers, body: body, title: override.title, ownSuccess: false)
        case .status, .failure:
            return
        }
        switch override.duration {
        case let .next(value):
            count = value
            always = false
        case .always:
            count = 1
            always = true
        }
        delay = override.delay ?? 0
        condition = override.condition ?? ""
        pinned = override.isPinned
    }

    private func arm() {
        guard let status else { return }
        let action: OverrideAction
        let title: String
        switch mode {
        case .changes:
            let operations = changes
            action = .changes(operations, statusCode: statusChanged ? status : nil)
            var parts = operations.map(\.summary)
            if statusChanged { parts.insert("status \(status)", at: 0) }
            title = parts.count == 1 ? parts[0] : "\(parts.count) changes"
        case .replace:
            let body: Data
            if isJSON, let json = currentJSON {
                body = json.data()
            } else {
                body = Data(rawText.utf8)
            }
            var replacementHeaders = headers
            if isJSON, !replacementHeaders.keys.contains(where: { $0.caseInsensitiveCompare("Content-Type") == .orderedSame }) {
                replacementHeaders["Content-Type"] = "application/json"
            }
            action = .replace(statusCode: status, headers: replacementHeaders, body: body)
            title = "Replace with \(status)"
        }
        let override = Override(
            title: title,
            action: action,
            duration: always ? .always : .next(max(count, 1)),
            delay: delay > 0 ? delay : nil,
            condition: condition.isEmpty ? nil : condition,
            isPinned: pinned
        )
        store.perform(.arm(key, override))
        store.perform(.saveOverride(key, override))
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        dismiss()
    }
}
