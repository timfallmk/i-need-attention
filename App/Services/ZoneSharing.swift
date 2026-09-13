import CloudKit
import Foundation

/// What `CloudKitService.resolveInboxZone` found.
///
/// Three answers rather than an optional, because "we never had one" and "we had one and
/// it is gone" call for opposite handling: the first waits, the second ends a pairing.
enum InboxZoneResolution {
    /// The zone this device should use. Already adopted and persisted if it was found
    /// rather than already known.
    case resolved(CKRecordZone.ID)

    /// This device has a zone name and the account has no such zone. Another device
    /// signed into this Apple ID ended the pairing and took the zone with it (or an
    /// erase did). Whoever holds a `PairState` has to let it go.
    case vanished

    /// No name stored and nothing adoptable. A fresh install on an account with no
    /// pairing, or a second device whose pair key has not synced yet — indistinguishable
    /// from here, and both answered by trying again later.
    case absent
}

/// Zone and share plumbing for the 2.0 inbox model.
///
/// Each device owns one zone in its own private database and shares it with the
/// partner, who writes alerts into it. Two shares are needed for symmetry, but only
/// the first is user-visible: once the joiner accepts it they are a read-write
/// participant in the inviter's zone, so the second share travels over that channel
/// rather than over a second QR code.
///
/// Everything here is the mechanism, not the handshake — sequencing the two shares is
/// `PairingService`'s job.
extension CloudKitService {

    /// What listing this account's zones says about the inbox this device should be
    /// using. Three answers, because two of the three are things a caller has to act on
    /// rather than shrug at.
    ///
    /// The private database is per *account*, not per install, so a second device signed
    /// into the same Apple ID is looking at a database that may already contain the zone
    /// it needs — and a first device is looking at one another device can delete out
    /// from under it.
    func resolveInboxZone() async throws -> InboxZoneResolution {
        if let stored = InboxZone.storedName, ensuredZones.contains(stored) {
            return .resolved(Self.zoneID(named: stored))
        }

        let owned = Set(try await privateDB.allRecordZones().map(\.zoneID.zoneName))

        if let stored = InboxZone.storedName {
            // The ordinary case, and every install that exists today: we know our name
            // and the server agrees it exists. One list call per launch, then the cache.
            guard !owned.contains(stored) else {
                ensuredZones.insert(stored)
                return .resolved(Self.zoneID(named: stored))
            }
            // We have a name and the account does not have that zone. Deliberately not
            // "look for another one to adopt": if this device holds a pairing, that
            // pairing is over — ended from another device on this account — and the zone
            // sitting there instead may well belong to whatever pairing replaced it.
            // Adopting it would leave a `PairState` naming one partner and a zone
            // belonging to another. The caller ends the pairing first; adoption then
            // happens on a later pass, from a clean slate.
            return .vanished
        }

        // Nothing stored, so nothing has been lost and there is nothing to end. Either a
        // fresh install on an account that already pairs — the second-device case — or
        // one whose pair key has not arrived yet, which reads the same and is retried.
        guard let adopted = await adoptableInboxZone(among: owned) else { return .absent }
        InboxZone.adopt(adopted)
        ensuredZones.insert(adopted)
        log.notice("adopted inbox zone owned by another device on this account")
        return .resolved(Self.zoneID(named: adopted))
    }

    /// The zone this device owns, creating one if this account has none to resolve.
    /// Creating an existing zone is a no-op, so this is safe to call repeatedly.
    @discardableResult
    func ensureInboxZone() async throws -> CKRecordZone.ID {
        switch try await resolveInboxZone() {
        case .resolved(let zoneID):
            return zoneID
        case .vanished:
            // Reusing the vanished name would be the one thing per-pairing names exist
            // to stop. The zone is empty today, but the invariant is "a name is never
            // reused across pairings", not "it is usually harmless".
            InboxZone.rotate()
        case .absent:
            break
        }

        let zoneID = Self.inboxZoneID
        _ = try await privateDB.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
        ensuredZones.insert(zoneID.zoneName)
        return zoneID
    }

    /// Which of this account's zones, if any, a second device may take over.
    ///
    /// Not "it carries the prefix". `tearDownInboxZone` rotates the stored name whether
    /// or not the zone delete succeeded — deliberately, since the old name is what the
    /// next pairing would otherwise reuse — so a failed delete leaves an orphaned
    /// prefixed zone in the account. Adopting one of those by prefix would hand the
    /// previous partner's records to the next partner's share, which is the exact leak
    /// per-pairing zone names exist to prevent.
    ///
    /// So the test is cryptographic: the zone must hold a `PairProfile` that opens under
    /// the pair key this account currently has. `unpair` drops that key and a
    /// synchronizable delete propagates, so after an unpair nothing is adoptable; a zone
    /// from an earlier pairing is sealed under a key that no longer exists and fails the
    /// same test. What passes is a zone belonging to the pairing this account is in now.
    ///
    /// A zone mid-handshake has no profile yet — the partner writes it — so it is not
    /// adoptable until the pairing completes. A second device that launches into that
    /// window simply finds nothing and picks the zone up on a later foreground.
    ///
    /// Sorted and first-match so that two devices running this seconds apart reach the
    /// same answer: agreeing matters more than which one is picked. Losers are left
    /// alone rather than deleted, because deleting a zone deletes its share with it.
    private func adoptableInboxZone(among owned: Set<String>) async -> String? {
        guard let pairKey = PairSecrets.store.secret(for: Constants.Keychain.pairKeyAccount) else {
            return nil
        }
        for name in owned.filter({ $0.hasPrefix(InboxZone.namePrefix) }).sorted() {
            let recordID = CKRecord.ID(recordName: Constants.Profile.recordName,
                                       zoneID: Self.zoneID(named: name))
            guard let record = try? await privateDB.record(for: recordID),
                  PairCrypto.opened(record[Constants.Profile.nameSealed] as? Data,
                                    pairKey: pairKey,
                                    field: Constants.Profile.nameSealed) != nil else {
                continue
            }
            return name
        }
        return nil
    }

    static func zoneID(named name: String) -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: name, ownerName: CKCurrentUserDefaultName)
    }

    /// Deletes the inbox zone and everything in it, ending the partner's access to
    /// every record it holds. Callers archive first — see `AppState.unpair`.
    func deleteInboxZone() async throws {
        let zoneID = Self.inboxZoneID
        _ = try await privateDB.modifyRecordZones(saving: [], deleting: [zoneID])
        ensuredZones.forget(zoneID.zoneName)
    }

    /// Fetch-or-create the zone-wide share on this device's inbox zone.
    ///
    /// A zone holds exactly one zone-wide share, at the reserved record name
    /// `CKRecordNameZoneWideShare` — inserting a second returns "record to insert
    /// already exists", which is what the spike hit before it started fetching first.
    ///
    /// `publicPermission` decides which half of the handshake this is. The inviter's
    /// share is `.readWrite`, so the bearer URL in the QR code is enough to join: the
    /// inviter has no way to name the joiner's iCloud identity, and neither user ever
    /// types the other's Apple ID. The joiner's share back is `.none` with the inviter
    /// invited by `userRecordID`, which they learn from the first share's owner — so
    /// only one bearer token ever exists.
    /// Callers pairing a partner by identity must pass `participantUserRecordID`: a
    /// `.none` share with no participant is one nobody can ever accept.
    func inboxShare(publicPermission: CKShare.ParticipantPermission = .readWrite,
                    inviting participantUserRecordID: CKRecord.ID? = nil) async throws -> CKShare {
        let zoneID = try await ensureInboxZone()
        let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)

        if let existing = try? await privateDB.record(for: shareID) as? CKShare {
            return existing
        }

        let share = CKShare(recordZoneID: zoneID)
        share[CKShare.SystemFieldKey.title] = "Attention" as CKRecordValue
        share.publicPermission = publicPermission

        if let participantUserRecordID {
            let invitee = try await container.shareParticipant(forUserRecordID: participantUserRecordID)
            invitee.permission = .readWrite
            share.addParticipant(invitee)
        }

        let (saved, _) = try await privateDB.modifyRecords(saving: [share], deleting: [])
        guard case .success(let record)? = saved[shareID], let stored = record as? CKShare else {
            throw AttentionError.shareUnavailable
        }
        return stored
    }

    /// Accepts a share from a URL this app extracted itself, rather than letting the
    /// system route an `icloud.com` tap. The spike confirmed this is headless — no
    /// consent sheet — which is what keeps the second half of the handshake invisible.
    ///
    /// Returns the accepted zone's ID *in the shared database*, which is where outgoing
    /// alerts get written, and the owner's identity, which is how the joiner invites
    /// the inviter back without a second bearer token.
    func acceptShare(at url: URL) async throws -> (zoneID: CKRecordZone.ID, owner: CKRecord.ID?) {
        let metadata = try await shareMetadata(for: url)
        let share = try await accept(metadata)
        return (share.recordID.zoneID, metadata.ownerIdentity.userRecordID)
    }

    private func shareMetadata(for url: URL) async throws -> CKShare.Metadata {
        try await withCheckedThrowingContinuation { continuation in
            let operation = CKFetchShareMetadataOperation(shareURLs: [url])
            // The zone-wide share has no root record to fetch, and asking for one is a
            // wasted round trip.
            operation.shouldFetchRootRecord = false

            var fetched: Result<CKShare.Metadata, Error>?
            operation.perShareMetadataResultBlock = { _, result in fetched = result }
            // Resume only here: the per-share block can fire before the operation ends.
            operation.fetchShareMetadataResultBlock = { result in
                switch (result, fetched) {
                case (.failure(let error), _):        continuation.resume(throwing: error)
                case (.success, .success(let value)): continuation.resume(returning: value)
                case (.success, .failure(let error)): continuation.resume(throwing: error)
                case (.success, nil):                 continuation.resume(throwing: AttentionError.shareUnavailable)
                }
            }
            container.add(operation)
        }
    }

    private func accept(_ metadata: CKShare.Metadata) async throws -> CKShare {
        try await withCheckedThrowingContinuation { continuation in
            let operation = CKAcceptSharesOperation(shareMetadatas: [metadata])

            var accepted: Result<CKShare, Error>?
            operation.perShareResultBlock = { _, result in accepted = result }
            operation.acceptSharesResultBlock = { result in
                switch (result, accepted) {
                case (.failure(let error), _):        continuation.resume(throwing: error)
                case (.success, .success(let share)): continuation.resume(returning: share)
                case (.success, .failure(let error)): continuation.resume(throwing: error)
                case (.success, nil):                 continuation.resume(throwing: AttentionError.shareNotAccepted)
                }
            }
            container.add(operation)
        }
    }
}

/// What the partner has told us about themselves, read out of the zone we own.
struct PartnerProfile {
    let deviceID: String
    /// Nil when the partner is still on a build that does not write it. That is what
    /// keeps `PairState.partnerUserID` nil and the comparison on device IDs, which is
    /// correct for a partner who by definition has only one device on that build.
    let userID: String?
    let name: String
    /// Set only on the joiner's first write, carrying the share of their zone back.
    let shareURL: URL?
    /// When they finished archiving their pre-2.0 history, or nil if they haven't.
    let legacyHistoryCapturedAt: Date?
}

// MARK: - Profile records

extension CloudKitService {

    /// What we tell the partner about ourselves, written into the zone they own. Only an
    /// accepted share participant can write there, which is why the inviter can treat the
    /// first one that appears as proof its own share was accepted.
    ///
    /// `shareURL` is set only on the joiner's first write, where it carries the share of
    /// their zone back. A rename later is the same record with the same record name, so
    /// it replaces rather than accumulates.
    func writeProfile(into zoneID: CKRecordZone.ID,
                      deviceID: String,
                      name: String,
                      shareURL: URL?,
                      pairKey: String) async throws {
        let userID = await currentUserID()
        let db = database(for: zoneID)
        let recordID = CKRecord.ID(recordName: Constants.Profile.recordName, zoneID: zoneID)
        // Fetch-then-modify rather than a blind save: a retry after a partial failure, or
        // any rename after the first write, would otherwise fail with "record to insert
        // already exists".
        let record = (try? await db.record(for: recordID))
            ?? CKRecord(recordType: Constants.RecordType.profile, recordID: recordID)

        record[Constants.Profile.deviceID] = deviceID as CKRecordValue
        // Every profile write carries it, not just the first: this is how a pairing made
        // before per-account identity learns it, without a migration step or a version
        // check. A rename is enough, and so is the profile write at the end of pairing.
        if let userID {
            record[Constants.Profile.userID] = userID as CKRecordValue
        }
        record[Constants.Profile.nameSealed] =
            try PairCrypto.seal(name, pairKey: pairKey, field: Constants.Profile.nameSealed) as CKRecordValue
        if let shareURL {
            record[Constants.Profile.shareURLSealed] =
                try PairCrypto.seal(shareURL.absoluteString, pairKey: pairKey,
                                    field: Constants.Profile.shareURLSealed) as CKRecordValue
        }
        _ = try await db.save(record)
    }

    /// Records that this device has finished archiving its pre-2.0 history, by stamping
    /// the profile it keeps in the partner's zone. Their device reads it before deleting
    /// the shared public records — see `purgeLegacyPublicRecords`.
    ///
    /// Fetch-then-modify so it never clobbers the name or share URL already there, and a
    /// no-op if the profile hasn't been written yet: pairing writes it, and nothing can
    /// be purged before that anyway.
    func markLegacyHistoryCaptured(in zoneID: CKRecordZone.ID, at date: Date = Date()) async throws {
        let db = database(for: zoneID)
        let recordID = CKRecord.ID(recordName: Constants.Profile.recordName, zoneID: zoneID)
        guard let record = try? await db.record(for: recordID) else { return }
        guard record[Constants.Profile.legacyHistoryCapturedAt] == nil else { return }

        record[Constants.Profile.legacyHistoryCapturedAt] = date as CKRecordValue
        _ = try await db.save(record)
    }

    /// The partner's profile, read out of the zone we own. Returns nil while they haven't
    /// written one — which for the inviter is the whole time an invite is outstanding.
    func fetchPartnerProfile(pairKey: String) async -> PartnerProfile? {
        let zoneID = Self.inboxZoneID
        let recordID = CKRecord.ID(recordName: Constants.Profile.recordName, zoneID: zoneID)
        guard let record = try? await privateDB.record(for: recordID),
              let deviceID = record[Constants.Profile.deviceID] as? String else {
            return nil
        }

        // Written by the partner, so it gets the same bounds as any other name off the
        // wire — decryption proves they held the pair key, not that they were sensible.
        let name = UntrustedText.name(
            PairCrypto.opened(record[Constants.Profile.nameSealed] as? Data,
                              pairKey: pairKey, field: Constants.Profile.nameSealed),
            fallback: "Friend"
        )
        let shareURL = PairCrypto.opened(record[Constants.Profile.shareURLSealed] as? Data,
                                         pairKey: pairKey, field: Constants.Profile.shareURLSealed)
            .flatMap(URL.init(string:))
            .flatMap { $0.isCloudKitShare ? $0 : nil }
        return PartnerProfile(
            deviceID: deviceID,
            userID: record[Constants.Profile.userID] as? String,
            name: name,
            shareURL: shareURL,
            legacyHistoryCapturedAt: record[Constants.Profile.legacyHistoryCapturedAt] as? Date
        )
    }

    /// The partner's zone in our *shared* database, together with what a previous device
    /// on this account told them about us.
    ///
    /// For a second device joining an existing pairing this is the other half of
    /// `resolveInboxZone`: that one finds where alerts arrive, this one finds where they
    /// are sent. No share needs accepting — acceptance is recorded per account, so the
    /// first device's acceptance already put the partner's zone in this database.
    ///
    /// The profile read back is the one *we* wrote into their zone, so it carries the
    /// name and the device identifier the partner already knows this person by. Taking
    /// both from there rather than from this install is what keeps the pairing looking
    /// like one person: the partner matches incoming alerts against a single
    /// `senderDeviceID`, and a newcomer that introduced itself with its own would have
    /// its alerts silently dropped on their side.
    ///
    /// Same adoptability rule as the inbox zone, for the same reason: a zone whose
    /// profile will not open under the current pair key belongs to a pairing that is
    /// over, and sorted-first keeps two devices in agreement.
    func adoptableOutgoingZone(pairKey: String) async -> (zoneID: CKRecordZone.ID,
                                                          myName: String,
                                                          myDeviceID: String,
                                                          myUserID: String?)? {
        guard let zones = try? await sharedDB.allRecordZones() else { return nil }
        for zone in zones.map(\.zoneID).sorted(by: { $0.zoneName < $1.zoneName }) {
            let recordID = CKRecord.ID(recordName: Constants.Profile.recordName, zoneID: zone)
            guard let record = try? await sharedDB.record(for: recordID),
                  let deviceID = record[Constants.Profile.deviceID] as? String,
                  let name = PairCrypto.opened(record[Constants.Profile.nameSealed] as? Data,
                                               pairKey: pairKey,
                                               field: Constants.Profile.nameSealed) else {
                continue
            }
            return (zone, UntrustedText.name(name), deviceID,
                    record[Constants.Profile.userID] as? String)
        }
        return nil
    }

    /// Whether anyone has accepted this device's share — i.e. whether the partner can
    /// write into our inbox zone. The share's participants are the source of truth;
    /// `PairState.partnerCanReach` is only a cache of this.
    func partnerHasAcceptedInboxShare() async -> Bool {
        // Fetched directly rather than through `inboxShare()`, which is fetch-or-create
        // and defaults to `publicPermission: .readWrite`. Reached from the foreground
        // reconcile, that would mint a *bearer* share on the zone holding this pair's
        // alerts whenever one happened to be missing — and on the joiner's device it
        // would replace a `.none` share naming one participant with a link anyone
        // holding the URL could accept. A question about the world must not change it.
        //
        // No share means nobody has accepted one, which is the honest answer to the
        // question being asked.
        let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: Self.inboxZoneID)
        guard let share = try? await privateDB.record(for: shareID) as? CKShare else { return false }
        return share.participants.contains {
            $0.role != .owner && $0.acceptanceStatus == .accepted
        }
    }

    /// Revokes the outstanding bearer link by deleting the zone-wide share. Used when an
    /// invite is cancelled or renewed — otherwise the old QR code would keep working —
    /// and before minting a share for a new partner, since `inboxShare` returns an
    /// existing share as it stands and would never add the new participant to it.
    ///
    /// Not atomic, so deleting a share that was never created reports a per-record
    /// failure that this ignores rather than throwing. Callers treat a throw as "the
    /// old link may still be live", which a missing share is not.
    func revokeInboxShare() async throws {
        let zoneID = Self.inboxZoneID
        let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
        _ = try await privateDB.modifyRecords(saving: [], deleting: [shareID],
                                              savePolicy: .ifServerRecordUnchanged,
                                              atomically: false)
    }
}
