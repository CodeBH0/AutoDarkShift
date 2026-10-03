import Foundation

enum KeepAliveMethod: String, CaseIterable, Identifiable {
    case vpn, pip, location
    var id: String { rawValue }
}

struct KeepAliveEntry: Identifiable, Equatable {
    let id: KeepAliveMethod
    let name: String
    let state: KeepAliveState
    let isEnabled: Bool
    let isTransitioning: Bool
}

/// Generic registry: no AutoDarkShift configuration, sampling, notification or storage policy.
/// Each method owns its independent lifecycle; enabling one never stops another.
@MainActor final class KeepAliveManager {
    private let services: [KeepAliveMethod: any KeepAliveService]
    private let controls: [KeepAliveMethod: KeepAliveSwitchControl]
    private var pendingStops: Set<KeepAliveMethod> = []
    private var failures: [KeepAliveMethod: String] = [:]
    var onChange: (() -> Void)?

    init(services registrations: [(KeepAliveMethod, any KeepAliveService)]) {
        precondition(Set(registrations.map { $0.0 }).count == registrations.count)
        services = Dictionary(uniqueKeysWithValues: registrations)
        controls = Dictionary(uniqueKeysWithValues: registrations.map { ($0.0, KeepAliveSwitchControl(service: $0.1)) })
        for (_, service) in registrations {
            service.onStateChange = { [weak self] _ in self?.onChange?() }
        }
        for control in controls.values { control.onChange = { [weak self] in self?.onChange?() } }
    }

    var entries: [KeepAliveEntry] {
        KeepAliveMethod.allCases.compactMap { id in
            guard let service = services[id], let control = controls[id] else { return nil }
            var state = service.state
            if let error = failures[id], state.lastError == nil { state.lastError = error }
            return KeepAliveEntry(id: id, name: service.name, state: state,
                                  isEnabled: control.isOn, isTransitioning: control.isTransitioning)
        }
    }
    func state(for method: KeepAliveMethod) -> KeepAliveState? { services[method]?.state }
    func updateStates() { services.values.forEach { $0.updateState() } }
    func refresh() async {
        for method in KeepAliveMethod.allCases {
            guard let service = services[method] else { continue }
            do { try await service.refresh(); failures.removeValue(forKey: method) }
            catch { failures[method] = error.localizedDescription }
        }
        onChange?()
    }
    func setEnabled(_ enabled: Bool, method: KeepAliveMethod) async throws {
        guard let control = controls[method] else {
            throw NSError(domain: "KeepAlive", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "保活方案未注册。"])
        }
        if !enabled, control.pendingEnable {
            pendingStops.insert(method)
            services[method]?.stop()
            onChange?()
            return
        }
        do {
            try await control.setEnabled(enabled)
            if pendingStops.remove(method) != nil { try await control.setEnabled(false) }
            failures.removeValue(forKey: method)
            onChange?()
        } catch {
            pendingStops.remove(method)
            if error is CancellationError { failures.removeValue(forKey: method); onChange?(); return }
            failures[method] = error.localizedDescription
            onChange?()
            throw error
        }
    }
}
