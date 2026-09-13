import Foundation

enum Constants {
    static let cloudKitContainerID = "iCloud.com.timfallmk.attention"

    enum RecordType {
        static let pair = "Pair"
        static let alert = "Alert"
        /// Pre-2.0 only. Superseded by `alertStatus`, but `AttentionCLI` still speaks
        /// the old public-database protocol.
        static let ack = "Ack"
        /// One per person, written into the *partner's* inbox zone: it is how each side
        /// tells the other who they are. Closes the pairing handshake on first write and
        /// carries display-name changes after that.
        static let profile = "PairProfile"

        /// "I saw / acknowledged the alert you sent", written by the receiver into the
        /// *sender's* inbox zone. See `AlertStatusField` for why it exists at all.
        static let alertStatus = "AlertStatus"
    }

    /// The receiver's response to an alert, delivered as a record in the sender's own
    /// zone rather than as an update to the alert itself.
    ///
    /// The alert lives in the receiver's zone, so updating it in place tells the sender
    /// nothing: CloudKit allows only `CKDatabaseSubscription` in the shared database,
    /// and those notifications name a database rather than a record — an extension
    /// would have to run a full change-token fetch to discover what moved. A record in
    /// the sender's *own* zone is reachable by an ordinary private-database query
    /// subscription, which is the mechanism the spike verified delivers a visible push
    /// to a force-quit app.
    ///
    /// So the Alert record stays canonical — the receiver still updates it, and that is
    /// what history and reconciliation read — and this exists purely to be pushed.
    enum AlertStatusField {
        /// Ties the notice back to the Alert it answers.
        static let alertRecordName = "alertRecordName"
        /// `seen` or `acknowledged`. Queryable so the ack subscription can filter to the
        /// one that deserves a banner.
        static let state = "state"
        static let ackEmojiSealed = "ackEmojiSealed"

        /// Derived from the alert's record name so a retry replaces the previous notice
        /// instead of adding a second — one banner per alert however many times the
        /// receiver taps, retries, or has a push redelivered.
        static func recordName(for alertRecordName: String) -> String {
            "status-\(alertRecordName)"
        }
    }

    /// What one person tells their partner about themselves. The record lives in the
    /// partner's inbox zone — the one place this device can write and they can read —
    /// so it doubles as the channel that closes the pairing handshake: accepting the
    /// first share is what creates the write access this arrives on.
    enum Profile {
        /// Fixed, so a rename replaces the record rather than adding a second. One zone
        /// only ever has one partner writing into it.
        static let recordName = "profile"

        static let deviceID = "deviceID"

        /// Who this person is to CloudKit, rather than which of their devices wrote the
        /// record. Absent on profiles written before 2.2, which is what makes the whole
        /// migration additive: a pairing learns it the first time either side writes a
        /// profile under a build that has it, and falls back to `deviceID` until then.
        static let userID = "userID"

        /// Sealed like every other human-readable field. A display name in the clear
        /// beside encrypted alert contents would be a hole in the same wall.
        static let nameSealed = "nameSealed"

        /// Only set on the joiner's first write, where it carries the share of their own
        /// zone back to the inviter. Sealed too: it is not a bearer token — it names the
        /// inviter — but the storage provider has no more business reading it than the
        /// rest.
        static let shareURLSealed = "shareURLSealed"

        /// When this person finished archiving their pre-2.0 history, or absent if they
        /// haven't. Their partner reads it before deleting the shared public records:
        /// those records belong to the pair, not to whoever upgraded first, and deleting
        /// them on one device destroys the other's only copy.
        ///
        /// Plaintext, deliberately. It is a fact about the app's own migration, says
        /// nothing about the people using it, and the partner has to read it.
        static let legacyHistoryCapturedAt = "legacyHistoryCapturedAt"
    }

    enum PairField {
        static let pairKey = "pairKey"
        static let deviceA = "deviceA"
        static let deviceB = "deviceB"
        static let nameA = "nameA"
        static let nameB = "nameB"
    }

    enum AlertField {
        /// Pre-2.0 only. Zone membership is the boundary from 2.0, so new records don't
        /// carry it — but the history capture still parses records that do.
        static let pairKey = "pairKey"
        /// Per *install*, and that is exactly its limitation: one person can hold
        /// several devices on one Apple Account, so this answers "which phone" when
        /// every reader is really asking "which of us". Still written, still read as
        /// the fallback, because records from before `senderUserID` carry nothing else.
        static let senderDeviceID = "senderDeviceID"

        /// Per *account*: `CKContainer.userRecordID().recordName`. The identity the
        /// question "was this mine or theirs?" is actually about, and stable across
        /// every device a person signs in on.
        ///
        /// Not indexed. Zone membership is the filter and nothing queries the sender —
        /// the pre-2.0 design's `senderDeviceID` predicate is what the zone replaced.
        static let senderUserID = "senderUserID"

        static let state = "state"
        static let seenAt = "seenAt"
        static let acknowledgedAt = "acknowledgedAt"
        static let critical = "critical"

        /// Pre-2.0 plaintext. Still read, never written.
        static let senderName = "senderName"
        static let message = "message"
        static let ackEmoji = "ackEmoji"

        /// 2.0 ciphertext, sealed under a key derived from the pair key. Separate field
        /// names rather than a changed type on the old ones: CloudKit's schema is
        /// per-record-type across the whole container, so `senderName` is a String
        /// there for good, and the archived pre-2.0 records still need reading.
        static let senderNameSealed = "senderNameSealed"
        static let messageSealed = "messageSealed"
        static let ackEmojiSealed = "ackEmojiSealed"
    }

    enum AlertState: String {
        case sent
        case seen
        case acknowledged
    }

    /// **Pre-2.0 only.** The public-database ancestor of `AlertStatusField`, kept
    /// because `AttentionCLI` still speaks that protocol. The app writes `AlertStatus`
    /// records in private zones instead — same idea, different reason: this one existed
    /// because the public database rejects a mutable-content push on
    /// `firesOnRecordUpdate`, its replacement exists because the shared database has no
    /// usable subscription type at all.
    enum AckField {
        static let pairKey = "pairKey"
        /// Device that should receive the banner — i.e., the original Alert's
        /// `senderDeviceID`. Named "recipient" from the Ack's perspective so the
        /// subscription predicate reads naturally.
        static let recipientDeviceID = "recipientDeviceID"
        static let emoji = "emoji"
        static let alertRecordName = "alertRecordName"
    }

    /// All five are `CKQuerySubscription`s on this account's *own* inbox zone in the
    /// private database. Nothing subscribes to the partner's zone: the shared database
    /// accepts only `CKDatabaseSubscription`, whose notifications name a database
    /// rather than a record. Everything this device needs to be told about is therefore
    /// written into the zone it owns.
    enum SubscriptionID {
        /// v2 moved from the public database to the inbox zone.
        static let incomingAlerts = "incoming-alerts-v2"
        /// v2 changed record type from Alert to AlertStatus along with the move.
        static let outgoingStatus = "outgoing-status-v2"
        /// v3 is the same shape the public database rejected — firesOnRecordUpdate with
        /// a visible push — which private databases allow. The spike confirmed it
        /// renders a banner with the app force-quit.
        static let outgoingAck = "outgoing-ack-v3"
        /// Replaces pair-updates-v1. Drives two things: the last step of the pairing
        /// handshake, and a partner's rename.
        static let pairProfile = "pair-profile-v1"

        /// An alert *we received* becoming acknowledged, which on a single device is
        /// never news — this device did it — and on a second one is the only way to
        /// find out. `removeDeliveredNotifications` reaches only the notification centre
        /// of the process that calls it, so a banner on the iPad can be cleared by code
        /// running on the iPad and by nothing else. Without this, every device a person
        /// owns accumulates banners for alerts they have already answered.
        ///
        /// Silent, and distinct from `incomingAlerts` despite watching the same record
        /// type in the same zone: that one fires on creation only, so nothing today
        /// notices an Alert in our own zone changing state.
        static let incomingAnswered = "incoming-answered-v1"

        /// The ones this app owns. `registerSubscriptions` needs to tell them apart from
        /// anything else in the database so it can retire the ones left pointing at a
        /// previous pairing's zone without touching subscriptions it didn't create.
        static let all: Set<String> = [incomingAlerts, outgoingStatus, outgoingAck,
                                       pairProfile, incomingAnswered]
    }

    /// Keys the notification service extension puts into a rendered push's `userInfo`,
    /// and the app reads back out of a delivered or tapped notification.
    enum NotificationUserInfo {
        /// The `CKRecord.ID.recordName` of the alert a notification is about. Set by the
        /// NSE whenever it resolves the record; its absence means the NSE fell back to a
        /// generic body, which is worth telling apart from a notification about nothing.
        static let recordName = "recordName"
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

        /// Watch → phone: snooze (or, with `snoozeMinutesKey` == 0, cancel the snooze on)
        /// the latest incoming alert. `snoozeRecordNameKey` guards against a stale
        /// userInfo-queued message the same way `ackRecordNameKey` does.
        static let snoozeKind = "snooze"
        static let snoozeRecordNameKey = "snoozeRecordName"
        static let snoozeMinutesKey = "snoozeMinutes"
    }

    enum AppGroup {
        static let identifier = "group.com.timfallmk.attention"
    }

    /// Keychain item coordinates for the pair key. The access group is the App Group
    /// identifier (see `KeychainPairSecretStore`), so the app and the NSE address the
    /// same item without a `keychain-access-groups` entitlement.
    enum Keychain {
        static let service = "com.timfallmk.attention.pairKey"

        /// Account holding the key of the completed pairing.
        static let pairKeyAccount = "pair"
        /// Account holding the key of an invite that hasn't been accepted yet. Kept
        /// separate so cancelling an invite can't disturb a live pairing.
        static let pendingInviteKeyAccount = "pendingInvite"

        /// Account holding the *pre-2.0* pair key, kept only until the one-shot
        /// history capture succeeds. Separate from `pairKeyAccount` because the
        /// capture has to outlive the re-pair that replaces the live key.
        static let legacyHistoryKeyAccount = "legacyHistoryPairKey"
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

        /// Defer an incoming alert and re-surface it locally after a delay. Distinct from
        /// the ack actions — it does not acknowledge, so it never appears in
        /// `allAckActionIdentifiers` or `emoji(for:)`.
        static let snooze = "action.snooze"
        /// Interval for the one-tap notification-action snooze (the in-app / watch sheet
        /// offers finer choices). Local re-notification only — no server involvement.
        static let defaultSnoozeMinutes = 15

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
