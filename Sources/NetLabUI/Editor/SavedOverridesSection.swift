import NetLabCore
import SwiftUI

struct SavedOverridesSection: View {
    @ObservedObject var store: NetLabStore
    let key: EndpointKey
    let canEdit: (SavedOverride) -> Bool
    let onEdit: (SavedOverride) -> Void
    let onArmed: () -> Void

    private var items: [SavedOverride] { store.snapshot.saved(for: key) }

    var body: some View {
        if !items.isEmpty {
            Section {
                ForEach(items) { item in
                    Menu {
                        Button {
                            store.perform(.armSaved(item.id))
                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                            onArmed()
                        } label: {
                            Label("Arm again", systemImage: "wand.and.stars")
                        }
                        if canEdit(item) {
                            Button {
                                onEdit(item)
                            } label: {
                                Label("Adjust, then arm", systemImage: "slider.horizontal.3")
                            }
                        }
                        Button(role: .destructive) {
                            store.perform(.deleteSaved(item.id))
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    } label: {
                        SavedOverrideRow(item: item)
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Saved overrides")
            } footer: {
                Text("Every override you arm from the editor is saved here, and stays after a relaunch.")
            }
        }
    }
}

private struct SavedOverrideRow: View {
    let item: SavedOverride

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(item.override.changeSummaries, id: \.self) { summary in
                Text(summary)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(item.override.duration.title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
