import Foundation

/// The pending intent covers asynchronous setup; after that the switch follows actual state.
@MainActor final class KeepAliveSwitchControl {
    private let service: any KeepAliveService
    private(set) var pendingEnable = false
    var onChange: (() -> Void)?
    var isOn: Bool { pendingEnable || service.state.phase.canStop }
    var isTransitioning: Bool { pendingEnable || service.state.phase == .starting || service.state.phase == .stopping }

    init(service: any KeepAliveService) { self.service = service }

    func setEnabled(_ enabled: Bool) async throws {
        guard !pendingEnable else { return }
        if enabled {
            guard service.state.phase.canStart else { return }
            pendingEnable = true
            onChange?()
            defer { pendingEnable = false; onChange?() }
            try await service.start()
        } else {
            guard service.state.phase.canStop else { return }
            service.stop()
            onChange?()
        }
    }
}
