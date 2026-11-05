import NetLabCore
import SwiftUI

public struct NetLabRootView: View {
    @ObservedObject var store: NetLabStore
    let onClose: () -> Void

    @State private var tab = Tab.traffic

    enum Tab {
        case traffic
        case endpoints
        case settings
    }

    public init(store: NetLabStore, onClose: @escaping () -> Void) {
        self.store = store
        self.onClose = onClose
    }

    public var body: some View {
        TabView(selection: $tab) {
            NavigationStack {
                TrafficView(store: store, onClose: onClose)
            }
            .tabItem { Label("Traffic", systemImage: "arrow.left.arrow.right") }
            .tag(Tab.traffic)

            NavigationStack {
                EndpointsView(store: store, onClose: onClose)
            }
            .tabItem { Label("Endpoints", systemImage: "square.stack.3d.up") }
            .badge(store.snapshot.armedCount)
            .tag(Tab.endpoints)

            NavigationStack {
                SettingsView(store: store, onClose: onClose)
            }
            .tabItem { Label("Settings", systemImage: "gearshape") }
            .tag(Tab.settings)
        }
    }
}
