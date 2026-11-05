import NetLabCore
import SwiftUI

enum TrafficFilter: String, CaseIterable, Identifiable {
    case all = "All calls"
    case overridden = "Overridden"
    case failed = "Failed"

    var id: String { rawValue }
}

struct TrafficView: View {
    @ObservedObject var store: NetLabStore
    let onClose: () -> Void

    @State private var search = ""
    @State private var filter = TrafficFilter.all
    @State private var host: String?
    @State private var editor: EditorRequest?
    @State private var share: ShareItem?

    private var hosts: [String] {
        Array(Set(store.snapshot.calls.map(\.endpoint.host))).sorted()
    }

    private var calls: [Call] {
        store.snapshot.calls.filter { call in
            switch filter {
            case .all: break
            case .overridden: if call.report == nil { return false }
            case .failed: if !call.isFailure { return false }
            }
            if let host, call.endpoint.host != host { return false }
            guard !search.isEmpty else { return true }
            let haystack = "\(call.request.method) \(call.request.url.absoluteString) \(Format.status(call)) \(call.endpoint.template)"
            return haystack.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        List {
            if !store.snapshot.isIntercepting {
                Label("Not recording. Call NetLab.start() when the app launches.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            ForEach(calls) { call in
                NavigationLink(value: call.id) {
                    CallRow(call: call)
                }
                .swipeActions(edge: .trailing) {
                    Button {
                        editor = store.editorRequest(for: call)
                    } label: {
                        Label("Override", systemImage: "slider.horizontal.3")
                    }
                    .tint(.orange)
                }
                .swipeActions(edge: .leading) {
                    Button {
                        Clipboard.copy(store.backend.curl(for: call, raw: false))
                    } label: {
                        Label("cURL", systemImage: "doc.on.doc")
                    }
                    .tint(.blue)
                }
                .contextMenu {
                    Button {
                        editor = store.editorRequest(for: call)
                    } label: {
                        Label("Override next call…", systemImage: "slider.horizontal.3")
                    }
                    Button {
                        Clipboard.copy(store.backend.curl(for: call, raw: false))
                    } label: {
                        Label("Copy as cURL", systemImage: "doc.on.doc")
                    }
                    Button {
                        if let url = try? store.backend.exportHAR([call]) { share = ShareItem(url: url) }
                    } label: {
                        Label("Share as HAR", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if calls.isEmpty {
                if store.snapshot.calls.isEmpty {
                    EmptyStateView(title: "No calls yet", message: "Requests appear here as the app makes them.", systemImage: "arrow.left.arrow.right")
                } else {
                    EmptyStateView(title: "No matching calls", message: "Change the search or the filter.", systemImage: "line.3.horizontal.decrease.circle")
                }
            }
        }
        .searchable(text: $search, prompt: "Path, host or status")
        .navigationTitle("Traffic")
        .navigationDestination(for: UUID.self) { id in
            CallDetailView(store: store, callID: id)
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done", action: onClose)
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Show", selection: $filter) {
                        ForEach(TrafficFilter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    if hosts.count > 1 {
                        Picker("Host", selection: $host) {
                            Text("All hosts").tag(String?.none)
                            ForEach(hosts, id: \.self) { Text($0).tag(String?.some($0)) }
                        }
                    }
                    Divider()
                    Button {
                        if let url = try? store.backend.exportHAR(calls) { share = ShareItem(url: url) }
                    } label: {
                        Label("Share these calls as HAR", systemImage: "square.and.arrow.up")
                    }
                    Button(role: .destructive) {
                        store.perform(.clearTraffic)
                    } label: {
                        Label("Clear traffic", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: filter == .all && host == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                }
            }
        }
        .sheet(item: $editor) { request in
            OverrideEditorView(store: store, request: request)
        }
        .sheet(item: $share) { item in
            ActivityView(items: [item.url])
        }
    }
}

struct CallRow: View {
    let call: Call

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                MethodLabel(method: call.request.method)
                StatusText(call: call)
                Spacer(minLength: 8)
                Text(Format.duration(call.duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(call.request.url.absoluteString)
                .font(.footnote.monospaced())
                .fixedSize(horizontal: false, vertical: true)
            if let report = call.report {
                Label(report.summary, systemImage: report.notApplied ? "exclamationmark.circle" : "wand.and.stars")
                    .font(.caption)
                    .foregroundStyle(report.notApplied ? Color.secondary : Color.orange)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}
