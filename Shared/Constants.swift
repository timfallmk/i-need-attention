import Foundation

enum Constants {
    static let cloudKitContainerID = "iCloud.com.timfallmk.attention"

    enum RecordType {
        static let pair = "Pair"
        static let alert = "Alert"
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

    enum SubscriptionID {
        static let incomingAlerts = "incoming-alerts-v1"
        static let outgoingStatus = "outgoing-status-v1"
    }

    enum WatchMessage {
        static let kindKey = "kind"
        static let pressKind = "press"
        static let nameKey = "name"
    }

    enum AppGroup {
        static let identifier = "group.com.timfallmk.attention"
    }

    /// Identifiers for the inline notification actions ("pull down on banner" → ack with emoji).
    /// Used both when registering the UNNotificationCategory at launch and when interpreting
    /// the response in the notification delegate.
    enum NotificationAction {
        static let category = "ATTENTION_PING"

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
