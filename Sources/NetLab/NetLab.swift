@_exported import NetLabCore
import NetLabUI
import UIKit

public enum NetLab {
    public struct Entry: OptionSet {
        public let rawValue: Int

        public init(rawValue: Int) {
            self.rawValue = rawValue
        }

        public static let floatingButton = Entry(rawValue: 1 << 0)
        public static let shake = Entry(rawValue: 1 << 1)
    }

    public struct Configuration {
        public var entry: Entry
        public var redaction: Redaction
        public var storage: Storage

        public init(entry: Entry = [.floatingButton, .shake], redaction: Redaction = .default, storage: Storage = .memory) {
            self.entry = entry
            self.redaction = redaction
            self.storage = storage
        }
    }

    @MainActor
    public static func start(_ configuration: Configuration = Configuration()) {
        let engine = NetLabEngine.shared
        engine.configure(storage: configuration.storage, redaction: configuration.redaction)
        engine.startIntercepting()
        NetLabPresenter.shared.install(
            backend: engine,
            showsButton: configuration.entry.contains(.floatingButton),
            respondsToShake: configuration.entry.contains(.shake)
        )
    }

    @MainActor
    public static func present() {
        NetLabPresenter.shared.present()
    }

    @MainActor
    public static func dismiss() {
        NetLabPresenter.shared.dismiss()
    }

    @MainActor
    public static func stop() {
        NetLabEngine.shared.stopIntercepting()
        NetLabPresenter.shared.uninstall()
    }

    public static func register(_ item: NetLabSwitch) {
        NetLabEngine.shared.register(item)
    }

    public static func value(of switchName: String) -> String? {
        NetLabEngine.shared.value(of: switchName)
    }
}
