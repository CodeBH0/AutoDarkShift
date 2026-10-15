import SwiftUI
import UserNotifications
import UIKit

final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        center.getNotificationSettings { settings in
            // Trial notifications must remain quiet even while the App is open.
            if settings.authorizationStatus == .provisional {
                completionHandler([.list])
                return
            }
            guard [.authorized, .ephemeral].contains(settings.authorizationStatus) else {
                completionHandler([])
                return
            }
            var options: UNNotificationPresentationOptions = []
            if settings.notificationCenterSetting == .enabled { options.insert(.list) }
            if settings.alertSetting == .enabled { options.insert(.banner) }
            if settings.soundSetting == .enabled { options.insert(.sound) }
            completionHandler(options)
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    private let notificationDelegate = NotificationDelegate()
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = notificationDelegate
        return true
    }
}

@main
struct AutoDarkShiftApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    var body: some Scene { WindowGroup { ControlView() } }
}
