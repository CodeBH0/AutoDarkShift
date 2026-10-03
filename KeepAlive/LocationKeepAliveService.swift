import CoreLocation
import Foundation

/// Uses low-accuracy background location updates solely as a system-supported
/// background execution mode. Coordinates are neither logged nor persisted.
@MainActor final class LocationKeepAliveService: NSObject, KeepAliveService, CLLocationManagerDelegate {
    let name = "Location"
    private(set) var state = KeepAliveState()
    var onStateChange: ((KeepAliveState) -> Void)?

    private let record: (String, [String: String]) -> Void
    private let manager = CLLocationManager()
    private var isRequested = false
    private var isUpdatingLocation = false
    private var didRequestAlwaysAuthorization = false

    init(record: @escaping (String, [String: String]) -> Void = { _, _ in }) {
        self.record = record
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        manager.distanceFilter = CLLocationDistanceMax
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = true
        updateState()
    }

    func updateState() {
        guard isRequested else {
            let phase: KeepAlivePhase = manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted
                ? .failed : .stopped
            let message = authorizationDescription(manager.authorizationStatus)
            publish(.init(phase: phase, description: phase == .failed ? "定位权限不可用" : "定位保活已停止",
                          lastError: phase == .failed ? message : nil))
            return
        }
        switch manager.authorizationStatus {
        case .authorizedAlways:
            if state.phase != .reasserting {
                publish(.init(phase: .active, description: "后台定位保活运行中"))
            }
        case .authorizedWhenInUse:
            if state.phase != .reasserting {
                publish(.init(phase: .active, description: "定位运行中；当前为使用期间授权，后台持续性有限"))
            }
        case .notDetermined:
            publish(.init(phase: .starting, description: "等待定位授权"))
        case .denied, .restricted:
            let message = authorizationDescription(manager.authorizationStatus)
            publish(.init(phase: .failed, description: "定位授权被拒绝", lastError: message))
        @unknown default:
            publish(.init(phase: .failed, description: "定位授权状态未知"))
        }
    }

    func refresh() async throws { updateState() }
    func prepare() async throws { updateState() }

    func start() async throws {
        guard !isRequested else { updateState(); return }
        guard CLLocationManager.locationServicesEnabled() else {
            let message = "系统定位服务已关闭，无法启动定位保活。"
            publish(.init(phase: .failed, description: "定位保活启动失败", lastError: message))
            throw KeepAliveError.message(message)
        }
        isRequested = true
        didRequestAlwaysAuthorization = false
        publish(.init(phase: .starting, description: "正在请求定位授权"))
        record("location_start_requested", ["accuracy": "threeKilometers"])

        switch manager.authorizationStatus {
        case .authorizedAlways:
            beginLocationUpdates()
        case .authorizedWhenInUse:
            beginLocationUpdates()
            requestAlwaysAuthorizationIfNeeded()
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            let message = authorizationDescription(manager.authorizationStatus)
            failStart(message)
            throw KeepAliveError.message(message)
        @unknown default:
            let message = "无法识别系统定位授权状态。"
            failStart(message)
            throw KeepAliveError.message(message)
        }
    }

    func stop() {
        isRequested = false
        manager.stopUpdatingLocation()
        isUpdatingLocation = false
        publish(.init(phase: .stopped, description: "定位保活已停止"))
        record("location_stop_requested", [:])
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in self?.handleAuthorizationChange() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor [weak self] in self?.handleLocationUpdate() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let nsError = error as NSError
        let domain = nsError.domain
        let code = nsError.code
        let detail = nsError.localizedDescription
        Task { @MainActor [weak self] in
            self?.handleLocationError(domain: domain, code: code, detail: detail)
        }
    }

    nonisolated func locationManagerDidPauseLocationUpdates(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in self?.handleLocationPaused() }
    }

    nonisolated func locationManagerDidResumeLocationUpdates(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in self?.handleLocationResumed() }
    }

    private func handleAuthorizationChange() {
        updateState()
        guard isRequested else { return }
        switch manager.authorizationStatus {
        case .authorizedWhenInUse:
            beginLocationUpdates()
            requestAlwaysAuthorizationIfNeeded()
        case .authorizedAlways:
            beginLocationUpdates()
        case .denied, .restricted:
            failStart(authorizationDescription(manager.authorizationStatus))
        case .notDetermined:
            break
        @unknown default:
            failStart("无法识别系统定位授权状态。")
        }
    }

    private func handleLocationUpdate() {
        guard isRequested else { return }
        let description = manager.authorizationStatus == .authorizedAlways
            ? "后台定位保活运行中"
            : "定位运行中；当前为使用期间授权，后台持续性有限"
        publish(.init(phase: .active, description: description))
    }

    private func handleLocationError(domain: String, code: Int, detail: String) {
        if domain == kCLErrorDomain, code == CLError.denied.rawValue {
            failStart("系统已拒绝定位更新。请在设置中允许定位后重新开启。")
            return
        }
        record("location_update_interrupted", ["error": detail])
        if isRequested, (manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse) {
            publish(.init(phase: .reasserting, description: "定位更新暂时中断", lastError: detail))
        }
    }

    private func handleLocationPaused() {
        guard isRequested else { return }
        let detail = "系统已暂停后台定位更新。"
        publish(.init(phase: .reasserting, description: "定位更新已暂停", lastError: detail))
        record("location_updates_paused", [:])
    }

    private func handleLocationResumed() {
        guard isRequested else { return }
        handleLocationUpdate()
        record("location_updates_resumed", [:])
    }

    private func requestAlwaysAuthorizationIfNeeded() {
        guard isRequested, !didRequestAlwaysAuthorization else { return }
        didRequestAlwaysAuthorization = true
        record("location_always_authorization_requested", [:])
        manager.requestAlwaysAuthorization()
    }

    private func beginLocationUpdates() {
        guard isRequested,
              (manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse) else { return }
        if !isUpdatingLocation {
            manager.startUpdatingLocation()
            isUpdatingLocation = true
            record("location_updates_started", ["authorization": manager.authorizationStatus == .authorizedAlways ? "always" : "when_in_use"])
        }
        let description = manager.authorizationStatus == .authorizedAlways
            ? "后台定位保活运行中"
            : "定位运行中；当前为使用期间授权，后台持续性有限"
        publish(.init(phase: .active, description: description))
    }

    private func failStart(_ detail: String) {
        manager.stopUpdatingLocation()
        isUpdatingLocation = false
        isRequested = false
        publish(.init(phase: .failed, description: "定位保活启动失败", lastError: detail))
        record("location_start_failed", ["error": detail])
    }

    private func authorizationDescription(_ status: CLAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "尚未请求定位权限。"
        case .restricted: return "系统限制了定位权限。"
        case .denied: return "定位权限已拒绝。请在系统设置中允许定位后重试。"
        case .authorizedWhenInUse: return "当前只有使用期间定位权限；后台持续性有限，可在系统设置中升级为始终允许。"
        case .authorizedAlways: return "已允许始终定位。"
        @unknown default: return "无法识别系统定位授权状态。"
        }
    }

    private func publish(_ newState: KeepAliveState) {
        guard state != newState else { return }
        state = newState
        record("location_status", ["phase": state.phase.rawValue, "status": state.description])
        onStateChange?(state)
    }
}
