import Foundation
import Combine
import UserNotifications
import UIKit

@MainActor
final class AppController: ObservableObject {
    @Published var configuration = MonitorConfiguration()
    @Published private(set) var autoDarkShiftEnabled = true
    @Published private(set) var keepAliveEntries: [KeepAliveEntry] = []
    let pipService: PiPKeepAliveService?
    @Published private(set) var keepAliveState = KeepAliveState()
    @Published private(set) var runtimeConfirmed = false
    @Published private(set) var runtimeError: String?
    @Published private(set) var runtimeNotice: String?
    @Published private(set) var storageError: String?
    @Published private(set) var storageNotice: String?
    @Published private(set) var keepAliveEnabled = false
    @Published private(set) var keepAliveTransitioning = false
    @Published private(set) var authorization = "读取中"
    @Published private(set) var snapshot: RuntimeSnapshot?
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    @Published private(set) var appError: String?
    @Published private(set) var disconnectError: String?
    @Published private(set) var testFeedback: String?
    @Published private(set) var now = Date()
    @Published var exportURLs: [URL] = []

    private var store: SharedStore?
    private let storageMode: RuntimeStorageMode
    private let fallbackReason: String?
    private let keepAliveManager: KeepAliveManager
    private let hostCoordinator: MonitoringHostCoordinator?
    private let keepAlive: any KeepAliveService
    private let monitoring: any MonitoringClient
    private let diagnosticsStore: SharedStore?
    private let record: (String, [String: String]) -> Void
    private var refreshTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var diagnosticTask: Task<Void, Never>?
    private var lastDiagnosticSyncAt = Date.distantPast
    private var diagnosticSyncErrors: [MonitorLogStream: String] = [:]
    private var diagnosticSyncedAt: [MonitorLogStream: Date] = [:]
    private var sessionGeneration = UUID()
    private var readback = MonitoringReadback()
    private var appIsForeground = true
    private var vpnOperation: Bool?
    private var queuedVPNIntent: Bool?

    init(keepAlive: any KeepAliveService, monitoring: any MonitoringClient,
         storage: RuntimeStoreSelection?, storageError: String?,
         diagnostics: SharedStore?, record: @escaping (String, [String: String]) -> Void,
         keepAliveManager: KeepAliveManager? = nil, hostCoordinator: MonitoringHostCoordinator? = nil,
         pipService: PiPKeepAliveService? = nil) {
        self.keepAlive = keepAlive
        self.monitoring = monitoring
        self.diagnosticsStore = diagnostics
        self.record = record
        self.keepAliveManager = keepAliveManager ?? KeepAliveManager(services: [(.vpn, keepAlive)])
        self.hostCoordinator = hostCoordinator
        self.pipService = pipService
        self.store = storage?.store
        self.storageMode = storage?.mode ?? .appGroup
        self.fallbackReason = storage?.fallbackReason
        self.storageError = storageError
        if storage?.mode == .localIPC {
            storageNotice = "当前使用本地运行存储。"
        }
        do {
            if let store { configuration = try store.configuration(); snapshot = try store.snapshot() }
        } catch { self.storageError = describeError(error) }
        record("app_launch", ["storageMode": self.storageMode.rawValue,
                              "identity": String(describing: RuntimeIdentity.installed(storageMode: self.storageMode)),
                              "storageError": self.storageError ?? "none", "storageFallbackReason": fallbackReason ?? "none"])
        autoDarkShiftEnabled = configuration.isEnabled
        updateSwitchState()
        self.keepAliveManager.onChange = { [weak self] in
            guard let self else { return }
            self.updateSwitchState()
            self.acceptState(self.keepAlive.state)
            self.updateLocalExecutionPolicy()
            Task {
                do { try await self.hostCoordinator?.reconcile(); self.scheduleQuery() }
                catch { self.appError = describeError(error) }
            }
        }
        hostCoordinator?.onHostChange = { [weak self] in
            guard let self else { return }
            self.sessionGeneration = UUID()
            self.statusTask?.cancel(); self.statusTask = nil
            self.diagnosticTask?.cancel(); self.diagnosticTask = nil
            self.lastDiagnosticSyncAt = .distantPast
            self.diagnosticSyncErrors.removeAll(); self.diagnosticSyncedAt.removeAll()
            self.runtimeConfirmed = false
            self.snapshot = nil
            self.readback.reset()
            self.record("monitor_host_changed", ["host": self.hostCoordinator?.hostName ?? "VPN"])
            self.scheduleQuery()
        }
        acceptState(keepAlive.state)
        Task {
            await self.keepAliveManager.refresh()
            do { try await self.hostCoordinator?.reconcile(); self.scheduleQuery() }
            catch { appError = describeError(error); record("monitor_host_setup_error", ["error": describeError(error)]) }
            await refreshAuthorization()
        }
    }

    deinit { refreshTask?.cancel(); statusTask?.cancel(); diagnosticTask?.cancel() }

    var keepAliveName: String { keepAlive.name }
    var canReadMonitoring: Bool { hostCoordinator?.canMessage ?? keepAliveState.phase.canMessage }
    private var usesVPNMonitoring: Bool { hostCoordinator?.usesVPN ?? true }
    var keepAliveStatusText: String { keepAliveState.description }

    private func acceptState(_ state: KeepAliveState) {
        let previous = keepAliveState.phase
        keepAliveState = state
        updateSwitchState()
        disconnectError = state.lastError
        guard previous != state.phase, usesVPNMonitoring else { return }
        if !state.phase.canMessage {
            sessionGeneration = UUID()
            statusTask?.cancel()
            statusTask = nil
            diagnosticTask?.cancel()
            diagnosticTask = nil
            lastDiagnosticSyncAt = .distantPast
            diagnosticSyncErrors.removeAll()
            diagnosticSyncedAt.removeAll()
            runtimeConfirmed = false
            runtimeError = nil
            runtimeNotice = nil
            readback.reset()
        } else if previous != state.phase {
            runtimeConfirmed = false
            runtimeError = nil
            runtimeNotice = nil
            readback.reset()
            scheduleQuery()
        }
    }

    private func scheduleQuery() {
        guard statusTask == nil, canReadMonitoring, readback.shouldQuery(at: Date()) else { return }
        let token = sessionGeneration
        statusTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.sessionGeneration == token { self.statusTask = nil } }
            do {
                var reply = try await self.monitoring.queryStatus()
                guard self.sessionGeneration == token, !Task.isCancelled else { return }
                // A saved switch change during VPN setup may follow the captured start options.
                // Reapply persisted configuration after the actual host becomes readable.
                if self.vpnOperation == nil, let store = self.store, let snapshot = reply.snapshot,
                   [.running, .sleeping].contains(snapshot.phase) {
                    let saved = try store.configuration()
                    if snapshot.appliedConfiguration.revision != saved.revision {
                        reply = try await self.monitoring.applyConfiguration(saved)
                    }
                }
                guard self.sessionGeneration == token, !Task.isCancelled else { return }
                self.acceptReply(reply)
            } catch {
                guard self.sessionGeneration == token, !Task.isCancelled else { return }
                self.acceptMonitorError(error)
            }
        }
    }

    var heartbeatAge: TimeInterval? {
        snapshot?.heartbeatAt.map { max(0, now.timeIntervalSince($0)) }
    }
    var heartbeatLimit: TimeInterval {
        max(5, (snapshot?.activePollInterval ?? BrightnessTrendModel.normalPollInterval) * 3)
    }
    var samplingIsLive: Bool {
        guard let snapshot, snapshot.phase == .running, let age = heartbeatAge else { return false }
        return age <= heartbeatLimit && canReadMonitoring && runtimeConfirmed && snapshot.appliedConfiguration.isEnabled
    }
    var samplingText: String {
        if !autoDarkShiftEnabled {
            if runtimeConfirmed, snapshot?.appliedConfiguration.isEnabled == false { return "Auto Dark Shift 已关闭" }
            return "关闭开关已保存，等待监听确认"
        }
        if samplingIsLive { return "监听正在采样（心跳有效）" }
        if keepAliveState.phase == .starting { return "保活正在开启" }
        if keepAliveState.phase == .stopping { return "保活正在关闭" }
        if !canReadMonitoring { return "正在准备监听宿主" }
        if runtimeError != nil { return "读取监听状态出错，请查看错误信息" }
        if runtimeNotice != nil { return "监听宿主已就绪，实时状态暂不可读取" }
        if !runtimeConfirmed { return "正在读取监听状态" }
        if snapshot?.phase == .sleeping { return "监听睡眠中" }
        if let age = heartbeatAge, age > heartbeatLimit { return "最近状态较旧，等待刷新" }
        return "等待采样记录"
    }

    /// Foreground refresh reads shared files or provider replies, never UIScreen brightness.
    func setForeground(_ foreground: Bool) {
        appIsForeground = foreground
        updateLocalExecutionPolicy()
        refreshTask?.cancel()
        refreshTask = nil
        guard foreground else { return }
        scheduleQuery()
        refreshTask = Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                guard let self else { return }
                self.now = Date()
                self.refreshSnapshot()
                self.keepAliveManager.updateStates()
                if self.storageMode == .localIPC || !self.usesVPNMonitoring ||
                    self.snapshot?.appliedConfiguration.revision != self.configuration.revision { self.scheduleQuery() }
                self.scheduleDiagnosticSync()
                if ticks % 5 == 0 { await self.refreshAuthorization() }
                ticks += 1
                do { try await Task.sleep(nanoseconds: 1_000_000_000) }
                catch { return }
            }
        }
    }

    func requestNotifications() {
        run {
            let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            await self.refreshAuthorization()
            self.message = allowed ? "通知授权成功。" : "未获得通知权限；扩展仍会采样。"
        }
    }

    private func updateSwitchState() {
        keepAliveEntries = keepAliveManager.entries.map { entry in
            guard entry.id == .vpn, let vpnOperation else { return entry }
            return KeepAliveEntry(id: entry.id, name: entry.name, state: entry.state,
                isEnabled: vpnOperation || entry.isEnabled, isTransitioning: true)
        }
        if let vpn = keepAliveEntries.first(where: { $0.id == .vpn }) {
            keepAliveEnabled = vpn.isEnabled
            keepAliveTransitioning = vpn.isTransitioning
        }
    }

    /// Only a confirmed active PiP or Location service permits the App-hosted
    /// listener to continue after the scene enters the background.
    private func updateLocalExecutionPolicy() {
        let isBackgroundKeepAliveActive = [KeepAliveMethod.pip, .location].contains { method in
            guard let phase = keepAliveManager.state(for: method)?.phase else { return false }
            return phase == .active || phase == .reasserting
        }
        hostCoordinator?.setAppExecutionAllowed(appIsForeground || isBackgroundKeepAliveActive)
    }

    func setKeepAliveEnabled(_ enabled: Bool, method: KeepAliveMethod = .vpn) {
        if method == .vpn {
            queuedVPNIntent = enabled
            guard vpnOperation == nil else { return }
            vpnOperation = enabled
            updateSwitchState()
            Task {
                while let intent = self.queuedVPNIntent {
                    self.queuedVPNIntent = nil
                    self.vpnOperation = intent
                    self.updateSwitchState()
                    await self.applyKeepAliveIntent(intent, method: .vpn)
                }
                self.vpnOperation = nil
                self.updateSwitchState()
                self.readback.reset()
                self.scheduleQuery()
            }
        } else {
            Task { await self.applyKeepAliveIntent(enabled, method: method) }
        }
    }

    func minimizePiPWindow() {
        do {
            guard let pipService else { throw KeepAliveError.message("画中画方案未注册。") }
            try pipService.minimizeWindow()
            message = "悬浮窗已设为 0.1pt。"
            appError = nil
        } catch { appError = describeError(error) }
    }

    private func applyKeepAliveIntent(_ enabled: Bool, method: KeepAliveMethod) async {
        do {
            if method == .vpn {
                if enabled {
                    try await hostCoordinator?.prepareForVPNStart()
                    if queuedVPNIntent == false {
                        try await hostCoordinator?.finishVPNStartRequest()
                        return
                    }
                } else if canReadMonitoring {
                    do {
                        let reply: MonitorReply
                        if let hostCoordinator { reply = try await hostCoordinator.prepareForVPNStop() }
                        else { reply = try await monitoring.queryStatus() }
                        acceptReply(reply)
                        try await syncProviderDiagnostics()
                    } catch { record("provider_log_sync_before_stop_failed", ["error": describeError(error)]) }
                }
            }
            try await keepAliveManager.setEnabled(enabled, method: method)
            if method == .vpn { try await hostCoordinator?.finishVPNStartRequest() }
            updateSwitchState()
            message = enabled ? "已请求开启所选保活方案。" : "已请求关闭所选保活方案。"
        } catch {
            if method == .vpn { try? await hostCoordinator?.finishVPNStartRequest() }
            appError = describeError(error)
            record("keepalive_operation_error", ["method": method.rawValue, "error": describeError(error)])
        }
    }

    func setAutoDarkShiftEnabled(_ enabled: Bool) {
        guard !busy, enabled != autoDarkShiftEnabled else { return }
        run {
            var saved = self.configuration
            saved.isEnabled = enabled
            saved.revision = UUID().uuidString
            guard let store = self.store else { throw ProjectError.message("配置存储不可用。") }
            try store.saveConfiguration(saved.validated())
            self.configuration = saved
            self.autoDarkShiftEnabled = enabled
            if self.canReadMonitoring {
                do {
                    let reply = try await self.monitoring.applyConfiguration(saved)
                    guard reply.success, reply.appliedRevision == saved.revision else {
                        throw ProjectError.message(reply.message)
                    }
                    self.acceptReply(reply)
                    self.message = enabled ? "Auto Dark Shift 已开启。" : "Auto Dark Shift 已关闭，保活方案继续运行。"
                } catch let error as MonitorChannelError {
                    self.acceptMonitorError(error)
                    self.message = "开关已保存；当前监听是否应用尚未确认，重新开启 VPN 将使用保存的配置。"
                }
            } else {
                try await self.hostCoordinator?.reconcile()
                self.message = "开关已保存。"
            }
        }
    }

    private func acceptReply(_ reply: MonitorReply) {
        snapshot = reply.snapshot
        runtimeConfirmed = true
        runtimeError = nil
        runtimeNotice = nil
        readback.receivedReply(at: Date())
        // This is a read-only cache of provider-originated data, never app brightness or a new heartbeat.
        if storageMode == .localIPC, usesVPNMonitoring, let snapshot, let store {
            do { try store.saveSnapshot(snapshot) }
            catch { storageError = "保存运行状态缓存失败：\(describeError(error))" }
        }
        scheduleDiagnosticSync()
    }

    private func scheduleDiagnosticSync() {
        let interval: TimeInterval = 15
        guard diagnosticTask == nil, canReadMonitoring, usesVPNMonitoring,
              Date().timeIntervalSince(lastDiagnosticSyncAt) >= interval else { return }
        let token = sessionGeneration
        lastDiagnosticSyncAt = Date()
        diagnosticTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.sessionGeneration == token { self.diagnosticTask = nil } }
            do { try await self.syncProviderDiagnostics() }
            catch {
                guard !Task.isCancelled else { return }
                self.record("provider_log_sync_failed", ["error": describeError(error)])
            }
        }
    }

    private func syncProviderDiagnostics(stream requestedStream: MonitorLogStream? = nil) async throws {
        guard usesVPNMonitoring else { return }
        let token = sessionGeneration
        guard let store else { throw ProjectError.message("App 日志缓存存储不可用。") }
        var failures: [String] = []
        let availableStreams: [MonitorLogStream] = storageMode == .appGroup && usesVPNMonitoring ? [.runtime] : [.runtime, .boost]
        let streams = requestedStream.map { availableStreams.contains($0) ? [$0] : [] } ?? availableStreams
        for stream in streams {
            do {
                let logs = try await monitoring.diagnostics(stream: stream)
                guard token == sessionGeneration, !Task.isCancelled else { throw CancellationError() }
                try store.saveProviderDiagnostics(logs, stream: stream)
                diagnosticSyncErrors.removeValue(forKey: stream)
                diagnosticSyncedAt[stream] = Date()
                record("provider_logs_cached", ["stream": stream.rawValue, "bytes": String(logs.utf8.count)])
            } catch {
                guard token == sessionGeneration, !Task.isCancelled else { throw CancellationError() }
                diagnosticSyncErrors[stream] = describeError(error)
                failures.append("\(stream.rawValue): \(describeError(error))")
                record("provider_log_stream_sync_failed", ["stream": stream.rawValue, "error": describeError(error)])
            }
        }
        lastDiagnosticSyncAt = Date()
        if !failures.isEmpty { throw ProjectError.message(failures.joined(separator: "; ")) }
    }

    private func acceptMonitorError(_ error: Error) {
        runtimeConfirmed = false
        let changed = readback.receivedError(error, at: Date())
        if readback.availability == .unavailable {
            runtimeError = nil
            runtimeNotice = "当前无法读取扩展运行详情，可稍后重新查询。"
            if changed { record("monitor_readback_unavailable", ["detail": describeError(error)]) }
        } else {
            runtimeNotice = nil
            runtimeError = describeError(error)
            record("monitor_query_error", ["error": describeError(error)])
        }
    }

    func saveConfiguration() {
        run {
            var saved = try self.configuration.validated()
            saved.revision = UUID().uuidString
            guard let store = self.store else { throw ProjectError.message("运行存储不可用。") }
            try store.saveConfiguration(saved)
            self.configuration = saved
            self.keepAlive.updateState()
            if self.canReadMonitoring {
                let reply: MonitorReply
                do { reply = try await self.monitoring.applyConfiguration(saved) }
                catch {
                    self.acceptMonitorError(error)
                    if error is MonitorChannelError {
                        self.message = "配置已保存；本次运行是否已应用尚未确认，重新开启保活会使用新配置。"
                        self.record("configuration_confirmation_pending", ["revision": saved.revision,
                                    "detail": describeError(error)])
                        return
                    }
                    throw ProjectError.message("配置已保存，但监听未确认应用：\(describeError(error))")
                }
                guard reply.success, reply.appliedRevision == saved.revision else {
                    throw ProjectError.message("配置已保存，但监听未确认应用：\(reply.message)")
                }
                self.acceptReply(reply)
                self.message = "配置已保存，监听已确认应用。"
            } else {
                self.message = "配置已保存，下次监听启动时应用。"
            }
        }
    }

    func queryMonitoring() {
        run {
            let reply: MonitorReply
            do { reply = try await self.monitoring.queryStatus() }
            catch {
                self.acceptMonitorError(error)
                if error is MonitorChannelError {
                    self.message = "当前无法读取运行详情，可稍后重试。"
                    return
                }
                throw error
            }
            guard reply.success else { throw ProjectError.message(reply.message) }
            self.acceptReply(reply)
            self.message = reply.message
        }
    }

    func sendTestNotification() {
        run {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus) else {
                self.testFeedback = "测试通知被阻止：没有通知权限。"
                self.record("test_notification_blocked", ["reason": "notification permission insufficient"])
                throw ProjectError.message("没有通知权限，测试通知未提交。")
            }
            let content = UNMutableNotificationContent()
            content.title = "AutoDarkShift.Test"
            content.body = "测试通知：系统接受请求不代表外部快捷指令已经执行。"
            content.sound = .default
            let identifier = "AutoDarkShift.Test.\(UUID().uuidString)"
            do {
                try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
            } catch {
                self.testFeedback = "测试通知失败：\(describeError(error))"
                self.record("test_notification_error", ["error": describeError(error)])
                throw error
            }
            self.testFeedback = "测试通知提交成功。"
            self.record("test_notification_success", ["identifier": identifier])
        }
    }

    func exportLogs(stream: MonitorLogStream) {
        let previousAppError = appError
        run {
            self.record("export_requested", ["stream": stream.rawValue])
            var syncFailures: [MonitorLogStream: String] = [:]
            if self.canReadMonitoring && (!self.usesVPNMonitoring || self.storageMode == .localIPC || stream == .runtime) {
                do { try await self.syncProviderDiagnostics(stream: stream) }
                catch {
                    if error is CancellationError { throw error }
                    syncFailures[stream] = self.diagnosticSyncErrors[stream] ?? describeError(error)
                }
            }
            let metadata: [String: String] = [
                "deviceModel": UIDevice.current.model, "systemVersion": UIDevice.current.systemVersion,
                "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                "buildVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
                "keepAlive": self.keepAliveEntries.filter { $0.isEnabled }.map { $0.id.rawValue }.joined(separator: ","),
                "keepAliveStatus": self.keepAliveEntries.map { "\($0.id.rawValue)=\($0.state.phase.rawValue)" }.joined(separator: ","),
                "protocolVersion": String(RuntimeIdentity.currentProtocolVersion),
                "storageMode": self.storageMode.rawValue,
                "storageFallbackReason": self.fallbackReason ?? "none",
                "appGroupIdentifier": RuntimeIdentity.installed().appGroupIdentifier,
                "monitorHost": self.hostCoordinator?.hostName ?? "VPN 扩展",
                "autoDarkShiftEnabled": String(self.autoDarkShiftEnabled),
                "runtimeConfirmed": String(self.runtimeConfirmed), "runtimeError": self.runtimeError ?? "none",
                "readbackAvailability": self.readback.availability.rawValue,
                "readbackDetail": self.readback.issue ?? "none",
                "consecutiveReadbackUnavailable": String(self.readback.consecutiveUnavailable),
                "storageError": self.storageError ?? "none", "appError": previousAppError ?? "none",
                "disconnectError": self.disconnectError ?? "none", "debuggerDetached": "must be recorded by tester"
            ]
            var data = try SharedJSON.encoder().encode(LogRecord(instanceID: "app", event: "export_metadata", fields: metadata.merging(["stream": stream.rawValue]) { _, new in new }))
            data.append(0x0A)
            if stream == .runtime, let diagnostics = self.diagnosticsStore {
                do { data.append(try diagnostics.exportData(metadata: ["scope": "app_diagnostics"])) }
                catch { try self.appendExportEvent("diagnostic_logs_unavailable", fields: ["error": describeError(error)], to: &data) }
            } else if stream == .runtime {
                try self.appendExportEvent("diagnostic_storage_unavailable", fields: [:], to: &data)
            }
            do {
                guard let store = self.store else { throw ProjectError.message(self.storageError ?? "日志存储不可用。") }
                data.append(try store.exportData(metadata: ["scope": self.storageMode == .appGroup ? "shared_runtime" : "app_runtime_cache"],
                    stream: stream, includeProviderCache: stream == .runtime || self.storageMode == .localIPC || !self.usesVPNMonitoring))
            } catch {
                try self.appendExportEvent("\(stream.rawValue)_logs_unavailable", fields: ["error": describeError(error)], to: &data)
            }
            if let coordinator = self.hostCoordinator {
                do { data.append(Data(try coordinator.localDiagnostics(stream: stream).utf8)) }
                catch { try self.appendExportEvent("app_monitor_logs_unavailable", fields: ["error": describeError(error)], to: &data) }
            }
            var stateData = Data()
            if stream == .boost, self.storageMode == .appGroup, self.usesVPNMonitoring {
                try self.appendExportEvent("boost_logs_sync_state", fields: ["source": "shared_runtime", "liveSync": "direct_read"], to: &stateData)
            } else {
                do {
                    if let store = self.store, try store.providerDiagnostics(stream: stream) != nil {
                        try self.appendExportEvent("provider_logs_sync_state", fields: ["stream": stream.rawValue,
                            "liveSync": self.canReadMonitoring && syncFailures[stream] == nil && self.diagnosticSyncedAt[stream] != nil ? "success" : "cached"], to: &stateData)
                    } else {
                        try self.appendExportEvent("provider_logs_missing", fields: ["stream": stream.rawValue,
                            "reason": "No provider snapshot has been acquired for this stream."], to: &stateData)
                    }
                } catch {
                    try self.appendExportEvent("provider_logs_cache_unavailable", fields: ["stream": stream.rawValue, "error": describeError(error)], to: &stateData)
                }
            }
            if let failure = syncFailures[stream] {
                try self.appendExportEvent("provider_logs_unavailable", fields: ["stream": stream.rawValue, "error": failure], to: &stateData)
            }
            data.append(stateData)
            self.exportURLs = try SharedStore.writeExports([stream: data])
        }
    }

    private func appendExportEvent(_ event: String, fields: [String: String], to data: inout Data) throws {
        data.append(try SharedJSON.encoder().encode(LogRecord(instanceID: "app", event: event, fields: fields)))
        data.append(0x0A)
    }

    private func refreshSnapshot() {
        guard storageMode == .appGroup, usesVPNMonitoring else { return }
        do { if let store { snapshot = try store.snapshot() } }
        catch { storageError = "读取监听状态失败：\(describeError(error))" }
    }

    private func refreshAuthorization() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: authorization = "尚未请求"
        case .denied: authorization = "已拒绝"
        case .authorized: authorization = "已授权"
        case .provisional: authorization = "临时授权（可能静默显示）"
        case .ephemeral: authorization = "短时授权"
        @unknown default: authorization = "未知状态"
        }
        if settings.alertSetting == .disabled { authorization += "；横幅已关闭" }
    }

    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        appError = nil
        message = nil
        Task {
            defer { busy = false }
            do { try await operation() }
            catch { appError = describeError(error); record("app_operation_error", ["error": describeError(error)]) }
        }
    }
}
