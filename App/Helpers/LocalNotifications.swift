import Foundation
import UserNotifications

/// Schedules and cancels the local "remind me later" re-notification for snooze (#49).
///
/// This is the only place the app schedules its *own* notifications — everything else
/// arrives as a CloudKit push rendered by the NSE. The re-notification is built to look and
/// behave like the original incoming alert: same `ATTENTION_PING` category (so the inline ack
/// actions work), same `recordName` in userInfo, and the same priority/sound the NSE would
/// apply, mirrored from `SharedSettings`.
enum LocalNotifications {
    /// Deterministic per-alert identifier so a snooze can be cancelled or replaced precisely.
    static func identifier(for recordName: String) -> String {
        "snooze-\(recordName)"
    }

    static func scheduleSnooze(recordName: String, title: String, body: String, until: Date) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = Constants.NotificationAction.category
        content.userInfo = [Constants.NotificationUserInfo.recordName: recordName]
        content.badge = 1
        // Mirror NotificationService.applyPriority (the critical path is disabled — Apple
        // denied the entitlement — so only the time-sensitive branch is relevant here).
        content.interruptionLevel = SharedSettings.timeSensitiveEnabled ? .timeSensitive : .active
        content.sound = SharedSettings.customSoundEnabled
            ? UNNotificationSound(named: UNNotificationSoundName("needs-attention.caf"))
            : UNNotificationSound.default

        // Guard the minimum: UNTimeIntervalNotificationTrigger requires > 0.
        let interval = max(1, until.timeIntervalSinceNow)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let request = UNNotificationRequest(
            identifier: identifier(for: recordName),
            content: content,
            trigger: trigger
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// Cancels a scheduled snooze and clears any already-delivered copy of it.
    static func cancelSnooze(recordName: String) {
        let id = identifier(for: recordName)
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [id])
        center.removeDeliveredNotifications(withIdentifiers: [id])
    }

    /// Clears any delivered notification for an alert, matched by its `recordName` in
    /// userInfo — the CloudKit-push banner's identifier is APNs-assigned, not the recordName,
    /// so it can't be removed by a known id.
    ///
    /// Two callers: snoozing, which dismisses the banner it replaces, and an alert
    /// answered on another of this person's devices, which is the only way that device
    /// can reach this one's notification centre.
    /// Clears every delivered alert banner, for the case where the record names are not
    /// worth enumerating because all of them are stale: the caller has established that
    /// the newest incoming alert is answered or gone, so nothing behind it is waiting.
    ///
    /// Scoped by category so it takes only this app's alert banners — the sender-side
    /// "they got back to you" notices use a different one and are swept separately.
    static func removeDeliveredAlerts() async {
        let center = UNUserNotificationCenter.current()
        let delivered = await center.deliveredNotifications()
        let ids = delivered
            .filter { $0.request.content.categoryIdentifier == Constants.NotificationAction.category }
            .map(\.request.identifier)
        guard !ids.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }

    static func removeDelivered(matchingRecordName recordName: String) async {
        let center = UNUserNotificationCenter.current()
        let delivered = await center.deliveredNotifications()
        let ids = delivered
            .filter { ($0.request.content.userInfo[Constants.NotificationUserInfo.recordName] as? String) == recordName }
            .map(\.request.identifier)
        guard !ids.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }
}
