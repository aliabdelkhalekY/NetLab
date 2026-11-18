import Foundation

extension NetLabEngine {
    public func startIntercepting() {
        SessionSwizzler.install()
        isIntercepting = true
    }

    public func stopIntercepting() {
        isIntercepting = false
    }
}
