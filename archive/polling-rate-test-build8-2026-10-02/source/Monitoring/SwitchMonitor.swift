import Foundation

/// Backend-independent listening, threshold and notification lifecycle on the main actor.
@MainActor
final class SwitchMonitor: MonitoringRuntime {
    private let store: any MonitorStore
    private let sampler: any BrightnessSampling
    private let notifications: any ModeNotificationSubmitting
    private let diagnostic: (String) -> Void
    private let clock: () -> Date
    private let uptime: () -> TimeInterval
    private var machine: ThresholdStateMachine
    private(set) var snapshot: RuntimeSnapshot
    private var observationGeneration = UUID()
    private var lastSampleAt: Date?
    private var lastPollAt: Date?
    private var lastSampleUptime: TimeInterval?
    private var lastSnapshotUptime: TimeInterval?
    private var pollingWindow: PollingStatistics?
    private var testStage: PollingStatistics?
    private var testStageIndex = 0
    private var completedTestID: String?
    private var testResults: [[String: String]] = []
    private var historyNeedsSave = false
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
        machine = try ThresholdStateMachine(configuration: configuration, history: history)
        var counters = previous?.counters ?? RuntimeCounters()
        counters.extensionStarts += 1
        snapshot = RuntimeSnapshot(instanceID: UUID().uuidString, history: history,
                                   appliedConfiguration: configuration, counters: counters)
        if let interruptedID = previous?.pollingTestID {
            recordPollingResult("polling_test_interrupted", [
                "testID": interruptedID, "reason": "host_restarted", "completed": "false",
                "previousInstanceID": previous?.instanceID ?? "unknown",
                "detail": "Host ended before test completion; retained stage records are partial results."
            ])
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
        finishPollingTest(reason: reason, completed: false)
        removeSampling()
        machine.resetStability()
        snapshot.phase = .stopping
        snapshot.heartbeatAt = nil
        record("monitor_stop", ["reason": reason])
        persist()
        // An already-issued add may finish after a stop request. Commit its result before teardown.
        finishStopIfPossible()
    }

    func sleep() {
        guard snapshot.phase == .running else { return }
        finishPollingTest(reason: "sleep", completed: false)
        removeSampling()
        machine.resetStability()
        snapshot.phase = .sleeping
        snapshot.heartbeatAt = nil
        record("monitor_sleep")
        persist()
    }

    func wake() {
        guard snapshot.phase == .sleeping else { return }
        machine.resetStability()
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
            finishPollingTest(reason: "configuration_changed", completed: false)
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

    func startPollingTest(id: String) -> MonitorReply {
        // The transport may repeat a request after losing its reply. Never restart the same test.
        if snapshot.pollingTestID == id || completedTestID == id {
            return MonitorReply(success: true, message: "该轮询测试请求已处理，结果写入日志。", snapshot: snapshot)
        }
        guard UUID(uuidString: id) != nil, snapshot.phase == .running, snapshot.pollingTestID == nil else {
            return MonitorReply(success: false, message: "请在监听运行且没有其他轮询测试时开始测试。", snapshot: snapshot)
        }
        do {
            try store.appendPollingResult(LogRecord(instanceID: snapshot.instanceID, event: "polling_test_start", fields: [
                "testID": id, "frequenciesHz": PollingBoost.testFrequencies.map { String($0) }.joined(separator: ","),
                "stageSeconds": String(PollingBoost.testStageDuration),
                "savedIntervalSeconds": String(machine.configuration.effectivePollInterval),
                "revision": machine.configuration.revision,
                "criterion": "deliveryRatio>=0.90;intervalP95<=1.5*requestedInterval;invalidReadings=0;apiReadCount=polls",
                "scope": "UIScreen.main.brightness getter plus main-run-loop scheduling; not panel refresh rate"
            ]))
        } catch {
            return MonitorReply(success: false, message: "无法保存测试日志：\(describeError(error))", snapshot: snapshot)
        }
        removeSampling()
        snapshot.pollingTestID = id
        testStageIndex = 0
        testResults = []
        installSampling()
        persist()
        return MonitorReply(success: true, message: "逐档轮询测试已开始，约 100 秒后自动恢复原档位；结果写入可导出日志。", snapshot: snapshot)
    }

    func stopPollingTest() -> MonitorReply {
        guard snapshot.pollingTestID != nil else {
            return MonitorReply(success: true, message: "当前没有轮询测试。", snapshot: snapshot)
        }
        finishPollingTest(reason: "user_cancelled", completed: false)
        removeSampling()
        if snapshot.phase == .running { installSampling() }
        persist()
        return MonitorReply(success: true, message: "轮询测试已停止，部分结果已写入日志并恢复原档位。", snapshot: snapshot)
    }

    private func updatePollingTest(at now: TimeInterval) {
        guard let stage = testStage, now - stage.startedAt >= PollingBoost.testStageDuration else { return }
        saveTestStage(stage, at: now, completed: true)
        testStage = nil
        testStageIndex += 1
        if testStageIndex == PollingBoost.testFrequencies.count {
            finishPollingTest(reason: "completed", completed: true)
        }
        removeSampling()
        installSampling()
        persist()
    }

    private func saveTestStage(_ stage: PollingStatistics, at now: TimeInterval, completed: Bool) {
        var fields = stage.fields(endedAt: now)
        fields["testID"] = snapshot.pollingTestID
        fields["stageIndex"] = String(testStageIndex)
        fields["completed"] = String(completed)
        testResults.append(fields)
        recordPollingResult("polling_test_stage", fields)
    }

    private func finishPollingTest(reason: String, completed: Bool) {
        guard let id = snapshot.pollingTestID else { return }
        if let stage = testStage { saveTestStage(stage, at: uptime(), completed: false) }
        let finished = testResults.filter { $0["completed"] == "true" }
        let highest = finished.filter { $0["sustained"] == "true" }
            .compactMap { $0["requestedHz"].flatMap(Double.init) }.max()
        let peak = finished.compactMap { $0["actualHz"].flatMap(Double.init) }.max()
        recordPollingResult("polling_test_summary", [
            "testID": id, "reason": reason, "completed": String(completed),
            "completedStages": String(finished.count), "highestSustainedRequestedHz": highest.map { String($0) } ?? "unmeasured",
            "peakActualHz": peak.map { String($0) } ?? "unmeasured", "testedCeilingHz": "1000",
            "ceilingSustained": String(highest == PollingBoost.testFrequencies.last),
            "interpretation": "Empirical polling throughput in this runtime; reaching 1000 Hz means the API upper limit was not found.",
            "restoredIntervalSeconds": String(machine.configuration.effectivePollInterval)
        ])
        completedTestID = id
        snapshot.pollingTestID = nil
        testStage = nil
        testResults = []
    }

    private func installSampling() {
        let interval = snapshot.pollingTestID == nil ? machine.configuration.effectivePollInterval
            : 1 / PollingBoost.testFrequencies[testStageIndex]
        snapshot.activePollInterval = interval
        let now = uptime()
        pollingWindow = PollingStatistics(startedAt: now, requestedInterval: interval)
        if snapshot.pollingTestID != nil { testStage = PollingStatistics(startedAt: now, requestedInterval: interval) }
        lastSampleAt = nil
        lastPollAt = nil
        lastSampleUptime = nil
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
        flushPollingWindow(at: uptime(), restart: false)
        snapshot.activePollInterval = nil
    }

    private func flushPollingWindow(at now: TimeInterval, restart: Bool) {
        guard let window = pollingWindow else { return }
        // Ordinary low-frequency sampling retains its per-sample logs.
        if window.polls > 0, window.requestedInterval < 1 || snapshot.pollingTestID != nil {
            var fields = window.fields(endedAt: now)
            fields["testID"] = snapshot.pollingTestID
            record("polling_window", fields)
        }
        pollingWindow = restart ? PollingStatistics(startedAt: now, requestedInterval: window.requestedInterval) : nil
    }

    private func sample(_ reading: BrightnessReading) {
        guard snapshot.phase == .running else { return }
        let now = reading.timestamp
        let source = reading.source
        let monotonicNow = reading.uptime ?? uptime()
        let activeInterval = snapshot.activePollInterval ?? machine.configuration.effectivePollInterval
        pollingWindow?.add(reading, uptime: monotonicNow)
        testStage?.add(reading, uptime: monotonicNow)
        defer { if source == .poll { updatePollingTest(at: monotonicNow) } }
        let publish = (activeInterval >= 1 && snapshot.pollingTestID == nil)
            || (lastSnapshotUptime.map { monotonicNow - $0 >= 1 } ?? true)
        if let window = pollingWindow, monotonicNow - window.startedAt >= 1 {
            flushPollingWindow(at: monotonicNow, restart: true)
        }
        let interval = lastSampleAt.map { now.timeIntervalSince($0) }
        // A long scheduling gap does not establish continuous satisfaction of a condition.
        if let previous = lastSampleUptime, monotonicNow - previous > max(2, activeInterval * 2) {
            machine.resetStability()
            record("sampling_gap", ["seconds": String(monotonicNow - previous)])
        }
        lastSampleAt = now
        lastSampleUptime = monotonicNow
        if source == .poll {
            snapshot.lastPollInterval = lastPollAt.map { now.timeIntervalSince($0) }
            lastPollAt = now
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
        let previousSince = machine.stableSince
        let candidate = machine.sample(brightness: actual, at: now)
        if previousTarget != machine.pendingTarget || previousSince != machine.stableSince {
            record("candidate_changed", ["target": machine.pendingTarget?.rawValue ?? "none",
                                          "source": source.rawValue])
        }
        if publish { lastSnapshotUptime = monotonicNow; persist() }
        if let candidate { submit(candidate, source: source) }
    }

    private func submit(_ candidate: NotificationCandidate, source: SampleSource) {
        let samplingGeneration = observationGeneration
        let stableSinceAtRequest = machine.stableSince
        let identifier = "AutoDarkShift.Mode.\(candidate.id.uuidString)"
        snapshot.submission = SubmissionSnapshot(identifier: identifier, target: candidate.target,
            brightness: candidate.brightness, source: source, timestamp: clock(), result: .submitting)
        persist()
        notifications.authorization { [weak self] authorized, authorizationDescription in
            guard let self else { return }
            guard self.snapshot.phase == .running,
                  self.observationGeneration == samplingGeneration,
                  self.machine.stableSince == stableSinceAtRequest,
                  self.machine.pendingTarget == candidate.target else {
                self.finish(candidate, result: .cancelled, detail: "监听已暂停、停止或候选条件已改变。")
                return
            }
            guard authorized else {
                self.finish(candidate, result: .blocked, detail: "通知权限不足，authorizationStatus=\(authorizationDescription)。采样继续。")
                return
            }
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
        machine.complete(candidate, succeeded: result == .success, at: now)
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
        snapshot.history = machine.history
        snapshot.desiredTarget = machine.desiredTarget
        snapshot.pendingTarget = machine.pendingTarget
        snapshot.stableSince = machine.stableSince
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

    private func recordPollingResult(_ event: String, _ fields: [String: String]) {
        do { try store.appendPollingResult(LogRecord(instanceID: snapshot.instanceID, event: event, fields: fields)) }
        catch {
            snapshot.lastError = "轮询测试日志写入失败：\(describeError(error))"
            diagnostic(snapshot.lastError ?? "polling log failure")
        }
    }
}
