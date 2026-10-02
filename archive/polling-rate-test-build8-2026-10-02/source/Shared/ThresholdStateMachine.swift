import Foundation

struct NotificationCandidate: Equatable {
    let id: UUID
    let target: DisplayMode
    let brightness: Double
    let sampledAt: Date
}

/// No UIKit, notification center or storage dependencies. The caller supplies all time values.
struct ThresholdStateMachine {
    private(set) var configuration: MonitorConfiguration
    private(set) var history: SubmissionHistory?
    private(set) var desiredTarget: DisplayMode?
    private(set) var pendingTarget: DisplayMode?
    private(set) var stableSince: Date?
    private(set) var inFlight: NotificationCandidate?
    private var stableTarget: DisplayMode?
    private var lastAttemptAt: Date?
    private var lastSampleAt: Date?

    init(configuration: MonitorConfiguration, history: SubmissionHistory? = nil) throws {
        self.configuration = try configuration.validated()
        self.history = history
        desiredTarget = history?.target
        lastAttemptAt = history?.submittedAt
    }

    mutating func updateConfiguration(_ configuration: MonitorConfiguration) throws {
        self.configuration = try configuration.validated()
        resetStability()
    }

    /// Sleep, wake, invalid samples and configuration changes cannot prove continuous stability.
    mutating func resetStability() {
        stableTarget = nil
        stableSince = nil
        pendingTarget = nil
    }

    mutating func sample(brightness: Double, at now: Date) -> NotificationCandidate? {
        if let previous = lastSampleAt, now < previous {
            // A backwards wall clock must not fabricate a stable interval or a long future cooldown.
            resetStability()
        }
        if let attempt = lastAttemptAt, attempt > now { lastAttemptAt = now }
        lastSampleAt = now
        guard MonitorConfiguration.validBrightness(brightness) else {
            resetStability()
            return nil
        }

        let target: DisplayMode
        if brightness <= configuration.darkThreshold { target = .dark }
        else if brightness >= configuration.lightThreshold { target = .light }
        else {
            // Preserve the last desired mode, but require a new stable boundary condition.
            resetStability()
            return nil
        }
        desiredTarget = target
        if history?.target == target {
            resetStability()
            return nil
        }
        pendingTarget = target
        if stableTarget != target {
            stableTarget = target
            stableSince = now
        }
        guard inFlight == nil, let since = stableSince,
              now.timeIntervalSince(since) >= configuration.stableDuration else { return nil }
        if let attempt = lastAttemptAt,
           now.timeIntervalSince(attempt) < configuration.cooldown { return nil }

        // Only a fresh qualifying sample can emit a request after cooldown.
        let candidate = NotificationCandidate(id: UUID(), target: target,
                                              brightness: brightness, sampledAt: now)
        inFlight = candidate
        lastAttemptAt = now
        return candidate
    }

    /// Only notification-center acceptance counts as success, never shortcut execution.
    mutating func complete(_ candidate: NotificationCandidate, succeeded: Bool, at now: Date) {
        guard inFlight?.id == candidate.id else { return }
        inFlight = nil
        lastAttemptAt = now
        if succeeded {
            history = SubmissionHistory(target: candidate.target, submittedAt: now)
            if pendingTarget == candidate.target { resetStability() }
        }
        // Failure leaves the current candidate condition intact, ready to retry after cooldown.
    }
}
