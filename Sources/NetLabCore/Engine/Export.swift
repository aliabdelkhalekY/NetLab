import Foundation

enum Export {
    static func curl(_ call: Call) -> String {
        let request = call.request
        var parts = ["curl", "-X", request.method, shellQuote(request.url.absoluteString)]
        for (name, value) in request.headers.sorted(by: { $0.key < $1.key }) {
            parts.append("-H")
            parts.append(shellQuote("\(name): \(value)"))
        }
        if let body = request.body, !body.isEmpty {
            parts.append("--data-raw")
            parts.append(shellQuote(String(decoding: body, as: UTF8.self)))
        }
        return parts.joined(separator: " ")
    }

    static func har(_ calls: [Call]) -> Data {
        let formatter = ISO8601DateFormatter()
        let entries: [[String: Any]] = calls.map { call in
            let request = call.request
            let response = call.response
            let query = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            var requestObject: [String: Any] = [
                "method": request.method,
                "url": request.url.absoluteString,
                "httpVersion": "HTTP/1.1",
                "headers": headerList(request.headers),
                "queryString": query.map { ["name": $0.name, "value": $0.value ?? ""] },
                "cookies": [],
                "headersSize": -1,
                "bodySize": request.body?.count ?? 0
            ]
            if let body = request.body {
                requestObject["postData"] = ["mimeType": request.headers["Content-Type"] ?? "application/octet-stream", "text": String(decoding: body, as: UTF8.self)]
            }
            let responseObject: [String: Any] = [
                "status": response?.statusCode ?? 0,
                "statusText": call.errorCode ?? "",
                "httpVersion": "HTTP/1.1",
                "headers": headerList(response?.headers ?? [:]),
                "cookies": [],
                "content": [
                    "size": response?.body?.count ?? 0,
                    "mimeType": response?.headers["Content-Type"] ?? "application/octet-stream",
                    "text": response?.body.map { String(decoding: $0, as: UTF8.self) } ?? ""
                ],
                "redirectURL": "",
                "headersSize": -1,
                "bodySize": response?.body?.count ?? 0
            ]
            let milliseconds = (call.duration ?? 0) * 1000
            return [
                "startedDateTime": formatter.string(from: call.startedAt),
                "time": milliseconds,
                "request": requestObject,
                "response": responseObject,
                "cache": [:],
                "timings": ["send": 0, "wait": milliseconds, "receive": 0],
                "comment": call.report?.summary ?? ""
            ]
        }
        let log: [String: Any] = ["log": ["version": "1.2", "creator": ["name": "NetLab", "version": "1.0"], "entries": entries]]
        return (try? JSONSerialization.data(withJSONObject: log, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    static func headerList(_ headers: [String: String]) -> [[String: String]] {
        headers.sorted { $0.key < $1.key }.map { ["name": $0.key, "value": $0.value] }
    }

    static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
