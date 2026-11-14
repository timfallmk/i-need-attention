import XCTest

/// The decision half of closing the invite link. The CloudKit half — that making a share
/// private evicts its public participants, and that a participant named afterwards can
/// accept again — is Apple's documented behaviour and has to be confirmed on devices;
/// what can be pinned here is when this app chooses to do it, which is where a mistake
/// would end somebody's pairing.
final class InviteLinkClosureTests: XCTestCase {

    private let partner = "_partner"
    private let stranger = "_stranger"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private var longAgo: Date { now.addingTimeInterval(-InviteLinkClosure.upgradeGrace - 60) }

    private func decide(isPublic: Bool = true,
                        accepted: Set<String>,
                        partnerUserID: String?,
                        since: Date?) -> InviteLinkClosure {
        InviteLinkClosure.decide(shareIsPublic: isPublic,
                                 acceptedParticipantUserIDs: accepted,
                                 partnerUserID: partnerUserID,
                                 partnerCanRejoinSince: since,
                                 now: now)
    }

    // MARK: - Closing

    func testClosesKeepingThePartnerOnceTheirAccountCanRejoin() {
        XCTAssertEqual(decide(accepted: [partner], partnerUserID: partner, since: longAgo),
                       .close(keepingUserID: partner))
    }

    /// The case the whole change exists for: someone else used the link. Closing keeps
    /// only the partner, so the same save is what removes the stranger.
    func testClosesOverAStrangerWhoJoinedThroughTheLink() {
        XCTAssertEqual(decide(accepted: [partner, stranger], partnerUserID: partner, since: longAgo),
                       .close(keepingUserID: partner))
    }

    func testAPrivateShareIsAlreadyClosedWhateverElseIsTrue() {
        XCTAssertEqual(decide(isPublic: false, accepted: [], partnerUserID: nil, since: nil),
                       .alreadyClosed)
    }

    // MARK: - Keeping it open

    /// A partner whose account has never said it can rejoin is on a build that would take
    /// the eviction for an unpairing and end the pairing on every device it has.
    func testKeepsOpenWhenThePartnerHasNeverSaidTheyCanRejoin() {
        XCTAssertEqual(decide(accepted: [partner], partnerUserID: partner, since: nil),
                       .keepOpen(.partnerCannotRejoinYet))
    }

    /// The flag is per account and written by whichever device updated first. The grace
    /// period is the time their other devices get to catch up.
    func testKeepsOpenUntilTheGracePeriodHasPassed() {
        let recently = now.addingTimeInterval(-InviteLinkClosure.upgradeGrace + 60)
        XCTAssertEqual(decide(accepted: [partner], partnerUserID: partner, since: recently),
                       .keepOpen(.partnerCannotRejoinYet))
    }

    func testClosesAtExactlyTheEndOfTheGracePeriod() {
        let boundary = now.addingTimeInterval(-InviteLinkClosure.upgradeGrace)
        XCTAssertEqual(decide(accepted: [partner], partnerUserID: partner, since: boundary),
                       .close(keepingUserID: partner))
    }

    /// Without the partner's identity there is no one to name, and closing would leave
    /// the share with nobody invited.
    func testKeepsOpenWithoutThePartnersIdentity() {
        XCTAssertEqual(decide(accepted: [partner], partnerUserID: nil, since: longAgo),
                       .keepOpen(.partnerCannotRejoinYet))
    }

    /// If none of the accepted accounts is the partner, the share is not in a state this
    /// code understands, and closing it would evict whoever is there for no one.
    func testKeepsOpenWhenThePartnerIsNotAmongTheParticipants() {
        XCTAssertEqual(decide(accepted: [stranger], partnerUserID: partner, since: longAgo),
                       .keepOpen(.partnerNotAmongParticipants))
        XCTAssertEqual(decide(accepted: [], partnerUserID: partner, since: longAgo),
                       .keepOpen(.partnerNotAmongParticipants))
    }

    // MARK: - The partner's side

    func testAFreshOfferHoldsOffAnUnpairing() {
        XCTAssertTrue(PartnerZoneLoss.offerIsFresh(now.addingTimeInterval(-60), now: now))
    }

    /// A stale offer must not keep a pairing alive after the inviter really unpaired:
    /// the URL left in the profile from a closing long ago stays there forever.
    func testAStaleOfferDoesNot() {
        let stale = now.addingTimeInterval(-PartnerZoneLoss.offerFreshness - 60)
        XCTAssertFalse(PartnerZoneLoss.offerIsFresh(stale, now: now))
    }

    func testTheFreshnessBoundaryCountsAsStale() {
        let boundary = now.addingTimeInterval(-PartnerZoneLoss.offerFreshness)
        XCTAssertFalse(PartnerZoneLoss.offerIsFresh(boundary, now: now))
    }

    func testNoOfferIsNeverFresh() {
        XCTAssertFalse(PartnerZoneLoss.offerIsFresh(nil, now: now))
    }

    /// The partner's clock can run ahead of ours. An offer dated slightly in the future
    /// is a real offer, not a reason to unpair.
    func testAnOfferFromAClockRunningAheadIsFresh() {
        XCTAssertTrue(PartnerZoneLoss.offerIsFresh(now.addingTimeInterval(300), now: now))
    }
}
