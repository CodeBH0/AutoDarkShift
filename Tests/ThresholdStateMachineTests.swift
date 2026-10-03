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
    private func score(_ brightness: Double, baseline: Double? = nil, velocity: Double = 0) -> BrightnessTrendSnapshot {
        BrightnessTrendModel.score(brightness: brightness, baseline: baseline, velocity: velocity,
            dynamic: false, quietDuration: 0)
    }

    func testPositionClippingAndNoMotionScore() {
        XCTAssertEqual(score(0.10).position, -1, accuracy: 1e-12)
        XCTAssertEqual(score(0.25).position, 0)
        XCTAssertEqual(score(0.40).position, 1, accuracy: 1e-12)
        XCTAssertEqual(score(1).score, 0)
        XCTAssertEqual(score(0).score, 0)
    }

    func testVIsBoundedPredictionRatherThanNormalizedSpeed() {
        let value = score(0.28, baseline: 0.25, velocity: 0.05)
        XCTAssertEqual(value.position, 0.2, accuracy: 1e-12)
        XCTAssertEqual(value.change, 0.025 / 0.145, accuracy: 1e-12)
        XCTAssertEqual(value.speed, 0.025 / 0.15, accuracy: 1e-12)
        XCTAssertEqual(value.projectedBrightness!, 0.305, accuracy: 1e-12)
        XCTAssertEqual(value.score, 0.25 * 0.2 + 0.55 * 0.025 / 0.145 + 0.20 * 0.025 / 0.15, accuracy: 1e-12)
        let tiny = score(0.256, baseline: 0.25, velocity: 100)
        XCTAssertEqual(tiny.speed, 0.006 / 0.15, accuracy: 1e-12)
        XCTAssertNil(BrightnessTrendModel.target(for: tiny.score), "A very fast tiny movement cannot independently switch modes")
    }

    func testPredictionRespectsHeadroomAndExcursionDirection() {
        let upper = score(0.99, baseline: 0.8, velocity: 10)
        XCTAssertEqual(upper.projectedBrightness, 1)
        XCTAssertEqual(upper.speed, 0.01 / 0.15, accuracy: 1e-12)
        let lower = score(0.01, baseline: 0.2, velocity: -10)
        XCTAssertEqual(lower.projectedBrightness, 0)
        XCTAssertEqual(lower.speed, -0.01 / 0.15, accuracy: 1e-12)
        XCTAssertEqual(score(0.3, baseline: 0.1, velocity: -1).speed, 0)
        XCTAssertEqual(score(0.2, baseline: 0.4, velocity: 1).speed, 0)
    }

    func testNoiseDeadbandAndAlignedPositionCannotRequestOppositeMode() {
        XCTAssertEqual(score(0.8, baseline: 0.8, velocity: 1).score, 0)
        XCTAssertEqual(score(0.804, baseline: 0.8, velocity: 1).score, 0)
        XCTAssertEqual(score(0.90, baseline: 0.95, velocity: -0.05).position, 1)
        XCTAssertLessThan(score(0.90, baseline: 0.95, velocity: -0.05).score, 0)
        XCTAssertGreaterThan(score(0.05, baseline: 0, velocity: 0.05).score, 0)
        XCTAssertEqual(BrightnessTrendModel.target(for: score(0.75, baseline: 0.9).score), .dark)
        XCTAssertEqual(BrightnessTrendModel.target(for: score(0.25, baseline: 0.1).score), .light)
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
            XCTAssertEqual(machine.trend?.score, 0)
        }
    }

    func testTriggerUsesExcursionOriginAndRetainsVelocityWindow() throws {
        var machine = try engine()
        _ = sample(&machine, 0.20, 0)
        XCTAssertNil(sample(&machine, 0.22, 1))
        XCTAssertEqual(machine.trend?.baseline, 0.20)
        XCTAssertEqual(machine.trend!.velocity, 0.02, accuracy: 1e-12)
        XCTAssertEqual(machine.pollInterval, 0.1)
        _ = sample(&machine, 0.22, 1.1)
        XCTAssertEqual(machine.trend!.velocity, 0.018, accuracy: 1e-12)
        XCTAssertTrue(machine.trend!.dynamicSampling)
    }

    func testSubTriggerSlowMotionAccumulatesAndCanSwitch() throws {
        var machine = try engine()
        _ = sample(&machine, 0.10, 0)
        var candidate: NotificationCandidate?
        for i in 1...30 {
            candidate = sample(&machine, 0.10 + Double(i) * 0.005, Double(i)) ?? candidate
            XCTAssertEqual(machine.pollInterval, 1)
        }
        XCTAssertEqual(candidate?.target, .light)
        XCTAssertEqual(machine.trend?.baseline, 0.10)
        XCTAssertEqual(machine.trend!.change, 1, accuracy: 1e-12)
    }

    func testSubNoiseStepsAccumulateAgainstAcceptedReading() throws {
        var machine = try engine()
        _ = sample(&machine, 0.10, 0)
        for i in 1...75 { _ = sample(&machine, 0.10 + Double(i) * 0.002, Double(i)) }
        XCTAssertEqual(machine.trend?.baseline, 0.10)
        XCTAssertGreaterThan(machine.trend!.change, 0.95)
        XCTAssertEqual(machine.desiredTarget, .light)
        XCTAssertEqual(machine.pollInterval, 1)
    }

    func testPartialWindowProducesZeroVelocityEvenWithEventBurst() throws {
        var machine = try engine()
        _ = sample(&machine, 0.20, 0)
        _ = machine.sample(brightness: 0.30, at: time(0.001), uptime: 0.001, source: .event)
        _ = sample(&machine, 0.22, 0.999)
        XCTAssertEqual(machine.trend?.velocity, 0)
        XCTAssertEqual(machine.pollInterval, 1)
        _ = sample(&machine, 0.22, 1)
        XCTAssertEqual(machine.trend!.velocity, 0.02, accuracy: 1e-12)
    }

    func testSameTimeEventAndPollAreOneObservation() throws {
        var machine = try engine()
        _ = sample(&machine, 0.20, 0)
        _ = machine.sample(brightness: 0.25, at: time(1), uptime: 1, source: .event)
        let snapshot = machine.trend
        _ = sample(&machine, 0.9, 1)
        XCTAssertEqual(machine.trend, snapshot)
    }

    func testDynamicRateBoundariesAreSymmetric() {
        for (velocity, frequency) in [(0.0, 10.0), (0.015, 10), (0.029999, 10), (0.03, 30),
                                      (0.059999, 30), (0.06, 60), (0.099999, 60), (0.10, 120), (1, 120)] {
            XCTAssertEqual(BrightnessTrendModel.dynamicFrequency(for: velocity), frequency)
            XCTAssertEqual(BrightnessTrendModel.dynamicFrequency(for: -velocity), frequency)
        }
    }

    func testUniformVelocityAtEveryRateAndIrregularInterpolation() throws {
        for rate in [1.0, 10, 30, 60, 120] {
            var machine = try engine()
            _ = sample(&machine, 0.2, 0)
            for i in 1...Int(2 * rate) { _ = sample(&machine, 0.2 + 0.06 * Double(i) / rate, Double(i) / rate) }
            XCTAssertEqual(machine.trend!.velocity, 0.06, accuracy: 0.006)
            XCTAssertEqual(machine.trend?.baseline, 0.2)
        }
        var machine = try engine()
        _ = sample(&machine, 0.2, 0)
        _ = sample(&machine, 0.25, 1)
        _ = sample(&machine, 0.26, 1.1)
        _ = sample(&machine, 0.28, 1.7)
        XCTAssertEqual(machine.trend!.velocity, 0.045, accuracy: 1e-12)
        _ = sample(&machine, 0.30, 2.4)
        XCTAssertEqual(machine.trend!.velocity, 0.03, accuracy: 1e-12)
    }

    func testNoiseDoesNotMoveFilteredBrightnessOrBaseline() throws {
        var machine = try engine()
        _ = sample(&machine, 0.25, 0)
        for i in 1...20 { _ = sample(&machine, i % 2 == 0 ? 0.254 : 0.246, Double(i) / 10) }
        XCTAssertEqual(machine.trend?.filteredBrightness, 0.25)
        XCTAssertNil(machine.trend?.baseline)
        XCTAssertEqual(machine.trend?.score, 0)
    }

    func testReversalRequiresCumulativeExcursionFromPeak() throws {
        var machine = try engine()
        _ = sample(&machine, 0.2, 0)
        _ = sample(&machine, 0.3, 1)
        _ = sample(&machine, 0.295, 1.1)
        _ = sample(&machine, 0.292, 1.2)
        XCTAssertEqual(machine.trend?.baseline, 0.2, "A small reverse fluctuation must preserve the origin")
        _ = sample(&machine, 0.29, 1.3)
        XCTAssertEqual(machine.trend?.baseline, 0.3)
        XCTAssertLessThan(machine.trend!.change, 0)
        _ = sample(&machine, 0.25, 1.4)
        XCTAssertEqual(machine.trend?.baseline, 0.3)
    }

    func testExitUsesElapsedTimeAndRetainsBaselineAtEveryRate() throws {
        for rate in [10.0, 30, 60, 120] {
            var machine = try engine()
            _ = sample(&machine, 0.25, 0)
            _ = sample(&machine, 0.27, 1)
            _ = sample(&machine, 0.27, 2)
            for i in 1...Int(rate * 0.30) - 1 {
                _ = sample(&machine, 0.27, 2 + Double(i) / rate)
                XCTAssertTrue(machine.trend!.dynamicSampling)
            }
            _ = sample(&machine, 0.27, 2.30)
            XCTAssertFalse(machine.trend!.dynamicSampling)
            XCTAssertEqual(machine.pollInterval, 1)
            XCTAssertEqual(machine.trend?.baseline, 0.25)
            XCTAssertEqual(machine.trend!.change, 0.015 / 0.145, accuracy: 1e-12)
        }
    }

    func testCumulativeChangeSurvivesExitPlateausAndNewSameDirectionSteps() throws {
        for ascending in [true, false] {
            var machine = try engine()
            let origin = ascending ? 0.10 : 0.40
            _ = sample(&machine, origin, 0)
            let candidate = try XCTUnwrap(sample(&machine, 0.25, 1))
            machine.complete(candidate, result: .success, at: time(1))
            _ = sample(&machine, 0.25, 2)
            _ = sample(&machine, 0.25, 2.4)
            XCTAssertFalse(machine.trend!.dynamicSampling)
            _ = sample(&machine, 0.25, 10)
            XCTAssertEqual(machine.trend?.baseline, origin)
            XCTAssertEqual(machine.trend!.score, ascending ? 0.55 : -0.55, accuracy: 1e-12)
            _ = sample(&machine, ascending ? 0.30 : 0.20, 11)
            XCTAssertEqual(machine.trend?.baseline, origin)
        }
    }

    func testNonQuietSampleRestartsExitTimer() throws {
        var machine = try engine()
        _ = sample(&machine, 0.20, 0)
        _ = sample(&machine, 0.22, 1)
        _ = sample(&machine, 0.22, 2)
        _ = sample(&machine, 0.25, 2.1)
        XCTAssertEqual(machine.trend?.quietDuration, 0)
        _ = sample(&machine, 0.25, 3.1)
        _ = sample(&machine, 0.25, 3.39)
        XCTAssertTrue(machine.trend!.dynamicSampling)
        _ = sample(&machine, 0.25, 3.40)
        XCTAssertEqual(machine.pollInterval, 1)
    }

    func testSettledEvidenceRemainsQualifiedForCooldownRetry() throws {
        var machine = try engine(cooldown: 3)
        _ = sample(&machine, 0.1, 0)
        let first = try XCTUnwrap(sample(&machine, 0.25, 1))
        machine.complete(first, result: .blocked, at: time(1))
        _ = sample(&machine, 0.25, 2)
        _ = sample(&machine, 0.25, 2.4)
        XCTAssertEqual(machine.pendingTarget, .light)
        XCTAssertEqual(sample(&machine, 0.25, 4)?.target, .light)
    }

    func testOldSnapshotDecodesWithoutRetiredDAndWithoutNewOptionalFields() throws {
        let data = Data(#"{"position":0,"change":1,"speed":0,"direction":1,"score":0.35,"velocity":0,"baseline":0.1,"effectiveChanges":2,"dynamicSampling":false,"quietDuration":0}"#.utf8)
        let value = try SharedJSON.decoder().decode(BrightnessTrendSnapshot.self, from: data)
        XCTAssertNil(value.filteredBrightness)
        XCTAssertNil(value.projectedBrightness)
        let encoded = String(decoding: try SharedJSON.encoder().encode(value), as: UTF8.self)
        XCTAssertFalse(encoded.contains("direction"))
        XCTAssertFalse(encoded.contains("effectiveChanges"))
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
        let candidate = try XCTUnwrap(sample(&machine, 0.25, 1))
        XCTAssertEqual(candidate.target, .dark)
        XCTAssertNil(sample(&machine, 0.26, 1.1))
        XCTAssertNil(sample(&machine, 0.26, 1.4))
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
