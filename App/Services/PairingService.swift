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
            throw AttentionError.inviteNotSaved
        }

        // Best effort: the joiner's profile record landing in our zone is what completes
        // the handshake, and this is the subscription that notices. Launch and foreground
        // both reconcile without it, so a failure here costs promptness, not the pairing.
        do {
            try await cloud.registerSubscriptions()
        } catch {
            log.error("invite-time subscription registration failed: \(error.localizedDescription)")
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

        try await cloud.ensureInboxZone()
        guard let profile = await cloud.fetchPartnerProfile(pairKey: pending.pairKey),
              let theirShare = profile.shareURL else { return nil }

        let (partnerZoneID, _) = try await cloud.acceptShare(at: theirShare)

        let state = PairState(
            pairKey: pending.pairKey,
            myDeviceID: pending.myDeviceID,
            myName: pending.myName,
            partnerDeviceID: profile.deviceID,
            partnerName: profile.name,
            outgoingZone: ZoneRef(partnerZoneID),
            partnerCanReach: true
        )
        guard state.save() else { throw AttentionError.shareNotAccepted }
        PendingInvite.clear()

        // Now that we can write into their zone, tell them who we are. Without this the
        // joiner would be stuck with whatever name the invite carried, and would have no
        // record of ours to update when we rename ourselves.
        try? await cloud.writeProfile(into: partnerZoneID,
                                      deviceID: state.myDeviceID,
                                      name: state.myName,
                                      shareURL: nil,
                                      pairKey: state.pairKey)
        await stampLegacyCaptureIfSettled(zoneID: partnerZoneID)
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

        let (inviterZoneID, owner) = try await cloud.acceptShare(at: invite.shareURL)
        // Without their identity the share back would be minted with no participant and
        // no public permission — a share nobody can accept, leaving the pair silently
        // one-directional forever. Better to fail the pairing outright and be retried.
        guard let inviterUserID = owner else {
            throw AttentionError.partnerIdentityUnavailable
        }

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
        try await cloud.writeProfile(
            into: inviterZoneID,
            deviceID: DeviceIdentity.id,
            name: myName,
            shareURL: ourShareURL,
            pairKey: invite.pairKey
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
        await stampLegacyCaptureIfSettled(zoneID: inviterZoneID)
        // Idempotent by subscription ID, and needed now rather than at next launch:
        // without it the first alert the inviter sends would arrive silently.
        try? await cloud.registerSubscriptions()
        return state
    }

    /// Tells the partner we have no outstanding claim on the pre-2.0 public records, so
    /// they can purge them.
    ///
    /// A device with history of its own stamps this when its capture finishes. One with
    /// none — a fresh install, or somebody pairing with a new partner — would otherwise
    /// never stamp at all, and a partner who *does* have history would wait forever for
    /// a signal that was never coming. Nothing to archive is exactly as good as archived.
    private func stampLegacyCaptureIfSettled(zoneID: CKRecordZone.ID) async {
        guard LegacyHistoryCaptureState.load()?.phase == .done else { return }
        try? await cloud.markLegacyHistoryCaptured(in: zoneID)
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

    /// Picks up a partner who renamed themselves. Their profile record lives in the zone
    /// we own, so this is a read of our own private database — no push required, though
    /// the profile subscription makes it immediate rather than next-foreground.
    ///
    /// Returns the updated state only when the name actually changed, so callers don't
    /// write on every foreground.
    func refreshPartnerName(_ state: PairState) async -> PairState? {
        guard let profile = await cloud.fetchPartnerProfile(pairKey: state.pairKey) else { return nil }
        guard profile.deviceID == state.partnerDeviceID else { return nil }
        guard !profile.name.isEmpty, profile.name != state.partnerName else { return nil }

        var updated = state
        updated.partnerName = profile.name
        guard updated.save() else { return nil }
        return updated
    }

    /// Wipes local pairing state and tears down the zone this pairing used.
    ///
    /// The zone used to survive an unpair, on the reasoning that it held records the
    /// partner might still be reading. That was the wrong trade: a zone-wide share hands
    /// its participant the whole zone, so a surviving zone is one the *next* partner's
    /// share would hand over wholesale — every alert the previous partner sent, with the
    /// plaintext structural fields (who, when, answered, how fast) readable even though
    /// the contents stay sealed under a key they never had.
    ///
    /// So it goes, and `AppState.unpair` copies it into `PairingArchive` first. The cost
    /// is the partner's remote copy of what they sent us; their own archive is the answer
    /// to that, and it is a smaller harm than leaking a past relationship to a new one.
    func unpair() async {
        try? await cloud.removeAllSubscriptions()
        try? await cloud.revokeInboxShare()
        try? await cloud.deleteInboxZone()
        // A fresh name for whatever pairing comes next. Not `clear()` — that falls back
        // to the fixed legacy name, which is precisely the zone just deleted.
        InboxZone.rotate()
        PairState.clear()
    }
}
