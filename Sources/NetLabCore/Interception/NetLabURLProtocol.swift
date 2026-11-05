#if DEBUG
import Foundation

final class NetLabURLProtocol: URLProtocol, URLSessionDataDelegate {
    static let handledKey = "NetLab.handled"
    static let maxRequestBody = 20_000_000

    private var engine: NetLabEngine { NetLabEngine.shared }
    private let lock = NSLock()
    private var clientRunLoop: CFRunLoop?
    private var plan: NetLabEngine.Plan?
    private var session: URLSession?
    private var dataTask: URLSessionDataTask?
    private var realResponse: HTTPURLResponse?
    private var realData = Data()
    private var pending: [DispatchWorkItem] = []
    private var isStopped = false
    private var isFinished = false

    override class func canInit(with request: URLRequest) -> Bool {
        guard NetLabEngine.shared.isIntercepting, let scheme = request.url?.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        return URLProtocol.property(forKey: handledKey, in: request) == nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        clientRunLoop = CFRunLoopGetCurrent()
        let body = Self.body(of: request)
        let recorded = RecordedRequest(
            method: request.httpMethod ?? "GET",
            url: request.url ?? URL(fileURLWithPath: "/"),
            headers: mergedHeaders(),
            body: body
        )
        let plan = engine.begin(recorded)
        self.plan = plan
        let delay = plan.override?.delay ?? 0

        switch plan.override?.action {
        case .failure(.offline)?:
            schedule(after: max(delay, 0.05)) { self.fail(URLError(.notConnectedToInternet), report: self.report()) }
        case .failure(.timeout)?:
            let timeout = request.timeoutInterval > 0 ? request.timeoutInterval : 60
            schedule(after: timeout + delay) { self.fail(URLError(.timedOut), report: self.report()) }
        case let .replace(statusCode, headers, replacement)?:
            schedule(after: delay) { self.deliver(statusCode: statusCode, headers: headers, body: replacement ?? Data(), report: self.report()) }
        case let .status(statusCode, .empty)?:
            schedule(after: delay) { self.deliver(statusCode: statusCode, headers: ["Content-Type": "application/json"], body: Data(), report: self.report()) }
        default:
            startRealRequest(body: body)
        }
    }

    override func stopLoading() {
        lock.lock()
        isStopped = true
        let items = pending
        pending.removeAll()
        lock.unlock()
        items.forEach { $0.cancel() }
        dataTask?.cancel()
        session?.invalidateAndCancel()
        session = nil
        if let plan, markFinished() {
            if plan.override?.action.needsRealCall == true { engine.release(plan) }
            engine.finish(plan, response: nil, errorCode: "cancelled", report: nil)
        }
    }

    // MARK: Real request

    private var originalSession: URLSession? {
        guard let task, task.responds(to: NSSelectorFromString("session")) else { return nil }
        return task.value(forKey: "session") as? URLSession
    }

    private func mergedHeaders() -> [String: String] {
        var headers: [String: String] = [:]
        for (key, value) in originalSession?.configuration.httpAdditionalHeaders ?? [:] {
            if let key = key as? String { headers[key] = String(describing: value) }
        }
        for (key, value) in request.allHTTPHeaderFields ?? [:] { headers[key] = value }
        return headers
    }

    private func startRealRequest(body: Data?) {
        guard let mutable = (request as NSURLRequest).mutableCopy() as? NSMutableURLRequest else { return }
        URLProtocol.setProperty(true, forKey: Self.handledKey, in: mutable)
        if mutable.httpBodyStream != nil {
            mutable.httpBodyStream = nil
            mutable.httpBody = body
        }
        let configuration = SessionSwizzler.passThroughConfiguration(basedOn: originalSession?.configuration)
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        let task = session.dataTask(with: mutable as URLRequest)
        dataTask = task
        task.resume()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        realResponse = response as? HTTPURLResponse
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        realData.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let sender = ChallengeForwarder(completionHandler)
        let forwarded = URLAuthenticationChallenge(authenticationChallenge: challenge, sender: sender)
        onClient { client in client.urlProtocol(self, didReceive: forwarded) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        session.finishTasksAndInvalidate()
        self.session = nil
        lock.lock()
        let stopped = isStopped
        lock.unlock()
        guard let plan, !stopped else { return }
        if let error {
            if plan.override?.action.needsRealCall == true { engine.release(plan) }
            let report = plan.override.map { OverrideReport(overrideID: $0.id, title: $0.title, notApplied: true) }
            fail(error, report: report)
            return
        }
        guard let http = realResponse else {
            fail(URLError(.badServerResponse), report: nil)
            return
        }
        let headers = Self.stringHeaders(http.allHeaderFields)
        let recorded = RecordedResponse(statusCode: http.statusCode, headers: headers, body: realData)
        engine.learn(plan, response: recorded)
        applyOverride(to: recorded)
    }

    // MARK: Overrides on a real response

    private func applyOverride(to real: RecordedResponse) {
        guard let plan, let override = plan.override else {
            deliver(statusCode: real.statusCode, headers: real.headers, body: real.body ?? Data(), report: nil, overridden: false)
            return
        }
        let delay = override.delay ?? 0
        let body = real.body ?? Data()

        switch override.action {
        case let .changes(operations, statusCode):
            guard (200..<300).contains(real.statusCode) else {
                engine.release(plan)
                deliver(statusCode: real.statusCode, headers: real.headers, body: body, report: OverrideReport(overrideID: override.id, title: override.title, notApplied: true), overridden: false)
                return
            }
            var applied: [String] = []
            var skipped: [String] = operations.map(\.summary)
            var newBody = body
            if let json = try? JSONValue(data: body) {
                let result = JSONPatch.apply(operations, to: json)
                newBody = result.value.data()
                applied = result.applied.map(\.summary)
                skipped = result.skipped.map(\.summary)
            }
            if let statusCode, statusCode != real.statusCode { applied.insert("status: \(real.statusCode) → \(statusCode)", at: 0) }
            let report = OverrideReport(overrideID: override.id, title: override.title, applied: applied, skipped: skipped)
            schedule(after: delay) { self.deliver(statusCode: statusCode ?? real.statusCode, headers: real.headers, body: newBody, report: report) }
        case let .status(statusCode, _):
            schedule(after: delay) { self.deliver(statusCode: statusCode, headers: real.headers, body: body, report: self.report()) }
        case let .failure(kind):
            applyFailure(kind, to: real, delay: delay)
        case let .replace(statusCode, headers, replacement):
            schedule(after: delay) { self.deliver(statusCode: statusCode, headers: headers, body: replacement ?? Data(), report: self.report()) }
        }
    }

    private func applyFailure(_ kind: FailureKind, to real: RecordedResponse, delay: Double) {
        let body = real.body ?? Data()
        switch kind {
        case let .slow(seconds):
            schedule(after: seconds + delay) { self.deliver(statusCode: real.statusCode, headers: real.headers, body: body, report: self.report()) }
        case .connectionLost:
            schedule(after: delay) { self.loseConnection(real) }
        case let .brokenBody(broken):
            let newBody: Data
            switch broken {
            case .invalidJSON: newBody = Data("{\"netlab\": broken".utf8) + body.prefix(64)
            case .truncated: newBody = body.prefix(body.count / 2)
            case .emptyBody: newBody = Data()
            }
            schedule(after: delay) { self.deliver(statusCode: real.statusCode, headers: real.headers, body: newBody, report: self.report()) }
        case let .removeField(pointer):
            let operation = PatchOperation(kind: .remove, path: JSONPatch.pointer(pointer))
            schedule(after: delay) { self.deliverPatched(real, operations: [operation]) }
        case let .wrongType(pointer):
            let path = JSONPatch.pointer(pointer)
            guard let json = try? JSONValue(data: body), let current = JSONPatch.value(at: path, in: json) else {
                schedule(after: delay) { self.deliverPatched(real, operations: [PatchOperation(kind: .replace, path: path, value: .string("netlab"))]) }
                return
            }
            let wrong: JSONValue
            switch current {
            case .string: wrong = .int(0)
            case .int, .double: wrong = .string("netlab")
            case .bool: wrong = .string("true")
            case .null: wrong = .int(0)
            case .array, .object: wrong = .string("")
            }
            schedule(after: delay) { self.deliverPatched(real, operations: [PatchOperation(kind: .replace, path: path, value: wrong, oldValue: current)]) }
        case .offline, .timeout:
            deliver(statusCode: real.statusCode, headers: real.headers, body: body, report: nil, overridden: false)
        }
    }

    private func deliverPatched(_ real: RecordedResponse, operations: [PatchOperation]) {
        guard let override = plan?.override else { return }
        let body = real.body ?? Data()
        guard let json = try? JSONValue(data: body) else {
            deliver(statusCode: real.statusCode, headers: real.headers, body: body, report: OverrideReport(overrideID: override.id, title: override.title, skipped: operations.map(\.summary)))
            return
        }
        let result = JSONPatch.apply(operations, to: json)
        let report = OverrideReport(overrideID: override.id, title: override.title, applied: result.applied.map(\.summary), skipped: result.skipped.map(\.summary))
        deliver(statusCode: real.statusCode, headers: real.headers, body: result.value.data(), report: report)
    }

    private func loseConnection(_ real: RecordedResponse) {
        guard let plan, let url = request.url, markFinished() else { return }
        let body = real.body ?? Data()
        let partial = body.prefix(max(body.count / 2, 1))
        var headers = Self.cleaned(real.headers)
        headers["Content-Length"] = String(body.count)
        let response = HTTPURLResponse(url: url, statusCode: real.statusCode, httpVersion: "HTTP/1.1", headerFields: headers)
        onClient { client in
            if let response { client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed) }
            if !partial.isEmpty { client.urlProtocol(self, didLoad: Data(partial)) }
            client.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
        }
        engine.finish(plan, response: RecordedResponse(statusCode: real.statusCode, headers: headers, body: Data(partial)), errorCode: Self.errorName(URLError(.networkConnectionLost)), report: report())
    }

    // MARK: Delivery

    private func report() -> OverrideReport? {
        plan?.override.map { OverrideReport(overrideID: $0.id, title: $0.title, applied: [$0.title]) }
    }

    private func deliver(statusCode: Int, headers: [String: String], body: Data, report: OverrideReport?, overridden: Bool = true) {
        guard let plan, let url = request.url, markFinished() else { return }
        var cleanedHeaders = Self.cleaned(headers)
        cleanedHeaders["Content-Length"] = String(body.count)
        let response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: cleanedHeaders)
        onClient { client in
            if let response { client.urlProtocol(self, didReceive: response, cacheStoragePolicy: overridden ? .notAllowed : .allowed) }
            if !body.isEmpty { client.urlProtocol(self, didLoad: body) }
            client.urlProtocolDidFinishLoading(self)
        }
        engine.finish(plan, response: RecordedResponse(statusCode: statusCode, headers: cleanedHeaders, body: body), errorCode: nil, report: report)
    }

    private func fail(_ error: Error, report: OverrideReport?) {
        guard let plan, markFinished() else { return }
        onClient { client in client.urlProtocol(self, didFailWithError: error) }
        engine.finish(plan, response: nil, errorCode: Self.errorName(error), report: report)
    }

    private func markFinished() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else { return false }
        isFinished = true
        return true
    }

    private func schedule(after seconds: Double, _ work: @escaping () -> Void) {
        let item = DispatchWorkItem(block: work)
        lock.lock()
        let stopped = isStopped
        if !stopped { pending.append(item) }
        lock.unlock()
        guard !stopped else { return }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + max(seconds, 0), execute: item)
    }

    private func onClient(_ work: @escaping (URLProtocolClient) -> Void) {
        guard let runLoop = clientRunLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [weak self] in
            guard let self, let client = self.client else { return }
            work(client)
        }
        CFRunLoopWakeUp(runLoop)
    }

    // MARK: Helpers

    static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 16_384
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable, data.count < maxRequestBody {
            let read = stream.read(buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    static func stringHeaders(_ headers: [AnyHashable: Any]) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in headers {
            if let key = key as? String { result[key] = String(describing: value) }
        }
        return result
    }

    static func cleaned(_ headers: [String: String]) -> [String: String] {
        headers.filter { key, _ in
            let name = key.lowercased()
            return name != "content-encoding" && name != "content-length" && name != "transfer-encoding"
        }
    }

    static func errorName(_ error: Error) -> String {
        guard let urlError = error as? URLError else {
            let nsError = error as NSError
            return "\(nsError.domain) \(nsError.code)"
        }
        switch urlError.code {
        case .notConnectedToInternet: return "notConnectedToInternet"
        case .timedOut: return "timedOut"
        case .networkConnectionLost: return "networkConnectionLost"
        case .cancelled: return "cancelled"
        case .cannotFindHost: return "cannotFindHost"
        case .cannotConnectToHost: return "cannotConnectToHost"
        case .secureConnectionFailed: return "secureConnectionFailed"
        case .serverCertificateUntrusted: return "serverCertificateUntrusted"
        case .badServerResponse: return "badServerResponse"
        default: return "URLError \(urlError.code.rawValue)"
        }
    }
}

final class ChallengeForwarder: NSObject, URLAuthenticationChallengeSender {
    private let completion: (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    private var isDone = false

    init(_ completion: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        self.completion = completion
    }

    private func finish(_ disposition: URLSession.AuthChallengeDisposition, _ credential: URLCredential?) {
        guard !isDone else { return }
        isDone = true
        completion(disposition, credential)
    }

    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) { finish(.useCredential, credential) }
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) { finish(.useCredential, nil) }
    func cancel(_ challenge: URLAuthenticationChallenge) { finish(.cancelAuthenticationChallenge, nil) }
    func performDefaultHandling(for challenge: URLAuthenticationChallenge) { finish(.performDefaultHandling, nil) }
    func rejectProtectionSpaceAndContinue(with challenge: URLAuthenticationChallenge) { finish(.rejectProtectionSpace, nil) }
}
#endif
