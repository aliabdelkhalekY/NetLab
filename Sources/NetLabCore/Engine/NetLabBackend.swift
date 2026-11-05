import Combine
import Foundation

public enum NetLabEvent {
    case overrideApplied(String)
}

public protocol NetLabBackend: AnyObject {
    var snapshot: NetLabSnapshot { get }
    var updates: AnyPublisher<NetLabSnapshot, Never> { get }
    var events: AnyPublisher<NetLabEvent, Never> { get }
    func perform(_ action: NetLabAction)
    func curl(for call: Call, raw: Bool) -> String
    func exportHAR(_ calls: [Call]) throws -> URL
    func exportLearnedAPI() throws -> URL
    func importLearnedAPI(from url: URL) throws
    func exportPreset(_ id: UUID) throws -> URL
    func importPreset(from url: URL) throws
}
