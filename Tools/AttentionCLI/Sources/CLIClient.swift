import CloudKit
import Foundation

final class CLIClient {
    private let container: CKContainer
    private let publicDB: CKDatabase

    init() {
        self.container = CKContainer(identifier: Constants.cloudKitContainerID)
        self.publicDB = container.publicCloudDatabase
    }

    // MARK: - Pair

    func createPair(invite: PairingInvite) async throws -> CKRecord {
        let record = CKRecord(recordType: Constants.RecordType.pair)
        record[Constants.PairField.pairKey] = invite.pairKey as CKRecordValue
        record[Constants.PairField.deviceA] = invite.inviterDeviceID as CKRecordValue
        record[Constants.PairField.deviceB] = "" as CKRecordValue
        record[Constants.PairField.nameA] = invite.inviterName as CKRecordValue
        record[Constants.PairField.nameB] = "" as CKRecordValue
        return try await publicDB.save(record)
    }

    func fetchPair(pairKey: String) async throws -> CKRecord? {
        let predicate = NSPredicate(format: "%K == %@", Constants.PairField.pairKey, pairKey)
        let query = CKQuery(recordType: Constants.RecordType.pair, predicate: predicate)
        let (results, _) = try await publicDB.records(matching: query, resultsLimit: 1)
        for (_, result) in results {
            if case .success(let record) = result { return record }
        }
        return nil
    }

    func joinPair(record: CKRecord, joinerDeviceID: String, joinerName: String) async throws -> CKRecord {
        let existingB = (record[Constants.PairField.deviceB] as? String) ?? ""
        guard existingB.isEmpty else { throw CLIError.pairAlreadyJoined }
        record[Constants.PairField.deviceB] = joinerDeviceID as CKRecordValue
        record[Constants.PairField.nameB] = joinerName as CKRecordValue
        let op = CKModifyRecordsOperation(recordsToSave: [record], recordIDsToDelete: nil)
        op.savePolicy = .ifServerRecordUnchanged
        op.qualityOfService = .userInitiated
        return try await withCheckedThrowingContinuation { cont in
            op.modifyRecordsResultBlock = { result in
                switch result {
                case .success: cont.resume(returning: record)
                case .failure(let error): cont.resume(throwing: error)
                }
            }
            publicDB.add(op)
        }
    }

    // MARK: - Alert

    func sendAlert(pairKey: String, senderDeviceID: String, senderName: String, message: String) async throws -> AlertRecord {
        let record = CKRecord(recordType: Constants.RecordType.alert)
        record[Constants.AlertField.pairKey] = pairKey as CKRecordValue
        record[Constants.AlertField.senderDeviceID] = senderDeviceID as CKRecordValue
        record[Constants.AlertField.senderName] = senderName as CKRecordValue
        record[Constants.AlertField.message] = message as CKRecordValue
        record[Constants.AlertField.state] = Constants.AlertState.sent.rawValue as CKRecordValue
        record[Constants.AlertField.critical] = 0 as CKRecordValue
        let saved = try await publicDB.save(record)
        guard let model = AlertRecord(record: saved, pairKey: nil) else { throw CLIError.malformedRecord }
        return model
    }

    func markAlertSeen(recordID: CKRecord.ID) async throws {
        let record = try await publicDB.record(for: recordID)
        record[Constants.AlertField.state] = Constants.AlertState.seen.rawValue as CKRecordValue
        record[Constants.AlertField.seenAt] = Date() as CKRecordValue
        _ = try await publicDB.save(record)
    }

    func acknowledgeAlert(recordID: CKRecord.ID, emoji: String?) async throws {
        let record = try await publicDB.record(for: recordID)
        let alreadyAcked = (record[Constants.AlertField.state] as? String) == Constants.AlertState.acknowledged.rawValue
        let saved: CKRecord
        if alreadyAcked {
            saved = record
        } else {
            record[Constants.AlertField.state] = Constants.AlertState.acknowledged.rawValue as CKRecordValue
            record[Constants.AlertField.acknowledgedAt] = Date() as CKRecordValue
            if let emoji { record[Constants.AlertField.ackEmoji] = emoji as CKRecordValue }
            saved = try await publicDB.save(record)
        }
        guard let pairKey = saved[Constants.AlertField.pairKey] as? String,
              let originalSenderID = saved[Constants.AlertField.senderDeviceID] as? String,
              !pairKey.isEmpty, !originalSenderID.isEmpty else { return }
        let ackRecordID = CKRecord.ID(recordName: "ack-\(recordID.recordName)")
        let ack = CKRecord(recordType: Constants.RecordType.ack, recordID: ackRecordID)
        ack[Constants.AckField.pairKey] = pairKey as CKRecordValue
        ack[Constants.AckField.recipientDeviceID] = originalSenderID as CKRecordValue
        if let emoji { ack[Constants.AckField.emoji] = emoji as CKRecordValue }
        ack[Constants.AckField.alertRecordName] = recordID.recordName as CKRecordValue
        do {
            _ = try await publicDB.save(ack)
        } catch let error as CKError where error.code == .serverRecordChanged {
            // Already exists from a previous ack attempt — no-op.
        } catch {
            // Alert state is already updated; Ack save failure means the sender-side
            // banner won't fire, but the CLI can report success and continue.
            fputs("warning: ack record save failed (sender banner may not appear): \(error.localizedDescription)\n", stderr)
        }
    }

    // MARK: - Polling

    func pollIncomingAlerts(pairKey: String, myDeviceID: String, since: Date) async throws -> [AlertRecord] {
        let predicate = NSPredicate(
            format: "%K == %@ AND %K != %@ AND creationDate > %@",
            Constants.AlertField.pairKey, pairKey,
            Constants.AlertField.senderDeviceID, myDeviceID,
            since as NSDate
        )
        let query = CKQuery(recordType: Constants.RecordType.alert, predicate: predicate)
        query.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let (results, _) = try await publicDB.records(matching: query, resultsLimit: 20)
        return results.compactMap { _, result in
            guard case .success(let record) = result else { return nil }
            return AlertRecord(record: record, pairKey: nil)
        }
    }

    func pollIncomingAcks(pairKey: String, myDeviceID: String, since: Date) async throws -> [(CKRecord.ID, String?, Date)] {
        let predicate = NSPredicate(
            format: "%K == %@ AND %K == %@ AND creationDate > %@",
            Constants.AckField.pairKey, pairKey,
            Constants.AckField.recipientDeviceID, myDeviceID,
            since as NSDate
        )
        let query = CKQuery(recordType: Constants.RecordType.ack, predicate: predicate)
        query.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let (results, _) = try await publicDB.records(matching: query, resultsLimit: 20)
        return results.compactMap { _, result in
            guard case .success(let record) = result else { return nil }
            return (record.recordID, record[Constants.AckField.emoji] as? String, record.creationDate ?? Date())
        }
    }

    func fetchMostRecentIncomingAlert(pairKey: String, myDeviceID: String) async throws -> AlertRecord? {
        let predicate = NSPredicate(
            format: "%K == %@ AND %K != %@",
            Constants.AlertField.pairKey, pairKey,
            Constants.AlertField.senderDeviceID, myDeviceID
        )
        let query = CKQuery(recordType: Constants.RecordType.alert, predicate: predicate)
        query.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let (results, _) = try await publicDB.records(matching: query, resultsLimit: 1)
        for (_, result) in results {
            if case .success(let record) = result { return AlertRecord(record: record, pairKey: nil) }
        }
        return nil
    }

    func fetchRecentAlerts(pairKey: String, limit: Int = 10) async throws -> [AlertRecord] {
        let predicate = NSPredicate(format: "%K == %@", Constants.AlertField.pairKey, pairKey)
        let query = CKQuery(recordType: Constants.RecordType.alert, predicate: predicate)
        query.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let (results, _) = try await publicDB.records(matching: query, resultsLimit: limit)
        return results.compactMap { _, result in
            guard case .success(let record) = result else { return nil }
            return AlertRecord(record: record, pairKey: nil)
        }
    }

    func fetchRecentAcks(pairKey: String, limit: Int = 10) async throws -> [(String?, String, Date)] {
        let predicate = NSPredicate(format: "%K == %@", Constants.AckField.pairKey, pairKey)
        let query = CKQuery(recordType: Constants.RecordType.ack, predicate: predicate)
        query.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let (results, _) = try await publicDB.records(matching: query, resultsLimit: limit)
        return results.compactMap { _, result in
            guard case .success(let record) = result else { return nil }
            let emoji = record[Constants.AckField.emoji] as? String
            let alertRef = record[Constants.AckField.alertRecordName] as? String ?? ""
            return (emoji, alertRef, record.creationDate ?? Date())
        }
    }
}

enum CLIError: LocalizedError {
    case pairAlreadyJoined
    case pairNotFound
    case malformedRecord
    case noState
    case invalidPayload
    case qrCodeFailed
    case supersededByPrivateZones

    var errorDescription: String? {
        switch self {
        case .pairAlreadyJoined: return "That pairing code is already in use by another device."
        case .pairNotFound:      return "Couldn't find that pairing code."
        case .malformedRecord:   return "Got an unexpected response from iCloud."
        case .noState:           return "No pair state found. Run 'pair invite' or 'pair join' first."
        case .invalidPayload:    return "Invalid payload URL."
        case .qrCodeFailed:      return "Failed to generate QR code PNG."
        case .supersededByPrivateZones:
            return """
                Pairing moved to per-user private CloudKit zones in 2.0, and this tool \
                can't take part: joining means accepting a CKShare, which needs an \
                iCloud entitlement a macOS `tool` target can't carry. Rebuilding it as \
                an app bundle is tracked in issue #60.
                """
        }
    }
}
