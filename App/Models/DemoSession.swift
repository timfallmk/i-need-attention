import CloudKit
import Foundation

/// A self-contained walkthrough of the app with no partner, no network and no storage.
///
/// It exists because pairing is a wall, and two people hit it for the same reason: the
/// person who installed this before talking their partner into it, and an App Review
/// tester, who has one device and cannot pair at all. A carve-out visible only to Apple
/// would be a hidden feature; the honest version is a door everyone can see, and it is
/// better product for it.
///
/// **The safety property is structural, not defensive.** A demo never sets
/// `AppState.pair`, and every CloudKit path in `AppState` opens with
/// `guard let pair else { return }` — so no reachable call can write a demo record into
/// anyone's zone. That guard predates the demo; the demo is safe because it stays on the
/// side of it that was already impossible to cross, not because four new checks say so.
/// `DemoSessionTests` pins the invariant.
///
/// Nothing is persisted either — no zone, no archive, no `UserDefaults`, no watch
/// snapshot — so a relaunch ends the demo and it can never be mistaken for a pairing.
enum DemoSession {
    static let partnerName = "Sam"

    /// Distinct from any real `DeviceIdentity.id`, which is a UUID string.
    static let partnerDeviceID = "demo-partner"

    /// How long the scripted partner takes to notice and to answer. Slow enough to read
    /// as a sequence rather than a flicker, quick enough that a reviewer doesn't leave.
    static let seenAfter: TimeInterval = 1.5
    static let acknowledgedAfter: TimeInterval = 2.5
    /// The partner's own alert, so the receiving half can be tried too.
    static let incomingAfter: TimeInterval = 6

    static let ackEmoji = "❤️"
    static let incomingMessage = "needs attention"

    /// Built through a real `CKRecord` held only in memory, the same way
    /// `AlertRecord.preview` is — it exercises the parser production uses instead of
    /// adding a second construction path that could drift from it. Nothing is saved: a
    /// `CKRecord` is an ordinary object until some database is asked to store it, and
    /// nothing here asks.
    static func alert(
        senderDeviceID: String,
        senderName: String,
        message: String,
        state: Constants.AlertState,
        ackEmoji: String? = nil,
        createdAt: Date = Date()
    ) -> AlertRecord {
        let record = CKRecord(
            recordType: Constants.RecordType.alert,
            recordID: CKRecord.ID(recordName: "demo-\(UUID().uuidString)")
        )
        record[Constants.AlertField.senderDeviceID] = senderDeviceID as CKRecordValue
        record[Constants.AlertField.senderName] = senderName as CKRecordValue
        record[Constants.AlertField.message] = message as CKRecordValue
        record[Constants.AlertField.state] = state.rawValue as CKRecordValue
        record[Constants.AlertField.critical] = 0 as CKRecordValue
        if let ackEmoji {
            record[Constants.AlertField.ackEmoji] = ackEmoji as CKRecordValue
        }

        // `creationDate` is server-assigned and nil on an unsaved record, which the
        // parser reads as "now". Fine for the alert being sent this second; the override
        // below is what lets a demo alert be backdated.
        var alert = AlertRecord(record: record, pairKey: nil)!
        alert.createdAt = createdAt
        return alert
    }

    /// The press the user just made, waiting on a partner who will answer on a timer.
    /// Message phrasing mirrors `AppState.sendAttention` so the demo shows the real thing.
    static func outgoing(from deviceID: String, senderName: String, noun: String?) -> AlertRecord {
        let resolved = noun.flatMap(NounPresets.sanitize) ?? "attention"
        return alert(
            senderDeviceID: deviceID,
            senderName: senderName,
            message: "needs \(resolved)",
            state: .sent
        )
    }

    /// The partner's press, so the receiving half — banner, emoji, acknowledge — can be
    /// tried on the one device too.
    static func incoming() -> AlertRecord {
        alert(
            senderDeviceID: partnerDeviceID,
            senderName: partnerName,
            message: incomingMessage,
            state: .sent
        )
    }

    /// Moves an alert along the script. Returns a copy: `AlertRecord` is a value type and
    /// the caller reassigns it, which is what makes the view update.
    static func advanced(
        _ alert: AlertRecord,
        to state: Constants.AlertState,
        emoji: String? = nil,
        at date: Date = Date()
    ) -> AlertRecord {
        var next = alert
        next.state = state
        switch state {
        case .sent:
            next.seenAt = nil
            next.acknowledgedAt = nil
            next.ackEmoji = nil
        case .seen:
            next.seenAt = date
        case .acknowledged:
            next.seenAt = next.seenAt ?? date
            next.acknowledgedAt = date
            next.ackEmoji = emoji
        }
        return next
    }
}
