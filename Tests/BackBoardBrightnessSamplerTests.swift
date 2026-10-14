import XCTest
#if canImport(AutoDarkShiftCore)
@testable import AutoDarkShiftCore
#endif

final class BackBoardBrightnessSamplerTests: XCTestCase {
    @MainActor func testProbeFeedsOnlyBackBoardValueAndKeepsUIKitAsDiagnostic() {
        let scheduler = ProbeTestScheduler()
        var records: [(String, [String: String])] = []
        var readings: [BrightnessReading] = []
        let sampler = BackBoardBrightnessSampler(scheduler: scheduler, read: { 0.125 }, reference: { 0.75 },
            record: { records.append(($0, $1)) })
        sampler.start(interval: 1) { readings.append($0) }
        sampler.sampleNow(.initial)
        scheduler.tick?()
        sampler.sampleNow(.event)

        XCTAssertEqual(readings.map(\.value), [0.125, 0.125])
        XCTAssertEqual(readings.map(\.source), [.initial, .poll])
        XCTAssertNotNil(readings.first?.uptime)
        let fields = records.first { $0.0 == "backboard_brightness_sample" }?.1
        XCTAssertEqual(fields?["uiKitBrightness"], "0.75")
        XCTAssertEqual(fields?["difference"], "-0.625")
        XCTAssertEqual(fields?["business"], "backboard")
    }

    @MainActor func testMissingGetterProducesDiagnosticWithoutFabricatingSample() {
        let scheduler = ProbeTestScheduler()
        var events: [String] = []
        var readings: [BrightnessReading] = []
        let sampler = BackBoardBrightnessSampler(scheduler: scheduler, read: { nil }, reference: { 0.8 },
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
        let sampler = BackBoardBrightnessSampler(scheduler: scheduler, read: { value }, reference: { 0.5 })
        sampler.start(interval: 1) { readings.append($0) }
        sampler.sampleNow(.initial)
        value = 1.25
        scheduler.tick?()

        XCTAssertTrue(readings[0].value.isNaN)
        XCTAssertEqual(readings[1].value, 1.25)
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

    @MainActor func testDynamicRetimingPreservesCallbackAndDoesNotInventReadings() {
        let scheduler = ProbeTestScheduler()
        var readings: [BrightnessReading] = []
        let sampler = BackBoardBrightnessSampler(scheduler: scheduler, read: { 0.25 })
        sampler.start(interval: 1) { readings.append($0) }
        sampler.updateInterval(1.0 / 120)
        XCTAssertTrue(readings.isEmpty)
        scheduler.tick?()
        XCTAssertEqual(readings.count, 1)
        XCTAssertEqual(scheduler.intervals, [1, 1.0 / 120])
        sampler.stop()
        sampler.updateInterval(1)
        XCTAssertEqual(scheduler.intervals.count, 2)
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
