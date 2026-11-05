import NetLabCore
import SwiftUI

struct EndpointDetailView: View {
    @ObservedObject var store: NetLabStore
    let key: EndpointKey

    @State private var editor: EditorRequest?
    @State private var editingStep: Override?
    @State private var splitKind: SplitKind?
    @State private var splitName = ""

    enum SplitKind: String, Identifiable {
        case query = "Query parameter"
        case body = "Body field"

        var id: String { rawValue }
    }

    private var endpoint: EndpointInfo? { store.snapshot.endpoint(for: key) }
    private var queue: OverrideQueue? { store.snapshot.queue(for: key) }

    var body: some View {
        List {
            if let endpoint {
                pathSection(endpoint)
                responsesSection(endpoint)
            }
            SavedOverridesSection(store: store, key: key, canEdit: { saved in
                if case .changes = saved.override.action { return endpoint?.variants.isEmpty == false }
                return true
            }, onEdit: { saved in
                editor = store.editorRequest(applying: saved)
            }, onArmed: {})
            quickFailuresSection
            if let queue, !queue.steps.isEmpty {
                queueSection(queue)
            }
        }
        .navigationTitle(key.template)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    editor = store.editorRequest(for: key)
                } label: {
                    Label("Override next call", systemImage: "slider.horizontal.3")
                }
            }
            if queue?.steps.isEmpty == false {
                ToolbarItem(placement: .secondaryAction) { EditButton() }
            }
        }
        .sheet(item: $editor) { request in
            OverrideEditorView(store: store, request: request)
        }
        .sheet(item: $editingStep) { step in
            StepSettingsView(step: step) { updated in
                store.perform(.updateStep(key, updated))
            }
        }
        .alert(splitKind?.rawValue ?? "", isPresented: Binding(get: { splitKind != nil }, set: { if !$0 { splitKind = nil } })) {
            TextField(splitKind == .body ? "Field, for example action or data.type" : "Parameter name", text: $splitName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Split") {
                let name = splitName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty {
                    store.perform(.setSplit(key, splitKind == .body ? .bodyField(name) : .query(name)))
                }
                splitName = ""
            }
            Button("Cancel", role: .cancel) { splitName = "" }
        } message: {
            Text("Calls to this path become separate endpoints, one per value.")
        }
    }

    private func pathSection(_ endpoint: EndpointInfo) -> some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Text(endpoint.key.method).font(.caption.monospaced().weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(Array(endpoint.segments.enumerated()), id: \.offset) { index, segment in
                        Text("/").foregroundStyle(.tertiary)
                        Button {
                            store.perform(.setSegment(key, index: index, variable: !segment.isVariable))
                        } label: {
                            Text(segment.isVariable ? "{id}" : segment.value)
                                .font(.footnote.monospaced())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(segment.isVariable ? Color.accentColor.opacity(0.15) : Color(.tertiarySystemFill), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(segment.isVariable ? "ID segment, \(segment.value)" : "Fixed segment, \(segment.value)")
                        .accessibilityHint(segment.isVariable ? "Treat as a fixed part of the path" : "Treat as an ID")
                    }
                }
                .padding(.vertical, 4)
            }
            LabeledContent("IDs seen", value: "\(endpoint.idsSeen.count)")
            LabeledContent("Calls", value: "\(endpoint.callCount)")
            Menu {
                Button("By query parameter…") { splitKind = .query }
                Button("By body field…") { splitKind = .body }
                if endpoint.key.discriminator != nil {
                    Button("Stop splitting", role: .destructive) { store.perform(.setSplit(key, nil)) }
                }
            } label: {
                Label(endpoint.key.discriminator.map { "Split: \($0)" } ?? "Split calls…", systemImage: "arrow.triangle.branch")
            }
        } header: {
            Text("Path")
        } footer: {
            Text("Tap a segment to switch it between an ID and a fixed part of the path. Endpoints that share a template are merged.")
        }
    }

    private func responsesSection(_ endpoint: EndpointInfo) -> some View {
        Section {
            if endpoint.variants.isEmpty {
                Text("No response yet. Run the call once in the app.").foregroundStyle(.secondary)
            }
            ForEach(endpoint.variants) { variant in
                Button {
                    editor = EditorRequest(key: key, statusCode: variant.statusCode, headers: variant.headers, body: variant.body)
                } label: {
                    HStack {
                        Circle().fill(Format.statusColor(variant.statusCode)).frame(width: 8, height: 8)
                        Text(Format.variantTitle(variant)).foregroundStyle(.primary)
                        Spacer()
                        Text(variant.capturedAt, style: .relative).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Responses seen")
        } footer: {
            Text("Tap a response to edit it and override the next call.")
        }
    }

    private var quickFailuresSection: some View {
        Section {
            QuickFailureButton(title: "Offline", systemImage: "wifi.slash") { arm(.failure(.offline)) }
            QuickFailureButton(title: "Timeout", systemImage: "hourglass") { arm(.failure(.timeout)) }
            QuickFailureButton(title: "Slow, 3 s", systemImage: "tortoise") { arm(.failure(.slow(seconds: 3))) }
            QuickFailureButton(title: "Slow, 10 s", systemImage: "tortoise.fill") { arm(.failure(.slow(seconds: 10))) }
            QuickFailureButton(title: "Connection lost mid-response", systemImage: "bolt.horizontal") { arm(.failure(.connectionLost)) }
            QuickFailureButton(title: "Server error 500", systemImage: "exclamationmark.octagon") { arm(.status(500, body: .real), title: "Status 500") }
            QuickFailureButton(title: "Unauthorized 401", systemImage: "lock") { arm(.status(401, body: .real), title: "Status 401") }
            Menu {
                ForEach(BrokenBody.allCases, id: \.self) { kind in
                    Button(kind.title) { arm(.failure(.brokenBody(kind))) }
                }
            } label: {
                Label("Broken body", systemImage: "doc.badge.ellipsis")
            }
        } header: {
            Text("Quick failures")
        } footer: {
            Text("Each one applies to the next call only.")
        }
    }

    private func queueSection(_ queue: OverrideQueue) -> some View {
        Section {
            ForEach(queue.steps) { step in
                StepRow(step: step) { enabled in
                    var updated = step
                    updated.isEnabled = enabled
                    store.perform(.updateStep(key, updated))
                } onEdit: {
                    editingStep = step
                }
            }
            .onMove { source, destination in
                store.perform(.moveSteps(key, source, destination))
            }
            .onDelete { offsets in
                offsets.map { queue.steps[$0].id }.forEach { store.perform(.removeStep(key, $0)) }
            }
            Toggle("Repeat the last step", isOn: Binding(get: { queue.repeatLast }, set: { store.perform(.setRepeatLast(key, $0)) }))
            Button("Remove all overrides", role: .destructive) {
                store.perform(.clearQueue(key))
            }
        } header: {
            Text("Queue")
        } footer: {
            Text("Calls take the steps in order. When the queue is empty, calls go to the server unchanged.")
        }
    }

    private func arm(_ action: OverrideAction, title: String? = nil) {
        let name: String
        if let title {
            name = title
        } else if case let .failure(kind) = action {
            name = kind.title
        } else {
            name = "Override"
        }
        store.perform(.arm(key, Override(title: name, action: action)))
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}

struct QuickFailureButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
        }
    }
}

struct StepRow: View {
    let step: Override
    let onToggle: (Bool) -> Void
    let onEdit: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onEdit) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(step.title).foregroundStyle(.primary).lineLimit(2)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            Spacer()
            Toggle("Enabled", isOn: Binding(get: { step.isEnabled }, set: onToggle))
                .labelsHidden()
        }
    }

    private var detail: String {
        var parts = [step.remainingText]
        if step.appliedCount > 0 { parts.append("applied \(step.appliedCount)×") }
        if let delay = step.delay, delay > 0 { parts.append("delay \(Int(delay)) s") }
        if let condition = step.condition, !condition.isEmpty { parts.append("only when “\(condition)”") }
        if step.isPinned { parts.append("kept after relaunch") }
        return parts.joined(separator: " · ")
    }
}

struct StepSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var step: Override
    @State private var count: Int
    @State private var always: Bool
    @State private var delay: Double
    @State private var condition: String
    let onSave: (Override) -> Void

    init(step: Override, onSave: @escaping (Override) -> Void) {
        _step = State(initialValue: step)
        if case let .next(value) = step.duration {
            _count = State(initialValue: value)
            _always = State(initialValue: false)
        } else {
            _count = State(initialValue: 1)
            _always = State(initialValue: true)
        }
        _delay = State(initialValue: step.delay ?? 0)
        _condition = State(initialValue: step.condition ?? "")
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Step") {
                    TextField("Title", text: $step.title)
                }
                DurationSection(count: $count, always: $always, delay: $delay, condition: $condition, pinned: $step.isPinned)
            }
            .navigationTitle("Step")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        step.duration = always ? .always : .next(max(count, 1))
                        step.delay = delay > 0 ? delay : nil
                        step.condition = condition.isEmpty ? nil : condition
                        onSave(step)
                        dismiss()
                    }
                }
            }
        }
    }
}

struct DurationSection: View {
    @Binding var count: Int
    @Binding var always: Bool
    @Binding var delay: Double
    @Binding var condition: String
    @Binding var pinned: Bool

    var body: some View {
        Section {
            Picker("Applies to", selection: $always) {
                Text("Next calls").tag(false)
                Text("Every call").tag(true)
            }
            if !always {
                Stepper(count == 1 ? "Next call" : "Next \(count) calls", value: $count, in: 1...50)
            }
            Stepper(delay == 0 ? "No extra delay" : "Extra delay \(Int(delay)) s", value: $delay, in: 0...60, step: 1)
            TextField("Only when the URL or body contains…", text: $condition)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Toggle("Keep after relaunch", isOn: $pinned)
        } header: {
            Text("When")
        } footer: {
            Text("Overrides end when the app relaunches unless they are kept.")
        }
    }
}
