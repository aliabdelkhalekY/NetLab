import Foundation

struct StoredEndpoint: Codable {
    var info: EndpointInfo
    var sample: RecordedRequest
    var schemas: [String: SchemaNode]
}

struct LearnedAPI: Codable {
    var version = 1
    var endpoints: [StoredEndpoint]
    var rules: GroupingRules
}

struct PinnedQueues: Codable {
    var queues: [OverrideQueue]
}

enum Persistence {
    static let learnedFile = "learned-api.json"
    static let presetsFile = "presets.json"
    static let savedFile = "saved-overrides.json"
    static let pinnedFile = "pinned.json"

    static var directory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        var url = base.appendingPathComponent("NetLab", isDirectory: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        }
        return url
    }

    static var exportDirectory: URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("NetLabExports", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func write<T: Encodable>(_ value: T, to name: String) {
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: directory.appendingPathComponent(name), options: [.atomic, .completeFileProtection])
    }

    static func read<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    static func remove(_ name: String) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
    }

    static func export<T: Encodable>(_ value: T, named name: String) throws -> URL {
        let url = exportDirectory.appendingPathComponent(name)
        try encoder.encode(value).write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
