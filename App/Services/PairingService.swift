import CloudKit
import Foundation
import os.log

/// Coordinates the two sides of the pairing handshake. Reads/writes go through
/// `CloudKitService`; persistence lives in `PairState` / `PendingInvite`.
@MainActor
final class PairingService {
    static let shared = PairingService()
    private let log = Logger(subsystem: "com.timfallmk.attention", category: "Pairing")
    private let cloud = CloudKitService.shared
    private init() {}

    /// Inviter side: generate a fresh secret, write the half-empty Pair record, return the
    /// invite the QR view should display. Also persists a `PendingInvite` and registers
    /// subscriptions under the new pairKey so the joiner's completion can reach this device
    /// via the pair-update silent push even after the Show Code screen is gone. Any previous
    /// pending invite is cancelled first, so "renew" is just starting a new invite.
    func startInviting(myName: String) async throws -> (invite: PairingInvite, record: CKRecord) {
        if let previous = PendingInvite.load() {
            await cancelInvite(previous)
        }
        let invite = PairingInvite.generate(myDeviceID: DeviceIdentity.id, myName: myName)
        let record = try await cloud.createPair(invite: invite)
        PendingInvite(
            pairKey: invite.pairKey,
            myDeviceID: invite.inviterDeviceID,
            myName: invite.inviterName,
            recordName: record.recordID.recordName,
            createdAt: Date()
        ).save()
        // Best-effort: the push is the fast path; the launch/foreground reconcile (and the
        // registration inside the completion helper) covers a failure here.
        do {
            try await cloud.registerSubscriptions(pairKey: invite.pairKey, myDeviceID: invite.inviterDeviceID)
        } catch {
            log.error("invite-time subscription registration failed: \(error.localizedDescription)")
        }
        return (invite, record)
    }

    /// Inviter side: poll the Pair record until `deviceB` is filled, or time out.
    /// Keyed by pairKey so a persisted invite can resume polling without the original record.
    func waitForJoiner(pairKey: String, timeout: TimeInterval = 120) async throws -> PairState {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if let fresh = try await cloud.fetchPair(pairKey: pairKey),
               let state = try await completeInviterPairing(from: fresh) {
                return state
            }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        throw AttentionError.pairNotFound
    }

    /// Shared inviter-side completion: if the record's joiner slot is filled, build and save
    /// the local `PairState`, register subscriptions, and clear the pending invite. Returns
    /// nil when the joiner hasn't arrived yet. Used by the Show Code poll, the pair-update
    /// push handler, and the launch/foreground reconcile.
    func completeInviterPairing(from record: CKRecord) async throws -> PairState? {
        guard let pairKey = record[Constants.PairField.pairKey] as? String,
              let deviceB = record[Constants.PairField.deviceB] as? String,
              !deviceB.isEmpty else {
            return nil
        }
        let state = PairState(
            pairKey: pairKey,
            myDeviceID: DeviceIdentity.id,
            myName: record[Constants.PairField.nameA] as? String ?? "",
            partnerDeviceID: deviceB,
            partnerName: record[Constants.PairField.nameB] as? String ?? "Friend"
        )
        state.save()
        PendingInvite.clear()
        // Idempotent by subscription ID — a no-op when the invite-time registration stuck.
        try await cloud.registerSubscriptions(pairKey: pairKey, myDeviceID: state.myDeviceID)
        return state
    }

    /// Inviter side: abandon a pending invite. Clears local state, purges the subscriptions
    /// registered under the invite's pairKey (so they can't squat on the subscription IDs a
    /// later pair needs), and deletes the half-empty Pair record. Cloud steps are
    /// best-effort — an orphaned record is unreachable without its pairKey.
    func cancelInvite(_ pending: PendingInvite) async {
        PendingInvite.clear()
        do {
            try await cloud.purgeSubscriptions(pairKey: pending.pairKey)
        } catch {
            log.error("invite subscription purge failed: \(error.localizedDescription)")
        }
        do {
            try await cloud.deletePair(recordName: pending.recordName)
        } catch {
            log.error("invite record delete failed: \(error.localizedDescription)")
        }
    }

    /// Joiner side: take a scanned QR payload (or tapped invite link — same wire format,
    /// same untrusted-input parser), validate, and complete the handshake.
    func completePairing(payload: String, myName: String) async throws -> PairState {
        guard let invite = PairingInvite.from(qrPayload: payload) else {
            throw AttentionError.pairNotFound
        }
        guard let record = try await cloud.fetchPair(pairKey: invite.pairKey) else {
            throw AttentionError.pairNotFound
        }
        let updated = try await cloud.joinPair(
            record: record,
            joinerDeviceID: DeviceIdentity.id,
            joinerName: myName
        )
        let state = PairState(
            pairKey: invite.pairKey,
            myDeviceID: DeviceIdentity.id,
            myName: myName,
            partnerDeviceID: invite.inviterDeviceID,
            partnerName: invite.inviterName
        )
        state.save()
        // also persist our own name onto the record now that we joined
        _ = updated
        try await cloud.registerSubscriptions(pairKey: invite.pairKey, myDeviceID: state.myDeviceID)
        return state
    }

    /// Wipes local pairing and CloudKit subscriptions. Doesn't delete the Pair record from
    /// the server — the other phone may still want to use it until it also unpairs.
    func unpair() async {
        try? await cloud.removeAllSubscriptions()
        PairState.clear()
    }
}
