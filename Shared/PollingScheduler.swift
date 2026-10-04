import Foundation
import Dispatch

/// Schedules polling without prescribing what the poll reads. Implementations deliver
/// callbacks on the main actor; waiting itself may happen on a background queue.
@MainActor protocol PollingScheduler: AnyObject {
    func start(interval: TimeInterval, tick: @escaping @MainActor () -> Void)
    func stop()
}

/// Dispatch timer backed polling. At most one main-actor callback may be pending, so a
/// blocked UI executor drops elapsed ticks instead of building an unbounded task queue.
@MainActor final class DispatchPollingScheduler: PollingScheduler {
    typealias Record = @Sendable (String, [String: String]) -> Void
    typealias Context = @MainActor () -> [String: String]

    private let record: Record
    private let context: Context
    private let queue: DispatchQueue
    private let gate = DispatchPollGate()
    private var source: DispatchSourceTimer?
    private var generation: UUID?

    init(record: @escaping Record = { _, _ in },
         context: @escaping Context = { [:] },
         queue: DispatchQueue = DispatchQueue(label: "AutoDarkShift.poll-scheduler", qos: .userInitiated)) {
        self.record = record
        self.context = context
        self.queue = queue
    }

    deinit {
        gate.invalidate()
        source?.cancel()
    }

    func start(interval: TimeInterval, tick: @escaping @MainActor () -> Void) {
        stop()
        let interval = min(3_600, max(0.001, interval.isFinite ? interval : 1))
        let token = UUID()
        generation = token
        gate.activate(token)
        let nanoseconds = max(1, Int(interval * 1_000_000_000))
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .nanoseconds(nanoseconds), repeating: .nanoseconds(nanoseconds), leeway: .milliseconds(1))
        let record = self.record
        timer.setEventHandler { [weak self, gate, record] in
            let uptime = ProcessInfo.processInfo.systemUptime
            guard let diagnostic = gate.reserve(token: token, uptime: uptime) else { return }
            if diagnostic.shouldRecord {
                record("poll_tick", [
                    "host": "app", "backend": "dispatch", "interval": String(interval),
                    "tickUptime": String(uptime), "generation": token.uuidString,
                    "count": String(diagnostic.count), "readPending": String(!diagnostic.accepted)
                ])
            }
            guard diagnostic.accepted else { return }
            Task { @MainActor [weak self] in
                guard let self, self.gate.isCurrent(token) else { return }
                tick()
                self.gate.finish(token: token)
            }
        }
        source = timer
        timer.resume()
        record("poll_scheduler_started", context().merging([
            "backend": "dispatch", "interval": String(interval), "generation": token.uuidString
        ]) { _, new in new })
    }

    func stop() {
        let oldSource = source
        source = nil
        let stoppedGeneration = generation
        generation = nil
        gate.invalidate()
        if oldSource != nil {
            oldSource?.cancel()
            record("poll_scheduler_stopped", context().merging([
                "backend": "dispatch", "generation": stoppedGeneration?.uuidString ?? "none"
            ]) { _, new in new })
        }
    }
}

/// Small lock-protected bridge used only by DispatchSource's worker and its main-actor task.
private final class DispatchPollGate: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UUID?
    private var callbackPending = false
    private var tickCount: UInt64 = 0
    private var lastDiagnosticUptime: TimeInterval = -.infinity

    func activate(_ token: UUID) {
        lock.lock(); defer { lock.unlock() }
        generation = token
        callbackPending = false
        tickCount = 0
        lastDiagnosticUptime = -.infinity
    }

    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        generation = nil
        callbackPending = false
    }

    func reserve(token: UUID, uptime: TimeInterval) -> (accepted: Bool, shouldRecord: Bool, count: UInt64)? {
        lock.lock(); defer { lock.unlock() }
        guard generation == token else { return nil }
        tickCount &+= 1
        let shouldRecord = uptime - lastDiagnosticUptime >= 1
        if shouldRecord { lastDiagnosticUptime = uptime }
        guard !callbackPending else { return (false, shouldRecord, tickCount) }
        callbackPending = true
        return (true, shouldRecord, tickCount)
    }

    func isCurrent(_ token: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return generation == token
    }

    func finish(token: UUID) {
        lock.lock(); defer { lock.unlock() }
        if generation == token { callbackPending = false }
    }
}
