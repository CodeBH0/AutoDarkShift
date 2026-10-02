import Foundation

enum DisplayMode: String, Codable, Equatable { case dark, light }
enum SampleSource: String, Codable { case event, poll, initial, wake }
enum RuntimePhase: String, Codable { case starting, running, sleeping, stopping, stopped, failed }
enum SubmissionResult: String, Codable { case submitting, success, failed, blocked, cancelled }

enum PollingBoost: String, Codable, CaseIterable {
    case off, hz5, hz10, hz20, hz30, hz60, hz120, hz240, hz500, hz1000

    var frequency: Double? {
        guard self != .off else { return nil }
        return Double(rawValue.dropFirst(2))
    }
    var title: String { frequency.map { "\(Int($0)) Hz" } ?? "关闭（使用采样间隔）" }
    static let testFrequencies: [Double] = [1] + allCases.compactMap(\.frequency)
    static let testStageDuration: TimeInterval = 10
}

struct MonitorConfiguration: Codable, Equatable {
    var revision = UUID().uuidString
    var darkThreshold: Double = 0.20
    var lightThreshold: Double = 0.28
    var pollInterval: TimeInterval = 1
    var stableDuration: TimeInterval = 1
    var cooldown: TimeInterval = 3
    /// Optional so configurations saved before Boost still decode without migration.
    var pollingBoost: PollingBoost?

    var effectivePollInterval: TimeInterval {
        pollingBoost?.frequency.map { 1 / $0 } ?? pollInterval
    }

    func validated() throws -> Self {
        guard darkThreshold.isFinite, lightThreshold.isFinite,
              0 <= darkThreshold, darkThreshold < lightThreshold, lightThreshold <= 1 else {
            throw ProjectError.message("阈值必须满足 0 ≤ 深色阈值 < 浅色阈值 ≤ 1。")
        }
        guard pollInterval.isFinite, pollInterval > 0,
              stableDuration.isFinite, stableDuration >= 0,
              cooldown.isFinite, cooldown >= 0 else {
            throw ProjectError.message("采样间隔必须为有限正数，稳定时间和冷却时间必须为有限非负数。")
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
    var schemaVersion = 1
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
    var stableSince: Date?
    var appliedConfiguration: MonitorConfiguration
    var counters: RuntimeCounters
    var lastError: String?
    var activePollInterval: TimeInterval?
    var pollingTestID: String?
}

enum MonitorCommand: String, Codable {
    case handshake, reloadConfiguration, queryStatus, exportDiagnostics, exportDiagnosticPage, startPollingTest, stopPollingTest
}

struct MonitorRequest: Codable {
    var command: MonitorCommand
    var expectedRevision: String?
    var configuration: MonitorConfiguration?
    var pollingTestID: String?
    var exportID: String?
    var exportOffset: Int?
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

/// Bounded in-memory measurements. Only timer reads enter these statistics, never brightness events.
struct PollingStatistics {
    let startedAt: TimeInterval
    let requestedInterval: TimeInterval
    private var lastPollAt: TimeInterval
    private var lastBrightness: Double?
    private var intervals: [Double] = []
    private(set) var polls = 0
    private var invalidReadings = 0
    private var brightnessChanges = 0
    private var estimatedMissedPolls = 0
    private var intervalTotal = 0.0
    private var intervalMin = Double.infinity
    private var intervalMax = 0.0
    private var readCount = 0
    private var readTotal = 0.0
    private var readMax = 0.0

    init(startedAt: TimeInterval, requestedInterval: TimeInterval) {
        self.startedAt = startedAt
        self.lastPollAt = startedAt
        self.requestedInterval = requestedInterval
    }

    mutating func add(_ reading: BrightnessReading, uptime: TimeInterval) {
        guard reading.source == .poll, uptime.isFinite, uptime >= lastPollAt else { return }
        let interval = uptime - lastPollAt
        lastPollAt = uptime
        polls += 1
        intervalTotal += interval
        intervalMin = min(intervalMin, interval)
        intervalMax = max(intervalMax, interval)
        if intervals.count < 20_000 { intervals.append(interval) }
        if interval > requestedInterval * 1.5 {
            let ratio = (interval / requestedInterval).rounded()
            if !ratio.isFinite || ratio >= Double(Int.max) { estimatedMissedPolls = Int.max }
            else {
                let (sum, overflow) = estimatedMissedPolls.addingReportingOverflow(max(0, Int(ratio) - 1))
                estimatedMissedPolls = overflow ? Int.max : sum
            }
        }
        if MonitorConfiguration.validBrightness(reading.value) {
            if let lastBrightness, lastBrightness != reading.value { brightnessChanges += 1 }
            lastBrightness = reading.value
        } else { invalidReadings += 1 }
        if let duration = reading.readDuration, duration.isFinite, duration >= 0 {
            readCount += 1
            readTotal += duration
            readMax = max(readMax, duration)
        }
    }

    func fields(endedAt: TimeInterval) -> [String: String] {
        let elapsed = max(0, endedAt - startedAt)
        let rate = elapsed > 0 ? Double(polls) / elapsed : 0
        let sorted = intervals.sorted()
        func percentile(_ fraction: Double) -> Double {
            sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))]
        }
        let p95 = percentile(0.95)
        // An empirical threshold for this runtime, not a system API contract or panel refresh limit.
        let sustained = polls > 0 && invalidReadings == 0 && readCount == polls
            && rate * requestedInterval >= 0.90 && p95 <= requestedInterval * 1.5
        return [
            "requestedHz": String(1 / requestedInterval), "elapsedSeconds": String(elapsed),
            "polls": String(polls), "actualHz": String(rate),
            "deliveryRatio": String(rate * requestedInterval),
            "intervalMeanMs": String(polls > 0 ? intervalTotal / Double(polls) * 1000 : 0),
            "intervalMinMs": String(polls > 0 ? intervalMin * 1000 : 0),
            "intervalMaxMs": String(intervalMax * 1000),
            "intervalP50Ms": String(percentile(0.50) * 1000),
            "intervalP95Ms": String(p95 * 1000), "intervalP99Ms": String(percentile(0.99) * 1000),
            "percentileSampleCount": String(sorted.count),
            "estimatedMissedPolls": String(estimatedMissedPolls),
            "invalidReadings": String(invalidReadings), "brightnessChanges": String(brightnessChanges),
            "apiReadCount": String(readCount),
            "apiReadMeanUs": String(readCount > 0 ? readTotal / Double(readCount) * 1_000_000 : 0),
            "apiReadMaxUs": String(readMax * 1_000_000), "sustained": String(sustained)
        ]
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
