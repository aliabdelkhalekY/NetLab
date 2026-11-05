#if DEBUG
import Foundation
import ObjectiveC

enum SessionSwizzler {
    private static var installed = false
    private static let lock = NSLock()

    static func install() {
        lock.lock()
        defer { lock.unlock() }
        guard !installed else { return }
        installed = true
        URLProtocol.registerClass(NetLabURLProtocol.self)
        exchange(NSSelectorFromString("defaultSessionConfiguration"), #selector(URLSessionConfiguration.netlab_defaultSessionConfiguration))
        exchange(NSSelectorFromString("ephemeralSessionConfiguration"), #selector(URLSessionConfiguration.netlab_ephemeralSessionConfiguration))
    }

    private static func exchange(_ original: Selector, _ replacement: Selector) {
        guard
            let originalMethod = class_getClassMethod(URLSessionConfiguration.self, original),
            let replacementMethod = class_getClassMethod(URLSessionConfiguration.self, replacement)
        else { return }
        method_exchangeImplementations(originalMethod, replacementMethod)
    }

    static func passThroughConfiguration(basedOn configuration: URLSessionConfiguration?) -> URLSessionConfiguration {
        let base = configuration ?? URLSessionConfiguration.default
        base.protocolClasses = (base.protocolClasses ?? []).filter { ObjectIdentifier($0) != ObjectIdentifier(NetLabURLProtocol.self) }
        return base
    }
}

extension URLSessionConfiguration {
    @objc class func netlab_defaultSessionConfiguration() -> URLSessionConfiguration {
        let configuration = netlab_defaultSessionConfiguration()
        configuration.netlab_insertProtocol()
        return configuration
    }

    @objc class func netlab_ephemeralSessionConfiguration() -> URLSessionConfiguration {
        let configuration = netlab_ephemeralSessionConfiguration()
        configuration.netlab_insertProtocol()
        return configuration
    }

    func netlab_insertProtocol() {
        var classes = protocolClasses ?? []
        guard !classes.contains(where: { ObjectIdentifier($0) == ObjectIdentifier(NetLabURLProtocol.self) }) else { return }
        classes.insert(NetLabURLProtocol.self, at: 0)
        protocolClasses = classes
    }
}
#endif
