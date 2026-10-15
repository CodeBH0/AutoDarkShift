import Foundation
import OSLog
import UIKit

/// Current backend selection lives here; the UI/controller depend only on service contracts.
@MainActor enum AppComposition {
    static func makeController() -> AppController {
        let logger = Logger(subsystem: "AutoDarkShift", category: "App")
        let diagnostics: SharedStore?
        do {
            let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
            diagnostics = try SharedStore(directory: root.appendingPathComponent("AppDiagnostics", isDirectory: true))
        } catch {
            logger.error("App diagnostic storage failed: \(describeError(error), privacy: .public)")
            diagnostics = nil
        }
        let record: @Sendable (String, [String: String]) -> Void = { event, fields in
            logger.info("\(event, privacy: .public): \(String(describing: fields), privacy: .public)")
            do { try diagnostics?.append(LogRecord(instanceID: "app", event: event, fields: fields)) }
            catch { logger.error("App diagnostic write failed: \(describeError(error), privacy: .public)") }
        }
        let storage: RuntimeStoreSelection?
        let storageError: String?
        do {
            storage = try RuntimeStoreSelection.forApp(shared: { try SharedStore() }, local: {
                try RuntimeStoreSelection.localStore(directoryName: "AppRuntime")
            })
            storageError = nil
        } catch { storage = nil; storageError = describeError(error) }
        let vpn = VPNKeepAliveService(storage: storage, storageError: storageError, record: record)
        let pip = PiPKeepAliveService(record: record)
        let location = LocationKeepAliveService(record: record)
        weak var diagnosticHost: MonitoringHostCoordinator?
        let context: @MainActor () -> [String: String] = { [weak pip, weak location] in
            let state = UIApplication.shared.applicationState
            let stateName: String
            switch state {
            case .active: stateName = "active"
            case .inactive: stateName = "inactive"
            case .background: stateName = "background"
            @unknown default: stateName = "unknown"
            }
            let snapshot = diagnosticHost?.localRuntimeSnapshot
            return ["applicationState": stateName, "appForeground": String(state != .background),
                    "pipPhase": pip?.state.phase.rawValue ?? "unregistered",
                    "locationPhase": location?.state.phase.rawValue ?? "unregistered",
                    "listenerHost": diagnosticHost?.usesVPN == true ? "vpn" : "app",
                    "runtimePhase": snapshot?.phase.rawValue ?? "none",
                    "pollInterval": snapshot?.activePollInterval.map { String($0) } ?? "none",
                    "heartbeatAt": snapshot?.heartbeatAt?.ISO8601Format() ?? "none",
                    "lastPollAt": snapshot?.lastPollAt?.ISO8601Format() ?? "none"]
        }
        let manager = KeepAliveManager(services: [(.vpn, vpn), (.pip, pip), (.location, location)],
            record: { event, fields in record(event, context().merging(fields) { _, new in new }) })
        let monitoring: MonitoringHostCoordinator?
        do {
            guard let storage else { throw ProjectError.message(storageError ?? "配置存储不可用。") }
            let local = try RuntimeStoreSelection.localStore(directoryName: "LocalMonitoring")
            monitoring = MonitoringHostCoordinator(process: .packetTunnel, vpn: vpn, vpnState: { vpn.state },
                configurationStore: storage.store, localStore: local, makeRuntime: {
                    throw ProjectError.message("Packet Tunnel 路径只能在扩展进程采样。")
                }, exportLocal: { stream in
                    let retiredMessages = try RuntimeStoreSelection.localStore(directoryName: "MessageMonitoring")
                    let legacy = try local.exportData(metadata: ["scope": "app_monitor", "host": "app", "historical": "true"],
                        stream: stream, includeProviderCache: false)
                    let messages = try retiredMessages.exportData(metadata: ["scope": "message_monitor", "business": "message",
                        "samplingMode": "typed_message_only", "historical": "true"], stream: stream, includeProviderCache: false)
                    return String(decoding: legacy + messages, as: UTF8.self)
                }, record: record, context: context)
        } catch {
            monitoring = nil
            record("local_monitor_setup_failed", ["error": describeError(error)])
        }
        let client: any MonitoringClient
        if let monitoring { client = monitoring } else { client = vpn }
        let appMonitoring: MonitoringHostCoordinator?
        let appStore: SharedStore?
        let businesses: ExclusiveMonitoringBusiness?
        let appSetupError: String?
        do {
            guard let storage else { throw ProjectError.message(storageError ?? "配置存储不可用。") }
            let local = try RuntimeStoreSelection.localStore(directoryName: "BackBoardMonitoring")
            let saved = try local.configuration(defaultValue: MonitorConfiguration(isEnabled: false))
            try local.saveConfiguration(saved)
            weak var appHost: MonitoringHostCoordinator?
            let appContext: @MainActor () -> [String: String] = {
                let snapshot = appHost?.localRuntimeSnapshot
                let fields: [String: String] = [
                    "business": "backboard", "api": BackBoardBrightnessProbe.symbol,
                    "samplingMode": "backboard_poll_only", "listenerHost": "app",
                    "runtimeInstanceID": snapshot?.instanceID ?? "none",
                    "runtimePhase": snapshot?.phase.rawValue ?? "none",
                    "pollInterval": snapshot?.activePollInterval.map { String($0) } ?? "none",
                    "heartbeatAt": snapshot?.heartbeatAt?.ISO8601Format() ?? "none",
                    "lastPollAt": snapshot?.lastPollAt?.ISO8601Format() ?? "none"
                ]
                return context().merging(fields) { _, new in new }
            }
            let coordinator = MonitoringHostCoordinator(process: .app, vpn: vpn, vpnState: { vpn.state },
                configurationStore: local, localStore: local, makeRuntime: {
                    try BackBoardBrightnessProbe.requireAvailable()
                    let scheduler = DispatchPollingScheduler(record: record, context: appContext)
                    return try SwitchMonitor(store: local,
                        sampler: BackBoardBrightnessSampler(scheduler: scheduler, record: record, context: appContext),
                        notifications: LocalModeNotificationSink(), diagnostic: { detail in
                            record("backboard_monitor_storage_error", ["error": detail])
                        }, diagnosticContext: appContext)
                }, exportLocal: { stream in
                    String(decoding: try local.exportData(metadata: ["scope": "backboard_monitor", "business": "backboard",
                        "host": "app", "api": BackBoardBrightnessProbe.symbol, "samplingMode": "backboard_poll_only"],
                        stream: stream, includeProviderCache: false), as: UTF8.self)
                }, record: record, context: appContext)
            appHost = coordinator
            diagnosticHost = coordinator
            appMonitoring = coordinator
            appStore = local
            businesses = ExclusiveMonitoringBusiness(standard: client, standardStore: storage.store,
                app: coordinator, appStore: local, preflightApp: {
                    record("backboard_api_load", BackBoardBrightnessProbe.availabilityFields)
                    try BackBoardBrightnessProbe.requireAvailable()
                })
            appSetupError = nil
        } catch {
            appMonitoring = nil; appStore = nil; businesses = nil
            appSetupError = describeError(error)
            record("backboard_monitor_setup_failed", ["error": describeError(error)])
        }
        return AppController(keepAlive: vpn, monitoring: client, storage: storage,
                             storageError: storageError, diagnostics: diagnostics, record: record,
                             keepAliveManager: manager, hostCoordinator: monitoring, pipService: pip,
                             appCoordinator: appMonitoring, appStore: appStore,
                             businesses: businesses, appSetupError: appSetupError)
    }
}
