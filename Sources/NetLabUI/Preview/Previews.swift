#if DEBUG
import NetLabCore
import SwiftUI

struct NetLabRootView_Previews: PreviewProvider {
    static var previews: some View {
        NetLabRootView(store: NetLabStore(backend: MockBackend()), onClose: {})
    }
}

struct CallDetailView_Previews: PreviewProvider {
    static var previews: some View {
        let store = NetLabStore(backend: MockBackend())
        return NavigationStack {
            CallDetailView(store: store, callID: store.snapshot.calls[0].id)
        }
    }
}

struct EndpointDetailView_Previews: PreviewProvider {
    static var previews: some View {
        let store = NetLabStore(backend: MockBackend())
        return NavigationStack {
            EndpointDetailView(store: store, key: store.snapshot.endpoints[2].key)
        }
    }
}

struct OverrideEditorView_Previews: PreviewProvider {
    static var previews: some View {
        let store = NetLabStore(backend: MockBackend())
        return OverrideEditorView(store: store, request: store.editorRequest(for: store.snapshot.endpoints[2].key))
    }
}
#endif
