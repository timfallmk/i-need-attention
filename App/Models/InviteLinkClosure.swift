import Foundation

/// The inviter's decision about the bearer link its inbox share was created with.
///
/// The share has to start public: the inviter cannot name a joiner it has never met, so
/// the QR code carries a URL anyone can accept. Left that way it is a standing credential —
/// whoever ever saw the code or the link can join the zone later, read what the partner
/// sends with the key the same code carries, and write alerts that decrypt as genuine.
///
/// Closing it is not a setting flip. CloudKit removes every public participant when a
/// share's public permission becomes `.none`, and a participant can only be added by name
/// to a share that is already private. So closing evicts the partner too, and they have
/// to accept again — which only a build that knows how will do. On an older one, a
/// partner zone that vanishes reads as "your partner unpaired" and tears the pairing
/// down. Hence the gate on `partnerCanRejoinSince`, and the grace period after it.
enum InviteLinkClosure: Equatable {
    case alreadyClosed
    case keepOpen(Reason)
    /// Close, re-inviting this account by name. Anyone else who joined through the link
    /// is evicted by the same save, which is the point.
    case close(keepingUserID: String)

    enum Reason: Equatable {
        /// The partner's account has not said it can rejoin, or said so too recently.
        case partnerCannotRejoinYet
        /// None of the accepted participants is the partner. Nothing to keep, so nothing
        /// is safe to close — this is the state to leave alone and look at, not repair.
        case partnerNotAmongParticipants
    }

    /// How long after the partner's account first says it can rejoin before the link is
    /// closed. The flag is per account, written by whichever of their devices updated
    /// first; any of their other devices still on an older build would take an eviction
    /// for an unpairing and end it for all of them. This is the time those devices get
    /// to auto-update, traded against how long the link stays open after that.
    ///
    /// A minute in Debug builds, which only ever talk to the Development environment and
    /// so only to the developer's own devices. Without it the handshake could not be
    /// watched end to end short of waiting three days.
    #if DEBUG
    static let upgradeGrace: TimeInterval = 60
    #else
    static let upgradeGrace: TimeInterval = 3 * 24 * 60 * 60
    #endif

    static func decide(shareIsPublic: Bool,
                       acceptedParticipantUserIDs: Set<String>,
                       partnerUserID: String?,
                       partnerCanRejoinSince: Date?,
                       now: Date) -> InviteLinkClosure {
        guard shareIsPublic else { return .alreadyClosed }
        guard let partnerUserID,
              let since = partnerCanRejoinSince,
              now.timeIntervalSince(since) >= upgradeGrace else {
            return .keepOpen(.partnerCannotRejoinYet)
        }
        guard acceptedParticipantUserIDs.contains(partnerUserID) else {
            return .keepOpen(.partnerNotAmongParticipants)
        }
        return .close(keepingUserID: partnerUserID)
    }
}

/// The partner's side: what to do when the inviter's zone has vanished from this
/// account's shared database.
///
/// Before the invite link could be closed that only ever meant the inviter had unpaired.
/// Now it can also mean they closed the link and re-invited us by name, and the two look
/// identical from here — the zone is gone either way. What tells them apart is the
/// inviter's profile in the zone *we* own: closing writes a share URL and an offer date
/// into it first, over our own share, which the closing never touches.
enum PartnerZoneLoss {
    /// How long a rejoin offer keeps an unaccepted rejoin from being read as an unpairing.
    ///
    /// The inviter refreshes the offer on every pass while we have not rejoined, so it
    /// only goes stale when they have stopped running the app. A stale offer means the
    /// pairing is decided by the old rule again, which is what makes a stray URL left
    /// from a closing long ago unable to keep a dead pairing looking alive.
    static let offerFreshness: TimeInterval = 7 * 24 * 60 * 60

    /// Whether an offer this recent should hold off an unpairing that acceptance could
    /// not yet resolve — the window between the inviter evicting us and naming us again.
    static func offerIsFresh(_ offeredAt: Date?, now: Date) -> Bool {
        guard let offeredAt else { return false }
        return now.timeIntervalSince(offeredAt) < offerFreshness
    }
}

/// What `PairingService.recoverFromClosedInviteLink` found.
enum PartnerZoneRecovery {
    /// The zone is missing and nothing says it is coming back: decide as before.
    case notApplicable
    /// The zone is there after all. Usually another recovery got there first, having
    /// waited on the same gate; the caller's evidence of loss is stale.
    case zonePresent
    /// Accepted again; the zone is back.
    case rejoined
    /// Not back yet, but a fresh offer says it is coming. Not an unpairing.
    case waiting
    /// The partner's profile could not be read, so whether an offer is waiting is
    /// unknown. Not an unpairing either: the next pass asks again.
    case undetermined

    /// Whether the caller must keep the pairing. Only `.notApplicable` hands it back.
    var keepsPairing: Bool { self != .notApplicable }
}
