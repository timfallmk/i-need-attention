import CloudKit
import UserNotifications

/// Runs on receipt of every CloudKit push for incoming alerts. We use it to:
///   1. Fetch the freshest version of the Alert record (in case the desiredKeys missed something)
///   2. Set a friendly title/body using the sender's name
///   3. Upgrade interruptionLevel to .critical (if sender requested + receiver granted entitlement)
///      or .timeSensitive otherwise — so the alert always breaks through Focus.
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

        // Default to time-sensitive — pierces Focus, doesn't need Apple approval.
        mutable.interruptionLevel = .timeSensitive

        let userInfo = request.content.userInfo
        guard let ckNotification = CKNotification(fromRemoteNotificationDictionary: userInfo),
              let queryNotification = ckNotification as? CKQueryNotification,
              let recordID = queryNotification.recordID else {
            // Not a CloudKit query notification — pass through unmodified.
            contentHandler(mutable)
            return
        }

        // Fast path: read what we can from the desiredKeys payload, present immediately.
        applyContent(from: queryNotification, to: mutable)

        // Slow path: fetch full record to validate critical flag etc., then deliver.
        let container = CKContainer(identifier: "iCloud.com.example.attention")
        container.publicCloudDatabase.fetch(withRecordID: recordID) { [weak self] record, _ in
            guard let self else { return }
            if let record {
                self.apply(record: record, to: mutable)
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

    private func applyContent(from notification: CKQueryNotification, to content: UNMutableNotificationContent) {
        let fields = notification.recordFields ?? [:]
        let senderName = (fields["senderName"] as? String) ?? "Someone"
        let message = (fields["message"] as? String) ?? "needs attention"
        let critical = (fields["critical"] as? Int ?? 0) == 1

        content.title = senderName
        content.body = message
        if critical {
            content.interruptionLevel = .critical
            content.sound = UNNotificationSound.defaultCriticalSound(withAudioVolume: 1.0)
        }

        if let recordID = notification.recordID {
            var ui = content.userInfo
            ui["recordName"] = recordID.recordName
            content.userInfo = ui
        }
    }

    private func apply(record: CKRecord, to content: UNMutableNotificationContent) {
        if let senderName = record["senderName"] as? String { content.title = senderName }
        if let message = record["message"] as? String { content.body = message }
        let critical = (record["critical"] as? Int ?? 0) == 1
        if critical {
            content.interruptionLevel = .critical
            content.sound = UNNotificationSound.defaultCriticalSound(withAudioVolume: 1.0)
        } else {
            content.sound = UNNotificationSound(named: UNNotificationSoundName("needs-attention.caf"))
                ?? UNNotificationSound.default
        }
        var ui = content.userInfo
        ui["recordName"] = record.recordID.recordName
        content.userInfo = ui
    }
}
