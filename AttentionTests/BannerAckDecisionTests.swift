import CloudKit
import XCTest

/// The judgement the notification-response handler makes before it writes anything.
/// The handler itself runs on a background launch against CloudKit and can't be stood up
/// here, so the rule is pinned where it lives.
final class BannerAckDecisionTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_000_000)

    private func alert(_ state: Constants.AlertState, at offset: TimeInterval = 0) -> AlertRecord {
        DemoSession.alert(
            senderDeviceID: DemoSession.partnerDeviceID,
            senderName: DemoSession.partnerName,
            message: DemoSession.incomingMessage,
            state: state,
            createdAt: base.addingTimeInterval(offset)
        )
    }

    // MARK: - Whether to acknowledge

    func testAnUnansweredAlertWithNothingAnsweredSinceIsAcknowledged() {
        XCTAssertEqual(BannerAckDecision.decide(tapped: alert(.sent), newestAnswered: nil), .acknowledge)
    }

    func testASeenAlertIsStillAcknowledged() {
        XCTAssertEqual(BannerAckDecision.decide(tapped: alert(.seen), newestAnswered: nil), .acknowledge)
    }

    /// #70: the banner outlived the answer.
    func testAnAlreadyAcknowledgedAlertIsNotAcknowledgedAgain() {
        let tapped = alert(.acknowledged)
        XCTAssertEqual(BannerAckDecision.decide(tapped: tapped, newestAnswered: tapped), .alreadyAcknowledged)
        XCTAssertEqual(BannerAckDecision.decide(tapped: tapped, newestAnswered: nil), .alreadyAcknowledged)
    }

    /// Whatever sits on top of the answered alert — nothing, or any number of newer
    /// requests still waiting — an answer given since settles the one before it.
    func testAnOlderAlertIsDroppedOnceALaterOneHasBeenAnswered() {
        let tapped = alert(.sent)
        let answered = alert(.acknowledged, at: 600)
        XCTAssertEqual(BannerAckDecision.decide(tapped: tapped, newestAnswered: answered),
                       .supersededByAnAnsweredAlert)
    }

    /// The newest answered alert predates the tapped one: nothing has been answered
    /// since, so the tapped alert is still owed its reply. This is also what a query
    /// that lags the tapped alert looks like.
    func testAnAnswerGivenBeforeTheTappedAlertDoesNotSettleIt() {
        let tapped = alert(.sent, at: 600)
        let earlierAnswer = alert(.acknowledged)
        XCTAssertEqual(BannerAckDecision.decide(tapped: tapped, newestAnswered: earlierAnswer), .acknowledge)
    }

    /// Two requests, neither answered: each banner still answers its own.
    func testAnOlderAlertIsAcknowledgedWhileALaterOneIsStillWaiting() {
        let tapped = alert(.sent)
        let laterUnanswered = alert(.seen, at: 600)
        XCTAssertEqual(BannerAckDecision.decide(tapped: tapped, newestAnswered: laterUnanswered), .acknowledge)
    }

    /// A query that failed says nothing, and must not cost the partner their reply.
    func testAFailedQueryNeverBlocksAnAcknowledgement() {
        XCTAssertEqual(BannerAckDecision.decide(tapped: alert(.sent), newestAnswered: nil), .acknowledge)
    }

    // MARK: - Whether a pending snooze survives the ack

    func testASnoozeOnTheAcknowledgedAlertIsCancelled() {
        let tapped = alert(.sent)
        XCTAssertTrue(BannerAckDecision.shouldCancelSnooze(on: tapped.id.recordName,
                                                           snoozedAlert: tapped,
                                                           afterAcknowledging: tapped))
        XCTAssertTrue(BannerAckDecision.shouldCancelSnooze(on: tapped.id.recordName,
                                                           snoozedAlert: nil,
                                                           afterAcknowledging: tapped))
    }

    /// #78: snooze the first alert, answer the second from its banner, never open the
    /// app. The first one's reminder must not fire.
    func testASnoozeOnAnEarlierAlertIsCancelledWhenALaterOneIsAnswered() {
        let snoozed = alert(.sent)
        let tapped = alert(.sent, at: 600)
        XCTAssertTrue(BannerAckDecision.shouldCancelSnooze(on: snoozed.id.recordName,
                                                           snoozedAlert: snoozed,
                                                           afterAcknowledging: tapped))
    }

    /// Answering an older alert must leave a newer one's reminder alone — whatever a
    /// query would have said about which is newest, since the ordering is read off the
    /// two records themselves.
    func testASnoozeOnANewerAlertSurvivesAnsweringAnOlderOne() {
        let tapped = alert(.sent)
        let snoozed = alert(.sent, at: 600)
        XCTAssertFalse(BannerAckDecision.shouldCancelSnooze(on: snoozed.id.recordName,
                                                            snoozedAlert: snoozed,
                                                            afterAcknowledging: tapped))
    }

    /// Unreadable is unknown, and unknown keeps the reminder: losing one for an alert
    /// that is still waiting is worse than a stale one firing.
    func testASnoozeOnAnotherAlertIsKeptWhenThatAlertCannotBeRead() {
        let tapped = alert(.sent)
        XCTAssertFalse(BannerAckDecision.shouldCancelSnooze(on: "some-other-alert",
                                                            snoozedAlert: nil,
                                                            afterAcknowledging: tapped))
    }
}
