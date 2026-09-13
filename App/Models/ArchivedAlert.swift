import CloudKit
import Foundation

/// A pre-2.0 `Alert`, frozen. The 2.0 cutover moves records into per-user private
/// zones under a new pair key, so everything in the public database becomes
/// unreachable the moment the user re-pairs — this is the local copy taken before
/// that happens.
///
/// Not replayed into the new zones: those records predate the pair key's role as a
/// content boundary, and re-uploading plaintext-derived rows to preserve a list of
/// past button presses isn't worth the dedupe and ordering problems it creates.
/// They render alongside live records and never change again.
struct ArchivedAlert: Codable, Equatable, Identifiable {
    var recordName: String
    var senderDeviceID: String
    /// Absent on rows archived by earlier builds, and on every genuinely pre-2.0 row.
    /// Decodes as nil from those blobs, which is exactly the fallback case.
    var senderUserID: String?
    var senderName: String
    var message: String
    var createdAt: Date
    var state: String
    var seenAt: Date?
    var acknowledgedAt: Date?
    var ackEmoji: String?
    var critical: Bool

    var id: String { recordName }

    init(_ alert: AlertRecord) {
        self.recordName = alert.id.recordName
        self.senderDeviceID = alert.senderDeviceID
        self.senderUserID = alert.senderUserID
        self.senderName = alert.senderName
        self.message = alert.message
        self.createdAt = alert.createdAt
        self.state = alert.state.rawValue
        self.seenAt = alert.seenAt
        self.acknowledgedAt = alert.acknowledgedAt
        self.ackEmoji = alert.ackEmoji
        self.critical = alert.critical
    }
}

extension AlertRecord {
    /// Rehydrates an archived row for rendering. The second construction path is
    /// deliberate and safe here in a way a preview-only initializer wouldn't be:
    /// archived rows are frozen, so this can't drift out of step with a schema that
    /// no longer applies to them. `pairKey` is dropped — the pre-2.0 key is gone by
    /// the time these render, and nothing downstream reads it for history.
    init(archived: ArchivedAlert) {
        self.id = CKRecord.ID(recordName: archived.recordName)
        self.pairKey = ""
        self.senderDeviceID = archived.senderDeviceID
        self.senderUserID = archived.senderUserID
        self.senderName = archived.senderName
        self.message = archived.message
        self.createdAt = archived.createdAt
        self.state = Constants.AlertState(rawValue: archived.state) ?? .sent
        self.seenAt = archived.seenAt
        self.acknowledgedAt = archived.acknowledgedAt
        self.ackEmoji = archived.ackEmoji
        self.critical = archived.critical
    }
}
