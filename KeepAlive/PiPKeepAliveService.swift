import AVKit
import UIKit

/// Public VideoCall PiP following GlobalRefresh-PiP's PiP-only lifecycle.
/// No backing player, media, display timer, or monitoring dependency.
@MainActor final class PiPKeepAliveService: NSObject, KeepAliveService, AVPictureInPictureControllerDelegate {
    let name = "PiP"
    private(set) var state = KeepAliveState()
    var onStateChange: ((KeepAliveState) -> Void)?
    private static let openingHeight: CGFloat = 44
    private static let minimumHeight: CGFloat = 0.1
    private var surfaceHeight: CGFloat = openingHeight
    private var contentSize: CGSize { CGSize(width: 300, height: surfaceHeight) }
    private let record: (String, [String: String]) -> Void
    private var sourceView: UIView?
    private weak var sourceHost: UIView?
    private var sourceHeightConstraint: NSLayoutConstraint?
    private var contentController: AVPictureInPictureVideoCallViewController?
    private var controller: AVPictureInPictureController?
    private var observations: [NSKeyValueObservation] = []
    private var notifications: [NSObjectProtocol] = []
    private var generation = UUID()
    private var requested = false
    private var confirmed = false
    private var systemStarting = false
    private var issuedStart = false
    private var startupFailure: String?
    private var finalAfterStop = KeepAliveState(phase: .stopped, description: "画中画已停止")
    private var stopTask: Task<Void, Never>?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    // There is no public AVAudioSession.isActive getter; record acknowledged calls.
    private var audioAcknowledgement = "not_configured"

    init(record: @escaping (String, [String: String]) -> Void = { _, _ in }) {
        self.record = record
        super.init()
        updateState()
    }

    func updateState() {
        if let controller, confirmed {
            if controller.isPictureInPictureActive, requested {
                publish(.init(phase: .active, description: surfaceHeight == Self.minimumHeight
                              ? "画中画运行中 · 已设为 0.1pt" : "画中画运行中"))
            } else if !controller.isPictureInPictureActive, state.phase == .active {
                record("pip_system_inactive", diagnostics())
                finish(.init(phase: .stopped, description: "画中画已停止"))
            }
            return
        }
        guard ![.starting, .stopping, .failed].contains(state.phase) else { return }
        publish(AVPictureInPictureController.isPictureInPictureSupported()
                ? .init(phase: .stopped, description: "画中画未启动")
                : .init(phase: .unavailable, description: "此设备不支持画中画"))
    }
    func refresh() async throws { updateState() }

    func prepare() async throws {
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            throw KeepAliveError.message("此设备不支持画中画保活。")
        }
        guard controller == nil else { return }
        guard let host = sourceHost, host.window != nil else {
            throw KeepAliveError.message("画中画来源尚未入窗；请回到 App 前台后重试。")
        }
        // The dedicated SwiftUI root host survives tab changes and lazy Form row removal.
        let source = UIView()
        source.backgroundColor = .clear
        source.isOpaque = false
        source.isUserInteractionEnabled = false
        source.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(source)
        let heightConstraint = source.heightAnchor.constraint(equalToConstant: contentSize.height)
        sourceHeightConstraint = heightConstraint
        NSLayoutConstraint.activate([
            source.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            source.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            source.widthAnchor.constraint(equalToConstant: contentSize.width),
            heightConstraint
        ])
        sourceView = source
        let content = AVPictureInPictureVideoCallViewController()
        content.preferredContentSize = contentSize
        content.view.frame = CGRect(origin: .zero, size: contentSize)
        content.view.backgroundColor = .clear
        content.view.isOpaque = false
        content.view.layer.backgroundColor = UIColor.clear.cgColor
        content.view.layer.isOpaque = false
        content.view.clipsToBounds = true
        let placeholder = UIView()
        placeholder.backgroundColor = .clear
        placeholder.isOpaque = false
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        content.view.addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.leadingAnchor.constraint(equalTo: content.view.leadingAnchor),
            placeholder.trailingAnchor.constraint(equalTo: content.view.trailingAnchor),
            placeholder.topAnchor.constraint(equalTo: content.view.topAnchor),
            placeholder.bottomAnchor.constraint(equalTo: content.view.bottomAnchor)
        ])
        contentController = content
        layoutSource()
        try configureAudio()
        let current = AVPictureInPictureController(contentSource: .init(
            activeVideoCallSourceView: source, contentViewController: content))
        current.delegate = self
        current.requiresLinearPlayback = true
        current.canStartPictureInPictureAutomaticallyFromInline = requested
        controller = current
        observeSession(current)
        record("pip_prepared", diagnostics())
    }

    func start() async throws {
        if controller?.isPictureInPictureActive == true, confirmed { updateState(); return }
        guard state.phase != .stopping else { throw KeepAliveError.message("画中画仍在停止，请稍后重试。") }
        generation = UUID()
        let token = generation
        requested = true
        startupFailure = nil
        finalAfterStop = .init(phase: .stopped, description: "画中画已停止")
        // GlobalRefresh normal opening restores 44pt before asking AVKit to start.
        // A 0.1pt Auto Layout source can round to zero on the device, so shrink only after didStart.
        setSurfaceHeight(Self.openingHeight)
        publish(.init(phase: .starting, description: "正在准备画中画"))
        do {
            try await prepare()
            guard let current = controller else { throw KeepAliveError.message("画中画控制器未能创建。") }
            let deadline = ProcessInfo.processInfo.systemUptime + 8
            var attempts = 0
            var lastRequest = -Double.infinity
            // Commit source/content layout before the first readiness check.
            try await Task.sleep(nanoseconds: 120_000_000)
            while ProcessInfo.processInfo.systemUptime < deadline {
                if let startupFailure { throw KeepAliveError.message(startupFailure) }
                try Task.checkCancellation()
                guard requested, token == generation else { throw CancellationError() }
                if confirmed, current.isPictureInPictureActive { return }
                layoutSource()
                let now = ProcessInfo.processInfo.systemUptime
                let sourceReady = sourceView?.window != nil && sourceView?.bounds.isEmpty == false
                if sourceReady, current.isPictureInPicturePossible, !current.isPictureInPictureActive,
                   !systemStarting, attempts < 3, now - lastRequest >= 1.5 {
                    attempts += 1
                    lastRequest = now
                    issuedStart = true
                    publish(.init(phase: .starting, description: "正在启动画中画"))
                    var fields = diagnostics()
                    fields["attempt"] = String(attempts)
                    record("pip_start_requested", fields)
                    current.startPictureInPicture()
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            let reason: String
            if sourceView?.window == nil { reason = "来源视图未入窗" }
            else if sourceView?.bounds.isEmpty != false { reason = "来源视图实际尺寸为空" }
            else if !current.isPictureInPicturePossible { reason = "系统 isPictureInPicturePossible 为 false" }
            else { reason = "系统未确认画中画启动" }
            throw KeepAliveError.message("\(reason)（8 秒超时）。")
        } catch {
            if token != generation { throw CancellationError() }
            if error is CancellationError { stop(); throw error }
            var fields = diagnostics()
            fields["error"] = keepAliveErrorDescription(error)
            record("pip_start_failed", fields)
            requestStop(finalState: .init(phase: .failed, description: "画中画启动失败",
                                         lastError: keepAliveErrorDescription(error)))
            throw error
        }
    }

    func stop() {
        requestStop(finalState: .init(phase: .stopped, description: "画中画已停止"))
    }

    func attachSourceHost(_ host: UIView) {
        sourceHost = host
    }

    func detachSourceHost(_ host: UIView) {
        if sourceHost === host { sourceHost = nil }
    }

    func minimizeWindow() throws {
        guard confirmed, requested, controller?.isPictureInPictureActive == true, state.phase == .active else {
            record("pip_minimum_height_rejected", diagnostics())
            throw KeepAliveError.message("请先开启悬浮窗并拖到侧边吸附。")
        }
        setSurfaceHeight(Self.minimumHeight)
        record("pip_minimum_height_applied", diagnostics())
        updateState()
    }

    private func setSurfaceHeight(_ height: CGFloat) {
        surfaceHeight = height
        sourceHeightConstraint?.constant = height
        contentController?.preferredContentSize = contentSize
        if controller?.isPictureInPictureActive != true {
            contentController?.view.frame = CGRect(origin: .zero, size: contentSize)
        }
        layoutSource()
    }

    private func requestStop(finalState: KeepAliveState) {
        requested = false
        controller?.canStartPictureInPictureAutomaticallyFromInline = false
        generation = UUID()
        finalAfterStop = finalState
        guard let current = controller else { finish(finalState); return }
        record("pip_stop_requested", diagnostics())
        endBackgroundTransition()
        if current.isPictureInPictureActive || issuedStart || systemStarting {
            publish(.init(phase: .stopping, description: "正在停止画中画", lastError: finalState.lastError))
            current.stopPictureInPicture()
            watchForStop(current)
        } else { finish(finalState) }
    }

    private func layoutSource() {
        sourceView?.isHidden = false
        sourceView?.alpha = 1
        sourceView?.layer.opacity = 1
        contentController?.view.alpha = 1
        sourceView?.superview?.layoutIfNeeded()
        contentController?.view.setNeedsLayout()
        contentController?.view.layoutIfNeeded()
        CATransaction.flush()
    }
    private func configureAudio() throws {
        do {
            // Reference VideoCall/PiP-only mode releases media audio instead of playing silence.
            audioAcknowledgement = try KeepAliveAudioSessionLeaseCoordinator.shared.configurePiPOnlyIfUnowned()
                ? "deactivation_succeeded" : "unchanged_other_owner"
        } catch {
            audioAcknowledgement = "configuration_failed: \(keepAliveErrorDescription(error))"
            throw error
        }
    }

    private func observeSession(_ current: AVPictureInPictureController) {
        let identity = ObjectIdentifier(current)
        observations = [
            current.observe(\.isPictureInPicturePossible, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    guard let self, self.matches(identity) else { return }
                    self.record("pip_possibility_changed", self.diagnostics())
                }
            },
            current.observe(\.isPictureInPictureActive, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    guard let self, self.matches(identity) else { return }
                    self.record("pip_active_changed", self.diagnostics())
                    self.updateState()
                }
            }
        ]
        for name in [UIApplication.didEnterBackgroundNotification, UIApplication.willEnterForegroundNotification,
                     AVAudioSession.interruptionNotification, AVAudioSession.routeChangeNotification] {
            notifications.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] notification in
                let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                Task { @MainActor [weak self] in
                    guard let self, self.matches(identity) else { return }
                    if name == UIApplication.didEnterBackgroundNotification {
                        self.beginBackgroundTransition()
                        self.record("pip_enter_background", self.diagnostics())
                    } else if name == UIApplication.willEnterForegroundNotification {
                        self.endBackgroundTransition()
                        self.updateState()
                    } else {
                        var fields = self.diagnostics()
                        fields["interruptionType"] = type.map(String.init) ?? "none"
                        fields["routeChangeReason"] = reason.map(String.init) ?? "none"
                        self.record("pip_audio_session_changed", fields)
                        self.updateState()
                    }
                }
            })
        }
    }
    private func beginBackgroundTransition() {
        guard backgroundTask == .invalid, requested,
              controller?.isPictureInPictureActive == true || state.phase == .starting else { return }
        // One finite transition grace period, never renewed as a background timer loop.
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "PiP transition") { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.record("pip_background_grace_expired", self.diagnostics())
                self.endBackgroundTransition()
            }
        }
        record("pip_background_grace_started", diagnostics())
    }
    private func endBackgroundTransition() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
    private func watchForStop(_ current: AVPictureInPictureController) {
        guard stopTask == nil else { return }
        let identity = ObjectIdentifier(current)
        stopTask = Task { @MainActor [weak self] in
            // Cancelled startup may produce no didStop. Wait for queued transitions to settle.
            for attempt in 0..<40 {
                do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
                guard let self, self.matches(identity) else { return }
                if attempt >= 29, !self.systemStarting, self.controller?.isPictureInPictureActive == false {
                    self.record("pip_stop_confirmed_inactive", self.diagnostics())
                    self.finish(self.finalAfterStop)
                    return
                }
                if attempt == 19 { self.controller?.stopPictureInPicture() }
            }
            guard let self, self.matches(identity) else { return }
            self.stopTask = nil
            self.record("pip_stop_unconfirmed", self.diagnostics())
            self.publish(.init(phase: .stopping, description: "系统尚未确认停止，请关闭画中画窗口",
                               lastError: self.finalAfterStop.lastError))
        }
    }
    private func finish(_ finalState: KeepAliveState) {
        requested = false
        confirmed = false
        systemStarting = false
        issuedStart = false
        stopTask?.cancel()
        stopTask = nil
        observations.removeAll()
        notifications.forEach { NotificationCenter.default.removeObserver($0) }
        notifications.removeAll()
        endBackgroundTransition()
        controller?.delegate = nil
        controller = nil
        contentController = nil
        sourceView?.removeFromSuperview()
        sourceView = nil
        sourceHeightConstraint = nil
        if audioAcknowledgement != "not_configured" {
            do { try configureAudio() }
            catch { record("pip_audio_release_failed", ["error": keepAliveErrorDescription(error)]) }
        }
        record("pip_session_released", diagnostics())
        publish(finalState)
    }
    private func matches(_ identity: ObjectIdentifier) -> Bool {
        controller.map { ObjectIdentifier($0) == identity } ?? false
    }
    private func diagnostics() -> [String: String] {
        let audio = AVAudioSession.sharedInstance()
        return [
            "route": "VideoCall_PiP_only", "playerStatus": "not_used", "preferredHeight": String(Double(surfaceHeight)),
            "sourceHeightConstraint": sourceHeightConstraint.map { String(Double($0.constant)) } ?? "none",
            "sourceHostInWindow": String(sourceHost?.window != nil),
            "isPictureInPicturePossible": String(controller?.isPictureInPicturePossible ?? false),
            "isPictureInPictureActive": String(controller?.isPictureInPictureActive ?? false),
            "isPictureInPictureSuspended": String(controller?.isPictureInPictureSuspended ?? false),
            "didConfirmStart": String(confirmed), "requested": String(requested),
            "systemIsStarting": String(systemStarting), "hasController": String(controller != nil),
            "sourceInWindow": String(sourceView?.window != nil),
            "sourceBounds": sourceView.map { NSCoder.string(for: $0.bounds) } ?? "none",
            "contentBounds": contentController.map { NSCoder.string(for: $0.view.bounds) } ?? "none",
            "applicationState": String(UIApplication.shared.applicationState.rawValue),
            "audioCategory": audio.category.rawValue, "audioMode": audio.mode.rawValue,
            "audioOptions": String(audio.categoryOptions.rawValue), "audioSessionAcknowledgement": audioAcknowledgement,
            "otherAudioPlaying": String(audio.isOtherAudioPlaying),
            "audioRoute": audio.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ","),
            "backgroundGrace": String(backgroundTask != .invalid), "stopTaskPending": String(stopTask != nil),
            "observerCount": String(observations.count + notifications.count)
        ]
    }

    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        let identity = ObjectIdentifier(pictureInPictureController)
        Task { @MainActor [weak self] in
            guard let self, self.matches(identity) else { return }
            self.systemStarting = true
            self.record("pip_will_start", self.diagnostics())
            if !self.requested { self.controller?.stopPictureInPicture() }
        }
    }
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        let identity = ObjectIdentifier(pictureInPictureController)
        Task { @MainActor [weak self] in
            guard let self, self.matches(identity) else { return }
            self.systemStarting = false
            guard self.requested else { self.controller?.stopPictureInPicture(); return }
            self.confirmed = true
            self.record("pip_did_start", self.diagnostics())
            self.updateState()
        }
    }
    nonisolated func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        let identity = ObjectIdentifier(pictureInPictureController)
        Task { @MainActor [weak self] in
            guard let self, self.matches(identity) else { return }
            self.requested = false
            self.controller?.canStartPictureInPictureAutomaticallyFromInline = false
            self.generation = UUID()
            self.publish(.init(phase: .stopping, description: "正在停止画中画"))
            self.endBackgroundTransition()
            if let current = self.controller { self.watchForStop(current) }
            self.record("pip_will_stop", self.diagnostics())
        }
    }
    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        let identity = ObjectIdentifier(pictureInPictureController)
        Task { @MainActor [weak self] in
            guard let self, self.matches(identity) else { return }
            self.generation = UUID()
            self.record("pip_did_stop", self.diagnostics())
            self.finish(self.finalAfterStop)
        }
    }
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                                failedToStartPictureInPictureWithError error: Error) {
        let identity = ObjectIdentifier(pictureInPictureController)
        let detail = keepAliveErrorDescription(error)
        Task { @MainActor [weak self] in
            guard let self, self.matches(identity) else { return }
            self.systemStarting = false
            self.startupFailure = detail
            self.issuedStart = false
            var fields = self.diagnostics()
            fields["error"] = detail
            self.record("pip_system_start_failed", fields)
            if !self.requested, self.controller?.isPictureInPictureActive == false {
                self.finish(self.finalAfterStop)
            }
            // The awaiting start() owns failure teardown and propagates the system error.
        }
    }
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                                restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        completionHandler(true) // Source is already mounted in the existing app root.
    }
    private func publish(_ newState: KeepAliveState) {
        guard state != newState else { return }
        state = newState
        record("pip_status", ["phase": state.phase.rawValue, "status": state.description])
        onStateChange?(state)
    }
}
