import Foundation

/// Compact view of the phone's alert state, shipped over WatchConnectivity so the watch
/// can render the same status pill the iPhone does. Encoded as JSON inside the WCSession
/// dictionary under `Constants.WatchMessage.snapshotKey`.
struct WatchSnapshot: Codable, Equatable {
    enum Outgoing: String, Codable {
        case sent
        case seen
        case acknowledged
    }

    struct OutgoingInfo: Codable, Equatable {
        /// CKRecord.ID.recordName — echoed back in the clear payload so the phone
        /// can ignore stale clears that don't match the current pendingOutgoing.
        var recordName: String
        var state: Outgoing
        var critical: Bool
        var ackEmoji: String?
    }

    struct IncomingInfo: Codable, Equatable {
        /// CKRecord.ID.recordName — used by the phone to ignore stale acks when a newer
        /// alert has already replaced this one.
        var recordName: String
        var senderName: String
        var critical: Bool
        var createdAt: Date
        var acknowledged: Bool
        /// Full body string ("needs hugs"). Optional for backward compatibility with
        /// snapshots encoded by older app versions.
        var message: String?
        /// When set (and in the future), this incoming alert is snoozed until this time.
        /// Defaulted so it's optional in the synthesized memberwise init too (source compat
        /// for existing call sites), and back-compatible in Codable (decodes nil when absent).
        var snoozedUntil: Date? = nil
    }

    var paired: Bool
    var outgoing: OutgoingInfo?
    var incoming: IncomingInfo?
    /// Absolute time so the watch can locally tick the cooldown without phone help.
    var cooldownEnds: Date?

    static let empty = WatchSnapshot(paired: false, outgoing: nil, incoming: nil, cooldownEnds: nil)

    func encode() -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try? encoder.encode(self)
    }

    static func decode(_ data: Data) -> WatchSnapshot? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try? decoder.decode(WatchSnapshot.self, from: data)
    }
}
