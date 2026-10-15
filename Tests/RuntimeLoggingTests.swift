import XCTest
#if canImport(AutoDarkShiftCore)
@testable import AutoDarkShiftCore
#endif

final class RuntimeLoggingTests: XCTestCase {
    func testLoggingDefaultsOffAndOldConfigurationStillEnablesMonitoring() throws {
        let legacy = Data(#"{"revision":"old","cooldown":3}"#.utf8)
        let decoded = try SharedJSON.decoder().decode(MonitorConfiguration.self, from: legacy)
        XCTAssertTrue(decoded.isEnabled)
        XCTAssertFalse(decoded.runtimeLoggingEnabled)
        XCTAssertFalse(MonitorConfiguration().runtimeLoggingEnabled)
        let independent = MonitorConfiguration(isEnabled: false, runtimeLoggingEnabled: true)
        let roundTrip = try SharedJSON.decoder().decode(MonitorConfiguration.self,
                                                       from: SharedJSON.encoder().encode(independent))
        XCTAssertEqual(roundTrip, independent)
    }

    @MainActor func testLoggingOffStillSamplesSubmitsAndPersistsStatusAndHistory() throws {
        let fixture = try LoggingFixture()
        defer { fixture.removeFiles() }
        let monitor = try fixture.makeMonitor()
        try monitor.start()
        fixture.emit(0.20, after: 1)
        monitor.flushDiagnostics()
        XCTAssertEqual(fixture.sink.targets, [.dark])
        XCTAssertEqual(monitor.snapshot.counters.samples, 2)
        XCTAssertEqual(monitor.snapshot.counters.notificationSuccesses, 1)
        XCTAssertEqual(monitor.snapshot.activePollInterval ?? 0, 1.0 / 120, accuracy: 1e-12)
        XCTAssertEqual(try fixture.store.snapshot()?.counters.samples, 2)
        XCTAssertEqual(try fixture.store.history()?.target, .dark)
        XCTAssertTrue(monitor.snapshot.boostTraceIDs?.isEmpty == true)
        XCTAssertTrue(try fixture.logFiles().isEmpty)
    }

    @MainActor func testLoggingToggleWritesBothStreamsAndPreservesSamplingAndExistingFiles() throws {
        let fixture = try LoggingFixture(loggingEnabled: true)
        defer { fixture.removeFiles() }
        let monitor = try fixture.makeMonitor()
        try monitor.start()
        fixture.emit(0.20, after: 1)
        monitor.flushDiagnostics()
        let recorded = try fixture.logFiles()
        XCTAssertTrue(String(decoding: try XCTUnwrap(recorded["runtime-0.jsonl"]), as: UTF8.self)
            .contains("notification_result"))
        XCTAssertTrue(recorded.keys.contains { $0.hasPrefix("boost-trace-") })
        XCTAssertTrue(try fixture.store.boostTraceDiagnostics().contains("boost_trace_start"))

        let samples = monitor.snapshot.counters.samples
        let heartbeat = monitor.snapshot.heartbeatAt
        let baseline = monitor.snapshot.trend?.baseline
        let activeInterval = monitor.snapshot.activePollInterval
        try fixture.setLogging(false, monitor: monitor)
        XCTAssertEqual(fixture.sampler.starts, 1)
        XCTAssertEqual(fixture.sampler.stops, 0)
        XCTAssertEqual(monitor.snapshot.counters.samples, samples)
        XCTAssertEqual(monitor.snapshot.heartbeatAt, heartbeat)
        XCTAssertEqual(monitor.snapshot.trend?.baseline, baseline)
        XCTAssertEqual(monitor.snapshot.activePollInterval, activeInterval)
        XCTAssertTrue(monitor.snapshot.boostTraceIDs?.isEmpty == true)
        XCTAssertEqual(try fixture.logFiles(), recorded)

        fixture.emit(0.20, after: 1)
        fixture.emit(0.20, after: 0.31)
        monitor.flushDiagnostics()
        XCTAssertEqual(try fixture.logFiles(), recorded)
        XCTAssertEqual(try fixture.store.snapshot()?.counters.samples, samples + 2)
        XCTAssertFalse(try fixture.store.boostTraceDiagnostics().isEmpty)

        try fixture.setLogging(true, monitor: monitor)
        XCTAssertEqual(fixture.sampler.starts, 1)
        fixture.emit(0.40, after: 1)
        monitor.flushDiagnostics()
        XCTAssertGreaterThan(try fixture.logFiles()["runtime-0.jsonl"]?.count ?? 0,
                             recorded["runtime-0.jsonl"]?.count ?? 0)
        XCTAssertGreaterThan(try fixture.logFiles().keys.filter { $0.hasPrefix("boost-trace-") }.count,
                             recorded.keys.filter { $0.hasPrefix("boost-trace-") }.count)
        XCTAssertEqual(monitor.snapshot.counters.samples, samples + 3)
    }

    @MainActor func testLoggingOnlyReloadDoesNotCancelPendingNotificationAuthorization() throws {
        let fixture = try LoggingFixture(loggingEnabled: true)
        defer { fixture.removeFiles() }
        fixture.sink.holdAuthorization = true
        let monitor = try fixture.makeMonitor()
        try monitor.start()
        fixture.emit(0.20, after: 1)
        let authorize = try XCTUnwrap(fixture.sink.authorize)
        try fixture.setLogging(false, monitor: monitor)
        let recorded = try fixture.logFiles()
        authorize(true, "test")
        XCTAssertEqual(fixture.sink.targets, [.dark])
        XCTAssertEqual(monitor.snapshot.submission?.result, .success)
        XCTAssertEqual(try fixture.store.history()?.target, .dark)
        XCTAssertEqual(try fixture.logFiles(), recorded)
        XCTAssertEqual(fixture.sampler.starts, 1)
    }

    func testStoreGateCoversAppendsCachesAndOrphanRecoveryWithoutRemovingOldLogs() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SharedStore(directory: directory)
        let record = LogRecord(instanceID: "test", event: "retained")
        let traceID = UUID().uuidString
        try store.append(record)
        try store.appendBoostTrace(id: traceID, records: [record], finished: false)
        XCTAssertEqual(try Self.logFiles(in: directory).count, 0)
        store.setLoggingEnabled(true)
        try store.append(record)
        try store.appendBoostTrace(id: traceID, records: [record], finished: false)
        try store.saveProviderDiagnostics("{\"event\":\"provider\"}\n")
        let recorded = try Self.logFiles(in: directory)
        store.setLoggingEnabled(false)
        try store.append(record)
        try store.appendBoostTrace(id: traceID, records: [record], finished: true)
        try store.recoverBoostTraces(instanceID: "next-process", at: Date())
        try store.saveProviderDiagnostics("{\"event\":\"new-provider\"}\n")
        XCTAssertEqual(try Self.logFiles(in: directory), recorded)
        XCTAssertNotNil(try store.providerDiagnostics())
        XCTAssertFalse(try store.exportData(metadata: [:]).isEmpty)
        store.setLoggingEnabled(true)
        try store.append(record)
        try store.recoverBoostTraces(instanceID: "next-process", at: Date())
        XCTAssertGreaterThan(try Self.logFiles(in: directory)["runtime-0.jsonl"]?.count ?? 0,
                             recorded["runtime-0.jsonl"]?.count ?? 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath:
            directory.appendingPathComponent("boost-trace-\(traceID).jsonl").path))
    }

    fileprivate static func logFiles(in directory: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for path in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where path.pathExtension == "jsonl" {
            result[path.lastPathComponent] = try Data(contentsOf: path)
        }
        return result
    }
}

@MainActor private final class LoggingFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store: SharedStore
    let sampler = LoggingSampler()
    let sink = LoggingNotifications()
    var time: TimeInterval = 0
    var now: Date { Date(timeIntervalSince1970: 1_700_000_000 + time) }

    init(loggingEnabled: Bool = false) throws {
        store = try SharedStore(directory: directory)
        try store.saveConfiguration(MonitorConfiguration(cooldown: 0, runtimeLoggingEnabled: loggingEnabled))
    }
    func makeMonitor() throws -> SwitchMonitor {
        sampler.reading = { source in
            BrightnessReading(value: 0.40, source: source, timestamp: self.now, uptime: self.time)
        }
        return try SwitchMonitor(store: store, sampler: sampler, notifications: sink,
                                 clock: { self.now }, uptime: { self.time })
    }
    func emit(_ value: Double, after interval: TimeInterval) {
        time += interval
        sampler.receive?(BrightnessReading(value: value, source: .poll, timestamp: now, uptime: time))
    }
    func setLogging(_ enabled: Bool, monitor: SwitchMonitor) throws {
        var configuration = try store.configuration()
        configuration.runtimeLoggingEnabled = enabled
        configuration.revision = UUID().uuidString
        try store.saveConfiguration(configuration)
        XCTAssertTrue(monitor.reload(expectedRevision: configuration.revision).success)
    }
    func logFiles() throws -> [String: Data] { try RuntimeLoggingTests.logFiles(in: directory) }
    func removeFiles() { try? FileManager.default.removeItem(at: directory) }
}

@MainActor private final class LoggingSampler: BrightnessSampling {
    var receive: ((BrightnessReading) -> Void)?
    var reading: ((SampleSource) -> BrightnessReading)?
    var starts = 0
    var stops = 0
    func start(interval: TimeInterval, receive: @escaping (BrightnessReading) -> Void) {
        starts += 1
        self.receive = receive
    }
    func updateInterval(_ interval: TimeInterval) {}
    func sampleNow(_ source: SampleSource) { if let reading { receive?(reading(source)) } }
    func stop() { stops += 1; receive = nil }
}

@MainActor private final class LoggingNotifications: ModeNotificationSubmitting {
    var targets: [DisplayMode] = []
    var holdAuthorization = false
    var authorize: ((Bool, String) -> Void)?
    func authorization(_ completion: @escaping (Bool, String) -> Void) {
        if holdAuthorization { authorize = completion }
        else { completion(true, "test") }
    }
    func submit(_ candidate: NotificationCandidate, source: SampleSource, completion: @escaping (Error?) -> Void) {
        targets.append(candidate.target)
        completion(nil)
    }
}
