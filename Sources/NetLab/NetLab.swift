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
        #if DEBUG
        let engine = NetLabEngine.shared
        engine.configure(storage: configuration.storage, redaction: configuration.redaction)
        engine.startIntercepting()
        NetLabPresenter.shared.install(
            backend: engine,
            showsButton: configuration.entry.contains(.floatingButton),
            respondsToShake: configuration.entry.contains(.shake)
        )
        #endif
    }

    @MainActor
    public static func present() {
        #if DEBUG
        NetLabPresenter.shared.present()
        #endif
    }

    @MainActor
    public static func dismiss() {
        #if DEBUG
        NetLabPresenter.shared.dismiss()
        #endif
    }

    @MainActor
    public static func stop() {
        #if DEBUG
        NetLabEngine.shared.stopIntercepting()
        NetLabPresenter.shared.uninstall()
        #endif
    }

    public static func register(_ item: NetLabSwitch) {
        #if DEBUG
        NetLabEngine.shared.register(item)
        #endif
    }

    public static func value(of switchName: String) -> String? {
        #if DEBUG
        return NetLabEngine.shared.value(of: switchName)
        #else
        return nil
        #endif
    }
}
