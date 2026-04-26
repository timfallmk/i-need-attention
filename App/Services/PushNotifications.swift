import CloudKit
import Foundation
import UIKit
import UserNotifications
import os.log

/// Owns notification authorization + remote-notification handling. Registers as the
/// `UNUserNotificationCenterDelegate` so we can present alerts while the app is foregrounded.
@MainActor
final class PushNotifications: NSObject {
    static let shared = PushNotifications()
    private let log = Logger(subsystem: "com.example.attention", category: "Push")

    private override init() { super.init() }

    /// Called from app launch. Sets the delegate and registers for remote notifications.
    func configure() {
        UNUserNotificationCenter.current().delegate = self
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// Asks for permissions. `requestCritical` only takes effect if Apple has granted the
    /// critical-alert entitlement; otherwise the option is silently ignored by the system.
    @discardableResult
    func requestAuthorization(requestCritical: Bool) async -> Bool {
        var options: UNAuthorizationOptions = [.alert, .sound, .badge]
        if requestCritical {
            options.insert(.criticalAlert)
        }
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: options)
            return granted
        } catch {
            log.error("authorization request failed: \(error.localizedDescription)")
            return false
        }
    }

    func currentSettings() async -> UNNotificationSettings {
        await UNUserNotificationCenter.current().notificationSettings()
    }

    // MARK: - Remote notification routing

    /// Called from AppDelegate's didReceiveRemoteNotification. Returns the appropriate
    /// background fetch result for the system. Pulls the changed alert and forwards it
    /// to AppState.
    func handleRemoteNotification(
        _ userInfo: [AnyHashable: Any],
        appState: AppState
    ) async -> UIBackgroundFetchResult {
        guard let ckNotification = CKNotification(fromRemoteNotificationDictionary: userInfo) else {
            return .noData
        }

        guard let queryNotification = ckNotification as? CKQueryNotification,
              let recordID = queryNotification.recordID else {
            return .noData
        }

        do {
            let alert = try await CloudKitService.shared.fetchAlert(recordID: recordID)
            await appState.handleIncomingChange(alert)
            return .newData
        } catch {
            log.error("fetch alert failed: \(error.localizedDescription)")
            return .failed
        }
    }
}

extension PushNotifications: UNUserNotificationCenterDelegate {
    /// When the alert push arrives while the app is foregrounded, the user is already looking
    /// at the screen — show a banner and play sound but don't badge.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    /// User tapped the notification. Handed off to AppState which marks the alert as seen.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        Task { @MainActor in
            if let recordName = userInfo["recordName"] as? String {
                let recordID = CKRecord.ID(recordName: recordName)
                try? await CloudKitService.shared.markAlertSeen(recordID: recordID)
            }
            completionHandler()
        }
    }
}
