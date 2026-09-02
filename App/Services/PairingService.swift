import CloudKit
import Foundation
import os.log

/// Coordinates the four-step pairing handshake. Reads and writes go through
/// `CloudKitService`; persistence lives in `PairState` / `PendingInvite`.
///
/// ```
/// 1. A taps Invite   creates zone_A + share_A; QR encodes the share URL and the key
/// 2. B scans         accepts share_A — B can now write into zone_A
///    ──────────────── machine-to-machine from here ────────────────
/// 3. B (no UI)       creates zone_B + share_B; leaves it as a record in zone_A
/// 4. A (no UI)       finds that record and accepts share_B
/// ```
///
/// Only the first share is user-visible. By step 3 the devices already have a channel,
/// so the second share travels over it rather than over a second QR code — and because
/// B knows A's identity from `share_A`'s owner, `share_B` names A directly instead of
/// being another bearer link.
///
/// Step 2 makes B→A live before A→B, so the pair is one-directional in between. That
/// window is real and is tracked, not assumed away: see `PairState.isComplete`.
@MainActor
final class PairingService {
    static let shared = PairingService()
    private let log = Logger(subsystem: "com.timfallmk.attention", category: "Pairing")
    private let cloud = CloudKitService.shared
    private init() {}

    // MARK: - Inviter

    /// Step 1. Mints a fresh secret and a fresh bearer link to this device's inbox zone,
    /// and persists both so the invite survives leaving the screen. Any previous invite
    /// is cancelled first — which revokes its share — so "renew" is just a new invite,
    /// and the old QR code stops working rather than lingering as a live credential.
    func startInviting(myName: String) async throws -> PairingInvite {
        if let previous = PendingInvite.load() {
            guard await cancelInvite(previous) else {
                throw AttentionError.inviteCleanupFailed
            }
        }

        try await cloud.ensureInboxZone()
        // A share left over from an earlier partner or invite would come back from
        // inboxShare unchanged, still carrying whoever it was minted for.
        try await cloud.revokeInboxShare()
        let share = try await cloud.inboxShare(publicPermission: .readWrite)
        guard let shareURL = share.url else {
            throw AttentionError.shareUnavailable
        }

        let invite = PairingInvite.generate(myDeviceID: DeviceIdentity.id,
                                            myName: UntrustedText.name(myName),
                                            shareURL: shareURL)
        guard PendingInvite(
            pairKey: invite.pairKey,
            myDeviceID: invite.inviterDeviceID,
            myName: invite.inviterName,
            shareURL: shareURL,
            createdAt: Date()
        ).save() else {
            throw AttentionError.inviteCleanupFailed
        }
        return invite
    }

    /// Step 4, driven by whatever notices first — the invite screen's poll, a
    /// foreground reconcile, or (from step 8) a push. Returns nil while the joiner
    /// hasn't arrived, which is the ordinary case for an outstanding invite.
    ///
    /// The handshake record can only have been written by an accepted participant in
    /// our zone, so finding one is itself proof that our share was accepted — which is
    /// why `partnerCanReach` is set without a separate check.
    @discardableResult
    func completeInviterPairing() async throws -> PairState? {
        guard let pending = PendingInvite.load() else { return nil }

        let zoneID = try await cloud.ensureInboxZone()
        guard let handshake = await cloud.fetchHandshake(in: zoneID) else { return nil }

        let (partnerZoneID, _) = try await cloud.acceptShare(at: handshake.shareURL)

        let state = PairState(
            pairKey: pending.pairKey,
            myDeviceID: pending.myDeviceID,
            myName: pending.myName,
            partnerDeviceID: handshake.deviceID,
            partnerName: handshake.name,
            outgoingZone: ZoneRef(partnerZoneID),
            partnerCanReach: true
        )
        guard state.save() else { throw AttentionError.shareNotAccepted }
        PendingInvite.clear()
        return state
    }

    /// Poll for the joiner while the invite screen is up. The reconcile path covers the
    /// case where the user leaves it.
    func waitForJoiner(timeout: TimeInterval = 120) async throws -> PairState {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if let state = try await completeInviterPairing() { return state }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        throw AttentionError.pairNotFound
    }

    /// Abandon a pending invite, revoking its share so the bearer link it published
    /// stops working. Ordering matters: the persisted invite is the retry handle, so it
    /// only clears once the revoke has actually happened. Returns false when cleanup
    /// failed and the invite was kept for another try.
    @discardableResult
    func cancelInvite(_ pending: PendingInvite) async -> Bool {
        do {
            try await cloud.revokeInboxShare()
        } catch {
            log.error("invite share revoke failed: \(error.localizedDescription)")
            return false
        }
        PendingInvite.clear()
        return true
    }

    // MARK: - Joiner

    /// Steps 2 and 3. Takes a scanned QR payload (or a tapped invite link — same wire
    /// format, same untrusted-input parser), accepts the inviter's share, then puts a
    /// share of our own zone back through the channel that just opened.
    func completePairing(payload: String, myName: String) async throws -> PairState {
        guard let invite = PairingInvite.from(qrPayload: payload) else {
            throw AttentionError.pairNotFound
        }
        // Joining someone else's pair abandons any invite we were offering ourselves —
        // and revokes its share, so a code we handed out earlier can't still be used.
        if let ownPending = PendingInvite.load() {
            guard await cancelInvite(ownPending) else {
                throw AttentionError.inviteCleanupFailed
            }
        }

        let (inviterZoneID, inviterUserID) = try await cloud.acceptShare(at: invite.shareURL)

        // share_B names the inviter rather than carrying a bearer token: their identity
        // came back with the share we just accepted. A failure to look them up would
        // otherwise leave the pair permanently one-directional, so it isn't swallowed.
        try await cloud.ensureInboxZone()
        // Same reason as the inviter side: an existing share is returned as it stands,
        // so it would never come to name this partner.
        try await cloud.revokeInboxShare()
        let ourShare = try await cloud.inboxShare(publicPermission: .none,
                                                  inviting: inviterUserID)
        guard let ourShareURL = ourShare.url else {
            throw AttentionError.shareUnavailable
        }

        let myName = UntrustedText.name(myName)
        try await cloud.writeHandshake(
            into: inviterZoneID,
            deviceID: DeviceIdentity.id,
            name: myName,
            shareURL: ourShareURL
        )

        // We can send immediately; they can't until they accept what we just left them.
        let state = PairState(
            pairKey: invite.pairKey,
            myDeviceID: DeviceIdentity.id,
            myName: myName,
            partnerDeviceID: invite.inviterDeviceID,
            partnerName: invite.inviterName,
            outgoingZone: ZoneRef(inviterZoneID),
            partnerCanReach: false
        )
        guard state.save() else { throw AttentionError.shareNotAccepted }
        return state
    }

    // MARK: - Reconciling the half-formed state

    /// Refreshes the direction this device can't observe directly. The joiner has no
    /// way to be told that the inviter accepted their share, so it asks: the share's
    /// participants are the source of truth and `partnerCanReach` is only a cache.
    ///
    /// Returns the updated state when something changed, so callers can persist it
    /// without writing on every foreground.
    func refreshPartnerReachability(_ state: PairState) async -> PairState? {
        guard !state.partnerCanReach else { return nil }
        guard await cloud.partnerHasAcceptedInboxShare() else { return nil }

        var updated = state
        updated.partnerCanReach = true
        guard updated.save() else { return nil }
        log.notice("Partner accepted our share; both directions live")
        return updated
    }

    /// Wipes local pairing state. The zone stays: it is ours, it holds records the
    /// partner may still be reading, and deleting it is a separate, louder act than
    /// unpairing this device.
    func unpair() async {
        try? await cloud.removeAllSubscriptions()
        try? await cloud.revokeInboxShare()
        PairState.clear()
    }
}
