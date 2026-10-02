import Foundation

/// Integration point for a future in-app PiP host. It supplies no keep-alive behavior.
@MainActor final class LocalMonitoringClient: MonitoringClient {
    private let runtime: any MonitoringRuntime
    private let store: any MonitorStore
    private let exportDiagnostics: () throws -> String

    init(runtime: any MonitoringRuntime, store: any MonitorStore,
         diagnostics: @escaping () throws -> String) {
        self.runtime = runtime
        self.store = store
        self.exportDiagnostics = diagnostics
    }
    func queryStatus() async throws -> MonitorReply { runtime.statusReply() }
    func applyConfiguration(_ configuration: MonitorConfiguration) async throws -> MonitorReply {
        try store.saveConfiguration(configuration)
        return runtime.reload(expectedRevision: configuration.revision)
    }
    func diagnostics() async throws -> String { try exportDiagnostics() }
}
