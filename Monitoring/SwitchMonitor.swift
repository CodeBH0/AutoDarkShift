import Foundation

/// Backend-independent trend scoring, dynamic sampling and notification lifecycle.
@MainActor
final class SwitchMonitor: MonitoringRuntime {
    private let store: any MonitorStore
    private let sampler: any BrightnessSampling
    private let notifications: any ModeNotificationSubmitting
    private let diagnostic: (String) -> Void
    private let clock: () -> Date
    private let uptime: () -> TimeInterval
    private var machine: BrightnessTrendStateMachine
    private var boostTrace: BoostTraceRecorder!
    private(set) var snapshot: RuntimeSnapshot
    private var observationGeneration = UUID()
    private var lastSampleAt: Date?
    private var lastPollAt: Date?
    private var lastPollUptime: TimeInterval?
    private var lastSampleUptime: TimeInterval?
    private var lastSnapshotUptime: TimeInterval?
    private var historyNeedsSave = false
    private var notificationStartedID: UUID?
    private var stopCallbacks: [() -> Void] = []
    private var stopFinalPhase: RuntimePhase = .stopped

    init(store: any MonitorStore, sampler: any BrightnessSampling,
         notifications: any ModeNotificationSubmitting, clock: @escaping () -> Date = Date.init,
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         diagnostic: @escaping (String) -> Void = { _ in }) throws {
        self.store = store
        self.sampler = sampler
        self.notifications = notifications
        self.clock = clock
        self.uptime = uptime
        self.diagnostic = diagnostic
        let configuration = try store.configuration()
        let previous = try store.snapshot()
        let history = try store.history()
        machine = try BrightnessTrendStateMachine(configuration: configuration, history: history)
        var counters = previous?.counters ?? RuntimeCounters()
        counters.extensionStarts += 1
        snapshot = RuntimeSnapshot(instanceID: UUID().uuidString, history: history,
                                   appliedConfiguration: configuration, counters: counters)
        try store.recoverBoostTraces(instanceID: snapshot.instanceID, at: clock())
        boostTrace = BoostTraceRecorder(store: store, instanceID: snapshot.instanceID) { [weak self] detail in
            guard let self else { return }
            self.snapshot.lastError = "完整亮度日志写入失败：\(detail)"
            self.record("boost_trace_error", ["detail": detail])
            self.diagnostic(detail)
        }
        record("monitor_start", ["revision": configuration.revision])
        try store.saveSnapshot(snapshot)
    }

    func start() throws {
        guard snapshot.phase == .starting else { throw ProjectError.message("监听已启动；请创建新的运行实例。") }
        snapshot.phase = .running
        installSampling()
        sampler.sampleNow(.initial)
        // Do not report startup success if the initial status cannot be shared.
        do { try store.saveSnapshot(snapshot) }
        catch {
            removeSampling()
            snapshot.phase = .failed
            snapshot.heartbeatAt = nil
            throw error
        }
        record("monitor_ready")
    }

    func fail(_ error: Error, completion: @escaping () -> Void) {
        snapshot.lastError = describeError(error)
        record("monitor_error", ["error": describeError(error)])
        persist()
        stop(reason: "startup_failure", finalPhase: .failed, completion: completion)
    }

    func stop(reason: String, finalPhase: RuntimePhase = .stopped, completion: @escaping () -> Void) {
        if snapshot.phase == .stopped || snapshot.phase == .failed, machine.inFlight == nil {
            completion()
            return
        }
        stopCallbacks.append(completion)
        guard snapshot.phase != .stopping else { return }
        stopFinalPhase = finalPhase
        boostTrace.interrupt(reason: "stop:\(reason)", at: clock())
        removeSampling()
        machine.resetObservations()
        snapshot.phase = .stopping
        snapshot.heartbeatAt = nil
        record("monitor_stop", ["reason": reason])
        persist()
        // An already-issued add may finish after a stop request. Commit its result before teardown.
        finishStopIfPossible()
    }

    func sleep() {
        guard snapshot.phase == .running else { return }
        boostTrace.interrupt(reason: "sleep", at: clock())
        removeSampling()
        machine.resetObservations()
        snapshot.phase = .sleeping
        snapshot.heartbeatAt = nil
        record("monitor_sleep")
        persist()
    }

    func wake() {
        guard snapshot.phase == .sleeping else { return }
        machine.resetObservations()
        snapshot.phase = .running
        record("monitor_wake")
        installSampling()
        sampler.sampleNow(.wake)
    }

    func reload(expectedRevision: String?) -> MonitorReply {
        do {
            guard snapshot.phase == .running || snapshot.phase == .sleeping else {
                throw ProjectError.message("监听未运行，配置将在下次启动时应用。")
            }
            let configuration = try store.configuration()
            if let expectedRevision, expectedRevision != configuration.revision {
                throw ProjectError.message("配置版本已变化，请重新保存。")
            }
            try machine.updateConfiguration(configuration)
            boostTrace.interrupt(reason: "configuration_reload", at: clock())
            snapshot.appliedConfiguration = configuration
            record("configuration_applied", ["revision": configuration.revision])
            if snapshot.phase == .running { removeSampling(); installSampling() }
            syncMachine()
            snapshot.updatedAt = clock()
            try store.saveSnapshot(snapshot)
            return MonitorReply(success: true, message: "监听已应用配置。", appliedRevision: configuration.revision, snapshot: snapshot)
        } catch {
            snapshot.lastError = describeError(error)
            record("configuration_error", ["error": describeError(error)])
            persist()
            return MonitorReply(success: false, message: describeError(error),
                                 appliedRevision: snapshot.appliedConfiguration.revision, snapshot: snapshot)
        }
    }

    func statusReply() -> MonitorReply {
        // Querying status is deliberately not a heartbeat or a brightness sample.
        syncMachine()
        return MonitorReply(success: true, message: "监听状态快照。",
                             appliedRevision: snapshot.appliedConfiguration.revision, snapshot: snapshot)
    }

    func flushDiagnostics() {
        boostTrace.flush()
        syncMachine()
    }

    private func installSampling() {
        let interval = machine.pollInterval
        snapshot.activePollInterval = interval
        lastSampleAt = nil
        lastPollAt = nil
        lastPollUptime = nil
        lastSampleUptime = nil
        lastSnapshotUptime = nil
        let generation = UUID()
        observationGeneration = generation
        sampler.start(interval: interval) { [weak self] reading in
            guard let self, self.observationGeneration == generation,
                  self.snapshot.phase == .running else { return }
            if reading.source == .event { self.snapshot.counters.eventCallbacks += 1 }
            if reading.source == .poll { self.snapshot.counters.polls += 1 }
            self.sample(reading)
        }
    }

    private func removeSampling() {
        observationGeneration = UUID()
        sampler.stop()
        snapshot.activePollInterval = nil
    }

    private func sample(_ reading: BrightnessReading) {
        guard snapshot.phase == .running else { return }
        let now = reading.timestamp
        let source = reading.source
        let monotonicNow = reading.uptime ?? uptime()
        let activeInterval = machine.pollInterval
        // Evaluate every read; event bursts must also respect the routine write cadence.
        let publish = lastSnapshotUptime.map { monotonicNow - $0 >= 1 } ?? true
        let interval = lastSampleAt.map { now.timeIntervalSince($0) }
        // A long scheduling gap does not establish continuous satisfaction of a condition.
        if let previous = lastSampleUptime, monotonicNow - previous > max(2, activeInterval * 2) {
            boostTrace.interrupt(reason: "sampling_gap", at: now)
            machine.resetObservations()
            record("sampling_gap", ["seconds": String(monotonicNow - previous)])
        }
        if let previous = lastSampleUptime, monotonicNow < previous {
            boostTrace.interrupt(reason: "clock_regression", at: now)
        }
        let pollInterval = source == .poll ? lastPollUptime.map { monotonicNow - $0 } : nil
        lastSampleAt = now
        lastSampleUptime = monotonicNow
        if source == .poll {
            snapshot.lastPollInterval = lastPollAt.map { now.timeIntervalSince($0) }
            lastPollAt = now
            lastPollUptime = monotonicNow
            snapshot.lastPollAt = now
        }
        // No app-supplied value, fallback value or brightness mutation is used here.
        let actual = reading.value
        let valid = MonitorConfiguration.validBrightness(actual)
        snapshot.counters.samples += 1
        snapshot.sample = SampleSnapshot(timestamp: now, source: source, brightness: valid ? actual : nil,
                                         rawValue: String(actual), sequence: snapshot.counters.samples,
                                         actualInterval: interval)
        snapshot.heartbeatAt = now
        if publish {
            var fields = ["source": source.rawValue, "brightness": String(actual),
                          "sequence": String(snapshot.counters.samples), "valid": String(valid)]
            if let interval { fields["actualInterval"] = String(interval) }
            if source == .poll, let interval = snapshot.lastPollInterval { fields["pollInterval"] = String(interval) }
            record("sample", fields)
        }
        if !valid {
            snapshot.lastError = "采样源返回非法亮度：\(actual)；未使用缓存值。"
            if publish { record("invalid_brightness", ["rawValue": String(actual), "source": source.rawValue]) }
        }
        let previousTarget = machine.pendingTarget
        let wasDynamic = machine.trend?.dynamicSampling ?? false
        let candidate = machine.sample(brightness: actual, at: now, uptime: monotonicNow, source: source)
        boostTrace.consume(reading, sample: snapshot.sample!, uptime: monotonicNow,
            previousInterval: activeInterval, nextInterval: machine.pollInterval, pollInterval: pollInterval,
            trend: machine.trend, enteredBoost: !wasDynamic && machine.trend?.dynamicSampling == true,
            configuration: machine.configuration, desired: machine.desiredTarget, pending: machine.pendingTarget,
            candidate: candidate, inFlight: machine.inFlight)
        let samplingChanged = snapshot.activePollInterval != machine.pollInterval
        if samplingChanged {
            sampler.updateInterval(machine.pollInterval)
            snapshot.activePollInterval = machine.pollInterval
            record("sampling_rate_changed", trendFields().merging([
                "previousFrequency": String(1 / activeInterval),
                "frequency": String(1 / machine.pollInterval)
            ]) { _, new in new })
        }
        if publish { record("trend_score", trendFields()) }
        if previousTarget != machine.pendingTarget {
            record("candidate_changed", ["target": machine.pendingTarget?.rawValue ?? "none",
                                          "source": source.rawValue,
                                          "score": machine.trend.map { String($0.score) } ?? "none"])
        }
        if publish || samplingChanged { lastSnapshotUptime = monotonicNow; persist() }
        if let candidate { submit(candidate, source: source) }
    }

    private func submit(_ candidate: NotificationCandidate, source: SampleSource) {
        let samplingGeneration = observationGeneration
        let identifier = "AutoDarkShift.Mode.\(candidate.id.uuidString)"
        snapshot.submission = SubmissionSnapshot(identifier: identifier, target: candidate.target,
            brightness: candidate.brightness, source: source, timestamp: clock(), result: .submitting)
        persist()
        notifications.authorization { [weak self] authorized, authorizationDescription in
            guard let self else { return }
            guard self.machine.inFlight?.id == candidate.id,
                  self.notificationStartedID != candidate.id else { return }
            guard self.snapshot.phase == .running,
                  self.observationGeneration == samplingGeneration else {
                self.finish(candidate, result: .cancelled, detail: "监听已暂停、停止或配置已重新应用；请求尚未提交通知中心。")
                return
            }
            guard authorized else {
                self.finish(candidate, result: .blocked, detail: "通知权限不足，authorizationStatus=\(authorizationDescription)。采样继续。")
                return
            }
            self.notificationStartedID = candidate.id
            self.snapshot.counters.notificationAttempts += 1
            self.record("notification_submit", ["identifier": identifier, "target": candidate.target.rawValue,
                                                 "brightness": String(candidate.brightness), "source": source.rawValue])
            self.persist()
            self.notifications.submit(candidate, source: source) { [weak self] error in
                self?.finish(candidate, result: error == nil ? .success : .failed, detail: error.map(describeError))
            }
        }
    }

    private func finish(_ candidate: NotificationCandidate, result: SubmissionResult, detail: String?) {
        guard machine.inFlight?.id == candidate.id else { return }
        let now = clock()
        machine.complete(candidate, result: result, at: now)
        notificationStartedID = nil
        snapshot.submission?.timestamp = now
        snapshot.submission?.result = result
        snapshot.submission?.detail = detail
        if result == .success {
            snapshot.counters.notificationSuccesses += 1
            historyNeedsSave = true
        } else if let detail, result != .cancelled { snapshot.lastError = detail }
        record("notification_result", ["identifier": snapshot.submission?.identifier ?? candidate.id.uuidString,
                                        "target": candidate.target.rawValue, "result": result.rawValue,
                                        "detail": detail ?? "系统接受了通知请求；尚未确认快捷指令执行。"])
        persist()
        finishStopIfPossible()
    }

    private func finishStopIfPossible() {
        guard machine.inFlight == nil, !stopCallbacks.isEmpty else { return }
        let callbacks = stopCallbacks
        stopCallbacks = []
        snapshot.phase = stopFinalPhase
        persist()
        callbacks.forEach { $0() }
    }

    private func syncMachine() {
        snapshot.boostTraceIDs = boostTrace.activeIDs
        snapshot.history = machine.history
        snapshot.desiredTarget = machine.desiredTarget
        snapshot.pendingTarget = machine.pendingTarget
        snapshot.trend = machine.trend
    }

    private func trendFields() -> [String: String] {
        guard let trend = machine.trend else { return ["valid": "false"] }
        return ["A": String(trend.position), "delta": String(trend.change),
                "V": String(trend.speed), "S": String(trend.score),
                "velocity": String(trend.velocity), "baseline": trend.baseline.map { String($0) } ?? "none",
                "dynamicSampling": String(trend.dynamicSampling), "quietDuration": String(trend.quietDuration),
                "source": snapshot.sample?.source.rawValue ?? "none",
                "sequence": String(snapshot.counters.samples)]
    }

    private func persist() {
        syncMachine()
        snapshot.updatedAt = clock()
        do {
            if historyNeedsSave, let history = machine.history {
                try store.saveHistory(history)
                historyNeedsSave = false
            }
            try store.saveSnapshot(snapshot)
        } catch {
            snapshot.lastError = "共享状态写入失败：\(describeError(error))"
            diagnostic(snapshot.lastError ?? "storage failure")
            // Future samples retry history persistence. No fabricated success is written.
        }
    }

    private func record(_ event: String, _ fields: [String: String] = [:]) {
        do { try store.append(LogRecord(instanceID: snapshot.instanceID, event: event, fields: fields)) }
        catch {
            snapshot.lastError = "日志写入失败：\(describeError(error))"
            diagnostic(snapshot.lastError ?? "log failure")
        }
    }

}
