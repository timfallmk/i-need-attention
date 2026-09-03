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

    /// Zone names this process has already created. `ensureInboxZone` is called from
    /// seven places across a single pairing handshake — three times in `startInviting`,
    /// four in `completePairing` — and each call was a full `modifyRecordZones` round
    /// trip against a zone that demonstrably already existed. That is most of why the
    /// handshake felt slow. Held behind a lock rather than left bare: this type is
    /// `@unchecked Sendable` precisely because it had no shared mutable state, and this
    /// is the one piece it now has.
    let ensuredZones = EnsuredZones()

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

    /// The inbox zone this device owns — where the partner's alerts to us land. The
    /// name is per-pairing (see `InboxZone`), so this is a lookup rather than a constant.
    static var inboxZoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: InboxZone.currentName, ownerName: CKCurrentUserDefaultName)
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
        await postStatusNotice(pair: pair, alert: recordID, state: .seen, emoji: nil)
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
        // Deliberately after the update and deliberately not gated on `alreadyAcked`:
        // a previous call that saved the Alert but failed to post the notice would
        // otherwise leave the sender with no banner and no way to get one.
        await postStatusNotice(pair: pair, alert: recordID, state: .acknowledged, emoji: emoji)
        return model
    }

    /// Tells the sender what we did with their alert, by writing into the zone *they*
    /// own — the only place a push we control can originate from. Best effort: the
    /// Alert record already carries the truth, so a failure here costs the banner, not
    /// the state, and the sender still reconciles on next foreground.
    ///
    /// No-ops for a record that isn't in our own zone, which means it isn't an incoming
    /// alert and has no sender to notify.
    private func postStatusNotice(pair: PairState,
                                  alert recordID: CKRecord.ID,
                                  state: Constants.AlertState,
                                  emoji: String?) async {
        guard recordID.zoneID.ownerName == CKCurrentUserDefaultName,
              let senderZone = pair.outgoingZone else { return }

        let noticeID = CKRecord.ID(
            recordName: Constants.AlertStatusField.recordName(for: recordID.recordName),
            zoneID: senderZone.zoneID
        )
        let notice = (try? await sharedDB.record(for: noticeID))
            ?? CKRecord(recordType: Constants.RecordType.alertStatus, recordID: noticeID)
        notice[Constants.AlertStatusField.alertRecordName] = recordID.recordName as CKRecordValue
        notice[Constants.AlertStatusField.state] = state.rawValue as CKRecordValue
        do {
            if let emoji, !emoji.isEmpty {
                notice[Constants.AlertStatusField.ackEmojiSealed] =
                    try PairCrypto.seal(emoji, pairKey: pair.pairKey,
                                        field: Constants.AlertStatusField.ackEmojiSealed) as CKRecordValue
            }
            _ = try await sharedDB.save(notice)
        } catch {
            log.error("status notice failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Reads a status notice the partner left in our zone. Used by the push handler,
    /// which is given the notice's record ID and needs to know which alert it answers.
    func fetchStatusNotice(recordID: CKRecord.ID,
                           pair: PairState) async -> (alertRecordName: String, state: Constants.AlertState, emoji: String?)? {
        guard let record = try? await privateDB.record(for: recordID),
              let alertRecordName = record[Constants.AlertStatusField.alertRecordName] as? String,
              let raw = record[Constants.AlertStatusField.state] as? String,
              let state = Constants.AlertState(rawValue: raw) else {
            return nil
        }
        let emoji = UntrustedText.emoji(
            PairCrypto.opened(record[Constants.AlertStatusField.ackEmojiSealed] as? Data,
                              pairKey: pair.pairKey,
                              field: Constants.AlertStatusField.ackEmojiSealed)
        )
        return (alertRecordName, state, emoji)
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
                let records = try await allRecords(matching: query, in: zoneID,
                                                   from: database(for: zoneID), limit: limit)
                alerts += records.compactMap { AlertRecord(record: $0, pairKey: pair.pairKey) }
            } catch {
                log.error("history fetch failed for one zone: \(String(describing: error), privacy: .public)")
            }
        }
        // Each zone was queried with the full limit, so trim after merging — otherwise
        // "30 most recent" would quietly mean up to 60.
        return Array(alerts.sorted { $0.createdAt > $1.createdAt }.prefix(limit))
    }

    /// The pre-2.0 public-database history, read once by `LegacyHistoryCapture` before
    /// the cutover strands it. Parsed with no pair key because those records predate
    /// encryption — their fields are plaintext, which is the problem 2.0 exists to fix.
    func fetchLegacyPublicAlerts(pairKey: String, limit: Int) async throws -> [AlertRecord] {
        let predicate = NSPredicate(format: "%K == %@", Constants.AlertField.pairKey, pairKey)
        let query = CKQuery(recordType: Constants.RecordType.alert, predicate: predicate)
        query.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let records = try await allRecords(matching: query, in: nil, from: publicDB, limit: limit)
        return records.compactMap { AlertRecord(record: $0, pairKey: nil) }
    }

    /// Follows the query cursor until the results run out or `limit` is reached.
    ///
    /// `resultsLimit` is a ceiling, not a quota: CloudKit decides how much to return per
    /// page and hands back a cursor whenever there is more, so a single call routinely
    /// comes back short even when the limit is nowhere near hit. Discarding that cursor
    /// silently truncates — which is how a pre-2.0 capture could report a few dozen
    /// alerts, look complete, and then have the originals purged out from under the rest.
    private func allRecords(matching query: CKQuery,
                            in zoneID: CKRecordZone.ID?,
                            from database: CKDatabase,
                            limit: Int) async throws -> [CKRecord] {
        var collected: [CKRecord] = []
        var cursor: CKQueryOperation.Cursor?

        repeat {
            let remaining = limit - collected.count
            guard remaining > 0 else { break }
            let page = try await {
                if let cursor {
                    return try await database.records(continuingMatchFrom: cursor, resultsLimit: remaining)
                }
                return try await database.records(matching: query, inZoneWith: zoneID, resultsLimit: remaining)
            }()
            collected += page.matchResults.compactMap { _, result in
                guard case .success(let record) = result else { return nil }
                return record
            }
            cursor = page.queryCursor
        } while cursor != nil

        return collected
    }

    /// Deletes this pair's pre-2.0 records from the public database, once the local
    /// archive holds them.
    ///
    /// 2.0 stops new data going somewhere every signed-in iCloud account can read. It
    /// does nothing by itself about what is already there — sender names, messages, and
    /// the `pairKey` on the Pair record, all in the clear, all still readable. Archiving
    /// them locally is what makes deleting them safe rather than destructive.
    ///
    /// Scoped by `pairKey`, so it only ever touches records this pair wrote. Both
    /// devices will attempt it; whoever gets there second finds nothing and is done.
    ///
    /// Returns true when a full pass found nothing left to delete. A pass that deleted
    /// something returns false whether or not more remains — the caller retries, and
    /// converging on an empty pass is cheaper than trying to count.
    @discardableResult
    func purgeLegacyPublicRecords(pairKey: String) async throws -> Bool {
        let targets: [(recordType: String, field: String)] = [
            (Constants.RecordType.alert, Constants.AlertField.pairKey),
            (Constants.RecordType.ack, Constants.AckField.pairKey),
            (Constants.RecordType.pair, Constants.PairField.pairKey)
        ]

        var deletedAnything = false
        for target in targets {
            let predicate = NSPredicate(format: "%K == %@", target.field, pairKey)
            let query = CKQuery(recordType: target.recordType, predicate: predicate)
            let (results, _) = try await publicDB.records(matching: query, resultsLimit: 200)

            let ids = results.compactMap { id, result -> CKRecord.ID? in
                guard case .success = result else { return nil }
                return id
            }
            guard !ids.isEmpty else { continue }

            // Not atomic: a record another device deleted a moment ago should not fail
            // the batch for the rest.
            _ = try await publicDB.modifyRecords(saving: [], deleting: ids,
                                                 savePolicy: .ifServerRecordUnchanged,
                                                 atomically: false)
            log.notice("Purged \(ids.count, privacy: .public) pre-2.0 \(target.recordType, privacy: .public) records")
            deletedAnything = true
        }
        return !deletedAnything
    }

    // MARK: - Subscriptions

    /// Registers (idempotently) the four query subscriptions this app needs, all of them
    /// on this device's own inbox zone in the private database:
    ///  - Incoming alerts: visible alert push when the partner sends.
    ///  - Outgoing status: silent push when the partner leaves a status notice.
    ///  - Outgoing ack: visible alert push for the notice that says they acknowledged,
    ///    so the sender sees a banner with the app force-quit.
    ///  - Pair profile: silent push when the partner introduces or renames themselves,
    ///    which is also what closes the last step of the pairing handshake.
    ///
    /// Nothing subscribes to the partner's zone. The shared database accepts only
    /// `CKDatabaseSubscription`, and those notifications name a database rather than a
    /// record — which is why the receiver writes a status notice into the sender's own
    /// zone instead of relying on the alert update being noticed.
    ///
    /// Resilient to per-subscription failure: if at least one save succeeds, partial
    /// failures are logged but not propagated, and the next launch retries the missing
    /// IDs. The failure worth surfacing is `outgoing-ack-v3` — it is the one shape the
    /// public database refused, so if a private database ever refuses it too, the
    /// Settings → Diagnostics row says so rather than the banner just never arriving.
    /// Throws only when nothing saved at all.
    func registerSubscriptions() async throws {
        let zoneID = try await ensureInboxZone()
        let existing = try await privateDB.allSubscriptions()

        // Existing is not the same as usable. The four subscription IDs are constants
        // while the zone name is per-pairing, so after a re-pair every one of these
        // still names the zone the *previous* pairing used — a zone `unpair` deleted.
        // Matching on ID alone would find them all present, save nothing, and leave a
        // pair that looks healthy and never pushes. Only a subscription watching the
        // zone we own right now counts; the rest are deleted in the same operation.
        var live = Set<String>()
        var stale: [String] = []
        for subscription in existing where Constants.SubscriptionID.all.contains(subscription.subscriptionID) {
            if let query = subscription as? CKQuerySubscription, query.zoneID == zoneID {
                live.insert(subscription.subscriptionID)
            } else {
                stale.append(subscription.subscriptionID)
            }
        }

        // If the ack subscription already lives on the server, the previously-saved
        // diagnostic flag + reason are stale — clear them so we don't keep flagging
        // a healthy install.
        if live.contains(Constants.SubscriptionID.outgoingAck) {
            SharedSettings.outgoingAckSubscriptionUnavailable = false
            SharedSettings.outgoingAckSubscriptionFailureReason = nil
        }

        var toSave: [CKSubscription] = []
        if !live.contains(Constants.SubscriptionID.incomingAlerts) {
            toSave.append(makeIncomingSubscription(zoneID: zoneID))
        }
        if !live.contains(Constants.SubscriptionID.outgoingStatus) {
            toSave.append(makeOutgoingStatusSubscription(zoneID: zoneID))
        }
        if !live.contains(Constants.SubscriptionID.outgoingAck) {
            toSave.append(makeOutgoingAckSubscription(zoneID: zoneID))
        }
        if !live.contains(Constants.SubscriptionID.pairProfile) {
            toSave.append(makePairProfileSubscription(zoneID: zoneID))
        }
        guard !toSave.isEmpty else { return }

        // Retiring the stale ones is its own operation, and has to be. A stale
        // subscription is by definition also one we are about to recreate under the same
        // ID, and CloudKit rejects that pairing outright — "You can't save and delete a
        // subscription in the same operation" — failing the whole modify atomically. The
        // first version of this fix did exactly that, so the subscriptions it existed to
        // repair stayed broken on every launch while the error scrolled past in Console.
        if !stale.isEmpty {
            try await deleteSubscriptions(stale)
        }

        let op = CKModifySubscriptionsOperation(subscriptionsToSave: toSave,
                                                subscriptionIDsToDelete: nil)
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
                        // Nothing saved means perSubscriptionSaveBlock never fired, so the
                        // ack diagnostic would otherwise still read "ok" while the very
                        // operation that registers it was failing every launch.
                        if toSave.contains(where: { $0.subscriptionID == Constants.SubscriptionID.outgoingAck }) {
                            SharedSettings.outgoingAckSubscriptionUnavailable = true
                            let raw = String(describing: error)
                            SharedSettings.outgoingAckSubscriptionFailureReason = raw.count > 500
                                ? String(raw.prefix(500)) + "…"
                                : raw
                        }
                        cont.resume(throwing: error)
                    }
                }
            }
            privateDB.add(op)
        }
    }

    /// Which of our subscriptions exist, and whether each watches the zone we own now.
    /// Best effort — this feeds the diagnostics export, which matters most precisely when
    /// CloudKit isn't working, so a failure reports "unknown" rather than blocking.
    func subscriptionStates() async -> [DiagnosticsReport.SubscriptionState] {
        let zoneID = Self.inboxZoneID
        let existing = (try? await privateDB.allSubscriptions()) ?? []
        let byID = Dictionary(
            existing.map { ($0.subscriptionID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return Constants.SubscriptionID.all.sorted().map { id in
            guard let subscription = byID[id] else {
                return DiagnosticsReport.SubscriptionState(id: id, status: .missing)
            }
            let matches = (subscription as? CKQuerySubscription)?.zoneID == zoneID
            return DiagnosticsReport.SubscriptionState(id: id, status: matches ? .ok : .staleZone)
        }
    }

    func removeAllSubscriptions() async throws {
        let existing = try await privateDB.allSubscriptions()
        try await deleteSubscriptions(existing.map(\.subscriptionID))
    }

    private func deleteSubscriptions(_ ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        let op = CKModifySubscriptionsOperation(subscriptionsToSave: nil, subscriptionIDsToDelete: ids)
        op.qualityOfService = .userInitiated
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            op.modifySubscriptionsResultBlock = { result in
                switch result {
                case .success: cont.resume()
                case .failure(let error): cont.resume(throwing: error)
                }
            }
            privateDB.add(op)
        }
    }

    // MARK: - Subscription factories

    /// The partner wrote an alert into our zone. Visible + mutable so the extension can
    /// replace the placeholder body with the decrypted one.
    ///
    /// No `desiredKeys`: the fields worth showing are ciphertext, and shipping binary in
    /// a push payload that CloudKit may truncate anyway buys nothing. The extension
    /// fetches the record, which it had to be able to do regardless.
    private func makeIncomingSubscription(zoneID: CKRecordZone.ID) -> CKQuerySubscription {
        let sub = CKQuerySubscription(
            recordType: Constants.RecordType.alert,
            predicate: SubscriptionPredicates.incomingAlerts(),
            subscriptionID: Constants.SubscriptionID.incomingAlerts,
            options: [.firesOnRecordCreation]
        )
        sub.zoneID = zoneID
        let info = CKSubscription.NotificationInfo()
        // CloudKit classifies a push as an alert push only when alertBody is non-empty,
        // and only alert pushes run the extension. This placeholder is overwritten there
        // with the real sender and message.
        info.alertBody = "Attention"
        info.shouldSendMutableContent = true
        sub.notificationInfo = info
        return sub
    }

    /// Any status notice the partner leaves — silent, so the in-app indicator flips to
    /// seen without a banner.
    private func makeOutgoingStatusSubscription(zoneID: CKRecordZone.ID) -> CKQuerySubscription {
        let sub = CKQuerySubscription(
            recordType: Constants.RecordType.alertStatus,
            predicate: SubscriptionPredicates.outgoingStatus(),
            subscriptionID: Constants.SubscriptionID.outgoingStatus,
            options: [.firesOnRecordCreation, .firesOnRecordUpdate]
        )
        sub.zoneID = zoneID
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        sub.notificationInfo = info
        return sub
    }

    /// The acknowledgement specifically — a visible banner, so the sender learns their
    /// partner answered even with the app force-quit.
    ///
    /// This is the shape the public database rejected with BAD_REQUEST: a visible push
    /// on `firesOnRecordUpdate`. Update permissions are broader than create permissions
    /// there, so it was treated as a spam vector. In a private zone the only writer is
    /// an accepted participant, and the spike confirmed the restriction doesn't apply.
    private func makeOutgoingAckSubscription(zoneID: CKRecordZone.ID) -> CKQuerySubscription {
        let sub = CKQuerySubscription(
            recordType: Constants.RecordType.alertStatus,
            predicate: SubscriptionPredicates.outgoingAck(),
            subscriptionID: Constants.SubscriptionID.outgoingAck,
            options: [.firesOnRecordCreation, .firesOnRecordUpdate]
        )
        sub.zoneID = zoneID
        let info = CKSubscription.NotificationInfo()
        info.alertBody = "Attention"
        info.shouldSendMutableContent = true
        sub.notificationInfo = info
        return sub
    }

    /// The partner introducing themselves — which closes the pairing handshake — or
    /// renaming themselves later. Silent either way; both are handled in-app.
    private func makePairProfileSubscription(zoneID: CKRecordZone.ID) -> CKQuerySubscription {
        let sub = CKQuerySubscription(
            recordType: Constants.RecordType.profile,
            predicate: SubscriptionPredicates.pairProfile(),
            subscriptionID: Constants.SubscriptionID.pairProfile,
            options: [.firesOnRecordCreation, .firesOnRecordUpdate]
        )
        sub.zoneID = zoneID
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        sub.notificationInfo = info
        return sub
    }
}

/// Lock-guarded set of zone names known to exist on the server. Correctness only
/// depends on it never holding a name that *doesn't* exist, so it is populated after a
/// successful create and emptied whenever a zone is deleted.
final class EnsuredZones: @unchecked Sendable {
    private var names: Set<String> = []
    private let lock = NSLock()

    func contains(_ name: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return names.contains(name)
    }

    func insert(_ name: String) {
        lock.lock(); defer { lock.unlock() }
        names.insert(name)
    }

    func forget(_ name: String) {
        lock.lock(); defer { lock.unlock() }
        names.remove(name)
    }
}

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
    case inviteNotSaved
    case partnerIdentityUnavailable

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
        case .inviteNotSaved:    return "Couldn't save the new invite on this phone. Try again."
        case .partnerIdentityUnavailable:
            return "Couldn't identify the other phone's iCloud account. Ask them to show a fresh code and try again."
        }
    }
}
