import Foundation

/// App composition owns the choice of process. KeepAliveManager has no knowledge of this policy.
/// VPN owns the listener while it connects/runs; otherwise exactly one in-app runtime owns it.
@MainActor final class MonitoringHostCoordinator: MonitoringClient {
    private let vpn: any MonitoringClient
    private let vpnState: () -> KeepAliveState
    private let configurationStore: any MonitorStore
    private let localStore: any MonitorStore
    private let makeRuntime: () throws -> any MonitoringRuntime
    private let exportLocal: (MonitorLogStream) throws -> String
    private let record: (String, [String: String]) -> Void
    private let context: () -> [String: String]
    private var runtime: (any MonitoringRuntime)?
    private var reconcileTask: Task<Void, Error>?
    private var vpnRequested = false
    private var appExecutionAllowed = true
    private var host = "none"
    var onHostChange: (() -> Void)?

    init(vpn: any MonitoringClient, vpnState: @escaping () -> KeepAliveState,
         configurationStore: any MonitorStore, localStore: any MonitorStore,
         makeRuntime: @escaping () throws -> any MonitoringRuntime,
         exportLocal: @escaping (MonitorLogStream) throws -> String,
         record: @escaping (String, [String: String]) -> Void = { _, _ in },
         context: @escaping () -> [String: String] = { [:] }) {
        self.vpn = vpn; self.vpnState = vpnState
        self.configurationStore = configurationStore; self.localStore = localStore
        self.makeRuntime = makeRuntime; self.exportLocal = exportLocal
        self.record = record; self.context = context
    }

    var usesVPN: Bool {
        vpnRequested || [.starting, .active, .reasserting, .stopping].contains(vpnState().phase)
    }
    var canMessage: Bool { usesVPN ? vpnState().phase.canMessage : runtime != nil }
    var hostName: String { usesVPN ? "VPN 扩展" : "App 内监听" }
    /// In-process snapshot for diagnostics only; status queries remain read-only and
    /// do not synthesize heartbeat or poll timestamps.
    var localRuntimeSnapshot: RuntimeSnapshot? { runtime?.snapshot }

    /// Controls only the App-hosted runtime. A foreground App remains eligible to
    /// sample; in the background, the caller grants execution only for an active
    /// platform keep-alive method.
    func setAppExecutionAllowed(_ allowed: Bool) {
        let changed = appExecutionAllowed != allowed
        appExecutionAllowed = allowed
        let phase = runtime?.snapshot.phase
        let needsWake = allowed && phase == .sleeping
        let needsSleep = !allowed && phase == .running
        guard changed || needsWake || needsSleep else { return }
        log("app_execution_allowed", ["allowed": String(allowed), "changed": String(changed)])
        guard !usesVPN, let runtime else { return }
        // Reconcile desired policy with actual runtime phase even when the policy
        // value repeats. A previous transition may have left the runtime sleeping.
        if allowed, runtime.snapshot.phase == .sleeping {
            runtime.wake()
            log("monitor_wake", ["reason": "execution_allowed"])
        } else if !allowed, runtime.snapshot.phase == .running {
            runtime.sleep()
            log("monitor_sleep", ["reason": "execution_disallowed"])
        }
    }

    func prepareForVPNStart() async throws {
        vpnRequested = true
        try await reconcile()
    }
    func finishVPNStartRequest() async throws {
        vpnRequested = false
        try await reconcile()
    }

    /// Disables this business and waits until its samples are stopped and any
    /// notification request already handed to the system has a terminal result.
    /// The VPN remains connected; only its monitoring runtime is disabled.
    func disableAndDrain(_ configuration: MonitorConfiguration) async throws -> MonitorReply {
        let disabled = try configuration.validated()
        guard !disabled.isEnabled else {
            throw ProjectError.message("disableAndDrain 需要已关闭的监听配置。")
        }
        try configurationStore.saveConfiguration(disabled)
        try localStore.saveConfiguration(disabled)

        if let reconcileTask { try await reconcileTask.value }

        if usesVPN {
            let initial = try await vpn.queryStatus()
            guard initial.success, let initialSnapshot = initial.snapshot else {
                throw ProjectError.message("VPN 监听状态不可读：\(initial.message)")
            }
            if let history = initialSnapshot.history { try mergeHistory(history) }
            if initialSnapshot.phase == .stopped && initialSnapshot.submission?.result != .submitting {
                return initial
            }
            let applied = try await vpn.applyConfiguration(disabled)
            guard applied.success, applied.appliedRevision == disabled.revision else {
                throw ProjectError.message("VPN 扩展未确认关闭监听：\(applied.message)")
            }
            var reply = applied
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while true {
                guard reply.success, let snapshot = reply.snapshot else {
                    throw ProjectError.message("VPN 监听关闭状态不可读：\(reply.message)")
                }
                if let history = snapshot.history { try mergeHistory(history) }
                if Self.isDisabledAndSettled(snapshot, revision: disabled.revision) ||
                    (snapshot.phase == .stopped && snapshot.submission?.result != .submitting) {
                    return reply
                }
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    throw MonitorChannelError.bridgeUnavailable("VPN 监听未能确认停采样及通知结算。")
                }
                try await Task.sleep(nanoseconds: 100_000_000)
                reply = try await vpn.queryStatus()
            }
        }

        guard let current = runtime else {
            let prior = try localStore.snapshot()
            if let history = prior?.history { try mergeHistory(history) }
            var snapshot = RuntimeSnapshot(instanceID: "not-started", phase: .stopped,
                history: prior?.history, appliedConfiguration: disabled,
                counters: prior?.counters ?? RuntimeCounters())
            snapshot.sample = nil
            snapshot.heartbeatAt = nil
            snapshot.activePollInterval = nil
            // A prior process's snapshot is historical. Keep only a terminal submission;
            // an orphaned `submitting` record cannot be completed by this process.
            if let submission = prior?.submission, submission.result != .submitting {
                snapshot.submission = submission
            }
            try localStore.saveSnapshot(snapshot)
            return MonitorReply(success: true, message: "App 内监听未初始化或已停止。", snapshot: snapshot)
        }

        if current.snapshot.phase == .running || current.snapshot.phase == .sleeping {
            let applied = current.reload(expectedRevision: disabled.revision)
            guard applied.success, applied.appliedRevision == disabled.revision else {
                throw ProjectError.message("App 内监听未确认关闭配置：\(applied.message)")
            }
        } else if current.snapshot.phase != .stopped && current.snapshot.phase != .failed &&
                    current.snapshot.phase != .stopping {
            throw MonitorChannelError.bridgeUnavailable("App 内监听状态无法确认。")
        }

        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while !Self.isDisabledAndSettled(current.snapshot, revision: disabled.revision) &&
                !(current.snapshot.phase == .stopped && current.snapshot.submission?.result != .submitting) {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw MonitorChannelError.bridgeUnavailable("App 内监听未能确认停采样及通知结算。")
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        await withCheckedContinuation { continuation in
            current.stop(reason: "business_disabled", finalPhase: .stopped) { continuation.resume() }
        }
        if let history = current.snapshot.history { try mergeHistory(history) }
        runtime = nil
        let reply = current.statusReply()
        guard reply.success, reply.snapshot?.phase == .stopped,
              reply.snapshot?.submission?.result != .submitting else {
            throw MonitorChannelError.bridgeUnavailable("App 内监听停止尚未确认。")
        }
        publishHost("none")
        log("monitor_host_released", ["reason": "business_disabled"])
        return reply
    }

    private static func isDisabledAndSettled(_ snapshot: RuntimeSnapshot, revision: String) -> Bool {
        snapshot.appliedConfiguration.revision == revision &&
            !snapshot.appliedConfiguration.isEnabled && snapshot.activePollInterval == nil &&
            snapshot.submission?.result != .submitting
    }

    func prepareForVPNStop() async throws -> MonitorReply {
        var reply = try await vpn.prepareHostHandoff()
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while true {
            guard reply.success, let snapshot = reply.snapshot else { throw ProjectError.message(reply.message) }
            if let history = snapshot.history { try mergeHistory(history) }
            if snapshot.phase == .stopped { return reply }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw MonitorChannelError.bridgeUnavailable("交接时尚未确认在途通知完成；保留已取得的历史。")
            }
            try await Task.sleep(nanoseconds: 100_000_000)
            reply = try await vpn.queryStatus()
        }
    }

    /// Performs a full host handoff. Business switches use disableAndDrain so a
    /// VPN host can remain connected with monitoring disabled.
    func prepareHostHandoff() async throws -> MonitorReply {
        if usesVPN { return try await prepareForVPNStop() }

        guard let current = runtime else {
            guard let snapshot = try localStore.snapshot(), snapshot.phase == .stopped,
                  snapshot.submission?.result != .submitting else {
                throw MonitorChannelError.bridgeUnavailable("App 内监听没有可确认的停止快照。")
            }
            if let history = snapshot.history { try mergeHistory(history) }
            return MonitorReply(success: true, message: "App 内监听已停止。", snapshot: snapshot)
        }

        await withCheckedContinuation { continuation in
            current.stop(reason: "business_handoff", finalPhase: .stopped) { continuation.resume() }
        }
        if let history = current.snapshot.history { try mergeHistory(history) }
        runtime = nil
        let reply = current.statusReply()
        guard reply.success, reply.snapshot?.phase == .stopped,
              reply.snapshot?.submission?.result != .submitting else {
            throw MonitorChannelError.bridgeUnavailable("App 内监听停止尚未确认。")
        }
        publishHost("none")
        log("monitor_host_released", ["reason": "business_handoff"])
        return reply
    }

    func reconcile() async throws {
        if let reconcileTask {
            try await reconcileTask.value
            // The shared task can suspend while a notification commits. Reapply
            // the latest app execution policy after it finishes, not its captured
            // value from before the suspension.
            applyCurrentExecutionPolicy()
            return
        }
        let task = Task { @MainActor in
            repeat {
                let remote = self.usesVPN
                if remote {
                    if let current = self.runtime {
                        // Wait for an already-issued notification to commit before changing process.
                        await withCheckedContinuation { continuation in
                            current.stop(reason: "host_handoff_to_vpn", finalPhase: .stopped) { continuation.resume() }
                        }
                        if let history = current.snapshot.history { try self.mergeHistory(history) }
                        self.runtime = nil
                    }
                    self.publishHost("vpn")
                    self.log("monitor_host_selected", ["host": "vpn"])
                } else if self.runtime == nil {
                    let configuration = try self.configurationStore.configuration()
                    // SwitchMonitor.start() samples immediately when enabled. Seed a
                    // disabled config when background execution is unavailable, then
                    // restore the saved config while sleeping so no background sample
                    // slips through during runtime creation.
                    var startupConfiguration = configuration
                    if !self.appExecutionAllowed { startupConfiguration.isEnabled = false }
                    var createdRuntime: (any MonitoringRuntime)?
                    do {
                        try self.localStore.saveConfiguration(startupConfiguration)
                        if let history = try self.configurationStore.history() { try self.mergeHistory(history) }
                        let current = try self.makeRuntime()
                        createdRuntime = current
                        try current.start()
                        if !self.appExecutionAllowed {
                            current.sleep()
                            if startupConfiguration != configuration {
                                try self.localStore.saveConfiguration(configuration)
                                let reply = current.reload(expectedRevision: configuration.revision)
                                guard reply.success, reply.appliedRevision == configuration.revision else {
                                    throw ProjectError.message(reply.message)
                                }
                            }
                        }
                        self.runtime = current
                    } catch {
                        if let current = createdRuntime {
                            await withCheckedContinuation { continuation in
                                current.stop(reason: "host_start_failed", finalPhase: .failed) { continuation.resume() }
                            }
                        }
                        try? self.localStore.saveConfiguration(configuration)
                        throw error
                    }
                    self.publishHost("app")
                    self.log("monitor_host_selected", ["host": "app"])
                }
                if remote == self.usesVPN { break }
            } while !Task.isCancelled
        }
        reconcileTask = task
        defer { reconcileTask = nil }
        try await task.value
        applyCurrentExecutionPolicy()
    }

    func queryStatus() async throws -> MonitorReply {
        if usesVPN {
            let reply = try await vpn.queryStatus()
            if let history = reply.snapshot?.history { try mergeHistory(history) }
            return reply
        }
        try await reconcile()
        guard let runtime else { throw MonitorChannelError.bridgeUnavailable("监听宿主正在切换。") }
        let reply = runtime.statusReply()
        if let history = reply.snapshot?.history { try mergeHistory(history) }
        return reply
    }

    func applyConfiguration(_ configuration: MonitorConfiguration) async throws -> MonitorReply {
        try localStore.saveConfiguration(configuration)
        if usesVPN { return try await vpn.applyConfiguration(configuration) }
        try await reconcile()
        guard let runtime else { throw MonitorChannelError.bridgeUnavailable("App 内监听未初始化。") }
        return runtime.reload(expectedRevision: configuration.revision)
    }

    func diagnostics(stream: MonitorLogStream) async throws -> String {
        if usesVPN { return try await vpn.diagnostics(stream: stream) }
        return try localDiagnostics(stream: stream)
    }

    /// Local and provider logs retain separate stores across host changes.
    func localDiagnostics(stream: MonitorLogStream) throws -> String {
        runtime?.flushDiagnostics()
        return try exportLocal(stream)
    }

    private func mergeHistory(_ history: SubmissionHistory) throws {
        for store in [configurationStore, localStore] {
            if let previous = try store.history(), previous.submittedAt >= history.submittedAt { continue }
            try store.saveHistory(history)
        }
    }
    private func publishHost(_ value: String) {
        guard host != value else { return }
        host = value
        onHostChange?()
    }

    private func applyCurrentExecutionPolicy() {
        guard !usesVPN, let runtime else { return }
        if appExecutionAllowed, runtime.snapshot.phase == .sleeping {
            runtime.wake()
            log("monitor_wake", ["reason": "reconcile_policy"])
        } else if !appExecutionAllowed, runtime.snapshot.phase == .running {
            runtime.sleep()
            log("monitor_sleep", ["reason": "reconcile_policy"])
        }
    }

    private func log(_ event: String, _ fields: [String: String] = [:]) {
        var values = context()
        values["listenerHost"] = usesVPN ? "vpn" : (runtime == nil ? host : "app")
        values["appExecutionAllowed"] = String(appExecutionAllowed)
        values["pipPhase"] = values["pipPhase"] ?? "unknown"
        values["appForeground"] = values["appForeground"] ?? "unknown"
        if let snapshot = runtime?.snapshot {
            values["runtimePhase"] = snapshot.phase.rawValue
            values["pollInterval"] = snapshot.activePollInterval.map { String($0) } ?? "none"
            values["heartbeatAt"] = snapshot.heartbeatAt.map(Self.timestamp) ?? "none"
            values["lastPollAt"] = snapshot.lastPollAt.map(Self.timestamp) ?? "none"
        } else {
            values["runtimePhase"] = "none"
            values["pollInterval"] = "none"
            values["heartbeatAt"] = "none"
            values["lastPollAt"] = "none"
        }
        values.merge(fields) { _, latest in latest }
        record(event, values)
    }

    private static func timestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
