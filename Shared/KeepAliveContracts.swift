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
/// Services report actual platform state; this layer has no monitoring business dependency.
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


enum KeepAliveError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let detail): return detail } }
}

func keepAliveErrorDescription(_ error: Error) -> String {
    let value = error as NSError
    return "\(value.domain) (\(value.code)): \(value.localizedDescription)"
}
