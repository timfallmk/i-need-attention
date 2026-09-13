import CloudKit
import UserNotifications

/// Runs on receipt of every CloudKit push routed through the extension. Two flavors,
/// both arriving on a subscription to this device's *own* inbox zone in the private
/// database:
///
///   - `incoming-alerts-v2`: the partner wrote an Alert into our zone — friendly
///     title/body, ack actions in the pull-down, time-sensitive (or critical)
///     interruption level.
///   - `outgoing-ack-v3`: the partner left an AlertStatus saying they acknowledged
///     something we sent — informational banner with their name and emoji. Interruption
///     level is `.timeSensitive` when `SharedSettings.timeSensitiveEnabled` is on,
///     `.active` otherwise; downgraded to `.passive` when ack banners are disabled.
///
/// Both fetch the record rather than reading the push payload. The fields worth showing
/// are ciphertext from 2.0, so the subscriptions carry no `desiredKeys` — there is
/// nothing useful to put in a payload CloudKit may truncate anyway.
///
/// Decryption needs the pair key, which this process reaches through the App Group
/// keychain (`PairSecrets.store`). Without it the extension still delivers a banner,
/// just an anonymous one: a push that arrives before the first unlock after a reboot
/// must not turn into silence.
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

        // Before anything is fetched or decrypted. Every subscription this app owns is on
        // the zone this account uses, so a push naming a different one is from a stale or
        // queued subscription — a previous pairing's, or a rival zone on a pre-2.2
        // account.
        //
        // **This suppresses the contents, not the notification.** A service extension has
        // to call `contentHandler`, and whatever it passes is what displays; there is no
        // way to drop an alert push from here. So a foreign-zone push still shows the
        // subscription's static placeholder body. What it cannot do is name the other
        // pairing's partner or carry their message, because returning here is what stops
        // the record ever being fetched or opened — and the pair key would not open it
        // anyway. A generic banner from a pairing that has ended is untidy; the partner's
        // name and words on the lock screen would be the actual leak, and that is the one
        // this closes.
        //
        // A nil setting is "no opinion" rather than "no zone": refusing on missing local
        // state would turn a first-launch race into a missed alert, which is the one
        // outcome this app cannot have.
        if let active = SharedSettings.inboxZoneName,
           recordID.zoneID.zoneName != active {
            contentHandler(mutable)
            return
        }

        let isAck = queryNotification.subscriptionID == Constants.SubscriptionID.outgoingAck
        let timeSensitive = SharedSettings.timeSensitiveEnabled
        if isAck {
            // Sender-side toggle: when off, deliver passively so the in-app indicator
            // still flips (the alert push still wakes didReceiveRemoteNotification) but
            // no banner pops and no sound plays.
            let bannersOn = SharedSettings.ackBannersEnabled
            mutable.interruptionLevel = bannersOn ? (timeSensitive ? .timeSensitive : .active) : .passive
            mutable.categoryIdentifier = Constants.NotificationAction.ackCategory
            mutable.sound = bannersOn
                ? (SharedSettings.customSoundEnabled
                    ? UNNotificationSound(named: UNNotificationSoundName("needs-attention.caf"))
                    : .default)
                : nil
            mutable.badge = nil
        } else {
            // applyPriority below upgrades to .critical when sender-flagged + receiver-
            // accepts + entitlement granted, otherwise honors the user's time-sensitive toggle.
            mutable.interruptionLevel = timeSensitive ? .timeSensitive : .active
            // Wire the inline ack actions (❤️ 👍 🤗 🚨 ✅) into the banner pull-down.
            mutable.categoryIdentifier = Constants.NotificationAction.category
            // Replaces the badge previously set via CKSubscription.NotificationInfo.shouldBadge,
            // which we dropped to stay under Production's "additional fields" limit. Absolute 1
            // (not an increment) is fine: any unread alert means "partner wants attention".
            mutable.badge = 1
        }

        // Something readable up front, in case the fetch is slow or fails outright.
        applyFallbackContent(to: mutable, isAck: isAck)

        let pairKey = PairSecrets.store.secret(for: Constants.Keychain.pairKeyAccount)
        let container = CKContainer(identifier: Constants.cloudKitContainerID)
        container.privateCloudDatabase.fetch(withRecordID: recordID) { [weak self] record, _ in
            guard let self else { return }
            if let record {
                self.apply(record: record, to: mutable, isAck: isAck, pairKey: pairKey)
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

    /// What the banner says before the record arrives. The partner's name is cached in
    /// the App Group, so this is not as bare as it looks — and it is what ships if the
    /// fetch fails, which for this app is much better than nothing.
    private func applyFallbackContent(to content: UNMutableNotificationContent, isAck: Bool) {
        let partnerName = UntrustedText.name(SharedSettings.partnerName, fallback: "Partner")
        content.title = partnerName
        content.body = isAck ? ackBody(emoji: nil) : "needs attention"
    }

    private func apply(record: CKRecord, to content: UNMutableNotificationContent, isAck: Bool, pairKey: String?) {
        let partnerName = UntrustedText.name(SharedSettings.partnerName, fallback: "Partner")

        if isAck {
            content.title = partnerName
            content.body = ackBody(emoji: opened(record, Constants.AlertStatusField.ackEmojiSealed, pairKey))
            // The notice names the alert it answers; the ack actions apply to that
            // record, not to this one.
            if let alertRecordName = record[Constants.AlertStatusField.alertRecordName] as? String {
                var ui = content.userInfo
                ui[Constants.NotificationUserInfo.recordName] = alertRecordName
                ui[Constants.NotificationUserInfo.zoneName] = record.recordID.zoneID.zoneName
                content.userInfo = ui
            }
            return
        }

        content.title = UntrustedText.name(opened(record, Constants.AlertField.senderNameSealed, pairKey),
                                           fallback: partnerName)
        content.body = UntrustedText.message(opened(record, Constants.AlertField.messageSealed, pairKey),
                                             fallback: "needs attention")
        let senderRequestedCritical = (record[Constants.AlertField.critical] as? Int ?? 0) == 1
        applyPriority(senderRequestedCritical: senderRequestedCritical, to: content)

        var ui = content.userInfo
        ui[Constants.NotificationUserInfo.recordName] = record.recordID.recordName
        ui[Constants.NotificationUserInfo.zoneName] = record.recordID.zoneID.zoneName
        content.userInfo = ui
    }

    /// Nil when the key isn't reachable — before the first unlock after a reboot, say.
    /// The caller falls back to the partner's cached name and a generic body rather than
    /// dropping a push it can't fully read.
    private func opened(_ record: CKRecord, _ field: String, _ pairKey: String?) -> String? {
        guard let pairKey, let sealed = record[field] as? Data else { return nil }
        return PairCrypto.opened(sealed, pairKey: pairKey, field: field)
    }

    /// Sanitizes here rather than at the call sites so the fallback body and the decrypted
    /// one cannot drift apart.
    private func ackBody(emoji: String?) -> String {
        if let emoji = UntrustedText.emoji(emoji) {
            return "Got back to you \(emoji)"
        }
        return "Got back to you"
    }

    /// Three-way decision for incoming alerts: sender's per-send flag AND receiver's
    /// critical-accepts toggle AND Apple's entitlement (enforced by the system, silently
    /// downgrades .critical to active if missing). When critical doesn't apply, the
    /// receiver's master `timeSensitiveEnabled` toggle decides between `.timeSensitive`
    /// (default) and `.active`.
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
            content.interruptionLevel = SharedSettings.timeSensitiveEnabled ? .timeSensitive : .active
            content.sound = SharedSettings.customSoundEnabled
                ? UNNotificationSound(named: UNNotificationSoundName("needs-attention.caf"))
                : UNNotificationSound.default
        }
    }
}
