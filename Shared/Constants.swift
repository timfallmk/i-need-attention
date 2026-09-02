import Foundation

enum Constants {
    static let cloudKitContainerID = "iCloud.com.timfallmk.attention"

    enum RecordType {
        static let pair = "Pair"
        static let alert = "Alert"
        static let ack = "Ack"
        /// One per person, written into the *partner's* inbox zone: it is how each side
        /// tells the other who they are. Closes the pairing handshake on first write and
        /// carries display-name changes after that.
        static let profile = "PairProfile"
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

        /// Sealed like every other human-readable field. A display name in the clear
        /// beside encrypted alert contents would be a hole in the same wall.
        static let nameSealed = "nameSealed"

        /// Only set on the joiner's first write, where it carries the share of their own
        /// zone back to the inviter. Sealed too: it is not a bearer token — it names the
        /// inviter — but the storage provider has no more business reading it than the
        /// rest.
        static let shareURLSealed = "shareURLSealed"
    }

    /// Record zones. From 2.0 each user owns one zone — their *inbox* — which their
    /// partner writes into as a share participant. The receiver therefore subscribes to
    /// their own private database rather than to a shared one, and neither user owns
    /// "the pair": deleting your own zone ends only the direction you receive.
    enum Zone {
        static let inbox = "attention-inbox-v1"
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
