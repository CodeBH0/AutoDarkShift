import XCTest
#if SWIFT_PACKAGE
@testable import AutoDarkShiftCore
#endif

private final class LockedDiagnosticCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    func record(_ name: String, _ fields: [String: String]) {
        lock.lock(); defer { lock.unlock() }
        counts[name, default: 0] += 1
    }

    func count(_ name: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return counts[name, default: 0]
    }
}

@MainActor private final class WeakSchedulerReference {
    weak var value: DispatchPollingScheduler?

    init(_ value: DispatchPollingScheduler) {
        self.value = value
    }
}

final class PollingSchedulerTests: XCTestCase {
    @MainActor
    private func blockMainActor(for interval: TimeInterval) {
        Thread.sleep(forTimeInterval: interval)
    }

    @MainActor
    func testDispatchSourceDeliversWithoutRunLoopTimer() async {
        let scheduler = DispatchPollingScheduler()
        let ticked = expectation(description: "dispatch timer tick")
        scheduler.start(interval: 0.02) { ticked.fulfill() }
        await fulfillment(of: [ticked], timeout: 2)
        scheduler.stop()
    }

    @MainActor
    func testStopRejectsQueuedTickAndRestartInstallsFreshTimer() async {
        let scheduler = DispatchPollingScheduler()
        var staleTicks = 0
        var freshTicks = 0
        scheduler.start(interval: 0.005) { staleTicks += 1 }

        // Hold MainActor while DispatchSource continues firing. The worker can enqueue
        // at most one callback; stopping before yielding must invalidate that callback.
        blockMainActor(for: 0.08)
        scheduler.stop()
        await Task.yield()
        XCTAssertEqual(staleTicks, 0)

        let restarted = expectation(description: "restarted dispatch timer tick")
        scheduler.start(interval: 0.02) {
            freshTicks += 1
            restarted.fulfill()
        }
        await fulfillment(of: [restarted], timeout: 2)
        scheduler.stop()
        XCTAssertGreaterThanOrEqual(freshTicks, 1)
    }

    @MainActor
    func testBlockedMainActorDoesNotAccumulateCallbacks() async {
        let scheduler = DispatchPollingScheduler()
        var ticks = 0
        scheduler.start(interval: 0.002) { ticks += 1 }
        blockMainActor(for: 0.12)
        await Task.yield()
        // Multiple worker ticks elapsed, but only one MainActor read was waiting.
        XCTAssertLessThanOrEqual(ticks, 1)
        scheduler.stop()
    }

    @MainActor
    func testChangingIntervalAndStoppingPreventsFurtherTicks() async throws {
        let scheduler = DispatchPollingScheduler()
        var ticks = 0
        scheduler.start(interval: 0.01) { ticks += 1 }
        try await Task.sleep(for: .milliseconds(60))
        let beforeChange = ticks
        XCTAssertGreaterThan(beforeChange, 0)

        scheduler.start(interval: 0.03) { ticks += 1 }
        try await Task.sleep(for: .milliseconds(75))
        scheduler.stop()
        let stoppedCount = ticks
        try await Task.sleep(for: .milliseconds(70))
        XCTAssertEqual(ticks, stoppedCount)
    }

    @MainActor
    func testDeallocationCancelsDispatchSource() async throws {
        let diagnostics = LockedDiagnosticCounter()
        var scheduler: DispatchPollingScheduler? = DispatchPollingScheduler { name, fields in
            diagnostics.record(name, fields)
        }
        let weakScheduler = WeakSchedulerReference(scheduler!)
        scheduler?.start(interval: 0.005) {}
        try await Task.sleep(for: .milliseconds(1_100))
        let countBeforeRelease = diagnostics.count("poll_tick")
        XCTAssertGreaterThan(countBeforeRelease, 0)

        scheduler = nil
        // Allow an already-enqueued MainActor callback to finish before checking release.
        for _ in 0..<50 where weakScheduler.value != nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(weakScheduler.value, "scheduler should deallocate after its owner releases it")
        let countAfterRelease = diagnostics.count("poll_tick")
        try await Task.sleep(for: .milliseconds(50))
        let countAfterInFlightDrain = diagnostics.count("poll_tick")
        XCTAssertEqual(countAfterInFlightDrain, countAfterRelease,
                       "in-flight source work should drain after scheduler deallocation")
        try await Task.sleep(for: .milliseconds(1_100))
        XCTAssertEqual(diagnostics.count("poll_tick"), countAfterInFlightDrain,
                       "cancelled source must not emit later poll diagnostics")
    }
}
