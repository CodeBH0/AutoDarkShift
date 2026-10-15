import UserNotifications

@MainActor final class NotificationAuthorizationService {
    private let center: UNUserNotificationCenter
    private var initialRequest: Task<Void, Error>?

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    /// Only an undecided installation gets the quiet, nonprompting trial request.
    /// Errors propagate to the caller; never fall back to an explicit prompt.
    func requestInitialAuthorizationIfNeeded() async throws {
        if let initialRequest { return try await initialRequest.value }
        let request = Task { @MainActor in
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .notDetermined else { return }
            _ = try await center.requestAuthorization(options: [.alert, .sound, .badge, .provisional])
        }
        initialRequest = request
        defer { initialRequest = nil }
        try await request.value
    }

    /// Call only in response to the user's explicit authorization action.
    func requestAuthorization() async throws -> Bool {
        if let initialRequest { _ = try? await initialRequest.value }
        return try await center.requestAuthorization(options: [.alert, .sound, .badge])
    }
}
