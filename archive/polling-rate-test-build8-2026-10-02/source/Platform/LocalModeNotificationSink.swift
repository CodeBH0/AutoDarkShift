import Foundation
import UserNotifications

@MainActor final class LocalModeNotificationSink: ModeNotificationSubmitting {
    func authorization(_ completion: @escaping (Bool, String) -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let allowed = [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus)
            let detail = String(settings.authorizationStatus.rawValue)
            Task { @MainActor in completion(allowed, detail) }
        }
    }

    func submit(_ candidate: NotificationCandidate, source: SampleSource,
                completion: @escaping (Error?) -> Void) {
        let content = UNMutableNotificationContent()
        content.title = "AutoDarkShift.Mode"
        content.subtitle = candidate.target.rawValue
        let brightness = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), candidate.brightness)
        content.body = "mode=\(candidate.target.rawValue);brightness=\(brightness);source=\(source.rawValue)"
        content.sound = .default
        let request = UNNotificationRequest(identifier: "AutoDarkShift.Mode.\(candidate.id.uuidString)",
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            Task { @MainActor in completion(error) }
        }
    }
}
