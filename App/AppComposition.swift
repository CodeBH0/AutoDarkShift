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
            monitoring = MonitoringHostCoordinator(vpn: vpn, vpnState: { vpn.state },
                configurationStore: storage.store, localStore: local, makeRuntime: {
                    let scheduler = DispatchPollingScheduler(record: record, context: context)
                    return try SwitchMonitor(store: local,
                                      sampler: ScreenBrightnessSampler(scheduler: scheduler, record: record, context: context),
                                      notifications: LocalModeNotificationSink(), diagnostic: { detail in
                        record("local_monitor_storage_error", ["error": detail])
                    }, diagnosticContext: context)
                }, exportLocal: { stream in
                    String(decoding: try local.exportData(metadata: ["scope": "app_monitor", "host": "app"],
                        stream: stream, includeProviderCache: false), as: UTF8.self)
                }, record: record, context: context)
            diagnosticHost = monitoring
        } catch {
            monitoring = nil
            record("local_monitor_setup_failed", ["error": describeError(error)])
        }
        let client: any MonitoringClient
        if let monitoring { client = monitoring } else { client = vpn }
        return AppController(keepAlive: vpn, monitoring: client, storage: storage,
                             storageError: storageError, diagnostics: diagnostics, record: record,
                             keepAliveManager: manager, hostCoordinator: monitoring, pipService: pip)
    }
}
