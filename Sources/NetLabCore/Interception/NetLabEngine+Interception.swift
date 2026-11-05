import Foundation

extension NetLabEngine {
    public func startIntercepting() {
        #if DEBUG
        SessionSwizzler.install()
        isIntercepting = true
        #endif
    }

    public func stopIntercepting() {
        isIntercepting = false
    }
}
