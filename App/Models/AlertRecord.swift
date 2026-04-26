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
