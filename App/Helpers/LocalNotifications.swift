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

    /// `zoneName` carries the alert's zone through to the reminder, and is not optional
    /// decoration: the reminder reuses `ATTENTION_PING`, so its Acknowledge action lands
    /// in the same handler as a real banner — and that handler now requires the zone,
    /// because an ack rebuilt against the wrong one writes into the next pairing. Without
    /// it a snoozed alert could be re-notified and then refuse to be acknowledged.
    static func scheduleSnooze(recordName: String,
                               zoneName: String?,
                               title: String,
                               body: String,
                               until: Date) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = Constants.NotificationAction.category
        var info: [String: Any] = [Constants.NotificationUserInfo.recordName: recordName]
        if let zoneName { info[Constants.NotificationUserInfo.zoneName] = zoneName }
        content.userInfo = info
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
