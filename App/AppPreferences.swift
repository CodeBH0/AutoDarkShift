import Combine
import Foundation

@MainActor
final class AppPreferences: ObservableObject {
    private static let developerModeKey = "developerModeEnabled"
    private let defaults: UserDefaults

    @Published var developerModeEnabled: Bool {
        didSet { defaults.set(developerModeEnabled, forKey: Self.developerModeKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.developerModeEnabled = defaults.bool(forKey: Self.developerModeKey)
    }
}
