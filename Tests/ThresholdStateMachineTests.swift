import XCTest
#if SWIFT_PACKAGE
@testable import AutoDarkShiftCore
#endif

final class BrightnessTrendStateMachineTests: XCTestCase {
    private func time(_ seconds: Double) -> Date { Date(timeIntervalSince1970: 1_700_000_000 + seconds) }
    private func engine(cooldown: Double = 0, history: SubmissionHistory? = nil) throws -> BrightnessTrendStateMachine {
        try BrightnessTrendStateMachine(configuration: MonitorConfiguration(cooldown: cooldown), history: history)
    }
    private func sample(_ machine: inout BrightnessTrendStateMachine, _ brightness: Double,
                        _ seconds: Double) -> NotificationCandidate? {
        machine.sample(brightness: brightness, at: time(seconds), uptime: seconds)
    }
    private func score(_ brightness: Double, baseline: Double? = nil, velocity: Double = 0,
                       directions: [Int] = []) -> BrightnessTrendSnapshot {
        BrightnessTrendModel.score(brightness: brightness, baseline: baseline, velocity: velocity,
            directions: directions, dynamic: baseline != nil, quietDuration: 0)
    }

    func testPositionAndComponentClipping() {
        XCTAssertEqual(score(0.10).position, -1, accuracy: 1e-12)
        XCTAssertEqual(score(0.25).position, 0)
        XCTAssertEqual(score(0.40).position, 1, accuracy: 1e-12)
        let upper = score(1, baseline: 0, velocity: 20, directions: [1, 1])
        let lower = score(0, baseline: 1, velocity: -20, directions: [-1, -1])
        XCTAssertEqual(upper.score, 1, accuracy: 1e-12)
        XCTAssertEqual(lower.score, -1, accuracy: 1e-12)
        XCTAssertEqual(upper.change, 1)
        XCTAssertEqual(lower.speed, -1)
    }

    func testWeightedScoreAndDirectionFraction() {
        let value = score(0.28, baseline: 0.25, velocity: 0.05, directions: [1, 1, -1])
        XCTAssertEqual(value.position, 0.2, accuracy: 1e-12)
        XCTAssertEqual(value.change, 0.2, accuracy: 1e-12)
        XCTAssertEqual(value.speed, 0.5)
        XCTAssertEqual(value.direction, 1.0 / 3, accuracy: 1e-12)
        XCTAssertEqual(value.score, 0.3033333333333333, accuracy: 1e-12)
    }

    func testInclusiveScoreBoundariesAndHoldBand() {
        XCTAssertEqual(BrightnessTrendModel.target(for: 0.50), .light)
        XCTAssertEqual(BrightnessTrendModel.target(for: -0.50), .dark)
        XCTAssertNil(BrightnessTrendModel.target(for: 0.499999))
        XCTAssertNil(BrightnessTrendModel.target(for: -0.499999))
    }

    func testConstantScreenBrightnessDoesNotInferAnEnvironmentTransition() throws {
        for brightness in [0.0, 0.10, 0.25, 0.40, 1.0] {
            var machine = try engine()
            XCTAssertNil(sample(&machine, brightness, 0))
            XCTAssertNil(sample(&machine, brightness, 1))
            XCTAssertNil(machine.desiredTarget)
            XCTAssertEqual(machine.pollInterval, 1)
            XCTAssertEqual(machine.trend?.change, 0)
        }
    }

    func testTriggerUsesPreviousReadingAsBaseline() throws {
        var machine = try engine()
        _ = sample(&machine, 0.20, 0)
        XCTAssertNil(sample(&machine, 0.22, 1))
        XCTAssertEqual(machine.trend?.baseline, 0.20)
        XCTAssertEqual(machine.trend!.velocity, 0.02, accuracy: 1e-12)
        XCTAssertEqual(machine.pollInterval, 0.1)
        XCTAssertEqual(machine.trend?.direction, 1)
    }

    func testSubTriggerSpeedStaysAtOneHz() throws {
        var machine = try engine()
        _ = sample(&machine, 0.25, 0)
        _ = sample(&machine, 0.26, 1)
        XCTAssertEqual(machine.pollInterval, 1)
        XCTAssertNil(machine.trend?.baseline)
    }

    func testEventBurstCannotShortenNormalOneSecondVelocityScale() throws {
        var machine = try engine()
        _ = sample(&machine, 0.20, 0)
        XCTAssertNil(machine.sample(brightness: 0.30, at: time(0.001), uptime: 0.001, source: .event))
        XCTAssertEqual(machine.pollInterval, 1)
        XCTAssertEqual(machine.trend?.velocity, 0)
        XCTAssertNil(sample(&machine, 0.22, 1))
        XCTAssertEqual(machine.trend!.velocity, 0.02, accuracy: 1e-12)
        XCTAssertEqual(machine.trend?.baseline, 0.20)
        XCTAssertEqual(machine.trend?.direction, 1)
        _ = machine.sample(brightness: 0.23, at: time(1.1), uptime: 1.1, source: .event)
        XCTAssertEqual(machine.trend!.velocity, 0.10, accuracy: 1e-12)
    }

    func testDynamicRateBoundariesAreSymmetric() {
        for (velocity, frequency) in [(0.0, 10.0), (0.015, 10), (0.029999, 10), (0.03, 30),
                                      (0.059999, 30), (0.06, 60), (0.099999, 60), (0.10, 120), (1, 120)] {
            XCTAssertEqual(BrightnessTrendModel.dynamicFrequency(for: velocity), frequency)
            XCTAssertEqual(BrightnessTrendModel.dynamicFrequency(for: -velocity), frequency)
        }
    }

    func testHighRateUsesTimeWindowRatherThanAdjacentJump() throws {
        var machine = try engine()
        _ = sample(&machine, 0.20, 0)
        _ = sample(&machine, 0.23, 1)
        for i in 1...24 { _ = sample(&machine, 0.23, 1 + Double(i) / 120) }
        _ = sample(&machine, 0.24, 1.21)
        XCTAssertEqual(machine.trend!.velocity, 0.05, accuracy: 1e-10)
        XCTAssertEqual(machine.pollInterval, 1.0 / 30)
    }

    func testWindowInterpolatesIrregularSamplesAcrossRateChanges() throws {
        var machine = try engine()
        _ = sample(&machine, 0.20, 0)
        _ = sample(&machine, 0.22, 1)
        _ = sample(&machine, 0.23, 1.10)
        _ = sample(&machine, 0.239, 1.19)
        _ = sample(&machine, 0.253, 1.33)
        XCTAssertEqual(machine.trend!.velocity, 0.10, accuracy: 1e-10)
        XCTAssertEqual(machine.trend!.baseline!, 0.20)
    }

    func testNoiseDoesNotEnterDirectionStatistics() throws {
        var machine = try engine()
        _ = sample(&machine, 0.25, 0)
        _ = sample(&machine, 0.27, 1)
        _ = sample(&machine, 0.271, 1.05)
        _ = sample(&machine, 0.270, 1.10)
        XCTAssertEqual(machine.trend?.effectiveChanges, 1)
        XCTAssertEqual(machine.trend?.direction, 1)
    }

    func testDirectionHistoryContainsLastTenEffectiveChanges() throws {
        var machine = try engine()
        _ = sample(&machine, 0.30, 0)
        _ = sample(&machine, 0.40, 1)
        for i in 1...10 { _ = sample(&machine, 0.40 - 0.01 * Double(i), 1 + 0.05 * Double(i)) }
        XCTAssertEqual(machine.trend?.effectiveChanges, 10)
        XCTAssertEqual(machine.trend?.direction, -1)
    }

    func testExitUsesElapsedTimeAtEveryDynamicRate() throws {
        for rate in [10.0, 30, 60, 120] {
            var machine = try engine()
            _ = sample(&machine, 0.25, 0)
            _ = sample(&machine, 0.27, 1)
            _ = sample(&machine, 0.27, 1.01)
            for i in 1...Int(rate * 0.30) - 1 {
                _ = sample(&machine, 0.27, 1.01 + Double(i) / rate)
                XCTAssertTrue(machine.trend!.dynamicSampling)
            }
            _ = sample(&machine, 0.27, 1.31)
            XCTAssertFalse(machine.trend!.dynamicSampling)
            XCTAssertEqual(machine.pollInterval, 1)
            XCTAssertEqual(machine.trend?.baseline, 0.25)
            XCTAssertEqual(machine.trend!.change, (0.27 - 0.25) / 0.15, accuracy: 1e-12)
            XCTAssertEqual(machine.trend?.effectiveChanges, 0)
        }
    }

    func testCumulativeChangeSurvivesExitAndNormalPollingInBothDirections() throws {
        for baseline in [0.10, 0.40] {
            var machine = try engine()
            _ = sample(&machine, baseline, 0)
            let candidate = try XCTUnwrap(sample(&machine, 0.25, 1))
            machine.complete(candidate, result: .success, at: time(1))
            _ = sample(&machine, 0.25, 1.10)
            _ = sample(&machine, 0.25, 1.40)
            XCTAssertFalse(machine.trend!.dynamicSampling)
            XCTAssertEqual(machine.pollInterval, 1)
            XCTAssertEqual(machine.trend?.baseline, baseline)
            XCTAssertEqual(machine.trend!.change, baseline < 0.25 ? 1 : -1, accuracy: 1e-12)
            XCTAssertNil(sample(&machine, 0.25, 2.40))
            XCTAssertEqual(machine.trend?.baseline, baseline)
            XCTAssertEqual(machine.trend!.change, baseline < 0.25 ? 1 : -1, accuracy: 1e-12)
            XCTAssertEqual(machine.trend!.score, baseline < 0.25 ? 0.35 : -0.35, accuracy: 1e-12)
            _ = sample(&machine, 0.30, 3.40)
            XCTAssertEqual(machine.trend?.baseline, 0.25, "A newly detected change establishes its own baseline")
        }
    }

    func testNonQuietSampleRestartsExitTimer() throws {
        var machine = try engine()
        _ = sample(&machine, 0.20, 0)
        _ = sample(&machine, 0.22, 1)
        _ = sample(&machine, 0.22, 1.10)
        _ = sample(&machine, 0.23, 1.25)
        XCTAssertEqual(machine.trend?.quietDuration, 0)
        _ = sample(&machine, 0.23, 1.46)
        _ = sample(&machine, 0.23, 1.75)
        XCTAssertTrue(machine.trend!.dynamicSampling)
        _ = sample(&machine, 0.23, 1.76)
        XCTAssertEqual(machine.pollInterval, 1)
    }

    func testScoreTriggersWithoutLegacyStableDelay() throws {
        var machine = try engine()
        _ = sample(&machine, 0.20, 0)
        let candidate = try XCTUnwrap(sample(&machine, 0.35, 1))
        XCTAssertEqual(candidate.target, .light)
        XCTAssertEqual(candidate.brightness, 0.35)
        XCTAssertGreaterThanOrEqual(machine.trend!.score, 0.50)
    }

    func testSuccessDeduplicatesAndOppositeTrendSwitches() throws {
        var machine = try engine()
        _ = sample(&machine, 0.20, 0)
        let light = try XCTUnwrap(sample(&machine, 0.35, 1))
        machine.complete(light, result: .success, at: time(1))
        XCTAssertNil(sample(&machine, 0.36, 1.10))
        machine.resetObservations()
        _ = sample(&machine, 0.40, 2)
        let dark = try XCTUnwrap(sample(&machine, 0.20, 3))
        XCTAssertEqual(dark.target, .dark)
    }

    func testCooldownRechecksCurrentScoreAndRetriesFailure() throws {
        var machine = try engine(cooldown: 1)
        _ = sample(&machine, 0.40, 0)
        let first = try XCTUnwrap(sample(&machine, 0.20, 1))
        machine.complete(first, result: .failed, at: time(1))
        XCTAssertNil(sample(&machine, 0.18, 1.5))
        XCTAssertEqual(machine.pendingTarget, .dark)
        let retry = try XCTUnwrap(sample(&machine, 0.16, 2))
        XCTAssertEqual(retry.target, .dark)
        XCTAssertNotEqual(first.id, retry.id)
    }

    func testHoldBandInvalidatesPendingRequest() throws {
        var machine = try engine(cooldown: 3)
        _ = sample(&machine, 0.20, 0)
        let first = try XCTUnwrap(sample(&machine, 0.35, 1))
        machine.complete(first, result: .failed, at: time(1))
        _ = sample(&machine, 0.25, 1.1)
        _ = sample(&machine, 0.25, 1.4)
        XCTAssertNil(machine.pendingTarget)
        XCTAssertNil(sample(&machine, 0.25, 4))
    }

    func testInFlightSurvivesScoreFallbackAndBlocksNewCandidates() throws {
        var machine = try engine()
        _ = sample(&machine, 0.40, 0)
        let candidate = try XCTUnwrap(sample(&machine, 0.30, 1))
        XCTAssertEqual(candidate.target, .dark)
        XCTAssertNil(sample(&machine, 0.30, 1.1))
        XCTAssertNil(sample(&machine, 0.30, 1.4))
        XCTAssertNil(machine.pendingTarget)
        XCTAssertGreaterThan(machine.trend!.score, -0.50)
        XCTAssertEqual(machine.inFlight, candidate)
        XCTAssertNil(sample(&machine, 0.10, 2.4))
        XCTAssertEqual(machine.inFlight, candidate, "A new qualifying sample cannot replace the in-flight request")
        machine.complete(candidate, result: .success, at: time(2.4))
        XCTAssertNil(machine.inFlight)
        XCTAssertEqual(machine.history?.target, .dark)
    }

    func testCancelledCandidateDoesNotStartCooldownOrChangeHistory() throws {
        let histories: [SubmissionHistory?] = [nil, SubmissionHistory(target: .light, submittedAt: time(0))]
        for history in histories {
            var machine = try engine(cooldown: 3, history: history)
            _ = sample(&machine, 0.40, 2)
            let first = try XCTUnwrap(sample(&machine, 0.20, 3))
            machine.complete(first, result: .cancelled, at: time(3.5))
            XCTAssertEqual(machine.history, history)
            let replacement = try XCTUnwrap(sample(&machine, 0.19, 3.6))
            XCTAssertNotEqual(replacement.id, first.id)
            XCTAssertEqual(replacement.target, .dark)
        }
    }

    func testCancelledCandidatePreservesCooldownOfEarlierFailedRequest() throws {
        var machine = try engine()
        _ = sample(&machine, 0.40, 0)
        let first = try XCTUnwrap(sample(&machine, 0.20, 1))
        machine.complete(first, result: .failed, at: time(1))
        let cancelled = try XCTUnwrap(sample(&machine, 0.19, 1.2))
        try machine.updateConfiguration(MonitorConfiguration(cooldown: 3))
        machine.complete(cancelled, result: .cancelled, at: time(1.3))
        _ = sample(&machine, 0.40, 1.4)
        XCTAssertNil(sample(&machine, 0.20, 2.4))
        XCTAssertEqual(sample(&machine, 0.15, 4)?.target, .dark)
    }

    func testHistoryAndCooldownSurviveRestart() throws {
        let history = SubmissionHistory(target: .light, submittedAt: time(0))
        var machine = try engine(cooldown: 3, history: history)
        _ = sample(&machine, 0.40, 0)
        XCTAssertNil(sample(&machine, 0.20, 1))
        XCTAssertEqual(machine.pendingTarget, .dark)
        _ = sample(&machine, 0.18, 2)
        XCTAssertEqual(sample(&machine, 0.16, 3)?.target, .dark)
        XCTAssertEqual(machine.history, history)
    }

    func testOneInFlightAndStaleCompletionIgnored() throws {
        var machine = try engine()
        _ = sample(&machine, 0.40, 0)
        let first = try XCTUnwrap(sample(&machine, 0.20, 1))
        XCTAssertNil(sample(&machine, 0.18, 1.1))
        machine.complete(first, result: .failed, at: time(1.1))
        let retry = try XCTUnwrap(sample(&machine, 0.16, 1.2))
        machine.complete(first, result: .success, at: time(1.2))
        XCTAssertEqual(machine.inFlight?.id, retry.id)
        XCTAssertNil(machine.history)
    }

    func testInvalidInputResetsTrendAndSampling() throws {
        for invalid in [Double.nan, .infinity, -.infinity, -0.01, 1.01] {
            var machine = try engine()
            _ = sample(&machine, 0.20, 0)
            _ = sample(&machine, 0.22, 1)
            XCTAssertNil(sample(&machine, invalid, 1.1))
            XCTAssertNil(machine.trend)
            XCTAssertEqual(machine.pollInterval, 1)
            XCTAssertNil(sample(&machine, 0.80, 2))
        }
    }

    func testDuplicateAndBackwardsMonotonicTimesCannotCreateVelocity() throws {
        var machine = try engine()
        _ = sample(&machine, 0.20, 10)
        XCTAssertNil(sample(&machine, 0.90, 10))
        XCTAssertEqual(machine.trend!.position, -1.0 / 3, accuracy: 1e-12)
        XCTAssertNil(sample(&machine, 0.90, 5))
        XCTAssertEqual(machine.trend?.velocity, 0)
        XCTAssertEqual(machine.pollInterval, 1)
    }

    func testWallClockChangeDoesNotAlterMonotonicVelocity() throws {
        var machine = try engine()
        _ = machine.sample(brightness: 0.20, at: time(1000), uptime: 0)
        _ = machine.sample(brightness: 0.22, at: time(5), uptime: 1)
        XCTAssertEqual(machine.trend!.velocity, 0.02, accuracy: 1e-12)
        XCTAssertEqual(machine.pollInterval, 0.1)
    }

    func testSleepAndConfigurationResetClearBaseline() throws {
        var machine = try engine()
        _ = sample(&machine, 0.20, 0)
        _ = sample(&machine, 0.22, 1)
        machine.resetObservations()
        XCTAssertNil(sample(&machine, 0.40, 300))
        XCTAssertNil(machine.trend?.baseline)
        _ = sample(&machine, 0.38, 301)
        try machine.updateConfiguration(MonitorConfiguration(cooldown: 5))
        XCTAssertNil(machine.trend)
        XCTAssertEqual(machine.pollInterval, 1)
        XCTAssertNil(sample(&machine, 0.10, 302))
    }

    func testInvalidConfigurationCannotMutateState() throws {
        var machine = try engine()
        let original = machine.configuration
        for cooldown in [-1.0, .nan, .infinity] {
            XCTAssertThrowsError(try machine.updateConfiguration(MonitorConfiguration(cooldown: cooldown)))
            XCTAssertEqual(machine.configuration, original)
        }
    }
}
