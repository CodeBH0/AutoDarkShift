import Foundation

struct NotificationCandidate: Equatable {
    let id: UUID
    let target: DisplayMode
    let brightness: Double
    let sampledAt: Date
}

/// MathModel v2. B(t) is screen brightness, not illuminance.
enum BrightnessTrendModel {
    static let noiseFloor = 0.005
    static let reversalThreshold = 2 * noiseFloor
    static let velocityWindow: TimeInterval = 1
    static let predictionHorizon: TimeInterval = 0.5
    static let positionCenter = 0.25
    static let positionScale = 0.15
    static let changeScale = 0.15
    static let scoreThreshold = 0.50
    static let triggerVelocity = 0.015
    static let exitVelocity = 0.01
    static let exitDuration: TimeInterval = 0.30
    static let normalPollInterval: TimeInterval = 1

    static var metadata: [String: String] {
        ["modelVersion": "2", "weights": "A_aligned=0.25,delta=0.55,V=0.20",
         "positionCenter": String(positionCenter), "positionScale": String(positionScale),
         "changeScale": String(changeScale), "scoreThreshold": String(scoreThreshold),
         "noiseFloor": String(noiseFloor), "reversalThreshold": String(reversalThreshold),
         "velocityWindow": String(velocityWindow), "predictionHorizon": String(predictionHorizon),
         "triggerVelocity": String(triggerVelocity), "exitVelocity": String(exitVelocity),
         "exitDuration": String(exitDuration), "frequencyBands": "1,10,30,60,120",
         "bandBoundaries": "0.015,0.03,0.06,0.10",
         "velocityDefinition": "fixed_1s_interpolated_secant_full_window_only",
         "VDefinition": "aligned_prediction_limited_by_confirmed_change_and_headroom",
         "baselineDefinition": "persistent_excursion_origin_rebase_after_0.010_reversal"]
    }

    static func clip(_ value: Double) -> Double { min(1, max(-1, value)) }

    static func score(brightness: Double, baseline: Double?, velocity: Double,
                      dynamic: Bool, quietDuration: TimeInterval) -> BrightnessTrendSnapshot {
        let position = clip((brightness - positionCenter) / positionScale)
        let displacement = baseline.map { brightness - $0 } ?? 0
        let magnitude = min(1, max(0, (abs(displacement) - noiseFloor) / (changeScale - noiseFloor)))
        let change = displacement < 0 ? -magnitude : magnitude
        // Absolute position may support an excursion, but cannot request its opposite mode.
        let alignedPosition = position * change > 0 ? position : 0
        var prediction = 0.0
        if velocity * change > 0 {
            let headroom = velocity > 0 ? 1 - brightness : brightness
            let distance = min(predictionHorizon * abs(velocity), abs(displacement), headroom)
            prediction = velocity > 0 ? distance : -distance
        }
        let speed = clip(prediction / changeScale)
        return BrightnessTrendSnapshot(position: position, change: change, speed: speed,
            score: clip(0.25 * alignedPosition + 0.55 * change + 0.20 * speed),
            velocity: velocity, baseline: baseline, dynamicSampling: dynamic, quietDuration: quietDuration,
            filteredBrightness: brightness, projectedBrightness: brightness + prediction)
    }

    static func target(for score: Double) -> DisplayMode? {
        if score >= scoreThreshold { return .light }
        if score <= -scoreThreshold { return .dark }
        return nil
    }

    /// While waiting to exit, speeds below the trigger stay at the lowest dynamic rate.
    static func dynamicFrequency(for velocity: Double) -> Double {
        let speed = abs(velocity)
        if speed >= 0.10 { return 120 }
        if speed >= 0.06 { return 60 }
        if speed >= 0.03 { return 30 }
        return 10
    }
}

struct BrightnessTrendSnapshot: Codable, Equatable {
    var position: Double // A
    var change: Double // Δ
    var speed: Double // V: bounded predicted displacement, not normalized velocity
    var score: Double // S
    var velocity: Double
    var baseline: Double?
    var dynamicSampling: Bool
    var quietDuration: TimeInterval
    // Optional for reading pre-v2 persisted snapshots. New observations always populate both.
    var filteredBrightness: Double?
    var projectedBrightness: Double?
}

/// Pure score, sampling and request policy; the caller supplies wall and monotonic time.
struct BrightnessTrendStateMachine {
    private(set) var configuration: MonitorConfiguration
    private(set) var history: SubmissionHistory?
    private(set) var desiredTarget: DisplayMode?
    private(set) var pendingTarget: DisplayMode?
    private(set) var inFlight: NotificationCandidate?
    private(set) var trend: BrightnessTrendSnapshot?
    private(set) var pollInterval = BrightnessTrendModel.normalPollInterval
    private var lastAttemptAt: Date?
    private var previous: Observation?
    private var velocitySamples: [Observation] = []
    private var initialAnchor: Double?
    private var baseline: Double?
    private var excursionSign = 0.0
    private var extremum: Double?
    private var quietSince: TimeInterval?
    private var dynamic = false

    private struct Observation {
        var brightness: Double
        var time: TimeInterval
    }

    init(configuration: MonitorConfiguration, history: SubmissionHistory? = nil) throws {
        self.configuration = try configuration.validated()
        self.history = history
        desiredTarget = history?.target
        lastAttemptAt = history?.submittedAt
    }

    mutating func updateConfiguration(_ configuration: MonitorConfiguration) throws {
        self.configuration = try configuration.validated()
        resetObservations()
    }

    /// Sleep, wake, gaps and invalid inputs cannot carry a trend across missing observations.
    mutating func resetObservations() {
        previous = nil
        velocitySamples.removeAll(keepingCapacity: true)
        initialAnchor = nil
        baseline = nil
        excursionSign = 0
        extremum = nil
        quietSince = nil
        dynamic = false
        trend = nil
        pollInterval = BrightnessTrendModel.normalPollInterval
        pendingTarget = nil
    }

    mutating func sample(brightness: Double, at now: Date, uptime: TimeInterval? = nil,
                         source: SampleSource = .poll) -> NotificationCandidate? {
        let time = uptime ?? now.timeIntervalSinceReferenceDate
        guard MonitorConfiguration.validBrightness(brightness), time.isFinite else {
            resetObservations()
            return nil
        }
        if let attempt = lastAttemptAt, attempt > now { lastAttemptAt = now }
        if let previous, time < previous.time { resetObservations() }
        // Event and poll at the same monotonic instant represent one observation.
        if let previous, time == previous.time { return nil }
        // A hysteresis deadband suppresses jitter without losing cumulative sub-step motion.
        let filtered = previous.map {
            abs(brightness - $0.brightness) + 1e-12 >= BrightnessTrendModel.noiseFloor ? brightness : $0.brightness
        } ?? brightness
        let current = Observation(brightness: filtered, time: time)
        updateBaseline(at: filtered)
        velocitySamples.append(current)
        let velocity = windowVelocity(at: current)
        if !dynamic, abs(velocity) >= BrightnessTrendModel.triggerVelocity { dynamic = true }
        self.previous = current

        var quietDuration = 0.0
        if dynamic {
            if abs(velocity) < BrightnessTrendModel.exitVelocity {
                if quietSince == nil { quietSince = time }
                quietDuration = time - (quietSince ?? time)
                if quietDuration + 1e-9 >= BrightnessTrendModel.exitDuration {
                    dynamic = false
                    // Sampling and cumulative evidence have independent lifetimes.
                    quietSince = nil
                }
            } else { quietSince = nil }
        }
        pollInterval = dynamic ? 1 / BrightnessTrendModel.dynamicFrequency(for: velocity)
                               : BrightnessTrendModel.normalPollInterval
        trend = BrightnessTrendModel.score(brightness: filtered, baseline: baseline, velocity: velocity,
            dynamic: dynamic, quietDuration: quietDuration)
        guard let target = BrightnessTrendModel.target(for: trend!.score) else {
            setPending(nil)
            return nil
        }
        desiredTarget = target
        guard history?.target != target else {
            setPending(nil)
            return nil
        }
        setPending(target)
        guard inFlight == nil else { return nil }
        if let attempt = lastAttemptAt, now.timeIntervalSince(attempt) < configuration.cooldown { return nil }
        let candidate = NotificationCandidate(id: UUID(), target: target, brightness: brightness, sampledAt: now)
        inFlight = candidate
        return candidate
    }

    /// Slow same-direction motion retains its origin even across sampling exits or plateaus.
    /// Only a cumulative reversal from the peak/trough, or an explicit reset, starts a new excursion.
    private mutating func updateBaseline(at brightness: Double) {
        guard let anchor = initialAnchor else {
            initialAnchor = brightness
            return
        }
        if baseline == nil {
            let displacement = brightness - anchor
            guard abs(displacement) > BrightnessTrendModel.noiseFloor else { return }
            baseline = anchor
            excursionSign = displacement > 0 ? 1 : -1
            extremum = brightness
            return
        }
        guard let peak = extremum else { return }
        if excursionSign * (brightness - peak) > 0 {
            extremum = brightness
        } else if excursionSign * (peak - brightness) + 1e-12 >= BrightnessTrendModel.reversalThreshold {
            baseline = peak
            excursionSign = -excursionSign
            extremum = brightness
        }
    }

    /// One physical time scale at every rate. A partial window has no velocity evidence.
    /// Never clear this history when entering, leaving or changing dynamic sampling.
    private mutating func windowVelocity(at current: Observation) -> Double {
        let cutoff = current.time - BrightnessTrendModel.velocityWindow
        while velocitySamples.count > 2, velocitySamples[1].time <= cutoff { velocitySamples.removeFirst() }
        guard let first = velocitySamples.first, first.time <= cutoff + 1e-9,
              velocitySamples.count >= 2 else { return 0 }
        let next = velocitySamples[1]
        let fraction = max(0, min(1, (cutoff - first.time) / (next.time - first.time)))
        let reference = first.brightness + fraction * (next.brightness - first.brightness)
        return (current.brightness - reference) / BrightnessTrendModel.velocityWindow
    }

    private mutating func setPending(_ target: DisplayMode?) {
        pendingTarget = target
    }

    /// Only terminal results settle a request. Cancellation before submission consumes no cooldown.
    /// Acceptance does not prove a shortcut ran; blocked/failed results retain the retry policy.
    mutating func complete(_ candidate: NotificationCandidate, result: SubmissionResult, at now: Date) {
        guard inFlight?.id == candidate.id, result != .submitting else { return }
        inFlight = nil
        if result != .cancelled { lastAttemptAt = now }
        if result == .success {
            history = SubmissionHistory(target: candidate.target, submittedAt: now)
            if pendingTarget == candidate.target { setPending(nil) }
        }
    }
}
