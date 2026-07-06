import CloudKit
import Foundation

/// Local representation of a single attention press. Mirrors the CloudKit `Alert` record.
struct AlertRecord: Identifiable, Equatable {
    var id: CKRecord.ID
    var pairKey: String
    var senderDeviceID: String
    var senderName: String
    var message: String
    var createdAt: Date
    var state: Constants.AlertState
    var seenAt: Date?
    var acknowledgedAt: Date?
    var ackEmoji: String?
    var critical: Bool

    init?(record: CKRecord) {
        guard
            let pairKey = record[Constants.AlertField.pairKey] as? String,
            let senderDeviceID = record[Constants.AlertField.senderDeviceID] as? String,
            let stateRaw = record[Constants.AlertField.state] as? String,
            let state = Constants.AlertState(rawValue: stateRaw)
        else { return nil }

        self.id = record.recordID
        self.pairKey = pairKey
        self.senderDeviceID = senderDeviceID
        self.senderName = record[Constants.AlertField.senderName] as? String ?? ""
        self.message = record[Constants.AlertField.message] as? String ?? "needs attention"
        self.createdAt = record.creationDate ?? Date()
        self.state = state
        self.seenAt = record[Constants.AlertField.seenAt] as? Date
        self.acknowledgedAt = record[Constants.AlertField.acknowledgedAt] as? Date
        self.ackEmoji = record[Constants.AlertField.ackEmoji] as? String
        self.critical = (record[Constants.AlertField.critical] as? Int ?? 0) == 1
    }
}

#if DEBUG
extension AlertRecord {
    /// Sample record for SwiftUI previews. Built through a real `CKRecord` so it exercises
    /// the same parser production uses — no preview-only second initializer to drift.
    static func preview(
        state: Constants.AlertState = .sent,
        senderName: String = "Sam",
        message: String = "needs coffee",
        ackEmoji: String? = nil
    ) -> AlertRecord {
        let record = CKRecord(
            recordType: Constants.RecordType.alert,
            recordID: CKRecord.ID(recordName: "preview-\(UUID().uuidString)")
        )
        record[Constants.AlertField.pairKey] = "preview" as CKRecordValue
        record[Constants.AlertField.senderDeviceID] = "sender" as CKRecordValue
        record[Constants.AlertField.senderName] = senderName as CKRecordValue
        record[Constants.AlertField.message] = message as CKRecordValue
        record[Constants.AlertField.state] = state.rawValue as CKRecordValue
        record[Constants.AlertField.critical] = 0 as CKRecordValue
        if let ackEmoji {
            record[Constants.AlertField.ackEmoji] = ackEmoji as CKRecordValue
        }
        return AlertRecord(record: record)!
    }
}
#endif
