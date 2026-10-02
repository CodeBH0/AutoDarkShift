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
        return AppController(keepAlive: vpn, monitoring: vpn, storage: storage, storageError: storageError,
                             diagnostics: diagnostics, record: record)
    }
}
