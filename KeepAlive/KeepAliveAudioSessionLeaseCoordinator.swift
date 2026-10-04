import AVFoundation
import Foundation

/// Coordinates audio-session ownership across independent keep-alive services.
/// A service releases only its own token; the shared session is deactivated after
/// the final owner releases its token.
@MainActor final class KeepAliveAudioSessionLeaseCoordinator {
    static let shared = KeepAliveAudioSessionLeaseCoordinator()

    private var owners = Set<UUID>()
    private let session = AVAudioSession.sharedInstance()

    private init() {}

    /// VideoCall's PiP-only route has no media lease. Keep the reference's
    /// inactive audio policy without overriding another adapter's owned session.
    func configurePiPOnlyIfUnowned() throws -> Bool {
        guard owners.isEmpty else { return false }
        try session.setActive(false, options: [.notifyOthersOnDeactivation])
        try session.setCategory(.soloAmbient, mode: .default)
        return true
    }

    func acquire() throws -> UUID {
        let token = UUID()
        if owners.isEmpty {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        }
        owners.insert(token)
        return token
    }

    func reactivateIfNeeded() throws {
        guard !owners.isEmpty else { return }
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try session.setActive(true)
    }

    func release(_ token: UUID?) {
        guard let token, owners.remove(token) != nil, owners.isEmpty else { return }
        do { try session.setActive(false, options: [.notifyOthersOnDeactivation]) }
        catch { /* A final release must not prevent the service from stopping. */ }
    }
}
