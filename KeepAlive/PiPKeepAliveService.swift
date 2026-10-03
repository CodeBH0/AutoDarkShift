import AVKit
import SwiftUI
import UIKit

/// Keeps the app eligible for background execution through public video-call PiP APIs.
/// The PiP content is deliberately informational and is unrelated to monitoring.
@MainActor final class PiPKeepAliveService: NSObject, KeepAliveService, AVPictureInPictureControllerDelegate {
    let name = "PiP"
    private(set) var state = KeepAliveState()
    var onStateChange: ((KeepAliveState) -> Void)?

    private let record: (String, [String: String]) -> Void
    private weak var sourceView: UIView?
    private var contentController: AVPictureInPictureVideoCallViewController?
    private var controller: AVPictureInPictureController?
    private var audioLease: UUID?
    private var startGeneration = UUID()
    private var isRequested = false
    private var audioInterruptionObserver: NSObjectProtocol?

    init(record: @escaping (String, [String: String]) -> Void = { _, _ in }) {
        self.record = record
        super.init()
        audioInterruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: nil
        ) { [weak self] notification in
            let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor [weak self] in
                self?.handleAudioInterruption(type: rawType, optionsRawValue: rawOptions)
            }
        }
        updateState()
    }

    deinit {
        if let audioInterruptionObserver {
            NotificationCenter.default.removeObserver(audioInterruptionObserver)
        }
    }

    func attachSourceView(_ view: UIView) {
        if sourceView !== view, controller?.isPictureInPictureActive != true,
           state.phase != .starting, state.phase != .stopping {
            controller = nil
            contentController = nil
        }
        sourceView = view
        if controller == nil { updateState() }
    }

    func detachSourceView(_ view: UIView) {
        guard sourceView === view else { return }
        sourceView = nil
    }

    func updateState() {
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            if state.phase != .starting, state.phase != .stopping, state.phase != .failed {
                publish(.init(phase: .unavailable, description: "此设备不支持画中画"))
            }
            return
        }
        guard let controller else {
            guard state.phase != .starting, state.phase != .stopping, state.phase != .failed else { return }
            publish(.init(phase: .stopped, description: "画中画未启动"))
            return
        }
        // Transitions and failures are driven by AVPictureInPictureControllerDelegate.
        // A periodic refresh must not clear them or make the switch appear stopped.
        guard state.phase != .starting, state.phase != .stopping, state.phase != .failed else { return }
        if state.phase == .active, !controller.isPictureInPictureActive { return }
        if controller.isPictureInPictureActive {
            publish(.init(phase: .active, description: "画中画运行中"))
        } else {
            publish(.init(phase: .stopped, description: controller.isPictureInPicturePossible ? "画中画已就绪" : "等待系统允许画中画"))
        }
    }

    func refresh() async throws { updateState() }

    func prepare() async throws {
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            throw KeepAliveError.message("此设备不支持画中画保活。")
        }
        guard let sourceView else {
            throw KeepAliveError.message("画中画锚点尚未显示；请先打开保活页面。")
        }
        guard controller == nil else { updateState(); return }

        let videoCallController = AVPictureInPictureVideoCallViewController()
        videoCallController.preferredContentSize = CGSize(width: 240, height: 135)
        let contentView = UIView()
        contentView.backgroundColor = UIColor.systemBackground
        let label = UILabel()
        label.text = "后台保活"
        label.textColor = .label
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)
        ])
        videoCallController.view = contentView

        let contentSource = AVPictureInPictureController.ContentSource(
            activeVideoCallSourceView: sourceView,
            contentViewController: videoCallController
        )
        let pipController = AVPictureInPictureController(contentSource: contentSource)
        pipController.delegate = self
        pipController.canStartPictureInPictureAutomaticallyFromInline = false
        contentController = videoCallController
        controller = pipController
        publish(.init(phase: .stopped, description: "画中画已就绪"))
        record("pip_prepared", [:])
    }

    func start() async throws {
        try await prepare()
        guard let controller else { throw KeepAliveError.message("画中画控制器未能创建。") }
        guard !controller.isPictureInPictureActive else { updateState(); return }
        isRequested = true
        startGeneration = UUID()
        let generation = startGeneration
        do {
            if audioLease == nil { audioLease = try KeepAliveAudioSessionLeaseCoordinator.shared.acquire() }
            publish(.init(phase: .starting, description: "正在准备画中画"))
            // The public content source becomes possible asynchronously after layout/audio activation.
            for _ in 0..<40 {
                guard isRequested, generation == startGeneration else { throw CancellationError() }
                if controller.isPictureInPicturePossible { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            guard isRequested, generation == startGeneration else { throw CancellationError() }
            guard controller.isPictureInPicturePossible else {
                throw KeepAliveError.message("画中画尚未就绪，请保持来源区域可见并确认系统允许画中画后重试。")
            }
            publish(.init(phase: .starting, description: "正在启动画中画"))
            record("pip_start_requested", [:])
            controller.startPictureInPicture()
        } catch {
            isRequested = false
            KeepAliveAudioSessionLeaseCoordinator.shared.release(audioLease)
            audioLease = nil
            if error is CancellationError {
                publish(.init(phase: .stopped, description: "画中画启动已取消"))
                throw error
            }
            publish(.init(phase: .failed, description: "画中画启动失败", lastError: keepAliveErrorDescription(error)))
            record("pip_start_failed", ["error": keepAliveErrorDescription(error)])
            throw error
        }
    }

    func stop() {
        isRequested = false
        startGeneration = UUID()
        guard let controller, controller.isPictureInPictureActive || state.phase == .starting else {
            KeepAliveAudioSessionLeaseCoordinator.shared.release(audioLease)
            audioLease = nil
            publish(.init(phase: .stopped, description: "画中画已停止"))
            return
        }
        publish(.init(phase: .stopping, description: "正在停止画中画"))
        record("pip_stop_requested", [:])
        controller.stopPictureInPicture()
    }

    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        let controllerID = ObjectIdentifier(pictureInPictureController)
        Task { @MainActor [weak self] in self?.handleDidStart(controllerID: controllerID) }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        let controllerID = ObjectIdentifier(pictureInPictureController)
        Task { @MainActor [weak self] in self?.handleDidStop(controllerID: controllerID) }
    }

    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                                failedToStartPictureInPictureWithError error: Error) {
        let controllerID = ObjectIdentifier(pictureInPictureController)
        let detail = keepAliveErrorDescription(error)
        Task { @MainActor [weak self] in self?.handleStartFailure(controllerID: controllerID, detail: detail) }
    }

    private func handleDidStart(controllerID: ObjectIdentifier) {
        guard let controller, ObjectIdentifier(controller) == controllerID else { return }
        guard isRequested else { controller.stopPictureInPicture(); return }
        publish(.init(phase: .active, description: "画中画运行中"))
        record("pip_did_start", [:])
    }

    private func handleDidStop(controllerID: ObjectIdentifier) {
        guard let controller, ObjectIdentifier(controller) == controllerID else { return }
        isRequested = false
        startGeneration = UUID()
        KeepAliveAudioSessionLeaseCoordinator.shared.release(audioLease)
        audioLease = nil
        publish(.init(phase: .stopped, description: "画中画已停止"))
        record("pip_did_stop", [:])
    }

    private func handleStartFailure(controllerID: ObjectIdentifier, detail: String) {
        guard let controller, ObjectIdentifier(controller) == controllerID else { return }
        let wasRequested = isRequested
        KeepAliveAudioSessionLeaseCoordinator.shared.release(audioLease)
        audioLease = nil
        isRequested = false
        startGeneration = UUID()
        publish(wasRequested ? .init(phase: .failed, description: "画中画启动失败", lastError: detail)
                             : .init(phase: .stopped, description: "画中画启动已取消"))
        record("pip_start_failed", ["error": detail])
    }

    private func handleAudioInterruption(type rawType: UInt?, optionsRawValue: UInt) {
        guard audioLease != nil,
              let rawType,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
        switch type {
        case .began:
            record("pip_audio_session_interruption_began", [:])
        case .ended:
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsRawValue)
            guard options.contains(.shouldResume) else {
                record("pip_audio_session_interruption_ended", ["shouldResume": "false"])
                return
            }
            do {
                try KeepAliveAudioSessionLeaseCoordinator.shared.reactivateIfNeeded()
                record("pip_audio_session_resumed", [:])
            } catch {
                record("pip_audio_session_resume_failed", ["error": keepAliveErrorDescription(error)])
            }
        @unknown default:
            break
        }
    }

    private func publish(_ newState: KeepAliveState) {
        guard state != newState else { return }
        state = newState
        record("pip_status", ["phase": state.phase.rawValue, "status": state.description])
        onStateChange?(state)
    }
}

/// A visible inline anchor required by the public video-call PiP content source.
/// Place this representable in the keep-alive screen while PiP is enabled.
struct PiPSourceView: UIViewRepresentable {
    let service: PiPKeepAliveService

    func makeCoordinator() -> Coordinator { Coordinator(service: service) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = UIColor.secondarySystemBackground
        view.layer.cornerRadius = 8
        view.clipsToBounds = true
        let label = UILabel()
        label.text = "保活来源已就绪"
        label.textColor = .secondaryLabel
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -6),
            label.topAnchor.constraint(equalTo: view.topAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -4)
        ])
        service.attachSourceView(view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        service.attachSourceView(uiView)
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.service.detachSourceView(uiView)
    }

    final class Coordinator {
        let service: PiPKeepAliveService
        init(service: PiPKeepAliveService) { self.service = service }
    }
}
