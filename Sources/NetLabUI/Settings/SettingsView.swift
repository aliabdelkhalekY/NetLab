import NetLabCore
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var store: NetLabStore
    let onClose: () -> Void

    @State private var share: ShareItem?
    @State private var importing: ImportKind?
    @State private var savingPreset = false
    @State private var presetName = ""
    @State private var confirmForget = false
    @State private var message: String?

    enum ImportKind: Identifiable {
        case preset
        case learned

        var id: Self { self }
    }

    private var snapshot: NetLabSnapshot { store.snapshot }

    var body: some View {
        Form {
            Section("Status") {
                LabeledContent("Recording", value: snapshot.isIntercepting ? "On" : "Off")
                LabeledContent("Calls", value: "\(snapshot.calls.count)")
                LabeledContent("Endpoints learned", value: "\(snapshot.endpoints.count)")
                LabeledContent("Overrides armed", value: "\(snapshot.armedCount)")
            }

            if !snapshot.switches.isEmpty {
                Section {
                    ForEach(snapshot.switches) { item in
                        Picker(item.name, selection: Binding(get: { item.value }, set: { store.perform(.setSwitch(item.name, $0)) })) {
                            ForEach(item.options, id: \.self) { Text($0).tag($0) }
                        }
                    }
                } header: {
                    Text("App switches")
                } footer: {
                    Text("Switches are provided by the app for behaviour that does not go through the network.")
                }
            }

            Section {
                Toggle("Keep learned API on this device", isOn: Binding(
                    get: { snapshot.storage == .device },
                    set: { store.perform(.setStorage($0 ? .device : .memory)) }
                ))
            } header: {
                Text("Storage")
            } footer: {
                Text("When on, learned endpoints, responses and schemas survive relaunches. They are stored with file protection, excluded from backups, and redacted. Recorded calls always stay in memory.")
            }

            Section {
                Button {
                    savingPreset = true
                } label: {
                    Label("Save current overrides as a preset…", systemImage: "square.and.arrow.down")
                }
                .disabled(snapshot.queues.isEmpty)
                ForEach(snapshot.presets) { preset in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.name)
                            Text("\(preset.queues.count) endpoints · \(preset.createdAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Menu {
                            Button {
                                store.perform(.loadPreset(preset.id))
                                message = "Loaded “\(preset.name)”."
                            } label: {
                                Label("Load", systemImage: "play")
                            }
                            Button {
                                if let url = try? store.backend.exportPreset(preset.id) { share = ShareItem(url: url) }
                            } label: {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                            Button(role: .destructive) {
                                store.perform(.deletePreset(preset.id))
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
                Button {
                    importing = .preset
                } label: {
                    Label("Import a preset…", systemImage: "square.and.arrow.down.on.square")
                }
            } header: {
                Text("Presets")
            } footer: {
                Text("A preset saves the armed overrides of every endpoint so a tester can repeat or share a setup.")
            }

            Section {
                Button {
                    do {
                        share = ShareItem(url: try store.backend.exportLearnedAPI())
                    } catch {
                        message = "Export failed: \(error.localizedDescription)"
                    }
                } label: {
                    Label("Export learned API", systemImage: "square.and.arrow.up")
                }
                .disabled(snapshot.endpoints.isEmpty)
                Button {
                    importing = .learned
                } label: {
                    Label("Import learned API…", systemImage: "square.and.arrow.down")
                }
            } header: {
                Text("Learned API")
            } footer: {
                Text("Share endpoints and the responses seen for them, redacted, so other testers can override responses they have not seen yet.")
            }

            Section("Redaction") {
                NavigationLink {
                    ListEditorView(title: "Headers", placeholder: "Header name", items: snapshot.redaction.headers) { headers in
                        store.perform(.setRedaction(Redaction(headers: headers, jsonKeys: snapshot.redaction.jsonKeys)))
                    }
                } label: {
                    LabeledContent("Headers", value: "\(snapshot.redaction.headers.count)")
                }
                NavigationLink {
                    ListEditorView(title: "JSON keys", placeholder: "Key, matched anywhere in the name", items: snapshot.redaction.jsonKeys) { keys in
                        store.perform(.setRedaction(Redaction(headers: snapshot.redaction.headers, jsonKeys: keys)))
                    }
                } label: {
                    LabeledContent("JSON keys", value: "\(snapshot.redaction.jsonKeys.count)")
                }
            }

            Section {
                CoverageRow(title: "URLSession.shared", covered: true)
                CoverageRow(title: "Default and ephemeral sessions", covered: true)
                CoverageRow(title: "WKWebView pages", covered: false)
                CoverageRow(title: "Background sessions", covered: false)
                CoverageRow(title: "Sessions that set their own protocol classes", covered: false)
            } header: {
                Text("Coverage")
            } footer: {
                Text("Traffic marked as not covered never appears in NetLab and cannot be overridden.")
            }

            Section {
                Button("Clear traffic", role: .destructive) {
                    store.perform(.clearTraffic)
                }
                Button("Forget learned API", role: .destructive) {
                    confirmForget = true
                }
            }
        }
        .navigationTitle("Settings")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done", action: onClose)
            }
        }
        .sheet(item: $share) { item in
            ActivityView(items: [item.url])
        }
        .fileImporter(isPresented: Binding(get: { importing != nil }, set: { if !$0 { importing = nil } }), allowedContentTypes: [.json]) { result in
            let kind = importing
            importing = nil
            switch result {
            case let .success(url):
                do {
                    if kind == .preset {
                        try store.backend.importPreset(from: url)
                        message = "Preset imported."
                    } else {
                        try store.backend.importLearnedAPI(from: url)
                        message = "Learned API imported."
                    }
                } catch {
                    message = "Import failed: this file is not a NetLab \(kind == .preset ? "preset" : "learned API")."
                }
            case let .failure(error):
                message = "Import failed: \(error.localizedDescription)"
            }
        }
        .alert("Save preset", isPresented: $savingPreset) {
            TextField("Name", text: $presetName)
            Button("Save") {
                let name = presetName.trimmingCharacters(in: .whitespaces)
                store.perform(.savePreset(name.isEmpty ? "Preset" : name))
                presetName = ""
            }
            Button("Cancel", role: .cancel) { presetName = "" }
        } message: {
            Text("Saves the overrides armed on every endpoint.")
        }
        .confirmationDialog("Forget learned API?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Forget endpoints and responses", role: .destructive) {
                store.perform(.clearLearned)
            }
        } message: {
            Text("Endpoints are learned again as the app makes requests.")
        }
        .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }
}

struct CoverageRow: View {
    let title: String
    let covered: Bool

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: covered ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(covered ? Color.green : Color.secondary)
        }
        .accessibilityValue(covered ? "Covered" : "Not covered")
    }
}

struct ListEditorView: View {
    let title: String
    let placeholder: String
    @State var items: [String]
    let onChange: ([String]) -> Void

    @State private var newItem = ""

    init(title: String, placeholder: String, items: [String], onChange: @escaping ([String]) -> Void) {
        self.title = title
        self.placeholder = placeholder
        _items = State(initialValue: items)
        self.onChange = onChange
    }

    var body: some View {
        List {
            Section {
                HStack {
                    TextField(placeholder, text: $newItem)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(add)
                    Button("Add", action: add)
                        .disabled(newItem.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            Section {
                ForEach(items, id: \.self) { Text($0).font(.body.monospaced()) }
                    .onDelete { offsets in
                        items.remove(atOffsets: offsets)
                        onChange(items)
                    }
            }
        }
        .navigationTitle(title)
        .toolbar { EditButton() }
    }

    private func add() {
        let item = newItem.trimmingCharacters(in: .whitespaces)
        guard !item.isEmpty, !items.contains(item) else { return }
        items.append(item)
        newItem = ""
        onChange(items)
    }
}
