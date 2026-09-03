import CloudKit
import Foundation

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

    /// The zone this device owns. Creating an existing zone is a no-op, so this is safe
    /// to call on every launch.
    @discardableResult
    func ensureInboxZone() async throws -> CKRecordZone.ID {
        let zoneID = Self.inboxZoneID
        // Creating a zone that exists is a no-op server-side, but it is still a round
        // trip, and the handshake makes this call seven times. Once per launch is enough.
        if ensuredZones.contains(zoneID.zoneName) { return zoneID }
        _ = try await privateDB.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
        ensuredZones.insert(zoneID.zoneName)
        return zoneID
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
        let db = database(for: zoneID)
        let recordID = CKRecord.ID(recordName: Constants.Profile.recordName, zoneID: zoneID)
        // Fetch-then-modify rather than a blind save: a retry after a partial failure, or
        // any rename after the first write, would otherwise fail with "record to insert
        // already exists".
        let record = (try? await db.record(for: recordID))
            ?? CKRecord(recordType: Constants.RecordType.profile, recordID: recordID)

        record[Constants.Profile.deviceID] = deviceID as CKRecordValue
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
            name: name,
            shareURL: shareURL,
            legacyHistoryCapturedAt: record[Constants.Profile.legacyHistoryCapturedAt] as? Date
        )
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
