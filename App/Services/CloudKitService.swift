import CloudKit
import Foundation
import os.log

/// Owns all CloudKit interaction. The container ID is wired via `Constants.cloudKitContainerID`.
/// Not actor-isolated — CKDatabase APIs are already thread-safe and the methods here only
/// read/return values, no shared mutable state. Callers (AppState, PairingService, etc.)
/// hop to @MainActor on their own side for UI updates.
final class CloudKitService: @unchecked Sendable {
    static let shared = CloudKitService()

    private let log = Logger(subsystem: "com.timfallmk.attention", category: "CloudKit")
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

    /// Updates the name field corresponding to `myDeviceID` on the Pair record. Used
    /// when the user renames themselves in Settings so the partner sees the new name.
    func updatePairName(pairKey: String, myDeviceID: String, newName: String) async throws {
        guard let record = try await fetchPair(pairKey: pairKey) else {
            throw AttentionError.pairNotFound
        }
        let deviceA = (record[Constants.PairField.deviceA] as? String) ?? ""
        if deviceA == myDeviceID {
            record[Constants.PairField.nameA] = newName as CKRecordValue
        } else {
            record[Constants.PairField.nameB] = newName as CKRecordValue
        }
        _ = try await publicDB.save(record)
    }

    /// Deletes a Pair record by name. Used when the inviter cancels a pending invite —
    /// best-effort; an orphaned record is harmless (nobody else knows its pairKey).
    func deletePair(recordName: String) async throws {
        _ = try await publicDB.deleteRecord(withID: CKRecord.ID(recordName: recordName))
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

    /// Idempotent: a second call on an already-acked Alert skips the update and the
    /// Ack-record save is a no-op (the deterministic Ack recordID makes the second
    /// save trip `.serverRecordChanged`, which we swallow). One banner per Alert,
    /// even under repeated taps, retries, or duplicated push delivery.
    func acknowledgeAlert(recordID: CKRecord.ID, emoji: String?) async throws -> AlertRecord {
        let record = try await publicDB.record(for: recordID)
        let alreadyAcked = (record[Constants.AlertField.state] as? String) == Constants.AlertState.acknowledged.rawValue

        let saved: CKRecord
        if alreadyAcked {
            saved = record
        } else {
            record[Constants.AlertField.state] = Constants.AlertState.acknowledged.rawValue as CKRecordValue
            record[Constants.AlertField.acknowledgedAt] = Date() as CKRecordValue
            if let emoji {
                record[Constants.AlertField.ackEmoji] = emoji as CKRecordValue
            }
            saved = try await publicDB.save(record)
        }
        guard let model = AlertRecord(record: saved) else { throw AttentionError.malformedRecord }

        // Companion Ack record so the original sender's outgoing-ack-v2 subscription
        // (firesOnRecordCreation) fires. Source of truth for the in-app indicator
        // remains the Alert update above; the Ack record exists purely to trigger the
        // visible banner.
        //
        // Deterministic recordID derived from the Alert's recordName: a second save
        // attempt for the same Alert hits `.serverRecordChanged` (which we swallow) so
        // we get exactly one Ack-creation event — and exactly one banner — regardless
        // of how many times the caller invokes this method. Crucially this also
        // recovers from a partial-failure case where a previous call wrote the Alert
        // but failed to save the Ack: the next call still attempts the Ack write
        // because `alreadyAcked` doesn't gate it.
        if let pairKey = saved[Constants.AlertField.pairKey] as? String,
           let originalSenderID = saved[Constants.AlertField.senderDeviceID] as? String,
           !pairKey.isEmpty, !originalSenderID.isEmpty {
            let ackRecordID = CKRecord.ID(recordName: "ack-\(recordID.recordName)")
            let ack = CKRecord(recordType: Constants.RecordType.ack, recordID: ackRecordID)
            ack[Constants.AckField.pairKey] = pairKey as CKRecordValue
            ack[Constants.AckField.recipientDeviceID] = originalSenderID as CKRecordValue
            if let emoji {
                ack[Constants.AckField.emoji] = emoji as CKRecordValue
            }
            ack[Constants.AckField.alertRecordName] = recordID.recordName as CKRecordValue
            do {
                _ = try await publicDB.save(ack)
            } catch let error as CKError where error.code == .serverRecordChanged {
                // Already created on a previous ack — subscription already fired, no-op.
            } catch {
                log.error("ack record save failed: \(String(describing: error), privacy: .public)")
            }
        }
        return model
    }

    func fetchAlert(recordID: CKRecord.ID) async throws -> AlertRecord {
        let record = try await publicDB.record(for: recordID)
        guard let model = AlertRecord(record: record) else { throw AttentionError.malformedRecord }
        return model
    }

    /// Latest alert in a pair, optionally filtered to a specific sender.
    /// Pass `senderDeviceID` to fetch the most recent outgoing or incoming alert independently.
    func fetchMostRecentAlert(pairKey: String, senderDeviceID: String? = nil) async throws -> AlertRecord? {
        let predicate: NSPredicate
        if let senderDeviceID {
            predicate = NSPredicate(
                format: "%K == %@ AND %K == %@",
                Constants.AlertField.pairKey, pairKey,
                Constants.AlertField.senderDeviceID, senderDeviceID
            )
        } else {
            predicate = NSPredicate(format: "%K == %@", Constants.AlertField.pairKey, pairKey)
        }
        let query = CKQuery(recordType: Constants.RecordType.alert, predicate: predicate)
        query.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let (results, _) = try await publicDB.records(matching: query, resultsLimit: 1)
        for (_, result) in results {
            if case .success(let record) = result { return AlertRecord(record: record) }
        }
        return nil
    }

    /// Recent alerts in a pair, newest first, both directions. Used by the history view.
    /// Read-only; malformed records are skipped rather than failing the whole fetch.
    func fetchRecentAlerts(pairKey: String, limit: Int = 30) async throws -> [AlertRecord] {
        let predicate = NSPredicate(format: "%K == %@", Constants.AlertField.pairKey, pairKey)
        let query = CKQuery(recordType: Constants.RecordType.alert, predicate: predicate)
        query.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let (results, _) = try await publicDB.records(matching: query, resultsLimit: limit)
        return results.compactMap { _, result in
            guard case .success(let record) = result else { return nil }
            return AlertRecord(record: record)
        }
    }

    // MARK: - Subscriptions

    /// Registers (idempotently) the four query subscriptions this app needs:
    ///  - Incoming alerts: visible alert push when partner sends.
    ///  - Outgoing status: silent push when partner updates seen/ack on our alerts.
    ///  - Outgoing ack: visible alert push specifically when the partner acks (so the
    ///    sender sees a banner even with the app force-quit / device locked).
    ///  - Pair updates: silent push when the partner renames themselves.
    ///
    /// Resilient to per-subscription failure: if at least one save succeeds, partial
    /// failures are logged but not propagated. The next launch retries the missing
    /// IDs (since they aren't in `existingIDs`). The known-failure case worth
    /// surfacing is `outgoing-ack-v2`, which depends on the deployed `Ack` record
    /// type — its outcome is mirrored to `SharedSettings.outgoingAckSubscriptionUnavailable`
    /// so the Settings → Diagnostics row can flag the silent feature degradation.
    /// Throws only when the operation fails wholesale (no subscription saved at
    /// all), so callers should still treat the throw as "try again on next boot".
    func registerSubscriptions(pairKey: String, myDeviceID: String) async throws {
        let existing = try await publicDB.allSubscriptions()
        let existingIDs = Set(existing.map(\.subscriptionID))

        // If the ack subscription already lives on the server, the previously-saved
        // diagnostic flag + reason are stale — clear them so we don't keep flagging
        // a healthy install.
        if existingIDs.contains(Constants.SubscriptionID.outgoingAck) {
            SharedSettings.outgoingAckSubscriptionUnavailable = false
            SharedSettings.outgoingAckSubscriptionFailureReason = nil
        }

        var toSave: [CKSubscription] = []

        if !existingIDs.contains(Constants.SubscriptionID.incomingAlerts) {
            toSave.append(makeIncomingSubscription(pairKey: pairKey, myDeviceID: myDeviceID))
        }
        if !existingIDs.contains(Constants.SubscriptionID.outgoingStatus) {
            toSave.append(makeOutgoingStatusSubscription(pairKey: pairKey, myDeviceID: myDeviceID))
        }
        if !existingIDs.contains(Constants.SubscriptionID.outgoingAck) {
            toSave.append(makeOutgoingAckSubscription(pairKey: pairKey, myDeviceID: myDeviceID))
        }
        if !existingIDs.contains(Constants.SubscriptionID.pairUpdates) {
            toSave.append(makePairUpdateSubscription(pairKey: pairKey))
        }
        guard !toSave.isEmpty else { return }

        let op = CKModifySubscriptionsOperation(subscriptionsToSave: toSave, subscriptionIDsToDelete: nil)
        op.qualityOfService = .userInitiated
        let log = self.log
        let attemptedIDs = toSave.map(\.subscriptionID).joined(separator: ", ")
        let results = SubscriptionSaveResults()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            op.perSubscriptionSaveBlock = { id, result in
                switch result {
                case .success:
                    results.markSaved(id)
                    if id == Constants.SubscriptionID.outgoingAck {
                        SharedSettings.outgoingAckSubscriptionUnavailable = false
                        SharedSettings.outgoingAckSubscriptionFailureReason = nil
                    }
                case .failure(let error):
                    results.markFailed(id, error: error)
                    log.error("subscription \(id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                    if id == Constants.SubscriptionID.outgoingAck {
                        SharedSettings.outgoingAckSubscriptionUnavailable = true
                        // Bound the App Group payload — CKError descriptions can balloon when they
                        // include the full request/response dump, and SharedSettings is read by the NSE.
                        let raw = String(describing: error)
                        SharedSettings.outgoingAckSubscriptionFailureReason = raw.count > 500
                            ? String(raw.prefix(500)) + "…"
                            : raw
                    }
                }
            }
            op.modifySubscriptionsResultBlock = { result in
                switch result {
                case .success:
                    log.info("subscriptions saved: \(attemptedIDs, privacy: .public)")
                    cont.resume()
                case .failure(let error):
                    if results.savedCount > 0 {
                        // Partial failure: the saved ones stuck. Per-subscription failures
                        // are already logged above; don't poison the call site.
                        log.error("subscriptions partial failure — saved [\(results.savedJoined, privacy: .public)] failed [\(results.failedJoined, privacy: .public)]: \(String(describing: error), privacy: .public)")
                        cont.resume()
                    } else {
                        log.error("modifySubscriptions failed [\(attemptedIDs, privacy: .public)]: \(String(describing: error), privacy: .public)")
                        cont.resume(throwing: error)
                    }
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

    /// Deletes any subscriptions whose predicate references the given pairKey. Used when
    /// the inviter cancels a pending invite: `startInviting` registers subscriptions under
    /// the invite's pairKey before the pair completes, and `registerSubscriptions` is
    /// idempotent by subscription ID — so without this purge an abandoned invite's
    /// subscriptions would squat on the real IDs and silently swallow a later pair's
    /// registration. Same predicate-content matching technique as the DEBUG-only
    /// `purgeSeededSubscriptions`, but compiled into Release because invite cancel is a
    /// user-facing flow.
    func purgeSubscriptions(pairKey: String) async throws {
        let existing = try await publicDB.allSubscriptions()
        let matchingIDs: [String] = existing.compactMap { sub in
            guard let qsub = sub as? CKQuerySubscription else { return nil }
            return qsub.predicate.predicateFormat.contains("\"\(pairKey)\"")
                ? sub.subscriptionID
                : nil
        }
        guard !matchingIDs.isEmpty else { return }
        log.info("purging invite subs: \(matchingIDs.joined(separator: ", "), privacy: .public)")
        let op = CKModifySubscriptionsOperation(
            subscriptionsToSave: nil,
            subscriptionIDsToDelete: matchingIDs
        )
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

    #if DEBUG
    /// Deletes any subscriptions left over from `AppState.bootstrap`'s unpaired
    /// schema seeder — i.e. those whose predicate references the placeholder
    /// `pairKey == "schema-seed"`. Called before the paired re-registration
    /// path so `registerSubscriptions`' idempotent-on-ID check doesn't keep
    /// the inert placeholders alive under the real subscription IDs (which
    /// would silently break paired Dev tests). No-op when nothing matches.
    func purgeSeededSubscriptions() async throws {
        let existing = try await publicDB.allSubscriptions()
        let seededIDs: [String] = existing.compactMap { sub in
            guard let qsub = sub as? CKQuerySubscription else { return nil }
            return qsub.predicate.predicateFormat.contains("\"schema-seed\"")
                ? sub.subscriptionID
                : nil
        }
        guard !seededIDs.isEmpty else { return }
        log.info("purging seeded subs: \(seededIDs.joined(separator: ", "), privacy: .public)")
        let op = CKModifySubscriptionsOperation(
            subscriptionsToSave: nil,
            subscriptionIDsToDelete: seededIDs
        )
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
    #endif

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
        // CloudKit caps the per-subscription "additional fields" payload, and Production is
        // stricter than Development. NSE replaces title/body/sound from the fetched record,
        // so we keep this minimal: a static alertBody to make it an alert push (so the NSE
        // is invoked) plus mutable-content to route it through the extension.
        let info = CKSubscription.NotificationInfo()
        info.alertBody = "Attention"
        info.shouldSendMutableContent = true
        sub.notificationInfo = info
        return sub
    }

    private func makePairUpdateSubscription(pairKey: String) -> CKQuerySubscription {
        let predicate = NSPredicate(format: "%K == %@", Constants.PairField.pairKey, pairKey)
        let sub = CKQuerySubscription(
            recordType: Constants.RecordType.pair,
            predicate: predicate,
            subscriptionID: Constants.SubscriptionID.pairUpdates,
            options: [.firesOnRecordUpdate]
        )
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true   // silent push; handler refetches the record
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
        info.shouldSendContentAvailable = true   // silent push; handler refetches the record
        sub.notificationInfo = info
        return sub
    }

    /// Fires when my partner writes an Ack record naming me as the recipient — i.e.,
    /// they just acked one of my outgoing alerts. Routed as an alert push so the
    /// sender sees a banner even when the app is force-quit or the device is locked.
    ///
    /// This used to be a `firesOnRecordUpdate` subscription on the Alert record with
    /// a `state == "acknowledged"` predicate. CloudKit rejects that combination —
    /// public-DB CKQuerySubscription doesn't accept mutable-content alert pushes
    /// alongside `firesOnRecordUpdate` (anti-abuse: any signed-in user can update
    /// records they didn't create, so visible-push-on-update would be a spam vector).
    /// `firesOnRecordCreation` on a dedicated Ack record sidesteps the restriction.
    private func makeOutgoingAckSubscription(pairKey: String, myDeviceID: String) -> CKQuerySubscription {
        let predicate = NSPredicate(
            format: "%K == %@ AND %K == %@",
            Constants.AckField.pairKey, pairKey,
            Constants.AckField.recipientDeviceID, myDeviceID
        )
        let sub = CKQuerySubscription(
            recordType: Constants.RecordType.ack,
            predicate: predicate,
            subscriptionID: Constants.SubscriptionID.outgoingAck,
            options: [.firesOnRecordCreation]
        )
        let info = CKSubscription.NotificationInfo()
        info.alertBody = "Acknowledged"          // placeholder; NSE rewrites with partner name + emoji
        info.shouldSendMutableContent = true     // routes through the NSE
        sub.notificationInfo = info
        return sub
    }
}

/// Per-subscription tally for `registerSubscriptions`. CloudKit invokes the per-save
/// and final result blocks serially on the operation's internal queue, so a plain
/// class with `@unchecked Sendable` is enough — no concurrent mutation in practice.
private final class SubscriptionSaveResults: @unchecked Sendable {
    private(set) var saved: [String] = []
    private(set) var failed: [(String, Error)] = []
    func markSaved(_ id: String) { saved.append(id) }
    func markFailed(_ id: String, error: Error) { failed.append((id, error)) }
    var savedCount: Int { saved.count }
    var savedJoined: String { saved.joined(separator: ", ") }
    var failedJoined: String { failed.map(\.0).joined(separator: ", ") }
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
