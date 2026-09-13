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

    // MARK: - One pairing change at a time

    /// Adoption and the two pairing-start paths all rewrite the same two pieces of
    /// account-wide state — the stored inbox zone name and the pairing blob — with
    /// CloudKit awaits in between, and `@MainActor` does not stop them interleaving
    /// across those awaits. It only stops them interleaving *within* a synchronous run.
    ///
    /// The damage is specific. `adoptExistingPairing` takes the zone before it has
    /// either profile, then awaits three more round trips; a `Show Code` tap landing in
    /// that window runs `startingFreshPairing`, mints a rival zone and revokes the share
    /// the adopted pairing is using, after which adoption saves a `PairState` naming a
    /// zone that is no longer this device's — or, on its failure path, restores a name
    /// the invite has since replaced. Either way the account ends up with two zones and
    /// one set of subscriptions, which is #68 arriving by the back door.
    ///
    /// A gate rather than a cancellation: adoption that has already taken the zone has
    /// no safe point to stop at, and it is short. The invite waits for it, then starts
    /// fresh from whatever it settled on.
    ///
    /// Every method that moves the pairing between states takes it: `startInviting`,
    /// `completePairing`, `completeInviterPairing`, `cancelInvite` and
    /// `adoptExistingPairing`. An earlier version left the last two out on the reasoning
    /// that `@MainActor` and their own preconditions were enough, and that was wrong in
    /// the same way this gate exists to fix. The inviter's poll calls
    /// `completeInviterPairing`, which awaits a profile fetch and a share acceptance
    /// before it saves; a Cancel tap landing in that window deletes the zone and clears
    /// the invite, and the poll then resumes and saves a `PairState` for the pairing the
    /// user just abandoned, naming a zone that no longer exists.
    ///
    /// Not reentrant, which is why `cancelInviteLocked` exists: `startInviting` and
    /// `completePairing` cancel an outstanding invite of our own while already holding
    /// the gate, and calling the public entry point there would deadlock them.
    private var pairingChangeInProgress = false
    private var waitingForPairingChange: [CheckedContinuation<Void, Never>] = []

    private func beginPairingChange() async {
        while pairingChangeInProgress {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                waitingForPairingChange.append(continuation)
            }
        }
        pairingChangeInProgress = true
    }

    private func endPairingChange() {
        pairingChangeInProgress = false
        let waiting = waitingForPairingChange
        waitingForPairingChange.removeAll()
        for continuation in waiting { continuation.resume() }
    }

    // MARK: - Inviter

    /// Step 1. Mints a fresh secret and a fresh bearer link to this device's inbox zone,
    /// and persists both so the invite survives leaving the screen. Any previous invite
    /// is cancelled first — which revokes its share — so "renew" is just a new invite,
    /// and the old QR code stops working rather than lingering as a live credential.
    func startInviting(myName: String) async throws -> PairingInvite {
        await beginPairingChange()
        defer { endPairingChange() }

        if let previous = PendingInvite.load() {
            guard await cancelInviteLocked(previous) else {
                throw AttentionError.inviteCleanupFailed
            }
        }
        // After the cancel, so the revoke above still targets the zone it belongs to.
        startingFreshPairing()

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
        await beginPairingChange()
        defer { endPairingChange() }

        // Re-read rather than trusting a load from before the gate: a cancel that was
        // waiting on it has now finished, and this poll must see that the invite is gone
        // rather than completing a pairing the user just abandoned.
        guard let pending = PendingInvite.load() else { return nil }

        try await cloud.ensureInboxZone()
        guard let profile = await cloud.fetchPartnerProfile(pairKey: pending.pairKey),
              let theirShare = profile.shareURL else { return nil }

        let (partnerZoneID, partnerUserID) = try await cloud.acceptShare(at: theirShare)

        let state = PairState(
            pairKey: pending.pairKey,
            myDeviceID: pending.myDeviceID,
            myName: pending.myName,
            partnerDeviceID: profile.deviceID,
            partnerName: profile.name,
            myUserID: await cloud.currentUserID(),
            // Their own profile write is the authority; the share's owner identity is
            // the fallback for a joiner still on a build that writes no userID, and it
            // says the same thing by a different route.
            partnerUserID: profile.userID ?? partnerUserID?.recordName,
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

    // MARK: - Joining a pairing this Apple ID already has

    /// Brings a fresh install into the pairing another device on the same Apple ID has
    /// already made, with no QR scan and nothing for the user to confirm.
    ///
    /// There is nothing to confirm because nothing is being granted: Apple authenticated
    /// the account, iCloud Keychain moved the pair key, and the first device's share
    /// acceptance is recorded per account rather than per install. Everything this needs
    /// is already in front of it — it is reading state, not creating any.
    ///
    /// Returns nil, quietly, for every reason it might not apply: already paired, an
    /// invite of our own outstanding, no key synced yet, no zone to adopt, a pairing
    /// still mid-handshake. None is an error and all of them are retried on the next
    /// foreground, which is what makes a key that arrives late a non-event.
    ///
    /// Deliberately does not adopt while a pending invite of our own exists. That invite
    /// has a live share with a bearer URL in someone's hands; silently replacing it with
    /// a different pairing would leave that code pointing at a zone this device no
    /// longer thinks is its own.
    func adoptExistingPairing() async -> PairState? {
        await beginPairingChange()
        defer { endPairingChange() }

        guard PairState.load() == nil, PendingInvite.load() == nil else { return nil }
        guard let pairKey = PairSecrets.store.secret(for: Constants.Keychain.pairKeyAccount) else {
            return nil
        }

        // Find the zone without taking it, and deliberately without consulting
        // `resolveInboxZone`: a device that unpaired locally keeps a freshly rotated name
        // whose zone was never created, and reading that as "we had a zone and lost it"
        // would refuse to adopt the pairing this account has made since. With no pairing
        // held, a stored name means nothing and adoption overwrites it.
        guard let inbox = await cloud.adoptableInboxZone() else { return nil }

        // Both halves before anything is written. An adoption that took the zone and then
        // failed here would leave this device owning the pairing's inbox while still
        // showing the pairing screen — and the next Invite would hand that zone, with the
        // partner's records in it, to somebody new.
        let saved = InboxZone.storedName
        cloud.adoptInboxZone(named: inbox)
        guard let theirs = await cloud.fetchPartnerProfile(pairKey: pairKey),
              let ours = await cloud.adoptableOutgoingZone(pairKey: pairKey) else {
            restore(inboxZone: saved)
            return nil
        }

        let state = PairState(
            pairKey: pairKey,
            // Theirs, from the profile a previous device wrote into their zone: this
            // account presents one identity to the partner, whichever device is holding
            // it. See the note on `adoptableOutgoingZone`.
            myDeviceID: ours.myDeviceID,
            myName: ours.myName,
            partnerDeviceID: theirs.deviceID,
            partnerName: theirs.name,
            // Ours is asked directly rather than taken from the profile: this device is
            // the same account, so `currentUserID` is the same answer and is available
            // even when a previous device wrote its profile before this field existed.
            myUserID: (await cloud.currentUserID()) ?? ours.myUserID,
            partnerUserID: theirs.userID,
            outgoingZone: ZoneRef(ours.zoneID),
            // Asked rather than assumed. The share's participants are the source of
            // truth, and a pairing can legitimately be adopted mid-handshake.
            partnerCanReach: await cloud.partnerHasAcceptedInboxShare()
        )
        guard state.save() else {
            restore(inboxZone: saved)
            return nil
        }

        log.notice("adopted a pairing already made by another device on this account")
        // Subscriptions are the caller's to register: `AppState` tracks a failure and
        // retries it on the next foreground, where a swallowed `try?` here would leave an
        // apparently-paired device receiving nothing until it was relaunched.
        return state
    }

    /// Settles whether a pairing blob written before key binding still describes the
    /// pairing this account is actually in, and stamps it so the question is asked once.
    ///
    /// `PairState.load()` trusts an unfingerprinted blob against whatever key is in the
    /// keychain, which is right for an ordinary upgrade and wrong if the account has
    /// re-paired since. Until it is settled, that blob can drive account-wide CloudKit
    /// work: `registerSubscriptions` would resolve the old zone — still present when a
    /// teardown's delete failed — and repoint the constant, account-wide subscription
    /// IDs at it, taking the *new* pairing's pushes with them. Worse, the account
    /// identity backfill calls `save()`, which stamps a fingerprint computed from the
    /// current key, binding the stale blob to a pairing it was never part of and hiding
    /// the mismatch for good.
    ///
    /// The test is the one adoption uses: does the `PairProfile` in the zone we claim
    /// open under the key we hold? Only the partner writes that record, and only under
    /// the key of the pairing it belongs to.
    ///
    /// **Returns false only when the blob is proved to belong to a different key.**
    /// Everything else returns true and changes nothing: already bound, no blob, a
    /// pairing still mid-handshake (no profile written yet), or CloudKit out of reach.
    /// Acting on "cannot tell" here would unpair people whose network was merely down.
    func settleLegacyPairing() async -> Bool {
        guard PairState.hasStoredBlob, !PairState.hasKeyFingerprint else { return true }
        guard let state = PairState.load(), state.isComplete,
              let zoneName = InboxZone.storedName else { return true }
        guard let belongs = await cloud.inboxZoneBelongs(toKey: state.pairKey,
                                                         zoneNamed: zoneName) else {
            return true
        }
        if belongs {
            // Stamp it, so this costs one record read per upgraded install rather than
            // one per launch — and so the ordinary fingerprint check takes over from here.
            state.save()
            return true
        }
        log.notice("Stored pairing does not belong to the current pair key")
        return false
    }

    /// Drops the stored zone name so the pairing about to start gets a brand new one.
    ///
    /// Unconditional, after several attempts to be cleverer than that. Each one asked
    /// some version of "is the stored zone still ours?" and each had a hole, because
    /// *every* reuse leaks: an invite's zone has been joinable by anyone who scanned the
    /// QR, and they become a share participant able to write into it; a live pairing's
    /// zone holds the partner's records; and a blob that looks loadable during the
    /// keychain-sync window can be a pairing this device has not yet reconciled. A
    /// zone-wide share hands over the *whole* zone, so in all three the next partner
    /// receives what the last occupant left.
    ///
    /// The cost would have been an orphaned zone whenever a pairing start replaced one
    /// already created, but `cancelInvite` now deletes the zone it abandons, so the only
    /// orphans left are the ones a failed CloudKit delete leaves behind.
    /// `inboxZoneCensus` counts usable zones rather than prefixed ones precisely so
    /// those do not read as the #68 collision.
    private func startingFreshPairing() {
        InboxZone.clear()
    }

    /// Puts the zone name back when an adoption could not be finished, so a half-adopted
    /// device does not go on owning a pairing it never joined. Clearing is the right undo
    /// for "there was nothing stored before": a name that only ever came from this
    /// abandoned attempt should not outlive it.
    private func restore(inboxZone previous: String?) {
        if let previous {
            InboxZone.adopt(previous)
        } else {
            InboxZone.clear()
        }
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

    /// Abandon a pending invite: revoke its share so the bearer link stops working, and
    /// delete the zone that invite was offering.
    ///
    /// The zone goes because somebody may already be *in* it. A joiner who scanned the
    /// code before this device reconciled has accepted the share, written their profile,
    /// and saved a `PairState` pointing at this zone — with `canSend` true, so
    /// `MainView` gives them a working button. Leaving the zone behind after abandoning
    /// the invite would let them press it into a zone nobody reads: a "sent, waiting"
    /// pill that never resolves, which is the silent-delivery failure this whole change
    /// exists to remove. Deleting it makes their next write fail with `zoneNotFound`,
    /// which `endPairingIfPartnerZoneIsGone` already turns into "your partner unpaired"
    /// and a trip back to the pairing screen. A wrong explanation they can act on beats
    /// a dead button.
    ///
    /// It also stops the orphans. Pairing starts mint unconditionally now (see
    /// `startingFreshPairing`), so without this every abandoned invite would leave an
    /// empty zone behind for `inboxZoneCensus` to report.
    ///
    /// Ordering matters: the persisted invite is the retry handle, so it only clears
    /// once the revoke has actually happened. Returns false when *that* failed and the
    /// invite was kept for another try — a failed zone delete does not, because by then
    /// the code is already dead and an orphan is untidy rather than dangerous.
    @discardableResult
    func cancelInvite(_ pending: PendingInvite) async -> Bool {
        await beginPairingChange()
        defer { endPairingChange() }

        // Re-read inside the gate. The caller captured this invite before waiting, and
        // what it waited on may have been `completeInviterPairing` — which saves the
        // finished `PairState` and clears `PendingInvite`. Cancelling the captured copy
        // then revokes the share and deletes the zone of the pairing that just succeeded.
        // Nothing to cancel is success: the invite is gone, which is what was asked for.
        guard let live = PendingInvite.load() else { return true }
        guard live.pairKey == pending.pairKey else {
            log.notice("Invite changed while waiting to cancel; leaving the current one alone")
            return true
        }
        return await cancelInviteLocked(live)
    }

    /// The body of `cancelInvite`, for callers that already hold the gate.
    ///
    /// The gate is not reentrant, and `startInviting` and `completePairing` both cancel
    /// an outstanding invite of our own as their first act while holding it. Taking it
    /// again here would deadlock them, so the split is the whole reason this exists —
    /// not a convenience.
    private func cancelInviteLocked(_ pending: PendingInvite) async -> Bool {
        do {
            try await cloud.revokeInboxShare()
        } catch {
            log.error("invite share revoke failed: \(error.localizedDescription)")
            return false
        }
        PendingInvite.clear()

        // Guarded on a stored name: `deleteInboxZone` resolves through `currentName`,
        // which mints one when nothing is stored — and minting a name in order to delete
        // a zone that was never created is both pointless and a write to the App Group.
        if InboxZone.storedName != nil {
            do {
                try await cloud.deleteInboxZone()
            } catch {
                log.error("invite zone delete failed: \(error.localizedDescription)")
            }
            InboxZone.clear()
        }
        return true
    }

    // MARK: - Joiner

    /// Steps 2 and 3. Takes a scanned QR payload (or a tapped invite link — same wire
    /// format, same untrusted-input parser), accepts the inviter's share, then puts a
    /// share of our own zone back through the channel that just opened.
    func completePairing(payload: String, myName: String) async throws -> PairState {
        // Parsed before the gate: a malformed code is the scanner's answer to give back
        // immediately, not something to queue behind an adoption round trip.
        guard let invite = PairingInvite.from(qrPayload: payload) else {
            throw AttentionError.pairNotFound
        }
        await beginPairingChange()
        defer { endPairingChange() }

        // Joining someone else's pair abandons any invite we were offering ourselves —
        // and revokes its share, so a code we handed out earlier can't still be used.
        if let ownPending = PendingInvite.load() {
            guard await cancelInviteLocked(ownPending) else {
                throw AttentionError.inviteCleanupFailed
            }
        }
        startingFreshPairing()

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
            myUserID: await cloud.currentUserID(),
            // Known here for free: accepting their share is what told us who owns it,
            // and it is the same identity their own profile will carry.
            partnerUserID: inviterUserID.recordName,
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
    func refreshFromPartnerProfile(_ state: PairState) async -> PairState? {
        guard let profile = await cloud.fetchPartnerProfile(pairKey: state.pairKey) else { return nil }

        // Which "them" wrote this. Once both sides have an account identity that is the
        // comparison to make, because the partner's profile carries whichever of their
        // devices last wrote it and matching on that would reject their second phone.
        let sameParty: Bool
        if let known = state.partnerUserID, let writer = profile.userID {
            sameParty = known == writer
        } else {
            sameParty = profile.deviceID == state.partnerDeviceID
        }
        guard sameParty else { return nil }

        var updated = state
        // Backfill: a pairing made before per-account identity learns the partner's
        // identity the first time they write a profile under a build that carries one. No migration
        // step and no version check — just a field that starts arriving.
        if updated.partnerUserID == nil, let writer = profile.userID {
            updated.partnerUserID = writer
        }
        if !profile.name.isEmpty { updated.partnerName = profile.name }

        // Revalidated here rather than by the caller. `AppState.refreshPartnerProfile`
        // checks `stillPaired(as:)` on the way back, which is too late for this line: the
        // save has already happened, and what it writes is the whole blob — pair key
        // included. An unpair landing during the fetch above would be undone from inside
        // the service, below the guard meant to prevent exactly that.
        guard stillDescribesTheCurrentPairing(state) else {
            log.notice("Partner profile refresh finished after the pairing changed; dropping it")
            return nil
        }
        guard updated != state, updated.save() else { return nil }
        return updated
    }

    /// Whether the pairing a suspended method started with is still the one on disk.
    ///
    /// The pair key is the identity — minted once per pairing — so a different one, or
    /// none, means this pairing ended or was replaced while the caller was awaiting.
    /// `PairState.load()` returns nil for a fingerprinted blob whose key has since been
    /// replaced, which is the case this exists to catch.
    private func stillDescribesTheCurrentPairing(_ captured: PairState) -> Bool {
        PairState.load()?.pairKey == captured.pairKey
    }

    /// Writes our own profile into the partner's zone for no reason but to publish this
    /// account's identity, once per pairing per device.
    ///
    /// Needed because the backfill above is otherwise a deadlock: each side learns the
    /// other's identity by reading a profile, and neither writes one except on a rename.
    /// Whoever upgrades first would wait for a write the other has no reason to make.
    /// One unconditional write breaks it, and `writeProfile` fetches-then-modifies, so
    /// it cannot clobber the name or the share URL already there.
    @discardableResult
    func publishAccountIdentity(_ state: PairState) async -> Bool {
        guard !AccountIdentityPublished.done, state.outgoingZone != nil else { return false }

        // Resolve it here rather than trusting `state.myUserID`, and refuse to record a
        // publish we cannot make. `writeProfile` looks the identity up itself and omits
        // the field when that fails, so a persisted `myUserID` plus a failed lookup would
        // write a profile without it and still retire the one-time publish — leaving the
        // partner permanently unable to learn this account. `currentUserID` caches for
        // the life of the process, so once it answers here it answers there too.
        guard await cloud.currentUserID() != nil else { return false }

        // Re-read rather than using the snapshot this was called with. `AppState` is
        // reentrant across awaits, so a rename can land between the caller loading its
        // state and this write — and writing the stale name would silently undo it.
        // Both the zone and the fields come from the re-read, never one from each. Taking
        // the zone from the caller's snapshot and the key from the reload is how this
        // pairing's identity gets written into the *previous* pairing's zone — and
        // `AccountIdentityPublished.done` then retires the one-time publish, so the
        // current partner never learns this account at all.
        guard let current = PairState.load(), let zone = current.outgoingZone else {
            return false
        }
        do {
            try await cloud.writeProfile(into: zone.zoneID,
                                         deviceID: current.myDeviceID,
                                         name: current.myName,
                                         shareURL: nil,
                                         pairKey: current.pairKey)
            AccountIdentityPublished.done = true
            return true
        } catch {
            log.error("account identity publish: \(error.localizedDescription)")
            return false
        }
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
        await beginPairingChange()
        defer { endPairingChange() }

        await tearDownInboxZone()
        PairState.clear()
    }

    /// The remote half of "Erase all my data": the zone this device owns, its share and
    /// its subscriptions. Separate from `DataErasure`, which is local and cannot fail —
    /// every step here can, on a bad network or a signed-out iCloud account, and a device
    /// that stopped at the first CloudKit error would keep the archives it was asked to
    /// destroy.
    ///
    /// **Returns false when any of it failed**, which the caller has to surface: erase
    /// tells the user their iCloud records are gone, and that is a promise this method is
    /// the only one in a position to break.
    func eraseRemoteData() async -> Bool {
        await beginPairingChange()
        defer { endPairingChange() }

        return await tearDownInboxZone()
    }

    /// Rotates the zone name whether or not the teardown succeeded, and that is
    /// deliberate rather than an oversight.
    ///
    /// Keeping the old name to retry the delete later is the obvious repair, and it is
    /// the wrong one: the name is what the *next* pairing would then reuse, and a
    /// zone-wide share grants the whole zone, so the next partner would inherit whatever
    /// the failed delete left behind. That is the exact leak per-pairing zone names exist
    /// to prevent. An orphaned zone in the owner's own private database is the smaller
    /// harm — it is unreachable by anyone else, and iCloud storage the user can clear.
    ///
    /// So the failure is reported upward instead of repaired here.
    @discardableResult
    private func tearDownInboxZone() async -> Bool {
        var succeeded = true

        do { try await cloud.removeAllSubscriptions() } catch {
            succeeded = false
            log.error("teardown: subscriptions failed: \(error.localizedDescription)")
        }
        do { try await cloud.revokeInboxShare() } catch {
            succeeded = false
            log.error("teardown: share revoke failed: \(error.localizedDescription)")
        }
        do { try await cloud.deleteInboxZone() } catch {
            succeeded = false
            log.error("teardown: zone delete failed: \(error.localizedDescription)")
        }

        InboxZone.rotate()
        return succeeded
    }
}
