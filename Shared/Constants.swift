import Foundation

enum Constants {
    static let cloudKitContainerID = "iCloud.com.example.attention"

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
        static let identifier = "group.com.example.attention"
    }
}
