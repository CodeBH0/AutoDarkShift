import XCTest
#if SWIFT_PACKAGE
@testable import AutoDarkShiftCore
#endif

final class ThresholdStateMachineTests: XCTestCase {
    private func time(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000 + seconds)
    }
    private func engine(stable: TimeInterval = 1, cooldown: TimeInterval = 3,
                        history: SubmissionHistory? = nil) throws -> ThresholdStateMachine {
        try ThresholdStateMachine(configuration: MonitorConfiguration(stableDuration: stable, cooldown: cooldown), history: history)
    }
    private func requireCandidate(_ value: NotificationCandidate?, file: StaticString = #filePath,
                                  line: UInt = #line) throws -> NotificationCandidate {
        try XCTUnwrap(value, file: file, line: line)
    }

    func testDarkBoundaryIsInclusiveAndRequiresStability() throws {
        var machine = try engine()
        XCTAssertNil(machine.sample(brightness: 0.20, at: time(0)))
        XCTAssertNil(machine.sample(brightness: 0.20, at: time(0.999)))
        let candidate = try requireCandidate(machine.sample(brightness: 0.20, at: time(1)))
        XCTAssertEqual(candidate.target, .dark)
        XCTAssertEqual(candidate.brightness, 0.20)
    }

    func testLightBoundaryIsInclusive() throws {
        var machine = try engine()
        XCTAssertNil(machine.sample(brightness: 0.28, at: time(0)))
        XCTAssertEqual(machine.sample(brightness: 0.28, at: time(1))?.target, .light)
    }

    func testZeroAndOneAreValid() throws {
        var dark = try engine(stable: 0)
        var light = try engine(stable: 0)
        XCTAssertEqual(dark.sample(brightness: 0, at: time(0))?.target, .dark)
        XCTAssertEqual(light.sample(brightness: 1, at: time(0))?.target, .light)
    }

    func testInitialMiddleBandWaits() throws {
        var machine = try engine(stable: 0)
        XCTAssertNil(machine.sample(brightness: 0.24, at: time(0)))
        XCTAssertNil(machine.sample(brightness: 0.24, at: time(100)))
        XCTAssertNil(machine.desiredTarget)
        XCTAssertNil(machine.pendingTarget)
        XCTAssertEqual(machine.sample(brightness: 0.1, at: time(101))?.target, .dark)
    }

    func testMiddleBandKeepsExistingTargetWithoutSubmission() throws {
        let history = SubmissionHistory(target: .dark, submittedAt: time(0))
        var machine = try engine(history: history)
        XCTAssertNil(machine.sample(brightness: 0.24, at: time(10)))
        XCTAssertEqual(machine.desiredTarget, .dark)
        XCTAssertEqual(machine.history, history)
        XCTAssertNil(machine.pendingTarget)
    }

    func testJitterResetsStabilityIncludingMiddleBand() throws {
        var machine = try engine()
        XCTAssertNil(machine.sample(brightness: 0.19, at: time(0)))
        XCTAssertNil(machine.sample(brightness: 0.21, at: time(0.8)))
        XCTAssertNil(machine.stableSince)
        XCTAssertNil(machine.sample(brightness: 0.20, at: time(1)))
        XCTAssertNil(machine.sample(brightness: 0.199, at: time(1.8)))
        XCTAssertEqual(machine.sample(brightness: 0.19, at: time(2))?.target, .dark)
    }

    func testOppositeBoundaryResetsStability() throws {
        var machine = try engine()
        XCTAssertNil(machine.sample(brightness: 0.1, at: time(0)))
        XCTAssertNil(machine.sample(brightness: 0.9, at: time(0.9)))
        XCTAssertNil(machine.sample(brightness: 0.9, at: time(1)))
        XCTAssertEqual(machine.sample(brightness: 0.9, at: time(1.9))?.target, .light)
    }

    func testSuccessfulTargetDeduplicatesAndOppositeSwitches() throws {
        var machine = try engine()
        _ = machine.sample(brightness: 0.1, at: time(0))
        let dark = try requireCandidate(machine.sample(brightness: 0.1, at: time(1)))
        machine.complete(dark, succeeded: true, at: time(1))
        XCTAssertNil(machine.sample(brightness: 0.1, at: time(100)))
        XCTAssertNil(machine.sample(brightness: 0.9, at: time(101)))
        let light = try requireCandidate(machine.sample(brightness: 0.9, at: time(102)))
        XCTAssertEqual(light.target, .light)
        machine.complete(light, succeeded: true, at: time(102))
        XCTAssertNil(machine.sample(brightness: 0.9, at: time(200)))
    }

    func testCooldownRetainsTargetAndFreshSampleAtEndEmits() throws {
        var machine = try engine(stable: 0)
        let dark = try requireCandidate(machine.sample(brightness: 0.1, at: time(0)))
        machine.complete(dark, succeeded: true, at: time(0))
        XCTAssertNil(machine.sample(brightness: 0.9, at: time(1)))
        XCTAssertEqual(machine.pendingTarget, .light)
        XCTAssertNil(machine.sample(brightness: 0.9, at: time(2.999)))
        let light = try requireCandidate(machine.sample(brightness: 0.8, at: time(3)))
        XCTAssertEqual(light.target, .light)
        XCTAssertEqual(light.brightness, 0.8)
    }

    func testCooldownDoesNotEmitObsoletePendingTarget() throws {
        var machine = try engine(stable: 0)
        let dark = try requireCandidate(machine.sample(brightness: 0.1, at: time(0)))
        machine.complete(dark, succeeded: true, at: time(0))
        XCTAssertNil(machine.sample(brightness: 0.9, at: time(1)))
        XCTAssertNil(machine.sample(brightness: 0.24, at: time(3)))
        XCTAssertNil(machine.pendingTarget)
        XCTAssertNil(machine.sample(brightness: 0.1, at: time(4)))
    }

    func testFailureRetainsTargetAndRetriesAfterCooldownFromCompletion() throws {
        var machine = try engine(stable: 0)
        let first = try requireCandidate(machine.sample(brightness: 0.1, at: time(0)))
        machine.complete(first, succeeded: false, at: time(0.5))
        XCTAssertNil(machine.history)
        XCTAssertEqual(machine.pendingTarget, .dark)
        XCTAssertNil(machine.sample(brightness: 0.1, at: time(3.499)))
        let retry = try requireCandidate(machine.sample(brightness: 0.12, at: time(3.5)))
        XCTAssertEqual(retry.target, .dark)
        XCTAssertNotEqual(retry.id, first.id)
        XCTAssertEqual(retry.brightness, 0.12)
        machine.complete(retry, succeeded: true, at: time(3.5))
        XCTAssertNil(machine.sample(brightness: 0.1, at: time(10)))
    }

    func testRestoredHistoryDeduplicatesAndRestoresCooldown() throws {
        let history = SubmissionHistory(target: .light, submittedAt: time(10))
        var machine = try engine(stable: 1, history: history)
        XCTAssertNil(machine.sample(brightness: 0.9, at: time(10.5)))
        XCTAssertNil(machine.sample(brightness: 0.1, at: time(11)))
        XCTAssertNil(machine.sample(brightness: 0.1, at: time(12)))
        XCTAssertEqual(machine.pendingTarget, .dark)
        XCTAssertEqual(machine.sample(brightness: 0.1, at: time(13))?.target, .dark)
    }

    func testIllegalBrightnessNeverEmitsAndResetsStability() throws {
        for invalid in [Double.nan, .infinity, -.infinity, -0.01, 1.01] {
            var machine = try engine()
            XCTAssertNil(machine.sample(brightness: 0.1, at: time(0)))
            XCTAssertNil(machine.sample(brightness: invalid, at: time(1)))
            XCTAssertNil(machine.stableSince)
            XCTAssertNil(machine.sample(brightness: 0.1, at: time(1.1)))
            XCTAssertNil(machine.sample(brightness: 0.1, at: time(2)))
            XCTAssertEqual(machine.sample(brightness: 0.1, at: time(2.1))?.target, .dark)
        }
    }

    func testOneInFlightRequestAndStaleCompletionIgnored() throws {
        var machine = try engine(stable: 0, cooldown: 0)
        let first = try requireCandidate(machine.sample(brightness: 0.1, at: time(0)))
        XCTAssertNil(machine.sample(brightness: 0.1, at: time(10)))
        machine.complete(first, succeeded: false, at: time(10))
        let retry = try requireCandidate(machine.sample(brightness: 0.1, at: time(11)))
        machine.complete(first, succeeded: true, at: time(12))
        XCTAssertNil(machine.history)
        XCTAssertEqual(machine.inFlight?.id, retry.id)
    }

    func testOppositeConditionDuringInFlightRemainsPending() throws {
        var machine = try engine(stable: 0, cooldown: 3)
        let dark = try requireCandidate(machine.sample(brightness: 0.1, at: time(0)))
        XCTAssertNil(machine.sample(brightness: 0.9, at: time(1)))
        machine.complete(dark, succeeded: true, at: time(1))
        XCTAssertEqual(machine.pendingTarget, .light)
        XCTAssertNil(machine.sample(brightness: 0.9, at: time(3)))
        XCTAssertEqual(machine.sample(brightness: 0.9, at: time(4))?.target, .light)
    }

    func testConfigurationChangeRequiresNewStability() throws {
        var machine = try engine()
        XCTAssertNil(machine.sample(brightness: 0.1, at: time(0)))
        try machine.updateConfiguration(MonitorConfiguration(stableDuration: 2))
        XCTAssertNil(machine.sample(brightness: 0.1, at: time(1)))
        XCTAssertNil(machine.sample(brightness: 0.1, at: time(2)))
        XCTAssertEqual(machine.sample(brightness: 0.1, at: time(3))?.target, .dark)
    }

    func testSleepResetCannotCountSleepAsStableTime() throws {
        var machine = try engine()
        XCTAssertNil(machine.sample(brightness: 0.1, at: time(0)))
        machine.resetStability()
        XCTAssertNil(machine.sample(brightness: 0.1, at: time(300)))
        XCTAssertEqual(machine.sample(brightness: 0.1, at: time(301))?.target, .dark)
    }

    func testBackwardsClockResetsStableTimer() throws {
        var machine = try engine()
        XCTAssertNil(machine.sample(brightness: 0.1, at: time(10)))
        XCTAssertNil(machine.sample(brightness: 0.1, at: time(5)))
        XCTAssertNil(machine.sample(brightness: 0.1, at: time(5.9)))
        XCTAssertEqual(machine.sample(brightness: 0.1, at: time(6))?.target, .dark)
    }

    func testRestoredFutureTimestampDoesNotBlockIndefinitely() throws {
        let history = SubmissionHistory(target: .light, submittedAt: time(100))
        var machine = try engine(stable: 0, history: history)
        XCTAssertNil(machine.sample(brightness: 0.1, at: time(0)))
        XCTAssertNil(machine.sample(brightness: 0.1, at: time(2.99)))
        XCTAssertEqual(machine.sample(brightness: 0.1, at: time(3))?.target, .dark)
        XCTAssertEqual(machine.history, history)
    }

    func testInvalidConfigurationRejectedWithoutMutatingEngine() throws {
        var machine = try engine()
        let original = machine.configuration
        let invalid = [
            MonitorConfiguration(darkThreshold: 0.28, lightThreshold: 0.28),
            MonitorConfiguration(darkThreshold: -0.01),
            MonitorConfiguration(lightThreshold: 1.01),
            MonitorConfiguration(darkThreshold: .nan),
            MonitorConfiguration(pollInterval: 0),
            MonitorConfiguration(pollInterval: .infinity),
            MonitorConfiguration(stableDuration: -1),
            MonitorConfiguration(cooldown: -1)
        ]
        for configuration in invalid {
            XCTAssertThrowsError(try machine.updateConfiguration(configuration))
            XCTAssertEqual(machine.configuration, original)
        }
    }
}
