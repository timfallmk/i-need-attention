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
    private let log = Logger(subsystem: "com.timfallmk.attention", category: "Push")

    private override init() { super.init() }

    /// Called from app launch. Sets the delegate, registers the notification categories
    /// (the ping category with the five inline ack actions, plus the no-action ack
    /// category for sender-side acknowledgement banners), and registers for remote
    /// notifications.
    func configure() {
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().setNotificationCategories([
            Self.attentionPingCategory,
            Self.attentionAckCategory
        ])
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// One category, five actions. All run in the background (no `.foreground` option) so
    /// tapping an action acks instantly without the app coming to the front.
    private static var attentionPingCategory: UNNotificationCategory {
        let actions: [UNNotificationAction] = [
            UNNotificationAction(
                identifier: Constants.NotificationAction.heart,
                title: "❤️", options: []
            ),
            UNNotificationAction(
                identifier: Constants.NotificationAction.thumbs,
                title: "👍", options: []
            ),
            UNNotificationAction(
                identifier: Constants.NotificationAction.hug,
                title: "🤗", options: []
            ),
            UNNotificationAction(
                identifier: Constants.NotificationAction.urgent,
                title: "🚨 OMW", options: []
            ),
            UNNotificationAction(
                identifier: Constants.NotificationAction.plain,
                title: "Acknowledge", options: []
            ),
            UNNotificationAction(
                identifier: Constants.NotificationAction.snooze,
                title: "⏰ Remind me in \(Constants.NotificationAction.defaultSnoozeMinutes)m",
                options: []
            )
        ]
        return UNNotificationCategory(
            identifier: Constants.NotificationAction.category,
            actions: actions,
            intentIdentifiers: [],
            options: []
        )
    }

    /// No actions: an ack banner is informational. Tapping it opens the app via the
    /// default action; the response handler distinguishes ack-category notifications and
    /// skips the markAlertSeen path that applies to incoming alerts.
    private static var attentionAckCategory: UNNotificationCategory {
        UNNotificationCategory(
            identifier: Constants.NotificationAction.ackCategory,
            actions: [],
            intentIdentifiers: [],
            options: []
        )
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
    /// background fetch result for the system. Routes Alert subscription pushes to the
    /// alert handler and Pair subscription pushes to the pair refresher.
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

        if queryNotification.subscriptionID == Constants.SubscriptionID.pairUpdates {
            if appState.pair == nil {
                // Unpaired but subscribed = a pending remote invite; this push is the
                // joiner filling their slot. Complete the pairing.
                await appState.reconcilePendingInvite()
            } else {
                await appState.refreshPairFromCloud()
            }
            return .newData
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
    /// at the screen — show a banner and play sound but don't badge. For sender-side ack
    /// banners (`ATTENTION_ACK`), `StatusIndicatorView` already shows the same emoji, so
    /// suppress the banner entirely to avoid stacking duplicate UI on top of itself.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        if notification.request.content.categoryIdentifier == Constants.NotificationAction.ackCategory {
            completionHandler([])
            return
        }
        completionHandler([.banner, .sound, .list])
    }

    /// Three response paths:
    ///   - User tapped the banner (`defaultActionIdentifier`): mark seen.
    ///   - User pulled down and tapped one of our ack actions: mark acknowledged with
    ///     the matching emoji (or no emoji for the plain "Acknowledge" action).
    ///   - User dismissed the banner: do nothing.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let actionID = response.actionIdentifier
        let categoryID = response.notification.request.content.categoryIdentifier

        guard let recordName = userInfo["recordName"] as? String else {
            completionHandler()
            return
        }

        let notificationID = response.notification.request.identifier

        // Sender-side ack banner: tapping it just opens the app. Do NOT call markAlertSeen
        // — recordName here is the sender's own outgoing alert, and "seen" would overwrite
        // the acknowledged state.
        if categoryID == Constants.NotificationAction.ackCategory {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [notificationID])
            completionHandler()
            return
        }

        // Snooze from the banner: schedule a local re-notification and persist the state,
        // all without CloudKit or AppState (which may not exist in the background — the app
        // reconciles the persisted SnoozeState on next foreground). Title/body are copied
        // from the delivered notification, so the reminder reads identically.
        if actionID == Constants.NotificationAction.snooze {
            let minutes = Constants.NotificationAction.defaultSnoozeMinutes
            let until = Date().addingTimeInterval(TimeInterval(minutes * 60))
            let content = response.notification.request.content
            LocalNotifications.scheduleSnooze(
                recordName: recordName,
                title: content.title,
                body: content.body,
                until: until
            )
            SnoozeState(recordName: recordName, until: until).save()
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [notificationID])
            completionHandler()
            return
        }

        let recordID = CKRecord.ID(recordName: recordName)
        Task { @MainActor in
            defer { completionHandler() }
            if Constants.NotificationAction.allAckActionIdentifiers.contains(actionID) {
                let emoji = Constants.NotificationAction.emoji(for: actionID)
                do {
                    _ = try await CloudKitService.shared.acknowledgeAlert(recordID: recordID, emoji: emoji)
                    // Mirrors AppState.acknowledgeIncoming: the NSE-set badge persists until ack,
                    // and inline ack from the banner is still an ack.
                    try? await UNUserNotificationCenter.current().setBadgeCount(0)
                    UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [notificationID])
                } catch {
                    self.log.error("Failed to acknowledge alert \(recordName, privacy: .public): \(String(describing: error), privacy: .public)")
                }
            } else if actionID == UNNotificationDefaultActionIdentifier {
                _ = try? await CloudKitService.shared.markAlertSeen(recordID: recordID)
            }
            // UNNotificationDismissActionIdentifier and anything else: no-op.
        }
    }
}
