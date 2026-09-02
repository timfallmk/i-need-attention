import CloudKit
import Foundation
import os.log

/// Owns all CloudKit interaction. The container ID is wired via `Constants.cloudKitContainerID`.
/// Not actor-isolated — CKDatabase APIs are already thread-safe and the methods here only
/// read/return values, no shared mutable state. Callers (AppState, PairingService, etc.)
/// hop to @MainActor on their own side for UI updates.
final class CloudKitService: @unchecked Sendable {
    static let shared = CloudKitService()

    let log = Logger(subsystem: "com.timfallmk.attention", category: "CloudKit")

    /// Internal rather than private so the zone-sharing half (`ZoneSharing.swift`) can
    /// reach them — `private` is file-scoped, and splitting that work into its own file
    /// keeps it reviewable ahead of the step 7 rewrite.
    let container: CKContainer
    let publicDB: CKDatabase

    /// Owned zones. The inbox zone this device owns lives here, and the partner writes
    /// into it as a share participant.
    let privateDB: CKDatabase

    /// The partner's inbox zone appears here once their share is accepted. Outgoing
    /// alerts are written into it.
    let sharedDB: CKDatabase

    private init() {
        self.container = CKContainer(identifier: Constants.cloudKitContainerID)
        self.publicDB = container.publicCloudDatabase
        self.privateDB = container.privateCloudDatabase
        self.sharedDB = container.sharedCloudDatabase
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

    /// The inbox zone this device owns — where the partner's alerts to us land.
    static var inboxZoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: Constants.Zone.inbox, ownerName: CKCurrentUserDefaultName)
    }

    /// Which database a zone is reached through. Our own inbox zone is in the private
    /// database; the partner's, which we joined by accepting their share, is in the
    /// shared one. `CKCurrentUserDefaultName` is the owner name CloudKit gives a zone
    /// this account owns, so it is the discriminator.
    func database(for zoneID: CKRecordZone.ID) -> CKDatabase {
        zoneID.ownerName == CKCurrentUserDefaultName ? privateDB : sharedDB
    }

    /// Alerts we send are written into the *partner's* inbox zone, so their device sees
    /// the change in its own private database. Ours is the mirror image: what arrives
    /// for us lands in the zone we own.
    @discardableResult
    func sendAlert(pair: PairState, message: String, critical: Bool) async throws -> AlertRecord {
        guard let zone = pair.outgoingZone else { throw AttentionError.pairIncomplete }

        let record = CKRecord(recordType: Constants.RecordType.alert,
                              recordID: CKRecord.ID(recordName: UUID().uuidString, zoneID: zone.zoneID))
        record[Constants.AlertField.senderDeviceID] = pair.myDeviceID as CKRecordValue
        record[Constants.AlertField.state] = Constants.AlertState.sent.rawValue as CKRecordValue
        record[Constants.AlertField.critical] = (critical ? 1 : 0) as CKRecordValue
        try AlertRecord.seal(name: pair.myName, message: message, ackEmoji: nil,
                             into: record, pairKey: pair.pairKey)

        let saved = try await sharedDB.save(record)
        guard let model = AlertRecord(record: saved, pairKey: pair.pairKey) else {
            throw AttentionError.malformedRecord
        }
        return model
    }

    func markAlertSeen(recordID: CKRecord.ID, pair: PairState) async throws -> AlertRecord {
        let db = database(for: recordID.zoneID)
        let record = try await db.record(for: recordID)
        record[Constants.AlertField.state] = Constants.AlertState.seen.rawValue as CKRecordValue
        record[Constants.AlertField.seenAt] = Date() as CKRecordValue
        let saved = try await db.save(record)
        guard let model = AlertRecord(record: saved, pairKey: pair.pairKey) else {
            throw AttentionError.malformedRecord
        }
        return model
    }

    /// Idempotent: a second call on an already-acked Alert leaves the record alone.
    ///
    /// The companion `Ack` record is gone. It existed only because the *public*
    /// database rejects a visible push on `firesOnRecordUpdate`, so the sender's banner
    /// had to be triggered by a creation instead. Private-database subscriptions carry
    /// no such restriction — the spike confirmed a visible push on update, rendered with
    /// the app force-quit — so the Alert update now does both jobs and acknowledging
    /// costs one write instead of two.
    func acknowledgeAlert(recordID: CKRecord.ID, emoji: String?, pair: PairState) async throws -> AlertRecord {
        let db = database(for: recordID.zoneID)
        let record = try await db.record(for: recordID)
        let alreadyAcked = (record[Constants.AlertField.state] as? String) == Constants.AlertState.acknowledged.rawValue

        let saved: CKRecord
        if alreadyAcked {
            saved = record
        } else {
            record[Constants.AlertField.state] = Constants.AlertState.acknowledged.rawValue as CKRecordValue
            record[Constants.AlertField.acknowledgedAt] = Date() as CKRecordValue
            if let emoji {
                record[Constants.AlertField.ackEmojiSealed] =
                    try PairCrypto.seal(emoji, pairKey: pair.pairKey,
                                        field: Constants.AlertField.ackEmojiSealed) as CKRecordValue
            }
            saved = try await db.save(record)
        }
        guard let model = AlertRecord(record: saved, pairKey: pair.pairKey) else {
            throw AttentionError.malformedRecord
        }
        return model
    }

    func fetchAlert(recordID: CKRecord.ID, pair: PairState) async throws -> AlertRecord {
        let record = try await database(for: recordID.zoneID).record(for: recordID)
        guard let model = AlertRecord(record: record, pairKey: pair.pairKey) else {
            throw AttentionError.malformedRecord
        }
        return model
    }

    /// Newest alert the partner sent us — everything in the zone we own arrived from
    /// them, so the zone itself is the filter the `senderDeviceID` predicate used to be.
    func fetchMostRecentIncoming(pair: PairState) async throws -> AlertRecord? {
        try await newestAlert(in: Self.inboxZoneID, pair: pair)
    }

    /// Newest alert we sent, read back out of the partner's zone so their seen/ack
    /// updates to it are visible.
    func fetchMostRecentOutgoing(pair: PairState) async throws -> AlertRecord? {
        guard let zone = pair.outgoingZone else { return nil }
        return try await newestAlert(in: zone.zoneID, pair: pair)
    }

    private func newestAlert(in zoneID: CKRecordZone.ID, pair: PairState) async throws -> AlertRecord? {
        let query = CKQuery(recordType: Constants.RecordType.alert, predicate: NSPredicate(value: true))
        query.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let (results, _) = try await database(for: zoneID)
            .records(matching: query, inZoneWith: zoneID, resultsLimit: 1)
        for (_, result) in results {
            if case .success(let record) = result {
                return AlertRecord(record: record, pairKey: pair.pairKey)
            }
        }
        return nil
    }

    /// Recent alerts in both directions, newest first. Used by the history view.
    /// Read-only; malformed records are skipped rather than failing the whole fetch.
    /// A failure to read one zone doesn't hide the other — half the history beats none.
    func fetchRecentAlerts(pair: PairState, limit: Int = 30) async throws -> [AlertRecord] {
        var zones = [Self.inboxZoneID]
        if let outgoing = pair.outgoingZone {
            zones.append(outgoing.zoneID)
        }

        var alerts: [AlertRecord] = []
        for zoneID in zones {
            let query = CKQuery(recordType: Constants.RecordType.alert, predicate: NSPredicate(value: true))
            query.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            do {
                let (results, _) = try await database(for: zoneID)
                    .records(matching: query, inZoneWith: zoneID, resultsLimit: limit)
                alerts += results.compactMap { _, result in
                    guard case .success(let record) = result else { return nil }
                    return AlertRecord(record: record, pairKey: pair.pairKey)
                }
            } catch {
                log.error("history fetch failed for one zone: \(String(describing: error), privacy: .public)")
            }
        }
        return alerts.sorted { $0.createdAt > $1.createdAt }
    }

    /// The pre-2.0 public-database history, read once by `LegacyHistoryCapture` before
    /// the cutover strands it. Parsed with no pair key because those records predate
    /// encryption — their fields are plaintext, which is the problem 2.0 exists to fix.
    func fetchLegacyPublicAlerts(pairKey: String, limit: Int) async throws -> [AlertRecord] {
        let predicate = NSPredicate(format: "%K == %@", Constants.AlertField.pairKey, pairKey)
        let query = CKQuery(recordType: Constants.RecordType.alert, predicate: predicate)
        query.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let (results, _) = try await publicDB.records(matching: query, resultsLimit: limit)
        return results.compactMap { _, result in
            guard case .success(let record) = result else { return nil }
            return AlertRecord(record: record, pairKey: nil)
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
        let predicate = SubscriptionPredicates.incomingAlerts(pairKey: pairKey, myDeviceID: myDeviceID)
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
        let predicate = SubscriptionPredicates.pairUpdates(pairKey: pairKey)
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
        let predicate = SubscriptionPredicates.outgoingStatus(pairKey: pairKey, myDeviceID: myDeviceID)
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
        let predicate = SubscriptionPredicates.outgoingAck(pairKey: pairKey, myDeviceID: myDeviceID)
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
    case inviteCleanupFailed
    case shareUnavailable
    case shareNotAccepted
    case pairIncomplete

    var errorDescription: String? {
        switch self {
        case .pairAlreadyJoined: return "That pairing code is already in use by another device."
        case .pairNotFound:      return "Couldn't find that pairing code. Ask the other phone to show it again."
        case .malformedRecord:   return "Got an unexpected response from iCloud."
        case .noPair:            return "This phone isn't paired yet."
        case .iCloudUnavailable: return "Sign in to iCloud in Settings to use Attention."
        case .inviteCleanupFailed: return "Couldn't clean up the previous invite. Check your connection and try again."
        case .shareUnavailable:  return "That pairing link is no longer valid. Ask the other phone to show a new one."
        case .shareNotAccepted:  return "Couldn't finish connecting to the other phone. Check your connection and try again."
        case .pairIncomplete:    return "Still finishing setup with the other phone. Try again in a moment."
        }
    }
}
