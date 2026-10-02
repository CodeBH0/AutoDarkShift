import Foundation

enum KeepAlivePhase: String {
    case unavailable, stopped, starting, active, reasserting, stopping, failed
    var canMessage: Bool { self == .active || self == .reasserting }
    var canStart: Bool { self == .unavailable || self == .stopped || self == .failed }
    var canStop: Bool { self == .starting || canMessage }
}

struct KeepAliveState: Equatable {
    var phase: KeepAlivePhase = .unavailable
    var description = "未准备"
    var lastError: String?
}

/// No NetworkExtension, AVKit, or monitoring business operations in this contract.
/// A future PiP implementation reports actual delegate/KVO state here.
@MainActor protocol KeepAliveService: AnyObject {
    var name: String { get }
    var state: KeepAliveState { get }
    var onStateChange: ((KeepAliveState) -> Void)? { get set }
    func updateState()
    func refresh() async throws
    func prepare() async throws
    func start() async throws
    func stop()
}

/// Separate from keep-alive: a local PiP host can call the same runtime directly.
@MainActor protocol MonitoringClient: AnyObject {
    func queryStatus() async throws -> MonitorReply
    func applyConfiguration(_ configuration: MonitorConfiguration) async throws -> MonitorReply
    func startPollingTest(id: String) async throws -> MonitorReply
    func stopPollingTest() async throws -> MonitorReply
    func diagnostics() async throws -> String
}

protocol MonitorStore: AnyObject {
    func configuration() throws -> MonitorConfiguration
    func saveConfiguration(_ configuration: MonitorConfiguration) throws
    func snapshot() throws -> RuntimeSnapshot?
    func saveSnapshot(_ snapshot: RuntimeSnapshot) throws
    func history() throws -> SubmissionHistory?
    func saveHistory(_ history: SubmissionHistory) throws
    func append(_ record: LogRecord) throws
    func appendPollingResult(_ record: LogRecord) throws
}

struct BrightnessReading {
    var value: Double
    var source: SampleSource
    var timestamp: Date
    var uptime: TimeInterval?
    var readDuration: TimeInterval?
}

@MainActor protocol BrightnessSampling: AnyObject {
    /// Replaces any existing timer and observer; callbacks must be on the main actor.
    func start(interval: TimeInterval, receive: @escaping (BrightnessReading) -> Void)
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
    func startPollingTest(id: String) -> MonitorReply
    func stopPollingTest() -> MonitorReply
}
