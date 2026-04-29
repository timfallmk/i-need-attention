import CloudKit
import UserNotifications

/// Runs on receipt of every CloudKit push routed through the extension. Two flavors:
///
///   - `incoming-alerts-v1`: a partner-sent "needs attention" — friendly title/body, ack
///     actions in the pull-down, time-sensitive (or critical) interruption level.
///   - `outgoing-ack-v1`: my partner just acked one of my alerts — informational banner
///     with the partner's name + their ack emoji, .active interruption level (no Focus
///     piercing for a confirmation).
///
/// Both flavors fetch the freshest record on the slow path so we don't ship stale
/// title/body when desiredKeys has been pruned by CloudKit's per-subscription payload cap.
final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttemptContent: UNMutableNotificationContent?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        let mutable = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        self.bestAttemptContent = mutable

        let userInfo = request.content.userInfo
        guard let ckNotification = CKNotification(fromRemoteNotificationDictionary: userInfo),
              let queryNotification = ckNotification as? CKQueryNotification,
              let recordID = queryNotification.recordID else {
            // Not a CloudKit query notification — pass through unmodified.
            contentHandler(mutable)
            return
        }

        let isAck = queryNotification.subscriptionID == Constants.SubscriptionID.outgoingAck
        if isAck {
            // Sender-side toggle: when off, deliver passively so the in-app indicator
            // still flips (the alert push still wakes didReceiveRemoteNotification) but
            // no banner pops and no sound plays.
            let bannersOn = SharedSettings.ackBannersEnabled
            mutable.interruptionLevel = bannersOn ? .active : .passive
            mutable.categoryIdentifier = Constants.NotificationAction.ackCategory
            mutable.sound = bannersOn
                ? (SharedSettings.customSoundEnabled
                    ? UNNotificationSound(named: UNNotificationSoundName("needs-attention.caf"))
                    : .default)
                : nil
            mutable.badge = nil
        } else {
            // Default to time-sensitive — pierces Focus, doesn't need Apple approval.
            mutable.interruptionLevel = .timeSensitive
            // Wire the inline ack actions (❤️ 👍 🤗 🚨 ✅) into the banner pull-down.
            mutable.categoryIdentifier = Constants.NotificationAction.category
            // Replaces the badge previously set via CKSubscription.NotificationInfo.shouldBadge,
            // which we dropped to stay under Production's "additional fields" limit. Absolute 1
            // (not an increment) is fine: any unread alert means "partner wants attention".
            mutable.badge = 1
        }

        // Fast path: read what we can from the desiredKeys payload, present immediately.
        applyContent(from: queryNotification, to: mutable, isAck: isAck)

        // Slow path: fetch full record to validate critical flag / pull ackEmoji, then deliver.
        let container = CKContainer(identifier: Constants.cloudKitContainerID)
        container.publicCloudDatabase.fetch(withRecordID: recordID) { [weak self] record, _ in
            guard let self else { return }
            if let record {
                self.apply(record: record, to: mutable, isAck: isAck)
            }
            contentHandler(mutable)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        if let contentHandler, let bestAttemptContent {
            contentHandler(bestAttemptContent)
        }
    }

    // MARK: - Helpers

    private func applyContent(from notification: CKQueryNotification, to content: UNMutableNotificationContent, isAck: Bool) {
        let fields = notification.recordFields ?? [:]
        let partnerName = SharedSettings.partnerName ?? "Partner"

        if isAck {
            let emoji = (fields[Constants.AlertField.ackEmoji] as? String)
            content.title = partnerName
            content.body = ackBody(emoji: emoji)
        } else {
            let senderName = (fields[Constants.AlertField.senderName] as? String) ?? partnerName
            let message = (fields[Constants.AlertField.message] as? String) ?? "needs attention"
            let senderRequestedCritical = (fields[Constants.AlertField.critical] as? Int ?? 0) == 1
            content.title = senderName
            content.body = message
            applyPriority(senderRequestedCritical: senderRequestedCritical, to: content)
        }

        if let recordID = notification.recordID {
            var ui = content.userInfo
            ui["recordName"] = recordID.recordName
            content.userInfo = ui
        }
    }

    private func apply(record: CKRecord, to content: UNMutableNotificationContent, isAck: Bool) {
        if isAck {
            let emoji = record[Constants.AlertField.ackEmoji] as? String
            content.title = SharedSettings.partnerName ?? "Partner"
            content.body = ackBody(emoji: emoji)
        } else {
            if let senderName = record[Constants.AlertField.senderName] as? String { content.title = senderName }
            if let message = record[Constants.AlertField.message] as? String { content.body = message }
            let senderRequestedCritical = (record[Constants.AlertField.critical] as? Int ?? 0) == 1
            applyPriority(senderRequestedCritical: senderRequestedCritical, to: content)
        }
        var ui = content.userInfo
        ui["recordName"] = record.recordID.recordName
        content.userInfo = ui
    }

    private func ackBody(emoji: String?) -> String {
        if let emoji, !emoji.isEmpty {
            return "Got back to you \(emoji)"
        }
        return "Got back to you"
    }

    /// Three-way decision: sender's per-send flag AND receiver's master toggle (read from
    /// the App Group) AND Apple's entitlement (enforced by the system, silently downgrades
    /// .critical to active if missing). We keep .timeSensitive as the floor for everything.
    ///
    /// Sound resolution: if the bundled custom sound is enabled in SharedSettings and the
    /// .caf is present, use it; otherwise fall back to the system default. UNNotificationSound
    /// is non-optional — a missing file silently plays nothing, so we gate explicitly via
    /// the user's setting rather than relying on a nil fallback.
    private func applyPriority(senderRequestedCritical: Bool, to content: UNMutableNotificationContent) {
        let receiverAccepts = SharedSettings.acceptCriticalAlerts
        if senderRequestedCritical && receiverAccepts {
            content.interruptionLevel = .critical
            content.sound = UNNotificationSound.defaultCriticalSound(withAudioVolume: 1.0)
        } else {
            content.interruptionLevel = .timeSensitive
            content.sound = SharedSettings.customSoundEnabled
                ? UNNotificationSound(named: UNNotificationSoundName("needs-attention.caf"))
                : UNNotificationSound.default
        }
    }
}
