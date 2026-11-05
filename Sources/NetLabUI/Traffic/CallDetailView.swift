import NetLabCore
import SwiftUI

struct CallDetailView: View {
    @ObservedObject var store: NetLabStore
    let callID: UUID

    @State private var reveal = false
    @State private var editor: EditorRequest?
    @State private var share: ShareItem?

    var body: some View {
        Group {
            if let call = store.call(callID) {
                content(call)
            } else {
                EmptyStateView(title: "Call cleared", message: "This call is no longer in the traffic list.", systemImage: "tray")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editor) { request in
            OverrideEditorView(store: store, request: request)
        }
        .sheet(item: $share) { item in
            ActivityView(items: [item.url])
        }
    }

    private func content(_ call: Call) -> some View {
        let redaction = store.snapshot.redaction
        return List {
            Section("Overview") {
                LabeledContent("Status") { StatusText(call: call) }
                LabeledContent("Duration", value: Format.duration(call.duration))
                LabeledContent("Endpoint") {
                    Text(call.endpoint.title).font(.footnote.monospaced()).multilineTextAlignment(.trailing)
                }
                LabeledContent("Started", value: call.startedAt.formatted(date: .omitted, time: .standard))
            }

            if let report = call.report {
                Section {
                    if report.notApplied {
                        Text("The real call failed, so the override was not used. It stays armed for the next call.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(report.applied, id: \.self) { change in
                        Label(change, systemImage: "checkmark.circle").foregroundStyle(.green)
                    }
                    ForEach(report.skipped, id: \.self) { change in
                        Label("Skipped: \(change)", systemImage: "xmark.circle").foregroundStyle(.orange)
                    }
                } header: {
                    Text("Override · \(report.title)")
                } footer: {
                    if !report.skipped.isEmpty {
                        Text("Skipped changes point at fields this response does not have.")
                    }
                }
            }

            Section("Request") {
                Text(call.request.url.absoluteString)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                HeadersView(headers: call.request.headers, redaction: redaction, reveal: reveal)
            }

            if let body = call.request.body, !body.isEmpty {
                Section("Request body") {
                    BodyView(data: body, truncated: false, redaction: redaction, reveal: reveal)
                }
            }

            if let response = call.response {
                Section("Response headers") {
                    HeadersView(headers: response.headers, redaction: redaction, reveal: reveal)
                }
                Section("Response body") {
                    BodyView(data: response.body, truncated: response.bodyTruncated, redaction: redaction, reveal: reveal)
                }
            } else if let error = call.errorCode {
                Section("Error") {
                    Text(error).font(.footnote.monospaced())
                }
            }
        }
        .navigationTitle(call.endpoint.template)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
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
                        Clipboard.copy(store.backend.curl(for: call, raw: true))
                    } label: {
                        Label("Copy as cURL with secrets", systemImage: "key")
                    }
                    Button {
                        if let url = try? store.backend.exportHAR([call]) { share = ShareItem(url: url) }
                    } label: {
                        Label("Share as HAR", systemImage: "square.and.arrow.up")
                    }
                    Divider()
                    Toggle(isOn: $reveal) {
                        Label("Show sensitive values", systemImage: "eye")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }
}
