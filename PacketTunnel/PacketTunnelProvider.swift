import Foundation
import NetworkExtension
import OSLog

final class PacketTunnelProvider: NEPacketTunnelProvider {
    @MainActor private var monitor: (any MonitoringRuntime)?
    @MainActor private var generation = UUID()
    @MainActor private var pendingStart: ((Error?) -> Void)?
    @MainActor private var sleepRequested = false
    @MainActor private var storageMode: RuntimeStorageMode = .appGroup
    @MainActor private var runtimeStore: SharedStore?
    @MainActor private var bridgeServer: LoopbackMonitorServer?
    @MainActor private let diagnosticPager = MonitorDiagnosticPager()
    private let logger = Logger(subsystem: "AutoDarkShift", category: "Provider")
    @MainActor private lazy var diagnosticsStore: SharedStore? = {
        do {
            let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
            return try SharedStore(directory: root.appendingPathComponent("ProviderDiagnostics", isDirectory: true))
        } catch {
            logger.error("Diagnostic storage failed: \(describeError(error), privacy: .public)")
            return nil
        }
    }()

    @MainActor private func record(_ event: String, _ fields: [String: String] = [:]) {
        logger.info("\(event, privacy: .public): \(String(describing: fields), privacy: .public)")
        do { try diagnosticsStore?.append(LogRecord(instanceID: generation.uuidString, event: event, fields: fields)) }
        catch { logger.error("Diagnostic write failed: \(describeError(error), privacy: .public)") }
    }

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        DispatchQueue.main.async { self.startOnMain(options: options, completionHandler) }
    }

    @MainActor private func startOnMain(options: [String: NSObject]?, _ completion: @escaping (Error?) -> Void) {
        guard monitor == nil, pendingStart == nil else {
            completion(ProjectError.message("扩展已启动或正在启动。"))
            return
        }
        generation = UUID()
        sleepRequested = false
        let token = generation
        pendingStart = completion
        do {
            let configuration = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration ?? [:]
            if let mode = configuration["storageMode"] as? String {
                guard let parsed = RuntimeStorageMode(rawValue: mode) else {
                    throw ProjectError.message("VPN 配置来自未知存储模式 \(mode)，请从 App 重新开启保活。")
                }
                storageMode = parsed
            }
            if let version = configuration["protocolVersion"] as? Int,
               version != RuntimeIdentity.currentProtocolVersion {
                throw ProjectError.message("VPN 配置协议版本不匹配，请重新准备 VPN。")
            }
            if let group = configuration["appGroupIdentifier"] as? String,
               group != RuntimeIdentity.installed().appGroupIdentifier {
                throw ProjectError.message("VPN 配置的 App Group 不匹配，请重新准备 VPN。")
            }
            record("vpn_start", ["identity": String(describing: RuntimeIdentity.installed(storageMode: storageMode))])
            let selection = try RuntimeStoreSelection.forProvider(mode: storageMode, shared: { try SharedStore() }, local: {
                try RuntimeStoreSelection.localStore(directoryName: "ProviderRuntime")
            })
            runtimeStore = selection.store
            if storageMode == .localIPC {
                // Direct app starts carry current configuration. System restarts retain provider history/config.
                let cached = try selection.store.configuration()
                let initialData = options?["initialConfiguration"] as? Data
                    ?? (cached.revision == "defaults-v1" ? configuration["initialConfiguration"] as? Data : nil)
                if let initialData {
                    try selection.store.saveConfiguration(SharedJSON.decoder().decode(MonitorConfiguration.self, from: initialData))
                }
            }
            // This is the only composition point binding VPN hosting to the listener.
            monitor = try SwitchMonitor(store: selection.store, sampler: ScreenBrightnessSampler(),
                                        notifications: LocalModeNotificationSink(), diagnostic: { [weak self] detail in
                self?.record("monitor_storage_error", ["error": detail])
            })
            if let port = configuration["bridgePort"] as? Int, let validPort = UInt16(exactly: port), let token = configuration["bridgeToken"] as? String {
                let server = LoopbackMonitorServer(credentials: MonitorBridgeCredentials(port: validPort, token: token), handle: { [weak self] data in
                    self?.handleControl(data, transport: "loopback")
                }, record: { [weak self] event, fields in self?.record(event, fields) })
                do { try server.start(); bridgeServer = server }
                catch { record("loopback_listener_failed", ["error": describeError(error)]) }
            }
        } catch { monitor = nil; runtimeStore = nil; finishStart(error); return }

        // Deliberately no default routes, DNS settings, IPv6 settings or remote proxy.
        // The /32 confines any automatically-created interface route to the local address.
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        let ipv4 = NEIPv4Settings(addresses: ["198.18.0.1"], subnetMasks: ["255.255.255.255"])
        ipv4.includedRoutes = []
        ipv4.excludedRoutes = []
        settings.ipv4Settings = ipv4
        settings.mtu = 1280
        setTunnelNetworkSettings(settings) { error in
            DispatchQueue.main.async {
                guard self.generation == token, self.pendingStart != nil else { return }
                if let error { self.failStart(error); return }
                do {
                    guard let monitor = self.monitor else { throw ProjectError.message("监测模块不存在。") }
                    try monitor.start()
                    if self.sleepRequested { monitor.sleep() }
                    self.finishStart(nil)
                } catch { self.failStart(error) }
            }
        }
    }

    @MainActor private func finishStart(_ error: Error?) {
        let callback = pendingStart
        pendingStart = nil
        if let error { record("vpn_error", ["error": describeError(error)]) }
        else { record("vpn_ready") }
        // Swift errors must be serialized with a localized description across the process boundary.
        callback?(error.map { $0 as NSError })
    }

    @MainActor private func failStart(_ error: Error) {
        let token = generation
        // Retain and return the original system error; never fall back to capturing all traffic.
        let cleanup: () -> Void = {
            guard self.generation == token else { return }
            self.monitor = nil
            self.bridgeServer?.stop()
            self.bridgeServer = nil
            self.runtimeStore = nil
            self.setTunnelNetworkSettings(nil) { _ in
                DispatchQueue.main.async {
                    guard self.generation == token else { return }
                    self.finishStart(error)
                }
            }
        }
        if let monitor { monitor.fail(error, completion: cleanup) }
        else { cleanup() }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async {
            self.record("vpn_stop", ["reason": String(reason.rawValue)])
            self.generation = UUID()
            if self.pendingStart != nil { self.finishStart(ProjectError.message("VPN 启动已被停止请求取消。")) }
            guard let monitor = self.monitor else { completionHandler(); return }
            monitor.stop(reason: "NEProviderStopReason=\(reason.rawValue)", finalPhase: .stopped) {
                self.monitor = nil
                // Retain the last store for diagnostics if the system delivers a post-stop request.
                self.bridgeServer?.stop()
                self.bridgeServer = nil
                completionHandler()
            }
        }
    }

    override func sleep(completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async {
            self.sleepRequested = true
            self.record("vpn_sleep")
            self.monitor?.sleep()
            completionHandler()
        }
    }

    override func wake() {
        DispatchQueue.main.async {
            self.sleepRequested = false
            self.record("vpn_wake")
            self.monitor?.wake()
        }
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        // Fast echo is independent of the main actor, storage and JSON encoding.
        // If this returns nil in the app, failure is before/around handleAppMessage, not business readback.
        if messageData.starts(with: MonitorWire.probePrefix) {
            logger.info("provider_message_probe_received")
            completionHandler?(messageData)
            return
        }
        logger.info("provider_message_entry bytes=\(messageData.count)")
        DispatchQueue.main.async {
            let response = self.handleControl(messageData, transport: "provider_message")
            self.record("provider_message_replied", ["bytes": String(response?.count ?? 0)])
            completionHandler?(response)
        }
    }

    @MainActor private func handleControl(_ data: Data, transport: String) -> Data? {
        record("monitor_message_received", ["bytes": String(data.count), "transport": transport])
        let endpoint = MonitorControlEndpoint(identity: .installed(storageMode: storageMode), runtime: { self.monitor }, diagnostics: {
            var result = ""
            if let store = self.diagnosticsStore { result += try store.diagnosticTail(maxBytes: 8 * 1024) }
            if let store = self.runtimeStore {
                if let snapshot = try store.snapshot() {
                    var snapshotData = try SharedJSON.encoder().encode(snapshot)
                    let object = try JSONSerialization.jsonObject(with: snapshotData)
                    snapshotData = try JSONSerialization.data(withJSONObject: ["event": "provider_export_snapshot", "data": object], options: [.sortedKeys])
                    result += String(decoding: snapshotData, as: UTF8.self) + "\n"
                }
                result += try store.diagnosticTail(maxBytes: 24 * 1024)
                result += try store.legacyDiagnostics()
            }
            guard !result.isEmpty else { throw ProjectError.message("扩展日志存储不可用。") }
            return result
        }, configurationStore: runtimeStore, pager: diagnosticPager)
        return endpoint.handle(data)
    }
}
