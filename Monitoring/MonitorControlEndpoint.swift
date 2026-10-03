import Foundation

/// Wire decoding is separate from the host lifecycle; every valid/invalid request gets a reply.
@MainActor final class MonitorControlEndpoint {
    private let runtime: () -> (any MonitoringRuntime)?
    private let identity: RuntimeIdentity
    private let diagnostics: () throws -> String
    private let boostDiagnostics: () throws -> String
    private let configurationStore: (any MonitorStore)?
    private let pager: MonitorDiagnosticPager

    init(identity: RuntimeIdentity, runtime: @escaping () -> (any MonitoringRuntime)?,
         diagnostics: @escaping () throws -> String, configurationStore: (any MonitorStore)? = nil,
         pager: MonitorDiagnosticPager? = nil, boostDiagnostics: @escaping () throws -> String = { "" }) {
        self.identity = identity
        self.runtime = runtime
        self.diagnostics = diagnostics
        self.boostDiagnostics = boostDiagnostics
        self.configurationStore = configurationStore
        self.pager = pager ?? MonitorDiagnosticPager()
    }

    func handle(_ data: Data) -> Data? {
        var reply: MonitorReply
        do {
            let request = try SharedJSON.decoder().decode(MonitorRequest.self, from: data)
            let stream = request.exportStream ?? .runtime
            let load = stream == .runtime ? diagnostics : boostDiagnostics
            if request.command == .exportDiagnostics {
                reply = MonitorReply(success: true, message: "扩展诊断日志。", diagnostics: try load(), exportStream: stream)
            } else if request.command == .exportDiagnosticPage {
                reply = try pager.page(for: request, load: load)
            } else {
                guard let monitor = runtime() else {
                    throw ProjectError.message("监听模块尚未初始化；请查看扩展启动诊断。")
                }
                switch request.command {
                case .handshake, .queryStatus: reply = monitor.statusReply()
                case .prepareHostHandoff:
                    monitor.stop(reason: "host_handoff_to_app", finalPhase: .stopped) {}
                    reply = monitor.statusReply()
                case .reloadConfiguration:
                    if identity.storageMode == RuntimeStorageMode.localIPC.rawValue {
                        guard let configuration = request.configuration, let store = configurationStore,
                              configuration.revision == request.expectedRevision else {
                            throw ProjectError.message("本地通信模式需要完整配置和匹配的版本号。")
                        }
                        try store.saveConfiguration(configuration.validated())
                    }
                    reply = monitor.reload(expectedRevision: request.expectedRevision)
                case .exportDiagnostics, .exportDiagnosticPage: preconditionFailure("Handled above")
                }
            }
        } catch {
            reply = MonitorReply(success: false, message: describeError(error))
        }
        reply.identity = identity
        // All reply values are bounded valid Foundation/Codable values, including finite samples.
        do { return try SharedJSON.encoder().encode(reply) }
        catch {
            // Never turn an encoding failure into a nil system reply indistinguishable from transport failure.
            return try? SharedJSON.encoder().encode(MonitorReply(success: false, message: "回复编码失败：\(describeError(error))", identity: identity))
        }
    }
}
