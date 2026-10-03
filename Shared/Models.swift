import Foundation

enum DisplayMode: String, Codable, Equatable { case dark, light }
enum SampleSource: String, Codable { case event, poll, initial, wake }
enum RuntimePhase: String, Codable { case starting, running, sleeping, stopping, stopped, failed }
enum SubmissionResult: String, Codable { case submitting, success, failed, blocked, cancelled }

struct MonitorConfiguration: Codable, Equatable {
    var revision = UUID().uuidString
    var cooldown: TimeInterval = 3
    func validated() throws -> Self {
        guard cooldown.isFinite, cooldown >= 0 else {
            throw ProjectError.message("通知冷却时间必须为有限非负数。")
        }
        return self
    }

    static func validBrightness(_ value: Double) -> Bool {
        value.isFinite && (0...1).contains(value)
    }
}

struct SubmissionHistory: Codable, Equatable {
    var target: DisplayMode
    var submittedAt: Date
}

struct RuntimeCounters: Codable {
    var eventCallbacks: UInt64 = 0
    var polls: UInt64 = 0
    var samples: UInt64 = 0
    /// Number of calls to UNUserNotificationCenter.add; permission blocks do not count.
    var notificationAttempts: UInt64 = 0
    var notificationSuccesses: UInt64 = 0
    var extensionStarts: UInt64 = 0
}

struct SampleSnapshot: Codable {
    var timestamp: Date
    var source: SampleSource
    /// Invalid values have no numeric brightness; rawValue preserves the actual API result.
    var brightness: Double?
    var rawValue: String
    var sequence: UInt64
    var actualInterval: TimeInterval?
}

struct SubmissionSnapshot: Codable {
    var identifier: String
    var target: DisplayMode
    var brightness: Double
    var source: SampleSource
    var timestamp: Date
    var result: SubmissionResult
    var detail: String?
}

struct RuntimeSnapshot: Codable {
    var schemaVersion = 3
    var instanceID: String
    var phase: RuntimePhase = .starting
    var updatedAt = Date()
    var heartbeatAt: Date?
    var lastPollAt: Date?
    var lastPollInterval: TimeInterval?
    var sample: SampleSnapshot?
    var submission: SubmissionSnapshot?
    var history: SubmissionHistory?
    var desiredTarget: DisplayMode?
    var pendingTarget: DisplayMode?
    var trend: BrightnessTrendSnapshot?
    var appliedConfiguration: MonitorConfiguration
    var counters: RuntimeCounters
    var lastError: String?
    var activePollInterval: TimeInterval?
    /// Independent full-resolution diagnostic captures; ordinary logs remain throttled.
    var boostTraceIDs: [String]?
}

enum MonitorCommand: String, Codable {
    case handshake, reloadConfiguration, queryStatus, exportDiagnostics, exportDiagnosticPage
}

enum MonitorLogStream: String, Codable, CaseIterable { case runtime, boost }

struct MonitorRequest: Codable {
    var command: MonitorCommand
    var expectedRevision: String?
    var configuration: MonitorConfiguration?
    var exportID: String?
    var exportOffset: Int?
    var exportStream: MonitorLogStream?
}

struct MonitorReply: Codable {
    var success: Bool
    var message: String
    var appliedRevision: String?
    var snapshot: RuntimeSnapshot?
    var identity: RuntimeIdentity?
    var diagnostics: String?
    var diagnosticPage: Data?
    var exportID: String?
    var exportNextOffset: Int?
    var exportTotalBytes: Int?
    var exportStream: MonitorLogStream?
}

/// The control channel verifies the running process, rather than trusting VPN status.
struct RuntimeIdentity: Codable, Equatable {
    static let currentProtocolVersion = 3
    static let currentStorageMode = "app-group-v1"
    var protocolVersion = currentProtocolVersion
    var storageMode = currentStorageMode
    var bundleIdentifier: String
    var buildVersion: String
    var appGroupIdentifier: String

    static func installed(in bundle: Bundle = .main, storageMode: RuntimeStorageMode = .appGroup) -> Self {
        RuntimeIdentity(storageMode: storageMode.rawValue, bundleIdentifier: bundle.bundleIdentifier ?? "missing",
                        buildVersion: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "missing",
                        appGroupIdentifier: bundle.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String ?? "missing")
    }

    func validate(against expected: RuntimeIdentity) throws {
        guard self == expected else {
            throw ProjectError.message("运行中的扩展与当前 App 不兼容。请停止 VPN，安装本次构建的 App 与扩展后重启。期望 \(expected)，实际 \(self)。")
        }
    }
}

struct LogRecord: Codable {
    var timestamp = Date()
    var instanceID: String
    var event: String
    var fields: [String: String] = [:]
}

enum BoostTraceEncoding {
    static let sampleColumns = "sequence,unixSeconds,uptime,brightness,source,requestedHz,nextHz,S,baseline,filteredBrightness,velocity"
    /// The start/end records frame an entire capture; samples contain no repeated identity or constants.
    static func encode(_ record: LogRecord) throws -> Data {
        guard record.event == "boost_trace_sample" else { return try SharedJSON.encoder().encode(record) }
        func number(_ key: String) -> Any {
            guard let text = record.fields[key], let value = Double(text), value.isFinite else { return NSNull() }
            return value
        }
        let source = ["initial": 0, "poll": 1, "event": 2, "wake": 3][record.fields["source"] ?? ""]
        let sequence: Any = record.fields["sequence"].flatMap(UInt64.init).map { NSNumber(value: $0) } ?? NSNull()
        var object: [String: Any] = ["s": [sequence, record.timestamp.timeIntervalSince1970, number("uptime"),
            number("brightness"), source.map { $0 as Any } ?? NSNull(), number("requestedFrequency"),
            number("nextFrequency"), number("S"), number("baseline"), number("filteredBrightness"), number("velocity")]]
        if record.fields["stateChanged"] == "true" {
            func target(_ key: String) -> Int { ["none": 0, "dark": 1, "light": 2][record.fields[key] ?? "none"] ?? 0 }
            object["n"] = ["d": target("desiredTarget"), "p": target("pendingTarget"),
                "c": record.fields["candidateID"] == "none" ? NSNull() : (record.fields["candidateID"] as Any? ?? NSNull()),
                "f": record.fields["inFlightID"] == "none" ? NSNull() : (record.fields["inFlightID"] as Any? ?? NSNull())]
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed])
    }

}

enum ProjectError: LocalizedError, CustomNSError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let message): return message }
    }
    static var errorDomain: String { "AutoDarkShift" }
    var errorCode: Int { 1 }
    var errorUserInfo: [String: Any] { [NSLocalizedDescriptionKey: errorDescription ?? "未知错误"] }
}

func describeError(_ error: Error) -> String {
    let value = error as NSError
    return "\(value.domain) (\(value.code)): \(value.localizedDescription); info=\(value.userInfo)"
}

enum SharedJSON {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: string) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: string) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO-8601 timestamp")
        }
        return decoder
    }
}
