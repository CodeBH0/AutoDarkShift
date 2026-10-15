import XCTest
#if canImport(AutoDarkShiftCore)
@testable import AutoDarkShiftCore
#endif

final class BackBoardBrightnessSamplerTests: XCTestCase {
    @MainActor func testProbeFeedsOnlyBackBoardValuesWithoutAnEventObserver() {
        let scheduler = ProbeTestScheduler()
        var records: [(String, [String: String])] = []
        var readings: [BrightnessReading] = []
        let sampler = BackBoardBrightnessSampler(scheduler: scheduler, read: { 0.125 },
            record: { records.append(($0, $1)) })
        sampler.start(interval: 1) { readings.append($0) }
        sampler.sampleNow(.initial)
        scheduler.tick?()
        sampler.sampleNow(.event)

        XCTAssertEqual(readings.map(\.value), [0.125, 0.125])
        XCTAssertEqual(readings.map(\.source), [.initial, .poll])
        XCTAssertNotNil(readings.first?.uptime)
        let fields = records.first { $0.0 == "backboard_brightness_sample" }?.1
        XCTAssertEqual(fields?["samplingMode"], "backboard_poll_only")
        XCTAssertEqual(records.first { $0.0 == "backboard_sampler_started" }?.1["observer"], "none")
        XCTAssertEqual(fields?["business"], "backboard")
    }

    @MainActor func testMissingGetterProducesDiagnosticWithoutFabricatingSample() {
        let scheduler = ProbeTestScheduler()
        var events: [String] = []
        var readings: [BrightnessReading] = []
        let sampler = BackBoardBrightnessSampler(scheduler: scheduler, read: { nil },
                                                record: { event, _ in events.append(event) })
        sampler.start(interval: 1) { readings.append($0) }
        sampler.sampleNow(.initial)
        scheduler.tick?()

        XCTAssertTrue(readings.isEmpty)
        XCTAssertTrue(events.contains("backboard_read_unavailable"))
        XCTAssertFalse(events.contains("backboard_brightness_sample"))
    }

    @MainActor func testInvalidGetterValueIsPreservedForModelValidation() {
        let scheduler = ProbeTestScheduler()
        var value: Float = .nan
        var readings: [BrightnessReading] = []
        let sampler = BackBoardBrightnessSampler(scheduler: scheduler, read: { value })
        sampler.start(interval: 1) { readings.append($0) }
        sampler.sampleNow(.initial)
        value = 1.25
        scheduler.tick?()
        value = -0.25
        scheduler.tick?()
        value = .infinity
        scheduler.tick?()

        XCTAssertTrue(readings[0].value.isNaN)
        XCTAssertEqual(readings[1].value, 1.25)
        XCTAssertEqual(readings[2].value, -0.25)
        XCTAssertEqual(readings[3].value, .infinity)
    }

    @MainActor func testStopAndRestartRejectCapturedOldTickAndDoNotReadWhileStopped() throws {
        let scheduler = ProbeTestScheduler()
        var reads = 0
        var readings: [BrightnessReading] = []
        let sampler = BackBoardBrightnessSampler(scheduler: scheduler, read: { reads += 1; return 0.25 })
        sampler.start(interval: 1) { readings.append($0) }
        let oldTick = try XCTUnwrap(scheduler.tick)
        sampler.stop()
        sampler.sampleNow(.wake)
        oldTick()
        sampler.start(interval: 1) { readings.append($0) }
        oldTick()
        XCTAssertEqual(reads, 0)
        scheduler.tick?()
        sampler.sampleNow(.wake)
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(readings.map(\.source), [.poll, .wake])
    }

    @MainActor func testDynamicRetimingPreservesCallbackAndRejectsPreviousTick() throws {
        let scheduler = ProbeTestScheduler()
        var readings: [BrightnessReading] = []
        let sampler = BackBoardBrightnessSampler(scheduler: scheduler, read: { 0.25 })
        sampler.start(interval: 1) { readings.append($0) }
        let oldTick = try XCTUnwrap(scheduler.tick)
        sampler.updateInterval(1.0 / 120)
        oldTick()
        XCTAssertTrue(readings.isEmpty)
        scheduler.tick?()
        XCTAssertEqual(readings.count, 1)
        XCTAssertEqual(scheduler.intervals, [1, 1.0 / 120])
        sampler.stop()
        sampler.updateInterval(1)
        XCTAssertEqual(scheduler.intervals.count, 2)
    }

    @MainActor func testBackBoardPollingFeedsProductionModelBoostAndNotification() throws {
        let fixture = BackBoardMonitorFixture()
        let monitor = try fixture.makeMonitor()
        try monitor.start()
        XCTAssertEqual(monitor.snapshot.sample?.source, .initial)
        XCTAssertEqual(monitor.snapshot.activePollInterval, 1)
        XCTAssertEqual(fixture.reads, 1)

        fixture.advance(1, brightness: 0.20)
        fixture.scheduler.tick?()
        XCTAssertEqual(monitor.snapshot.counters.polls, 1)
        XCTAssertEqual(monitor.snapshot.counters.eventCallbacks, 0)
        XCTAssertEqual(monitor.snapshot.sample?.brightness ?? 0, Double(Float(0.20)), accuracy: 1e-12)
        XCTAssertEqual(monitor.snapshot.activePollInterval ?? 0, 1.0 / 120, accuracy: 1e-12)
        XCTAssertEqual(fixture.scheduler.intervals, [1, 1.0 / 120])
        XCTAssertEqual(fixture.sink.targets, [.dark])
        XCTAssertEqual(monitor.snapshot.boostTraceIDs?.count, 1)
        XCTAssertTrue(fixture.store.traceRecords.contains { $0.event == "boost_trace_start" })
        XCTAssertTrue(fixture.store.traceRecords.contains {
            $0.event == "boost_trace_sample" && $0.fields["source"] == "poll"
        })

        fixture.advance(0.1, brightness: 0.19)
        fixture.scheduler.tick?()
        let reads = fixture.reads
        let samples = monitor.snapshot.counters.samples
        let heartbeat = monitor.snapshot.heartbeatAt
        let score = monitor.snapshot.trend?.score
        let intervals = fixture.scheduler.intervals
        _ = monitor.statusReply()
        _ = monitor.statusReply()
        XCTAssertEqual(fixture.reads, reads)
        XCTAssertEqual(monitor.snapshot.counters.samples, samples)
        XCTAssertEqual(monitor.snapshot.heartbeatAt, heartbeat)
        XCTAssertEqual(monitor.snapshot.trend?.score, score)
        XCTAssertEqual(fixture.scheduler.intervals, intervals)
    }

    @MainActor func testBackBoardSleepWakeAndStopRejectOldPollingWork() throws {
        let fixture = BackBoardMonitorFixture()
        let monitor = try fixture.makeMonitor()
        try monitor.start()
        let beforeSleepTick = try XCTUnwrap(fixture.scheduler.tick)
        let initialSamples = monitor.snapshot.counters.samples
        monitor.sleep()
        XCTAssertEqual(monitor.snapshot.phase, .sleeping)
        XCTAssertNil(monitor.snapshot.heartbeatAt)
        XCTAssertNil(monitor.snapshot.activePollInterval)
        fixture.advance(1, brightness: 0.20)
        beforeSleepTick()
        fixture.sampler.sampleNow(.poll)
        _ = monitor.statusReply()
        XCTAssertEqual(fixture.reads, 1)
        XCTAssertEqual(monitor.snapshot.counters.samples, initialSamples)

        monitor.wake()
        XCTAssertEqual(monitor.snapshot.phase, .running)
        XCTAssertEqual(monitor.snapshot.sample?.source, .wake)
        XCTAssertEqual(monitor.snapshot.counters.samples, initialSamples + 1)
        XCTAssertEqual(fixture.reads, 2)
        beforeSleepTick()
        XCTAssertEqual(fixture.reads, 2)
        let beforeStopTick = try XCTUnwrap(fixture.scheduler.tick)
        var stopped = false
        monitor.stop(reason: "business_switch", finalPhase: .stopped) { stopped = true }
        beforeStopTick()
        fixture.sampler.sampleNow(.wake)
        _ = monitor.statusReply()
        XCTAssertTrue(stopped)
        XCTAssertEqual(monitor.snapshot.phase, .stopped)
        XCTAssertEqual(fixture.reads, 2)
        XCTAssertNil(monitor.snapshot.heartbeatAt)
        XCTAssertNil(monitor.snapshot.activePollInterval)
    }

    @MainActor func testUnavailableBackBoardReadDoesNotInventModelInputOrHeartbeat() throws {
        let fixture = BackBoardMonitorFixture()
        fixture.brightness = nil
        let monitor = try fixture.makeMonitor()
        try monitor.start()
        fixture.advance(1, brightness: nil)
        fixture.scheduler.tick?()
        _ = monitor.statusReply()
        XCTAssertEqual(fixture.reads, 2)
        XCTAssertEqual(monitor.snapshot.counters.samples, 0)
        XCTAssertEqual(monitor.snapshot.counters.polls, 0)
        XCTAssertNil(monitor.snapshot.sample)
        XCTAssertNil(monitor.snapshot.heartbeatAt)
        XCTAssertTrue(fixture.sink.targets.isEmpty)
        XCTAssertTrue(fixture.samplerEvents.contains("backboard_read_unavailable"))
    }

    @MainActor func testInvalidBackBoardReadReachesProductionValidationWithoutClipping() throws {
        for invalid in [Float.nan, .infinity, -0.25, 1.25] {
            let fixture = BackBoardMonitorFixture()
            let monitor = try fixture.makeMonitor()
            try monitor.start()
            fixture.advance(1, brightness: invalid)
            fixture.scheduler.tick?()
            XCTAssertEqual(monitor.snapshot.counters.samples, 2)
            XCTAssertEqual(monitor.snapshot.counters.polls, 1)
            XCTAssertNil(monitor.snapshot.sample?.brightness)
            XCTAssertEqual(monitor.snapshot.sample?.rawValue, String(Double(invalid)))
            XCTAssertNotNil(monitor.snapshot.lastError)
            XCTAssertTrue(fixture.sink.targets.isEmpty)
        }
    }

    @MainActor func testBackBoardRuntimeStopWaitsForIssuedNotificationAndPersistsHistory() throws {
        let fixture = BackBoardMonitorFixture()
        fixture.sink.holdSubmission = true
        let monitor = try fixture.makeMonitor()
        try monitor.start()
        fixture.advance(1, brightness: 0.20)
        fixture.scheduler.tick?()
        let complete = try XCTUnwrap(fixture.sink.completeSubmission)
        let oldTick = try XCTUnwrap(fixture.scheduler.tick)
        var stopped = false
        monitor.stop(reason: "business_switch", finalPhase: .stopped) { stopped = true }
        XCTAssertFalse(stopped)
        XCTAssertEqual(monitor.snapshot.phase, .stopping)
        let reads = fixture.reads
        fixture.advance(1, brightness: 0.10)
        oldTick()
        XCTAssertEqual(fixture.reads, reads)
        complete(nil)
        XCTAssertTrue(stopped)
        XCTAssertEqual(monitor.snapshot.phase, .stopped)
        XCTAssertEqual(fixture.store.savedHistory?.target, .dark)
        XCTAssertEqual(monitor.snapshot.submission?.result, .success)
        XCTAssertNil(monitor.snapshot.heartbeatAt)
    }

    func testNewAppStoreDefaultsOffWithoutChangingExistingConfiguration() throws {
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

@MainActor private final class ProbeTestScheduler: PollingScheduler {
    var tick: (@MainActor () -> Void)?
    var intervals: [TimeInterval] = []
    func start(interval: TimeInterval, tick: @escaping @MainActor () -> Void) {
        intervals.append(interval)
        self.tick = tick
    }
    func stop() { tick = nil }
}


@MainActor private final class BackBoardMonitorFixture {
    let scheduler = ProbeTestScheduler()
    let store = BackBoardTestStore()
    let sink = BackBoardTestNotifications()
    var brightness: Float? = 0.40
    var time: TimeInterval = 0
    var reads = 0
    var samplerEvents: [String] = []
    var now: Date { Date(timeIntervalSince1970: 1_700_000_000 + time) }
    lazy var sampler = BackBoardBrightnessSampler(scheduler: scheduler,
        read: { self.reads += 1; return self.brightness },
        clock: { self.now }, uptime: { self.time },
        record: { event, _ in self.samplerEvents.append(event) })

    func advance(_ interval: TimeInterval, brightness: Float?) {
        time += interval
        self.brightness = brightness
    }
    func makeMonitor() throws -> SwitchMonitor {
        try SwitchMonitor(store: store, sampler: sampler, notifications: sink,
                          clock: { self.now }, uptime: { self.time })
    }
}

private final class BackBoardTestStore: MonitorStore {
    var config = MonitorConfiguration(cooldown: 0)
    var savedSnapshot: RuntimeSnapshot?
    var savedHistory: SubmissionHistory?
    var records: [LogRecord] = []
    var traceRecords: [LogRecord] = []
    func configuration() throws -> MonitorConfiguration { config }
    func saveConfiguration(_ value: MonitorConfiguration) throws { config = value }
    func snapshot() throws -> RuntimeSnapshot? { savedSnapshot }
    func saveSnapshot(_ value: RuntimeSnapshot) throws { savedSnapshot = value }
    func history() throws -> SubmissionHistory? { savedHistory }
    func saveHistory(_ value: SubmissionHistory) throws { savedHistory = value }
    func append(_ record: LogRecord) throws { records.append(record) }
    func appendBoostTrace(id: String, records: [LogRecord], finished: Bool) throws { traceRecords += records }
    func recoverBoostTraces(instanceID: String, at: Date) throws {}
}

@MainActor private final class BackBoardTestNotifications: ModeNotificationSubmitting {
    var targets: [DisplayMode] = []
    var holdSubmission = false
    var completeSubmission: ((Error?) -> Void)?
    func authorization(_ completion: @escaping (Bool, String) -> Void) { completion(true, "test") }
    func submit(_ candidate: NotificationCandidate, source: SampleSource, completion: @escaping (Error?) -> Void) {
        targets.append(candidate.target)
        if holdSubmission { completeSubmission = completion }
        else { completion(nil) }
    }
}
