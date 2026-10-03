import Foundation

struct NotificationCandidate: Equatable {
    let id: UUID
    let target: DisplayMode
    let brightness: Double
    let sampledAt: Date
}

/// MathModel v1, chapters 1–4 and 8. B(t) is screen brightness, not illuminance.
enum BrightnessTrendModel {
    static let directionWindowSize = 10 // N is unspecified in v1; use ten effective changes.
    static let noiseFloor = 0.005
    static let velocityWindow: TimeInterval = 0.20
    static let triggerVelocity = 0.015
    static let exitVelocity = 0.01
    static let exitDuration: TimeInterval = 0.30
    static let normalPollInterval: TimeInterval = 1

    static func clip(_ value: Double) -> Double { min(1, max(-1, value)) }

    static func score(brightness: Double, baseline: Double?, velocity: Double,
                      directions: [Int], dynamic: Bool, quietDuration: TimeInterval) -> BrightnessTrendSnapshot {
        let position = clip((brightness - 0.25) / 0.15)
        let change = baseline.map { clip((brightness - $0) / 0.15) } ?? 0
        let speed = clip(velocity / 0.10)
        let direction = directions.isEmpty ? 0 : Double(directions.reduce(0, +)) / Double(directions.count)
        return BrightnessTrendSnapshot(position: position, change: change, speed: speed, direction: direction,
            score: clip(0.25 * position + 0.35 * change + 0.30 * speed + 0.10 * direction),
            velocity: velocity, baseline: baseline, effectiveChanges: directions.count,
            dynamicSampling: dynamic, quietDuration: quietDuration)
    }

    static func target(for score: Double) -> DisplayMode? {
        if score >= 0.50 { return .light }
        if score <= -0.50 { return .dark }
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
    var speed: Double // V
    var direction: Double // D
    var score: Double // S
    var velocity: Double
    var baseline: Double?
    var effectiveChanges: Int
    var dynamicSampling: Bool
    var quietDuration: TimeInterval
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
    private var normalReference: Observation?
    private var velocitySamples: [Observation] = []
    private var baseline: Double?
    private var directions: [Int] = []
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
        normalReference = nil
        velocitySamples.removeAll(keepingCapacity: true)
        baseline = nil
        directions.removeAll(keepingCapacity: true)
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
        // Duplicate event/poll callbacks cannot divide by zero or count a direction twice.
        if let previous, time == previous.time { return nil }
        let current = Observation(brightness: brightness, time: time)
        var velocity = 0.0
        var directionChange = previous.map { brightness - $0.brightness } ?? 0
        if previous != nil {
            if dynamic {
                velocitySamples.append(current)
                velocity = windowVelocity(at: current)
            } else if source != .event, let reference = normalReference {
                // Normal velocity compares adjacent 1 Hz polls; event bursts cannot shorten it.
                velocity = (brightness - reference.brightness) / (time - reference.time)
                if abs(velocity) >= BrightnessTrendModel.triggerVelocity {
                    dynamic = true
                    baseline = reference.brightness
                    directionChange = brightness - reference.brightness
                    directions.removeAll(keepingCapacity: true)
                    // Warm up from this trigger reading; the old 1 Hz sample is not a high-rate window.
                    velocitySamples = [current]
                }
            }
            if dynamic, abs(directionChange) >= BrightnessTrendModel.noiseFloor {
                directions.append(directionChange > 0 ? 1 : -1)
                if directions.count > BrightnessTrendModel.directionWindowSize { directions.removeFirst() }
            }
        }
        self.previous = current
        if source != .event { normalReference = current }

        var quietDuration = 0.0
        if dynamic {
            if abs(velocity) < BrightnessTrendModel.exitVelocity {
                if quietSince == nil { quietSince = time }
                quietDuration = time - (quietSince ?? time)
                if quietDuration + 1e-9 >= BrightnessTrendModel.exitDuration {
                    dynamic = false
                    // Sampling can slow down while cumulative evidence remains valid.
                    directions.removeAll(keepingCapacity: true)
                    velocitySamples.removeAll(keepingCapacity: true)
                    quietSince = nil
                    normalReference = current
                }
            } else { quietSince = nil }
        }
        pollInterval = dynamic ? 1 / BrightnessTrendModel.dynamicFrequency(for: velocity)
                               : BrightnessTrendModel.normalPollInterval
        trend = BrightnessTrendModel.score(brightness: brightness, baseline: baseline, velocity: velocity,
            directions: directions, dynamic: dynamic, quietDuration: quietDuration)
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

    /// Interpolate at t−0.20 s, retaining one older point to bracket that time.
    /// During warm-up use the earliest dynamic reading and its actual elapsed time.
    private mutating func windowVelocity(at current: Observation) -> Double {
        let cutoff = current.time - BrightnessTrendModel.velocityWindow
        while velocitySamples.count > 2, velocitySamples[1].time <= cutoff { velocitySamples.removeFirst() }
        guard let first = velocitySamples.first, current.time > first.time else { return 0 }
        if first.time <= cutoff, velocitySamples.count >= 2 {
            let next = velocitySamples[1]
            let fraction = (cutoff - first.time) / (next.time - first.time)
            let reference = first.brightness + fraction * (next.brightness - first.brightness)
            return (current.brightness - reference) / BrightnessTrendModel.velocityWindow
        }
        return (current.brightness - first.brightness) / (current.time - first.time)
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
