import Foundation

enum Constants {
    static let cloudKitContainerID = "iCloud.com.timfallmk.attention"

    enum RecordType {
        static let pair = "Pair"
        static let alert = "Alert"
        static let ack = "Ack"
    }

    enum PairField {
        static let pairKey = "pairKey"
        static let deviceA = "deviceA"
        static let deviceB = "deviceB"
        static let nameA = "nameA"
        static let nameB = "nameB"
    }

    enum AlertField {
        static let pairKey = "pairKey"
        static let senderDeviceID = "senderDeviceID"
        static let senderName = "senderName"
        static let message = "message"
        static let state = "state"
        static let seenAt = "seenAt"
        static let acknowledgedAt = "acknowledgedAt"
        static let ackEmoji = "ackEmoji"
        static let critical = "critical"
    }

    enum AlertState: String {
        case sent
        case seen
        case acknowledged
    }

    /// Companion record written by the receiver when acking an Alert. CloudKit's
    /// public-DB CKQuerySubscription rejects `firesOnRecordUpdate` combined with a
    /// mutable-content alert push — see CLAUDE.md — so we route the sender-side
    /// banner off `firesOnRecordCreation` of this record type instead. The Alert
    /// record itself still carries the canonical state for the in-app indicator.
    enum AckField {
        static let pairKey = "pairKey"
        /// Device that should receive the banner — i.e., the original Alert's
        /// `senderDeviceID`. Named "recipient" from the Ack's perspective so the
        /// subscription predicate reads naturally.
        static let recipientDeviceID = "recipientDeviceID"
        static let emoji = "emoji"
        static let alertRecordName = "alertRecordName"
    }

    enum SubscriptionID {
        static let incomingAlerts = "incoming-alerts-v1"
        static let outgoingStatus = "outgoing-status-v1"
        /// v2 changed record type from Alert (firesOnRecordUpdate) to Ack
        /// (firesOnRecordCreation) — the v1 form was rejected by CloudKit with
        /// BAD_REQUEST so no real device ever had v1 registered, but the bumped
        /// ID also avoids any chance of resurrecting a half-saved v1.
        static let outgoingAck = "outgoing-ack-v2"
        static let pairUpdates = "pair-updates-v1"
    }

    enum WatchMessage {
        static let kindKey = "kind"
        static let pressKind = "press"
        static let nameKey = "name"

        /// Phone → watch: a fresh `WatchSnapshot` (JSON-encoded) under `snapshotKey`.
        /// Sent both via `updateApplicationContext` (always, opportunistic delivery)
        /// and via `sendMessage` when reachable (live foreground updates).
        static let snapshotKind = "snapshot"
        static let snapshotKey = "snapshot"

        /// Watch → phone: acknowledge the latest incoming alert. `ackRecordNameKey`
        /// carries the CKRecord.ID.recordName so the phone can guard against acking
        /// a stale userInfo-queued message after a newer alert has replaced it.
        /// `ackEmojiKey` is optional — omitted means "Just acknowledge".
        static let ackKind = "ack"
        static let ackRecordNameKey = "recordName"
        static let ackEmojiKey = "emoji"

        /// Watch → phone: clear the outgoing alert pill (mirrors the iOS × button).
        /// `clearRecordNameKey` carries the CKRecord.ID.recordName of the outgoing
        /// alert being cleared so the phone can ignore stale transferUserInfo clears.
        static let clearKind = "clear"
        static let clearRecordNameKey = "clearRecordName"
    }

    enum AppGroup {
        static let identifier = "group.com.timfallmk.attention"
    }

    /// Identifiers for the inline notification actions ("pull down on banner" → ack with emoji).
    /// Used both when registering the UNNotificationCategory at launch and when interpreting
    /// the response in the notification delegate.
    enum NotificationAction {
        static let category = "ATTENTION_PING"
        /// Informational category for sender-side ack banners. No actions — tapping the
        /// banner just opens the app (default action). Kept distinct from `category` so
        /// the existing five ack actions don't appear on the sender's own ack banner.
        static let ackCategory = "ATTENTION_ACK"

        static let heart = "ack.heart"
        static let thumbs = "ack.thumbs"
        static let hug = "ack.hug"
        static let urgent = "ack.urgent"
        static let plain = "ack.plain"

        /// Maps an action identifier back to the emoji we'd persist on the alert. `plain`
        /// returns nil so the sender sees a generic ✅ instead of an emoji.
        static func emoji(for actionIdentifier: String) -> String? {
            switch actionIdentifier {
            case heart:  return "❤️"
            case thumbs: return "👍"
            case hug:    return "🤗"
            case urgent: return "🚨"
            default:     return nil
            }
        }

        static var allAckActionIdentifiers: Set<String> {
            [heart, thumbs, hug, urgent, plain]
        }
    }
}
