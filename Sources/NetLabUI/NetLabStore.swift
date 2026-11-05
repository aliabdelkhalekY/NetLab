import Combine
import Foundation
import NetLabCore

@MainActor
public final class NetLabStore: ObservableObject {
    @Published public private(set) var snapshot: NetLabSnapshot
    public let backend: NetLabBackend
    private var cancellables = Set<AnyCancellable>()

    public init(backend: NetLabBackend) {
        self.backend = backend
        snapshot = backend.snapshot
        backend.updates
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.snapshot = $0 }
            .store(in: &cancellables)
    }

    func perform(_ action: NetLabAction) {
        backend.perform(action)
    }

    func call(_ id: UUID) -> Call? {
        snapshot.calls.first { $0.id == id }
    }

    func editorRequest(for call: Call) -> EditorRequest {
        if let response = call.response, call.report == nil || call.report?.notApplied == true {
            return EditorRequest(key: call.endpoint, statusCode: response.statusCode, headers: response.headers, body: response.body)
        }
        return editorRequest(for: call.endpoint)
    }

    func editorRequest(applying saved: SavedOverride) -> EditorRequest {
        var request = editorRequest(for: saved.endpoint)
        request.saved = saved
        return request
    }

    func editorRequest(for key: EndpointKey) -> EditorRequest {
        let variants = snapshot.endpoint(for: key)?.variants ?? []
        if let variant = variants.first(where: { (200..<300).contains($0.statusCode) }) ?? variants.first {
            return EditorRequest(key: key, statusCode: variant.statusCode, headers: variant.headers, body: variant.body)
        }
        return EditorRequest(key: key, statusCode: 200, headers: ["Content-Type": "application/json"], body: nil)
    }
}

struct EditorRequest: Identifiable {
    let id = UUID()
    var key: EndpointKey
    var statusCode: Int
    var headers: [String: String]
    var body: Data?
    var saved: SavedOverride?
}

struct ShareItem: Identifiable {
    let id = UUID()
    var url: URL
}
