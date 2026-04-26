import CloudKit
import Foundation
import os.log

/// Owns all CloudKit interaction. The container ID is wired via `Constants.cloudKitContainerID`.
/// Not actor-isolated — CKDatabase APIs are already thread-safe and the methods here only
/// read/return values, no shared mutable state. Callers (AppState, PairingService, etc.)
/// hop to @MainActor on their own side for UI updates.
final class CloudKitService: @unchecked Sendable {
    static let shared = CloudKitService()

    private let log = Logger(subsystem: "com.example.attention", category: "CloudKit")
    private let container: CKContainer
    private let publicDB: CKDatabase

    private init() {
        self.container = CKContainer(identifier: Constants.cloudKitContainerID)
        self.publicDB = container.publicCloudDatabase
    }

    // MARK: - Account

    func accountStatus() async throws -> CKAccountStatus {
        try await container.accountStatus()
    }

    // MARK: - Pair record

    /// Creates a new Pair record with only the inviter's slot filled. Returns the saved record.
    func createPair(invite: PairingInvite) async throws -> CKRecord {
        let record = CKRecord(recordType: Constants.RecordType.pair)
        record[Constants.PairField.pairKey] = invite.pairKey as CKRecordValue
        record[Constants.PairField.deviceA] = invite.inviterDeviceID as CKRecordValue
        record[Constants.PairField.deviceB] = "" as CKRecordValue
        record[Constants.PairField.nameA] = invite.inviterName as CKRecordValue
        record[Constants.PairField.nameB] = "" as CKRecordValue
        return try await publicDB.save(record)
    }

    /// Looks up the Pair record by pairKey. Returns nil if not found.
    func fetchPair(pairKey: String) async throws -> CKRecord? {
        let predicate = NSPredicate(format: "%K == %@", Constants.PairField.pairKey, pairKey)
        let query = CKQuery(recordType: Constants.RecordType.pair, predicate: predicate)
        let (results, _) = try await publicDB.records(matching: query, resultsLimit: 1)
        for (_, result) in results {
            if case .success(let record) = result { return record }
        }
        return nil
    }

    /// Fills in the joiner's slot on an existing Pair record. Fails if `deviceB` is already set.
    func joinPair(record: CKRecord, joinerDeviceID: String, joinerName: String) async throws -> CKRecord {
        let existingB = (record[Constants.PairField.deviceB] as? String) ?? ""
        guard existingB.isEmpty else {
            throw AttentionError.pairAlreadyJoined
        }
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

    // MARK: - Alert record

    @discardableResult
    func sendAlert(
        pairKey: String,
        senderDeviceID: String,
        senderName: String,
        message: String,
        critical: Bool
    ) async throws -> AlertRecord {
        let record = CKRecord(recordType: Constants.RecordType.alert)
        record[Constants.AlertField.pairKey] = pairKey as CKRecordValue
        record[Constants.AlertField.senderDeviceID] = senderDeviceID as CKRecordValue
        record[Constants.AlertField.senderName] = senderName as CKRecordValue
        record[Constants.AlertField.message] = message as CKRecordValue
        record[Constants.AlertField.state] = Constants.AlertState.sent.rawValue as CKRecordValue
        record[Constants.AlertField.critical] = (critical ? 1 : 0) as CKRecordValue

        let saved = try await publicDB.save(record)
        guard let model = AlertRecord(record: saved) else {
            throw AttentionError.malformedRecord
        }
        return model
    }

    func markAlertSeen(recordID: CKRecord.ID) async throws -> AlertRecord {
        let record = try await publicDB.record(for: recordID)
        record[Constants.AlertField.state] = Constants.AlertState.seen.rawValue as CKRecordValue
        record[Constants.AlertField.seenAt] = Date() as CKRecordValue
        let saved = try await publicDB.save(record)
        guard let model = AlertRecord(record: saved) else { throw AttentionError.malformedRecord }
        return model
    }

    func acknowledgeAlert(recordID: CKRecord.ID, emoji: String?) async throws -> AlertRecord {
        let record = try await publicDB.record(for: recordID)
        record[Constants.AlertField.state] = Constants.AlertState.acknowledged.rawValue as CKRecordValue
        record[Constants.AlertField.acknowledgedAt] = Date() as CKRecordValue
        if let emoji {
            record[Constants.AlertField.ackEmoji] = emoji as CKRecordValue
        }
        let saved = try await publicDB.save(record)
        guard let model = AlertRecord(record: saved) else { throw AttentionError.malformedRecord }
        return model
    }

    func fetchAlert(recordID: CKRecord.ID) async throws -> AlertRecord {
        let record = try await publicDB.record(for: recordID)
        guard let model = AlertRecord(record: record) else { throw AttentionError.malformedRecord }
        return model
    }

    /// Latest alert in a pair (either direction). Used to repopulate UI on launch.
    func fetchMostRecentAlert(pairKey: String) async throws -> AlertRecord? {
        let predicate = NSPredicate(format: "%K == %@", Constants.AlertField.pairKey, pairKey)
        let query = CKQuery(recordType: Constants.RecordType.alert, predicate: predicate)
        query.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let (results, _) = try await publicDB.records(matching: query, resultsLimit: 1)
        for (_, result) in results {
            if case .success(let record) = result { return AlertRecord(record: record) }
        }
        return nil
    }

    // MARK: - Subscriptions

    /// Registers (idempotently) the two query subscriptions this app needs:
    ///  - Incoming alerts: visible alert push when partner sends.
    ///  - Outgoing status: silent push when partner updates seen/ack on our alerts.
    func registerSubscriptions(pairKey: String, myDeviceID: String) async throws {
        let existing = try await publicDB.allSubscriptions()
        let existingIDs = Set(existing.map(\.subscriptionID))

        var toSave: [CKSubscription] = []

        if !existingIDs.contains(Constants.SubscriptionID.incomingAlerts) {
            toSave.append(makeIncomingSubscription(pairKey: pairKey, myDeviceID: myDeviceID))
        }
        if !existingIDs.contains(Constants.SubscriptionID.outgoingStatus) {
            toSave.append(makeOutgoingStatusSubscription(pairKey: pairKey, myDeviceID: myDeviceID))
        }
        guard !toSave.isEmpty else { return }

        let op = CKModifySubscriptionsOperation(subscriptionsToSave: toSave, subscriptionIDsToDelete: nil)
        op.qualityOfService = .userInitiated
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            op.modifySubscriptionsResultBlock = { result in
                switch result {
                case .success: cont.resume()
                case .failure(let error): cont.resume(throwing: error)
                }
            }
            publicDB.add(op)
        }
    }

    func removeAllSubscriptions() async throws {
        let existing = try await publicDB.allSubscriptions()
        guard !existing.isEmpty else { return }
        let ids = existing.map(\.subscriptionID)
        let op = CKModifySubscriptionsOperation(subscriptionsToSave: nil, subscriptionIDsToDelete: ids)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            op.modifySubscriptionsResultBlock = { result in
                switch result {
                case .success: cont.resume()
                case .failure(let error): cont.resume(throwing: error)
                }
            }
            publicDB.add(op)
        }
    }

    // MARK: - Subscription factories

    private func makeIncomingSubscription(pairKey: String, myDeviceID: String) -> CKQuerySubscription {
        let predicate = NSPredicate(
            format: "%K == %@ AND %K != %@",
            Constants.AlertField.pairKey, pairKey,
            Constants.AlertField.senderDeviceID, myDeviceID
        )
        let sub = CKQuerySubscription(
            recordType: Constants.RecordType.alert,
            predicate: predicate,
            subscriptionID: Constants.SubscriptionID.incomingAlerts,
            options: [.firesOnRecordCreation]
        )
        let info = CKSubscription.NotificationInfo()
        info.titleLocalizationKey = "ATTENTION_NOTIFICATION_TITLE"
        info.titleLocalizationArgs = [Constants.AlertField.senderName]
        info.alertLocalizationKey = "ATTENTION_NOTIFICATION_BODY"
        info.alertLocalizationArgs = [Constants.AlertField.senderName, Constants.AlertField.message]
        info.soundName = "needs-attention.caf"
        info.shouldBadge = true
        info.shouldSendMutableContent = true     // routes through NSE so we can upgrade priority
        info.desiredKeys = [
            Constants.AlertField.pairKey,
            Constants.AlertField.senderDeviceID,
            Constants.AlertField.senderName,
            Constants.AlertField.message,
            Constants.AlertField.critical,
            Constants.AlertField.state
        ]
        sub.notificationInfo = info
        return sub
    }

    private func makeOutgoingStatusSubscription(pairKey: String, myDeviceID: String) -> CKQuerySubscription {
        // Updates to alerts I sent — used to refresh the "Sent / Seen / Acknowledged" indicator.
        let predicate = NSPredicate(
            format: "%K == %@ AND %K == %@",
            Constants.AlertField.pairKey, pairKey,
            Constants.AlertField.senderDeviceID, myDeviceID
        )
        let sub = CKQuerySubscription(
            recordType: Constants.RecordType.alert,
            predicate: predicate,
            subscriptionID: Constants.SubscriptionID.outgoingStatus,
            options: [.firesOnRecordUpdate]
        )
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true   // silent push, just wakes the app to refetch
        info.desiredKeys = [
            Constants.AlertField.state,
            Constants.AlertField.seenAt,
            Constants.AlertField.acknowledgedAt,
            Constants.AlertField.ackEmoji
        ]
        sub.notificationInfo = info
        return sub
    }
}

enum AttentionError: LocalizedError {
    case pairAlreadyJoined
    case pairNotFound
    case malformedRecord
    case noPair
    case iCloudUnavailable

    var errorDescription: String? {
        switch self {
        case .pairAlreadyJoined: return "That pairing code is already in use by another device."
        case .pairNotFound:      return "Couldn't find that pairing code. Ask the other phone to show it again."
        case .malformedRecord:   return "Got an unexpected response from iCloud."
        case .noPair:            return "This phone isn't paired yet."
        case .iCloudUnavailable: return "Sign in to iCloud in Settings to use Attention."
        }
    }
}
