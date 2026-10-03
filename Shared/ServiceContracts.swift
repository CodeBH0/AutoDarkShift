import Foundation

/// Separate from keep-alive: a local PiP host can call the same runtime directly.
@MainActor protocol MonitoringClient: AnyObject {
    func queryStatus() async throws -> MonitorReply
    func applyConfiguration(_ configuration: MonitorConfiguration) async throws -> MonitorReply
    func prepareHostHandoff() async throws -> MonitorReply
    func diagnostics(stream: MonitorLogStream) async throws -> String
}

extension MonitoringClient {
    func diagnostics() async throws -> String { try await diagnostics(stream: .runtime) }
    func prepareHostHandoff() async throws -> MonitorReply { try await queryStatus() }
}

protocol MonitorStore: AnyObject {
    func configuration() throws -> MonitorConfiguration
    func saveConfiguration(_ configuration: MonitorConfiguration) throws
    func snapshot() throws -> RuntimeSnapshot?
    func saveSnapshot(_ snapshot: RuntimeSnapshot) throws
    func history() throws -> SubmissionHistory?
    func saveHistory(_ history: SubmissionHistory) throws
    func append(_ record: LogRecord) throws
    func appendBoostTrace(id: String, records: [LogRecord], finished: Bool) throws
    func recoverBoostTraces(instanceID: String, at: Date) throws
}

struct BrightnessReading {
    var value: Double
    var source: SampleSource
    var timestamp: Date
    var uptime: TimeInterval?
}

@MainActor protocol BrightnessSampling: AnyObject {
    /// Replaces any existing timer and observer; callbacks must be on the main actor.
    func start(interval: TimeInterval, receive: @escaping (BrightnessReading) -> Void)
    /// Retimes polling without replacing the brightness observer or receive callback.
    func updateInterval(_ interval: TimeInterval)
    func sampleNow(_ source: SampleSource)
    func stop()
}

@MainActor protocol ModeNotificationSubmitting: AnyObject {
    func authorization(_ completion: @escaping (Bool, String) -> Void)
    func submit(_ candidate: NotificationCandidate, source: SampleSource,
                completion: @escaping (Error?) -> Void)
}

@MainActor protocol MonitoringRuntime: AnyObject {
    var snapshot: RuntimeSnapshot { get }
    func start() throws
    func fail(_ error: Error, completion: @escaping () -> Void)
    func stop(reason: String, finalPhase: RuntimePhase, completion: @escaping () -> Void)
    func sleep()
    func wake()
    func reload(expectedRevision: String?) -> MonitorReply
    func statusReply() -> MonitorReply
    func flushDiagnostics()
}
