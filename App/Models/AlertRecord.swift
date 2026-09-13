import CloudKit
import Foundation

/// Local representation of a single attention press. Mirrors the CloudKit `Alert` record.
///
/// From 2.0 the human-readable fields arrive sealed: the record lives in a zone only
/// the pair can reach, and its contents are encrypted under a key derived from the
/// pair key, so the storage provider holds ciphertext. Pre-2.0 records carry the same
/// values in the clear under the old field names, and are still parsed — the local
/// history archive is full of them.
struct AlertRecord: Identifiable, Equatable {
    var id: CKRecord.ID
    /// Empty for 2.0 records. Zone membership is the boundary; the field only survives
    /// so archived pre-2.0 records round-trip unchanged.
    var pairKey: String
    var senderDeviceID: String
    /// Nil on every record written before per-account identity, which is what the
    /// `PairState.isMine` fallback is for. Never empty-string for "absent": the
    /// difference between "this person has no account identity recorded" and "their
    /// account identity is the empty string" is the difference between falling back and
    /// matching everything.
    var senderUserID: String?
    var senderName: String
    var message: String
    var createdAt: Date
    var state: Constants.AlertState
    var seenAt: Date?
    var acknowledgedAt: Date?
    var ackEmoji: String?
    var critical: Bool

    /// `pairKey` is what opens the sealed fields. Passing nil parses the pre-2.0 shape
    /// only, which is what the history archive needs and all the NSE has before it
    /// reaches the keychain.
    ///
    /// Returns nil when the record isn't an Alert this app wrote. Sealed fields that
    /// fail to open are *not* fatal: a record whose ciphertext we can't read is still a
    /// real press from the partner, and showing "needs attention" from an unknown
    /// sender beats dropping it silently.
    init?(record: CKRecord, pairKey: String?) {
        guard
            let senderDeviceID = record[Constants.AlertField.senderDeviceID] as? String,
            let stateRaw = record[Constants.AlertField.state] as? String,
            let state = Constants.AlertState(rawValue: stateRaw)
        else { return nil }

        self.id = record.recordID
        self.pairKey = record[Constants.AlertField.pairKey] as? String ?? ""
        self.senderDeviceID = senderDeviceID
        self.senderUserID = record[Constants.AlertField.senderUserID] as? String
        self.createdAt = record.creationDate ?? Date()
        self.state = state
        self.seenAt = record[Constants.AlertField.seenAt] as? Date
        self.acknowledgedAt = record[Constants.AlertField.acknowledgedAt] as? Date
        self.critical = (record[Constants.AlertField.critical] as? Int ?? 0) == 1

        // Sealed first, falling back to the pre-2.0 plaintext fields. Both go through
        // the same bounds: decryption proves the writer held the pair key, which is a
        // far stronger claim than the public database ever supported, but a partner's
        // own device is still not a place to accept unbounded text from.
        let name = Self.opened(record, Constants.AlertField.senderNameSealed, pairKey)
            ?? record[Constants.AlertField.senderName] as? String
        let body = Self.opened(record, Constants.AlertField.messageSealed, pairKey)
            ?? record[Constants.AlertField.message] as? String
        let emoji = Self.opened(record, Constants.AlertField.ackEmojiSealed, pairKey)
            ?? record[Constants.AlertField.ackEmoji] as? String

        self.senderName = UntrustedText.name(name ?? "")
        self.message = UntrustedText.message(body, fallback: "needs attention")
        self.ackEmoji = UntrustedText.emoji(emoji)
    }

    private static func opened(_ record: CKRecord, _ field: String, _ pairKey: String?) -> String? {
        guard let pairKey, let sealed = record[field] as? Data else { return nil }
        return PairCrypto.opened(sealed, pairKey: pairKey, field: field)
    }

    /// Writes the human-readable fields into a record as ciphertext. The plaintext
    /// fields are never written from 2.0 on — writing both would leave the cleartext
    /// sitting beside the ciphertext and make the encryption decorative.
    static func seal(name: String?, message: String?, ackEmoji: String?,
                     into record: CKRecord, pairKey: String) throws {
        func put(_ value: String?, _ field: String) throws {
            guard let value, !value.isEmpty else {
                record[field] = nil
                return
            }
            record[field] = try PairCrypto.seal(value, pairKey: pairKey, field: field) as CKRecordValue
        }
        try put(name, Constants.AlertField.senderNameSealed)
        try put(message, Constants.AlertField.messageSealed)
        try put(ackEmoji, Constants.AlertField.ackEmojiSealed)
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
        return AlertRecord(record: record, pairKey: nil)!
    }
}
#endif
