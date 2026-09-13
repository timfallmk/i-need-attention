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

    /// Set once the UI exists, so `willPresent` can apply a status the app is already
    /// on screen for. Weak because AppState outlives nothing here and this is a
    /// singleton — a strong reference would pin one AppState for the process lifetime.
    /// `handleRemoteNotification` still takes its AppState as a parameter: the delegate
    /// callbacks that have one to hand should keep passing it.
    weak var appState: AppState?

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
            log.error("Remote notification wasn't a CKNotification")
            return .noData
        }

        guard let queryNotification = ckNotification as? CKQueryNotification,
              let recordID = queryNotification.recordID else {
            log.error("CKNotification carried no query record ID (subscription \(ckNotification.subscriptionID ?? "nil", privacy: .public))")
            return .noData
        }
        log.notice("Push received for subscription \(queryNotification.subscriptionID ?? "nil", privacy: .public)")

        // Checked before any branch dispatches, including the profile one. Subscription
        // IDs are account-wide constants while the zone is per pairing, so a stale or
        // queued subscription can deliver a record from a zone this device no longer
        // uses — which would otherwise render a foreign alert, mark it seen, or clear the
        // wrong banner. The profile branch sat above this check until now and so bypassed
        // it entirely: a queued `pair-profile-v1` push from a previous pairing's zone
        // reached `reconcileHalfFormedPair` and `refreshPartnerProfile`, which is a push
        // from a pairing that has ended steering the one that replaced it.
        //
        // Fails open on a missing name, like the extension's copy of this rule: no stored
        // zone is "no opinion, carry on" rather than "reject", because refusing on absent
        // local state would turn a first-launch race into a missed alert.
        if let mine = InboxZone.storedName, recordID.zoneID.zoneName != mine {
            let zone = recordID.zoneID.zoneName
            log.error("Push for unexpected zone \(zone, privacy: .public); ignoring")
            return .noData
        }

        if queryNotification.subscriptionID == Constants.SubscriptionID.pairProfile {
            // The partner introducing themselves — which closes the handshake — or
            // renaming themselves. Both land on the same record; which one it is depends
            // only on whether we're paired yet, and all three calls self-guard.
            //
            // reconcilePendingInvite is the inviter's half (it guards on `pair == nil`);
            // the joiner's half is reconcileHalfFormedPair, which is how the joiner
            // learns the inviter accepted its share. Leaving it out left the joiner's
            // one-way banner up until something else foregrounded the app.
            await appState.reconcilePendingInvite()
            await appState.reconcileHalfFormedPair()
            await appState.refreshPartnerProfile()
            return .newData
        }

        guard let pair = appState.pair else {
            log.error("Push arrived with no pairing loaded")
            return .noData
        }

        if queryNotification.subscriptionID == Constants.SubscriptionID.outgoingStatus
            || queryNotification.subscriptionID == Constants.SubscriptionID.outgoingAck {
            // A status notice about an alert *we* sent. The notice names the alert; the
            // alert itself still lives in the partner's zone and stays canonical.
            guard let notice = await CloudKitService.shared.fetchStatusNotice(recordID: recordID, pair: pair) else {
                log.error("Status notice \(recordID.recordName, privacy: .public) could not be read")
                return .noData
            }
            await appState.applyOutgoingStatus(alertRecordName: notice.alertRecordName,
                                               state: notice.state,
                                               emoji: notice.emoji)
            return .newData
        }

        if queryNotification.subscriptionID == Constants.SubscriptionID.incomingAnswered {
            // An alert *sent to us* has been acknowledged, which this device may or may
            // not have been the one to do. Either way the job is the same and idempotent.
            do {
                let alert = try await CloudKitService.shared.fetchAlert(recordID: recordID, pair: pair)
                await appState.handleAnsweredElsewhere(alert)
                return .newData
            } catch {
                log.error("fetch answered alert failed: \(error.localizedDescription)")
                return .failed
            }
        }

        do {
            let alert = try await CloudKitService.shared.fetchAlert(recordID: recordID, pair: pair)
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
            // Suppressing the banner is right — StatusIndicatorView is already showing
            // this — but discarding the notification was not. The pill's other route is
            // the silent `outgoing-status-v2` push, and iOS budgets content-available
            // delivery: it may delay, coalesce or drop it, on hardware as much as
            // anywhere. This push is visible, carries the same CloudKit payload (the NSE
            // merges its keys rather than replacing them), and is not throttled — so
            // applying it here makes the foreground pill depend on the delivery iOS
            // actually guarantees, and leaves the silent push as the redundant half.
            //
            // Not awaited: the completion handler decides how to present a banner we
            // have already decided not to show, and holding it open for a CloudKit
            // fetch would delay nothing useful.
            let userInfo = notification.request.content.userInfo
            Task { @MainActor in
                guard let appState = self.appState else { return }
                _ = await self.handleRemoteNotification(userInfo, appState: appState)
            }
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

        // Unconditional, and the first thing this does. A notification response on a
        // force-quit app is handled by a background launch with no debugger attached, so
        // this line in Console.app is the only evidence that the delegate was installed
        // in time and iOS found someone to deliver to. Its absence and a failure inside
        // look identical from the outside, and they are completely different bugs.
        log.notice("Notification response: action=\(actionID, privacy: .public) category=\(categoryID, privacy: .public)")

        guard let recordName = userInfo[Constants.NotificationUserInfo.recordName] as? String else {
            // The NSE sets this whenever it resolves the record. Missing means it fell
            // back to the generic body — worth knowing, since the banner still looked
            // almost right.
            let keys = userInfo.keys.map(String.init(describing:)).joined(separator: ",")
            log.error("Notification response carried no recordName; userInfo keys: \(keys, privacy: .public)")
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
                // Carried through from the banner being snoozed, so the reminder's own
                // Acknowledge can still be matched to the zone the alert lives in.
                zoneName: userInfo[Constants.NotificationUserInfo.zoneName] as? String,
                title: content.title,
                body: content.body,
                until: until
            )
            SnoozeState(recordName: recordName, until: until).save()
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [notificationID])
            completionHandler()
            return
        }

        // Inline ack actions only ever apply to an incoming alert, which lives in the
        // zone this device owns — but *which* zone it owned is the question, because a
        // delivered banner outlives its pairing. It sits on the lock screen until somebody
        // touches it, and by then the account may have re-paired into a different zone.
        //
        // Rebuilding the ID against whatever zone is current is how an ack on a stale
        // banner writes an `AlertStatus` into the *new* partner's zone, about an alert
        // they never sent — a cross-pairing write, which is the whole thing per-pairing
        // zones exist to prevent. `CloudKitService.inboxZoneID` would also *mint* a zone
        // by way of `currentName` on a device that has none, outside a pairing start.
        //
        // So the notification carries the zone it was built for, and it has to still be
        // ours. A banner from before this change has no zone to check and is not worth
        // guessing about: the alert it names is in a zone that pairing has since left.
        guard let banner = userInfo[Constants.NotificationUserInfo.zoneName] as? String,
              let mine = InboxZone.storedName, banner == mine else {
            log.notice("Ack action for a notification from another pairing's zone; ignoring")
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [notificationID])
            completionHandler()
            return
        }
        let recordID = CKRecord.ID(recordName: recordName, zoneID: CloudKitService.zoneID(named: mine))
        Task { @MainActor in
            defer { completionHandler() }
            // The delegate is nonisolated and holds no AppState; the persisted pairing
            // is the same source AppState itself loads from. Logged rather than returned
            // silently: this runs on a background launch where nothing else would notice,
            // and a keychain that isn't readable yet looks identical to a working ack.
            guard let pair = PairState.load() else {
                self.log.error("Notification response for \(recordName, privacy: .public) but no pairing is readable")
                return
            }
            if Constants.NotificationAction.allAckActionIdentifiers.contains(actionID) {
                let emoji = Constants.NotificationAction.emoji(for: actionID)
                do {
                    _ = try await CloudKitService.shared.acknowledgeAlert(recordID: recordID, emoji: emoji, pair: pair)
                    // Mirrors AppState.acknowledgeIncoming: the NSE-set badge persists until ack,
                    // and inline ack from the banner is still an ack.
                    try? await UNUserNotificationCenter.current().setBadgeCount(0)
                    UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [notificationID])
                } catch {
                    self.log.error("Failed to acknowledge alert \(recordName, privacy: .public): \(String(describing: error), privacy: .public)")
                }
            } else if actionID == UNNotificationDefaultActionIdentifier {
                _ = try? await CloudKitService.shared.markAlertSeen(recordID: recordID, pair: pair)
            }
            // UNNotificationDismissActionIdentifier and anything else: no-op.
        }
    }
}
