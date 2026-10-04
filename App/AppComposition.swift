import Foundation
import OSLog

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
        let record: (String, [String: String]) -> Void = { event, fields in
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
        let manager = KeepAliveManager(services: [(.vpn, vpn), (.pip, pip), (.location, location)])
        let monitoring: MonitoringHostCoordinator?
        do {
            guard let storage else { throw ProjectError.message(storageError ?? "配置存储不可用。") }
            let local = try RuntimeStoreSelection.localStore(directoryName: "LocalMonitoring")
            monitoring = MonitoringHostCoordinator(vpn: vpn, vpnState: { vpn.state },
                configurationStore: storage.store, localStore: local, makeRuntime: {
                    try SwitchMonitor(store: local, sampler: ScreenBrightnessSampler(),
                                      notifications: LocalModeNotificationSink(), diagnostic: { detail in
                        record("local_monitor_storage_error", ["error": detail])
                    })
                }, exportLocal: { stream in
                    String(decoding: try local.exportData(metadata: ["scope": "app_monitor", "host": "app"],
                        stream: stream, includeProviderCache: false), as: UTF8.self)
                })
        } catch {
            monitoring = nil
            record("local_monitor_setup_failed", ["error": describeError(error)])
        }
        let client: any MonitoringClient
        if let monitoring { client = monitoring } else { client = vpn }
        return AppController(keepAlive: vpn, monitoring: client, storage: storage,
                             storageError: storageError, diagnostics: diagnostics, record: record,
                             keepAliveManager: manager, hostCoordinator: monitoring)
    }
}
