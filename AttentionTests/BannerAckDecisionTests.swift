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

    func testAnUnansweredAlertThatIsTheNewestIsAcknowledged() {
        let tapped = alert(.sent)
        XCTAssertEqual(BannerAckDecision.decide(tapped: tapped, newestIncoming: tapped), .acknowledge)
    }

    func testASeenAlertIsStillAcknowledged() {
        let tapped = alert(.seen)
        XCTAssertEqual(BannerAckDecision.decide(tapped: tapped, newestIncoming: tapped), .acknowledge)
    }

    /// #70: the banner outlived the answer.
    func testAnAlreadyAcknowledgedAlertIsNotAcknowledgedAgain() {
        let tapped = alert(.acknowledged)
        XCTAssertEqual(BannerAckDecision.decide(tapped: tapped, newestIncoming: tapped), .alreadyAcknowledged)
        XCTAssertEqual(BannerAckDecision.decide(tapped: tapped, newestIncoming: nil), .alreadyAcknowledged)
    }

    func testAnOlderAlertIsDroppedOnceALaterOneHasBeenAnswered() {
        let tapped = alert(.sent)
        let newest = alert(.acknowledged, at: 600)
        XCTAssertEqual(BannerAckDecision.decide(tapped: tapped, newestIncoming: newest),
                       .supersededByAnAnsweredAlert)
    }

    /// Two requests, neither answered: each banner still answers its own.
    func testAnOlderAlertIsAcknowledgedWhileTheLaterOneIsStillWaiting() {
        let tapped = alert(.sent)
        let newest = alert(.seen, at: 600)
        XCTAssertEqual(BannerAckDecision.decide(tapped: tapped, newestIncoming: newest), .acknowledge)
    }

    /// A query that failed says nothing, and must not cost the partner their reply.
    func testAFailedQueryNeverBlocksAnAcknowledgement() {
        XCTAssertEqual(BannerAckDecision.decide(tapped: alert(.sent), newestIncoming: nil), .acknowledge)
    }

    /// A query can lag a record written a moment ago, and then names an *older* alert
    /// as the newest. An answered one there is not evidence against the one just tapped.
    func testALaggingQueryNeverBlocksAnAcknowledgement() {
        let tapped = alert(.sent, at: 600)
        let stale = alert(.acknowledged)
        XCTAssertEqual(BannerAckDecision.decide(tapped: tapped, newestIncoming: stale), .acknowledge)
    }

    // MARK: - Whether a pending snooze survives the ack

    func testASnoozeOnTheAcknowledgedAlertIsCancelled() {
        let tapped = alert(.sent)
        XCTAssertTrue(BannerAckDecision.shouldCancelSnooze(on: tapped.id.recordName,
                                                           afterAcknowledging: tapped,
                                                           newestIncoming: tapped))
        XCTAssertTrue(BannerAckDecision.shouldCancelSnooze(on: tapped.id.recordName,
                                                           afterAcknowledging: tapped,
                                                           newestIncoming: nil))
    }

    /// #78: snooze the first alert, answer the second from its banner, never open the
    /// app. The first one's reminder must not fire.
    func testASnoozeOnAnEarlierAlertIsCancelledWhenTheNewestIsAnswered() {
        let snoozed = alert(.sent)
        let tapped = alert(.sent, at: 600)
        XCTAssertTrue(BannerAckDecision.shouldCancelSnooze(on: snoozed.id.recordName,
                                                           afterAcknowledging: tapped,
                                                           newestIncoming: tapped))
    }

    /// The same, when the query has not caught up with the alert just answered and
    /// still names the snoozed one as newest.
    func testASnoozeOnAnEarlierAlertIsCancelledEvenWhenTheQueryLags() {
        let snoozed = alert(.sent)
        let tapped = alert(.sent, at: 600)
        XCTAssertTrue(BannerAckDecision.shouldCancelSnooze(on: snoozed.id.recordName,
                                                           afterAcknowledging: tapped,
                                                           newestIncoming: snoozed))
    }

    func testASnoozeOnANewerAlertSurvivesAnsweringAnOlderOne() {
        let tapped = alert(.sent)
        let snoozed = alert(.sent, at: 600)
        XCTAssertFalse(BannerAckDecision.shouldCancelSnooze(on: snoozed.id.recordName,
                                                            afterAcknowledging: tapped,
                                                            newestIncoming: snoozed))
    }

    func testASnoozeOnAnotherAlertIsLeftAloneWhenNothingIsKnown() {
        let tapped = alert(.sent)
        XCTAssertFalse(BannerAckDecision.shouldCancelSnooze(on: "some-other-alert",
                                                            afterAcknowledging: tapped,
                                                            newestIncoming: nil))
    }
}
