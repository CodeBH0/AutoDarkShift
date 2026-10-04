import CoreLocation
import Foundation
import UIKit

/// Continuous Core Location session. Only callback timing/accuracy is retained;
/// coordinates are never logged, persisted, or passed to the brightness monitor.
@MainActor final class LocationKeepAliveService: NSObject, KeepAliveService, CLLocationManagerDelegate {
    let name = "Location"
    private(set) var state = KeepAliveState()
    var onStateChange: ((KeepAliveState) -> Void)?

    private let record: (String, [String: String]) -> Void
    private var manager = CLLocationManager()
    private var isRequested = false
    private var isUpdatingLocation = false
    private var didRequestAlwaysAuthorization = false
    private var interruption: String?
    private var sessionID = UUID()
    private var updateCount = 0
    private var lastUpdateAt: Date?
    private var lastUpdateLogUptime: TimeInterval?
    private var observers: [NSObjectProtocol] = []
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var backgroundTaskSession: UUID?

    init(record: @escaping (String, [String: String]) -> Void = { _, _ in }) {
        self.record = record
        super.init()
        configureManager()
        for name in [UIApplication.didEnterBackgroundNotification, UIApplication.didBecomeActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.isRequested else { return }
                    if name == UIApplication.didEnterBackgroundNotification {
                        self.beginBackgroundTransition()
                        self.log("location_enter_background")
                    } else {
                        self.endBackgroundTransition(reason: "foreground")
                        self.reconcile(reason: "foreground")
                        self.log("location_enter_foreground")
                    }
                }
            })
        }
        updateState()
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        // UIKit cleanup must run on its main actor even if the owner is released elsewhere.
        let task = backgroundTask
        let current = manager
        Task { @MainActor in
            current.delegate = nil
            current.stopUpdatingLocation()
            if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
        }
    }

    private func configureManager() {
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .fitness
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
    }

    func updateState() {
        guard isRequested else {
            // A foreground refresh must not overwrite an explicit start failure.
            guard state.phase != .failed else { return }
            publish(.init(phase: .stopped, description: "定位保活已停止"))
            return
        }
        reconcile(reason: "refresh")
    }

    func refresh() async throws { updateState() }
    func prepare() async throws { updateState() }

    func start() async throws {
        guard !isRequested else { updateState(); return }
        guard CLLocationManager.locationServicesEnabled() else {
            let message = "系统定位服务已关闭，无法启动定位保活。"
            failStart(message)
            throw KeepAliveError.message(message)
        }
        guard manager.authorizationStatus != .denied, manager.authorizationStatus != .restricted else {
            let message = authorizationDescription(manager.authorizationStatus)
            failStart(message)
            throw KeepAliveError.message(message)
        }
        guard UIApplication.shared.applicationState != .background || manager.authorizationStatus == .authorizedAlways else {
            throw KeepAliveError.message("请回到 App 前台后开启定位保活。")
        }
        // New manager identity rejects callbacks queued by an earlier stopped session.
        manager.delegate = nil
        manager.stopUpdatingLocation()
        manager = CLLocationManager()
        configureManager()
        sessionID = UUID()
        isRequested = true
        isUpdatingLocation = false
        didRequestAlwaysAuthorization = false
        interruption = nil
        updateCount = 0
        lastUpdateAt = nil
        lastUpdateLogUptime = nil
        publish(.init(phase: .starting, description: "正在准备连续后台定位"))
        log("location_start_requested")
        reconcile(reason: "start")
    }

    func stop() {
        isRequested = false
        manager.stopUpdatingLocation()
        isUpdatingLocation = false
        interruption = nil
        endBackgroundTransition(reason: "stop")
        log("location_stop_requested")
        publish(.init(phase: .stopped, description: "定位保活已停止"))
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let identity = ObjectIdentifier(manager)
        Task { @MainActor [weak self] in
            guard let self, self.matches(identity) else { return }
            self.log("location_authorization_changed")
            self.reconcile(reason: "authorization")
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let identity = ObjectIdentifier(manager)
        // Copy metadata only. Do not retain the location array or any coordinates.
        let timestamp = locations.last?.timestamp
        let accuracy = locations.last?.horizontalAccuracy
        let count = locations.count
        Task { @MainActor [weak self] in
            guard let self, self.matches(identity) else { return }
            self.handleLocationUpdate(timestamp: timestamp, accuracy: accuracy, count: count)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let identity = ObjectIdentifier(manager)
        let nsError = error as NSError
        let domain = nsError.domain
        let code = nsError.code
        let detail = nsError.localizedDescription
        Task { @MainActor [weak self] in
            guard let self, self.matches(identity) else { return }
            self.handleLocationError(domain: domain, code: code, detail: detail)
        }
    }

    nonisolated func locationManagerDidPauseLocationUpdates(_ manager: CLLocationManager) {
        let identity = ObjectIdentifier(manager)
        Task { @MainActor [weak self] in
            guard let self, self.matches(identity) else { return }
            self.isUpdatingLocation = false
            self.interruption = "系统已暂停定位更新。"
            self.log("location_updates_paused")
            self.reconcile(reason: "paused")
        }
    }

    nonisolated func locationManagerDidResumeLocationUpdates(_ manager: CLLocationManager) {
        let identity = ObjectIdentifier(manager)
        Task { @MainActor [weak self] in
            guard let self, self.matches(identity) else { return }
            self.isUpdatingLocation = true
            self.interruption = nil
            self.log("location_updates_resumed")
            self.publishRunningState()
        }
    }

    private func matches(_ identity: ObjectIdentifier) -> Bool {
        isRequested && identity == ObjectIdentifier(manager)
    }

    private func reconcile(reason: String) {
        guard isRequested else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            if !isUpdatingLocation {
                // When In Use can continue a foreground-started session, but cannot
                // restart a paused/stopped session from the background.
                guard manager.authorizationStatus == .authorizedAlways || UIApplication.shared.applicationState != .background else {
                    publish(.init(phase: .starting, description: "定位更新已暂停；请回到 App 恢复"))
                    return
                }
                manager.startUpdatingLocation()
                isUpdatingLocation = true
                log("location_updates_started", ["reason": reason])
            }
            publishRunningState()
            requestAlwaysAuthorizationIfNeeded()
        case .notDetermined:
            if isUpdatingLocation {
                manager.stopUpdatingLocation()
                isUpdatingLocation = false
            }
            publish(.init(phase: .starting, description: "等待定位授权；请在前台允许定位"))
            if ["start", "foreground"].contains(reason), UIApplication.shared.applicationState != .background {
                manager.requestWhenInUseAuthorization()
                log("location_when_in_use_authorization_requested")
            }
        case .denied, .restricted:
            failStart(authorizationDescription(manager.authorizationStatus))
        @unknown default:
            failStart("无法识别系统定位授权状态。")
        }
    }

    private func publishRunningState() {
        guard isRequested, isUpdatingLocation else { return }
        guard manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse else {
            reconcile(reason: "authorization_check")
            return
        }
        let authorization = manager.authorizationStatus == .authorizedAlways ? "始终授权" : "使用期间授权"
        let description = updateCount == 0 ? "连续定位已启动，等待定位回调（\(authorization)）" : "连续后台定位运行中（\(authorization)）"
        publish(.init(phase: interruption == nil ? .active : .reasserting,
                      description: interruption == nil ? description : "定位会话保留，等待更新恢复（\(authorization)）",
                      lastError: interruption))
    }

    private func handleLocationUpdate(timestamp: Date?, accuracy: CLLocationAccuracy?, count: Int) {
        guard isRequested, isUpdatingLocation else { return }
        guard let timestamp, let accuracy, accuracy.isFinite, accuracy >= 0 else {
            log("location_update_invalid", ["batchCount": String(count)])
            return
        }
        updateCount += 1
        lastUpdateAt = Date()
        interruption = nil
        publishRunningState()
        let now = ProcessInfo.processInfo.systemUptime
        if lastUpdateLogUptime == nil || now - lastUpdateLogUptime! >= 5 {
            lastUpdateLogUptime = now
            log("location_update_received", ["batchCount": String(count),
                "fixTimestamp": timestamp.ISO8601Format(),
                "fixAge": String(Date().timeIntervalSince(timestamp)),
                "horizontalAccuracy": String(accuracy)])
        }
        endBackgroundTransition(reason: "location_callback")
    }

    private func handleLocationError(domain: String, code: Int, detail: String) {
        guard isRequested else { return }
        log("location_update_interrupted", ["errorDomain": domain, "errorCode": String(code), "error": detail])
        if domain == kCLErrorDomain, code == CLError.denied.rawValue {
            failStart("系统已拒绝定位更新。请在设置中允许定位后重新开启。")
            return
        }
        // No indoor fix / temporary positioning failure does not stop the session.
        interruption = detail
        publishRunningState()
    }

    private func requestAlwaysAuthorizationIfNeeded() {
        guard isRequested, manager.authorizationStatus == .authorizedWhenInUse,
              !didRequestAlwaysAuthorization, UIApplication.shared.applicationState == .active else { return }
        didRequestAlwaysAuthorization = true
        log("location_always_authorization_requested")
        manager.requestAlwaysAuthorization()
    }

    private func failStart(_ detail: String) {
        isRequested = false
        manager.stopUpdatingLocation()
        isUpdatingLocation = false
        interruption = nil
        endBackgroundTransition(reason: "failure")
        publish(.init(phase: .failed, description: "定位保活不可用", lastError: detail))
        log("location_start_failed", ["error": detail])
    }

    private func beginBackgroundTransition() {
        guard isRequested, isUpdatingLocation, backgroundTask == .invalid else { return }
        let token = UUID()
        backgroundTaskSession = token
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Location transition") { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.backgroundTaskSession == token else { return }
                self.log("location_background_grace_expired")
                self.endBackgroundTransition(reason: "expired")
            }
        }
        log("location_background_grace_started", ["granted": String(backgroundTask != .invalid)])
    }

    private func endBackgroundTransition(reason: String) {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
        backgroundTaskSession = nil
        log("location_background_grace_ended", ["reason": reason])
    }

    private func authorizationDescription(_ status: CLAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "尚未请求定位权限。"
        case .restricted: return "系统限制了定位权限。"
        case .denied: return "定位权限已拒绝或系统定位已关闭。请在设置中允许定位后重试。"
        case .authorizedWhenInUse: return "使用期间授权可延续前台启动的后台定位；会话停止后须回前台恢复。"
        case .authorizedAlways: return "已允许始终定位。"
        @unknown default: return "无法识别系统定位授权状态。"
        }
    }

    private func log(_ event: String, _ extra: [String: String] = [:]) {
        var fields = ["sessionID": sessionID.uuidString,
            "requested": String(isRequested), "updatesRequested": String(isUpdatingLocation),
            "authorization": String(manager.authorizationStatus.rawValue),
            "accuracyAuthorization": String(manager.accuracyAuthorization.rawValue),
            "desiredAccuracy": String(manager.desiredAccuracy), "distanceFilter": String(manager.distanceFilter),
            "activityType": String(manager.activityType.rawValue),
            "backgroundUpdates": String(manager.allowsBackgroundLocationUpdates),
            "automaticPause": String(manager.pausesLocationUpdatesAutomatically),
            "backgroundIndicator": String(manager.showsBackgroundLocationIndicator),
            "applicationState": String(UIApplication.shared.applicationState.rawValue),
            "updateCount": String(updateCount), "lastCallbackAt": lastUpdateAt?.ISO8601Format() ?? "none",
            "backgroundGraceActive": String(backgroundTask != .invalid)]
        fields.merge(extra) { _, new in new }
        record(event, fields)
    }

    private func publish(_ newState: KeepAliveState) {
        guard state != newState else { return }
        state = newState
        log("location_status", ["phase": state.phase.rawValue, "status": state.description])
        onStateChange?(state)
    }
}
