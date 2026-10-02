import Foundation
import NetworkExtension

/// VPN preferences/lifecycle and the cross-process transport are isolated from listening policy.
@MainActor final class VPNKeepAliveService: KeepAliveService, MonitoringClient {
    let name = "VPN"
    private(set) var state = KeepAliveState()
    var onStateChange: ((KeepAliveState) -> Void)?
    private var manager: NETunnelProviderManager?
    private var observer: NSObjectProtocol?
    private let channel = MonitorMessageChannel()
    private let router = MonitorTransportRouter()
    private let bridgeClient = LoopbackMonitorClient()
    private var hasProbed = false
    private var diagnosticExportTask: (id: UUID, task: Task<String, Error>)?
    private let record: (String, [String: String]) -> Void
    private let storage: RuntimeStoreSelection?
    private let storageError: String?
    private var storageMode: RuntimeStorageMode { storage?.mode ?? .appGroup }
    private var providerID: String {
        Bundle.main.object(forInfoDictionaryKey: "PacketTunnelBundleIdentifier") as? String ?? ""
    }

    init(storage: RuntimeStoreSelection?, storageError: String?, record: @escaping (String, [String: String]) -> Void) {
        self.storage = storage
        self.storageError = storageError
        self.record = record
        observer = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: nil, queue: .main) { [weak self] notification in
            let connection = notification.object as? NEVPNConnection
            Task { @MainActor in
                guard let self, connection === self.manager?.connection else { return }
                self.updateState()
                if connection?.status == .disconnected { self.fetchDisconnectError() }
            }
        }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    func refresh() async throws {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences().filter {
            ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == providerID
        }
        // Prefer the actual active profile when stale/duplicate profiles exist.
        manager = managers.first { [.connected, .reasserting, .connecting, .disconnecting].contains($0.connection.status) }
            ?? managers.first { $0.isEnabled } ?? managers.first
        updateState()
        if manager?.connection.status == .disconnected { fetchDisconnectError() }
    }

    func prepare() async throws {
        _ = try embeddedIdentity()
        try await refresh()
        guard state.phase.canStart else { throw ProjectError.message("请先停止 VPN，再更新配置。") }
        let manager = manager ?? NETunnelProviderManager()
        let configuration = NETunnelProviderProtocol()
        configuration.providerBundleIdentifier = providerID
        configuration.serverAddress = "127.0.0.1"
        configuration.includeAllNetworks = false
        configuration.enforceRoutes = false
        var metadata = profileMetadata()
        metadata["initialConfiguration"] = try SharedJSON.encoder().encode(currentConfiguration())
        configuration.providerConfiguration = metadata
        manager.protocolConfiguration = configuration
        manager.localizedDescription = "AutoDarkShift · 保活"
        manager.isEnabled = true
        manager.isOnDemandEnabled = false
        record("vpn_preferences_save_requested", ["storageMode": storageMode.rawValue, "protocolVersion": String(RuntimeIdentity.currentProtocolVersion)])
        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()
        self.manager = manager
        updateState()
        record("vpn_installed", ["providerBundleIdentifier": providerID])
    }

    func start() async throws {
        _ = try embeddedIdentity()
        try await refresh()
        if manager == nil { try await prepare() }
        guard let manager else { throw ProjectError.message("VPN 配置准备失败。") }
        guard state.phase.canStart else { throw ProjectError.message("VPN 已运行或正在切换状态。") }
        guard let configuration = manager.protocolConfiguration as? NETunnelProviderProtocol else {
            throw ProjectError.message("VPN 配置类型不正确，请重新准备。")
        }
        let initialConfiguration = try currentConfiguration()
        var metadata = profileMetadata()
        metadata["initialConfiguration"] = try SharedJSON.encoder().encode(initialConfiguration)
        let needsMigration = configuration.providerConfiguration?["storageMode"] as? String != storageMode.rawValue
            || configuration.providerConfiguration?["protocolVersion"] as? Int != RuntimeIdentity.currentProtocolVersion
            || configuration.providerConfiguration?["appGroupIdentifier"] as? String != metadata["appGroupIdentifier"] as? String
            || configuration.providerConfiguration?["bridgeToken"] as? String != metadata["bridgeToken"] as? String
            || configuration.providerConfiguration?["bridgePort"] as? Int != metadata["bridgePort"] as? Int
        if !manager.isEnabled || needsMigration {
            record("vpn_profile_repaired", ["wasEnabled": String(manager.isEnabled), "metadataUpdated": String(needsMigration)])
            manager.isEnabled = true
            configuration.providerConfiguration = metadata
            manager.protocolConfiguration = configuration
            try await manager.saveToPreferences()
            try await manager.loadFromPreferences()
        }
        publish(KeepAliveState(phase: state.phase, description: state.description))
        router.reset()
        diagnosticExportTask?.task.cancel()
        diagnosticExportTask = nil
        hasProbed = false
        record("vpn_start_requested", ["storageMode": storageMode.rawValue, "revision": initialConfiguration.revision])
        guard let session = manager.connection as? NETunnelProviderSession else { throw ProjectError.message("VPN 连接不是 PacketTunnel 会话。") }
        try session.startTunnel(options: ["initialConfiguration": try SharedJSON.encoder().encode(initialConfiguration)])
        updateState()
    }

    func stop() {
        record("vpn_stop_requested", [:])
        manager?.connection.stopVPNTunnel()
        updateState()
    }

    func updateState() {
        let status = manager?.connection.status ?? .invalid
        let phase: KeepAlivePhase
        let description: String
        switch status {
        case .invalid: phase = .unavailable; description = "未安装或配置无效"
        case .disconnected: phase = .stopped; description = "已断开"
        case .connecting: phase = .starting; description = "正在连接"
        case .connected: phase = .active; description = "已连接"
        case .reasserting: phase = .reasserting; description = "正在重新连接"
        case .disconnecting: phase = .stopping; description = "正在断开"
        @unknown default: phase = .failed; description = "未知状态 (\(status.rawValue))"
        }
        publish(KeepAliveState(phase: phase, description: description,
                              lastError: phase == .stopped ? state.lastError : nil))
    }

    func queryStatus() async throws -> MonitorReply {
        try await sendChecked(.init(command: .handshake))
    }
    func startPollingTest(id: String) async throws -> MonitorReply {
        try await sendChecked(MonitorRequest(command: .startPollingTest, pollingTestID: id))
    }
    func stopPollingTest() async throws -> MonitorReply {
        try await sendChecked(MonitorRequest(command: .stopPollingTest))
    }
    func applyConfiguration(_ configuration: MonitorConfiguration) async throws -> MonitorReply {
        try await sendChecked(.init(command: .reloadConfiguration, expectedRevision: configuration.revision,
                                    configuration: storageMode == .localIPC ? configuration : nil))
    }
    func diagnostics() async throws -> String {
        if let active = diagnosticExportTask { return try await active.task.value }
        let id = UUID()
        let task = Task { try await MonitorDiagnosticPager.collect(id: id.uuidString) { try await self.sendChecked($0) } }
        diagnosticExportTask = (id, task)
        defer { if diagnosticExportTask?.id == id { diagnosticExportTask = nil } }
        return try await task.value
    }

    private func sendChecked(_ request: MonitorRequest) async throws -> MonitorReply {
        updateState()
        guard let session = manager?.connection as? NETunnelProviderSession, state.phase.canMessage else {
            throw ProjectError.message("VPN 尚未连接，无法确认监听状态。配置保存成功时会在下次启动应用。")
        }
        let expected = try embeddedIdentity()
        let payload = try SharedJSON.encoder().encode(request)
        let metadata = (manager?.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration ?? [:]
        let credentials: MonitorBridgeCredentials?
        if let port = metadata["bridgePort"] as? Int, let validPort = UInt16(exactly: port), let token = metadata["bridgeToken"] as? String {
            credentials = MonitorBridgeCredentials(port: validPort, token: token)
        } else { credentials = nil }
        do {
            let reply = try await router.send(primary: {
                self.record("provider_message_sent", ["command": request.command.rawValue,
                    "sessionClass": String(describing: type(of: session)), "status": String(session.status.rawValue),
                    "providerBundleIdentifier": (self.manager?.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier ?? "missing"])
                do {
                    return try await self.channel.send(request) { data, completion in
                        try session.sendProviderMessage(data, responseHandler: completion)
                    }
                } catch {
                    self.record("provider_message_transport_failed", ["command": request.command.rawValue, "error": describeError(error)])
                    throw error
                }
            }, fallback: {
                if !self.hasProbed {
                    self.hasProbed = true
                    do {
                        try await self.channel.probe { data, completion in try session.sendProviderMessage(data, responseHandler: completion) }
                        self.record("provider_message_probe_success", ["interpretation": "System channel works; investigate runtime dispatch/encoding."])
                    } catch {
                        self.record("provider_message_probe_failed", ["error": describeError(error),
                            "interpretation": "Even immediate echo unavailable; investigate system delivery/profile/signing, not brightness statistics."])
                    }
                }
                guard let credentials else { throw MonitorChannelError.bridgeUnavailable("旧 VPN 配置缺少本机通道参数，请关闭保活后重新开启。") }
                self.record("loopback_message_sent", ["command": request.command.rawValue, "port": String(credentials.port)])
                let data = try await self.bridgeClient.send(payload, credentials: credentials)
                let reply = try SharedJSON.decoder().decode(MonitorReply.self, from: data)
                self.record("loopback_message_received", ["command": request.command.rawValue, "bytes": String(data.count)])
                return reply
            })
            guard self.manager?.connection === session, self.state.phase.canMessage else {
                throw ProjectError.message("消息期间 VPN 会话已改变，请重新查询监听状态。")
            }
            guard let identity = reply.identity else { throw ProjectError.message("扩展回复缺少版本握手；请安装当前版本并重启 VPN。") }
            try identity.validate(against: expected)
            guard reply.success else { throw ProjectError.message(reply.message) }
            record("monitor_message_confirmed", ["command": request.command.rawValue, "transport": router.usesFallback ? "loopback" : "provider_message",
                                                  "identity": String(describing: identity)])
            return reply
        } catch {
            let event = error is MonitorChannelError ? "provider_message_unavailable" : "provider_message_error"
            record(event, ["command": request.command.rawValue, "error": describeError(error)])
            throw error
        }
    }

    private func embeddedIdentity() throws -> RuntimeIdentity {
        guard !providerID.isEmpty, let plugins = Bundle.main.builtInPlugInsURL else {
            throw ProjectError.message("缺少嵌入的 Packet Tunnel 扩展，请检查构建与签名。")
        }
        let bundles = try FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "appex" }.compactMap { Bundle(url: $0) }
        guard let bundle = bundles.first(where: { $0.bundleIdentifier == providerID }),
              let extensionInfo = bundle.object(forInfoDictionaryKey: "NSExtension") as? [String: Any],
              extensionInfo["NSExtensionPointIdentifier"] as? String == "com.apple.networkextension.packet-tunnel",
              (extensionInfo["NSExtensionPrincipalClass"] as? String)?.hasSuffix(".PacketTunnelProvider") == true else {
            throw ProjectError.message("嵌入扩展的 Bundle ID 或入口不正确。期望 \(providerID)。")
        }
        let identity = RuntimeIdentity.installed(in: bundle, storageMode: storageMode)
        guard identity.buildVersion == RuntimeIdentity.installed().buildVersion,
              identity.appGroupIdentifier == RuntimeIdentity.installed().appGroupIdentifier,
              bundle.object(forInfoDictionaryKey: "RuntimeProtocolVersion") as? Int == RuntimeIdentity.currentProtocolVersion,
              (bundle.object(forInfoDictionaryKey: "RuntimeSupportedStorageModes") as? [String])?.contains(storageMode.rawValue) == true else {
            throw ProjectError.message("App 与嵌入扩展的构建版本、App Group 或通信协议不一致；请重新构建并安装。")
        }
        return identity
    }

    private func profileMetadata() -> [String: Any] {
        let existing = (manager?.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration ?? [:]
        let credentials: MonitorBridgeCredentials
        if let port = existing["bridgePort"] as? Int, let validPort = UInt16(exactly: port), let token = existing["bridgeToken"] as? String,
           let valid = try? MonitorBridgeCredentials(port: validPort, token: token).validated() { credentials = valid }
        else { credentials = MonitorBridgeCredentials() }
        return ["storageMode": storageMode.rawValue,
         "protocolVersion": RuntimeIdentity.currentProtocolVersion,
         "appGroupIdentifier": RuntimeIdentity.installed().appGroupIdentifier,
         "bridgePort": Int(credentials.port), "bridgeToken": credentials.token]
    }
    private func currentConfiguration() throws -> MonitorConfiguration {
        guard let store = storage?.store else { throw ProjectError.message(storageError ?? "运行存储不可用。") }
        return try store.configuration()
    }
    private func publish(_ newState: KeepAliveState) {
        guard state != newState else { return }
        state = newState
        record("vpn_status", ["phase": state.phase.rawValue, "status": state.description])
        onStateChange?(state)
    }
    private func fetchDisconnectError() {
        guard let connection = manager?.connection else { return }
        connection.fetchLastDisconnectError { [weak self] error in
            let detail = error.map(describeError)
            Task { @MainActor in
                guard let self, self.manager?.connection === connection, self.state.phase == .stopped else { return }
                var updated = self.state
                updated.lastError = detail
                self.publish(updated)
            }
        }
    }
}
