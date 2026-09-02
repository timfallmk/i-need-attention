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
        let zoneID = CKRecordZone.ID(zoneName: Constants.Zone.inbox, ownerName: CKCurrentUserDefaultName)
        _ = try await privateDB.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
        return zoneID
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
