import XCTest
#if SWIFT_PACKAGE
@testable import AutoDarkShiftCore
#endif

final class MessageSamplingTests: XCTestCase {
    @MainActor func testMessageInputUsesModelWithoutReportingOrRetimingPolling() throws {
        let store = MessageTestStore()
        let sampler = MessageTestSampler()
        let sink = MessageTestNotifications()
        let monitor = try SwitchMonitor(store: store, sampler: sampler, notifications: sink, pollingEnabled: false)
        try monitor.start()
        sampler.emit(0.02, time: 0.1)

        XCTAssertNil(monitor.snapshot.activePollInterval)
        XCTAssertNil(monitor.snapshot.lastPollAt)
        XCTAssertEqual(sampler.retimes, 0)
        XCTAssertEqual(monitor.snapshot.counters.eventCallbacks, 1)
        XCTAssertEqual(monitor.snapshot.counters.polls, 0)
        XCTAssertEqual(sink.targets, [.dark])
        XCTAssertNotNil(monitor.snapshot.trend)
    }

    @MainActor func testMessageSnapshotReflectsFinalBurstAndQueriesDoNotInventSamples() throws {
        let store = MessageTestStore()
        let sampler = MessageTestSampler()
        let monitor = try SwitchMonitor(store: store, sampler: sampler, notifications: MessageTestNotifications(),
                                        pollingEnabled: false)
        try monitor.start()
        sampler.emit(0.30, time: 0.1)
        sampler.emit(0.32, time: 0.2)
        let samples = monitor.snapshot.counters.samples
        let heartbeat = monitor.snapshot.heartbeatAt
        let trend = try XCTUnwrap(monitor.snapshot.trend)
        XCTAssertGreaterThan(trend.change, 0)
        XCTAssertEqual(monitor.statusReply().snapshot?.trend?.score, trend.score)
        XCTAssertEqual(monitor.snapshot.counters.samples, samples)
        XCTAssertEqual(monitor.snapshot.heartbeatAt, heartbeat)
    }

    @MainActor func testStoppedMessageRuntimeRejectsPreviouslyCapturedCallback() throws {
        let store = MessageTestStore()
        let sampler = MessageTestSampler()
        let sink = MessageTestNotifications()
        let monitor = try SwitchMonitor(store: store, sampler: sampler, notifications: sink, pollingEnabled: false)
        try monitor.start()
        let oldCallback = try XCTUnwrap(sampler.receive)
        let samples = monitor.snapshot.counters.samples
        var stopped = false
        monitor.stop(reason: "business_switch", finalPhase: .stopped) { stopped = true }
        oldCallback(sampler.reading(0.02, time: 0.1))
        XCTAssertTrue(stopped)
        XCTAssertEqual(monitor.snapshot.counters.samples, samples)
        XCTAssertEqual(sink.targets, [])
        XCTAssertNil(monitor.snapshot.heartbeatAt)
    }

    func testNewMessageStoreDefaultsOffWithoutChangingExistingConfiguration() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SharedStore(directory: directory)
        XCTAssertTrue(try store.configuration().isEnabled)
        XCTAssertFalse(try store.configuration(defaultValue: MonitorConfiguration(isEnabled: false)).isEnabled)
        let saved = MonitorConfiguration(revision: "existing", cooldown: 4, isEnabled: true)
        try store.saveConfiguration(saved)
        XCTAssertEqual(try store.configuration(defaultValue: MonitorConfiguration(isEnabled: false)), saved)
    }
}

private final class MessageTestStore: MonitorStore {
    var config = MonitorConfiguration(cooldown: 0)
    var savedSnapshot: RuntimeSnapshot?
    var savedHistory: SubmissionHistory?
    func configuration() throws -> MonitorConfiguration { config }
    func saveConfiguration(_ value: MonitorConfiguration) throws { config = value }
    func snapshot() throws -> RuntimeSnapshot? { savedSnapshot }
    func saveSnapshot(_ value: RuntimeSnapshot) throws { savedSnapshot = value }
    func history() throws -> SubmissionHistory? { savedHistory }
    func saveHistory(_ value: SubmissionHistory) throws { savedHistory = value }
    func append(_ record: LogRecord) throws {}
    func appendBoostTrace(id: String, records: [LogRecord], finished: Bool) throws {}
    func recoverBoostTraces(instanceID: String, at: Date) throws {}
}

@MainActor private final class MessageTestSampler: BrightnessSampling {
    var receive: ((BrightnessReading) -> Void)?
    var retimes = 0
    func start(interval: TimeInterval, receive: @escaping (BrightnessReading) -> Void) { self.receive = receive }
    func updateInterval(_ interval: TimeInterval) { retimes += 1 }
    func sampleNow(_ source: SampleSource) { receive?(reading(0.25, time: 0, source: source)) }
    func stop() { receive = nil }
    func reading(_ value: Double, time: Double, source: SampleSource = .event) -> BrightnessReading {
        BrightnessReading(value: value, source: source,
                          timestamp: Date(timeIntervalSince1970: 1_700_000_000 + time), uptime: time)
    }
    func emit(_ value: Double, time: Double) { receive?(reading(value, time: time)) }
}

@MainActor private final class MessageTestNotifications: ModeNotificationSubmitting {
    var targets: [DisplayMode] = []
    func authorization(_ completion: @escaping (Bool, String) -> Void) { completion(true, "test") }
    func submit(_ candidate: NotificationCandidate, source: SampleSource, completion: @escaping (Error?) -> Void) {
        targets.append(candidate.target)
        completion(nil)
    }
}
