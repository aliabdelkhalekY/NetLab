import NetLabCore
import SwiftUI

struct EndpointsView: View {
    @ObservedObject var store: NetLabStore
    let onClose: () -> Void

    @State private var search = ""

    private var endpoints: [EndpointInfo] {
        guard !search.isEmpty else { return store.snapshot.endpoints }
        return store.snapshot.endpoints.filter { "\($0.key.title) \($0.key.host)".localizedCaseInsensitiveContains(search) }
    }

    private var hosts: [String] {
        Array(Set(endpoints.map(\.key.host))).sorted()
    }

    private var armedQueues: [OverrideQueue] {
        store.snapshot.queues.filter { !$0.steps.isEmpty }
    }

    var body: some View {
        List {
            if !armedQueues.isEmpty {
                Section("Active overrides") {
                    ForEach(armedQueues) { queue in
                        NavigationLink(value: queue.endpoint) {
                            QueueSummaryRow(queue: queue)
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                store.perform(.clearQueue(queue.endpoint))
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            ForEach(hosts, id: \.self) { host in
                Section(host) {
                    ForEach(endpoints.filter { $0.key.host == host }) { endpoint in
                        NavigationLink(value: endpoint.key) {
                            EndpointRow(endpoint: endpoint, isArmed: store.snapshot.queue(for: endpoint.key)?.isArmed == true)
                        }
                    }
                }
            }
        }
        .overlay {
            if store.snapshot.endpoints.isEmpty {
                EmptyStateView(title: "No endpoints yet", message: "NetLab learns each endpoint the first time the app calls it.", systemImage: "square.stack.3d.up")
            }
        }
        .searchable(text: $search, prompt: "Path or host")
        .navigationTitle("Endpoints")
        .navigationDestination(for: EndpointKey.self) { key in
            EndpointDetailView(store: store, key: key)
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done", action: onClose)
            }
        }
    }
}

struct EndpointRow: View {
    let endpoint: EndpointInfo
    let isArmed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                MethodLabel(method: endpoint.key.method)
                Text(endpoint.key.template + (endpoint.key.discriminator.map { " · \($0)" } ?? ""))
                    .font(.subheadline)
                    .lineLimit(2)
                Spacer(minLength: 8)
                if isArmed {
                    Image(systemName: "wand.and.stars")
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Override armed")
                }
            }
            HStack(spacing: 8) {
                Text(endpoint.callCount == 1 ? "1 call" : "\(endpoint.callCount) calls")
                if let status = endpoint.lastStatus {
                    Text("Last \(status)").foregroundStyle(Format.statusColor(status))
                } else if let error = endpoint.lastError {
                    Text(error).foregroundStyle(.red)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

struct QueueSummaryRow: View {
    let queue: OverrideQueue

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                MethodLabel(method: queue.endpoint.method)
                Text(queue.endpoint.template).font(.subheadline).lineLimit(1)
            }
            Text(summary)
                .font(.caption)
                .foregroundStyle(queue.isArmed ? Color.orange : Color.secondary)
        }
    }

    private var summary: String {
        let next = queue.steps.first { $0.isEnabled && !$0.isUsedUp } ?? (queue.repeatLast ? queue.steps.last : nil)
        let applied = queue.steps.reduce(0) { $0 + $1.appliedCount }
        var parts: [String] = []
        if let next { parts.append("Next: \(next.title)") } else { parts.append("Paused") }
        if queue.steps.count > 1 { parts.append("\(queue.steps.count) steps") }
        if applied > 0 { parts.append("applied \(applied)×") }
        return parts.joined(separator: " · ")
    }
}
