import CloudKit
import XCTest

/// The demo's safety claim is that it cannot reach CloudKit or leave anything on disk.
/// `AppState` is `@MainActor` and reaches services these tests can't stand up, so what is
/// pinned here is the layer underneath it: that `DemoSession` fabricates records entirely
/// in memory, and that none of them carry a pair key or a real device identity. The
/// structural half of the claim — `pair` stays nil, and every CloudKit path in `AppState`
/// opens with `guard let pair else { return }` — is enforced by that guard, not by a test.
final class DemoSessionTests: XCTestCase {

    func testOutgoingMirrorsTheRealMessagePhrasing() {
        let alert = DemoSession.outgoing(from: "device-A", senderName: "Alice", noun: "Hugs")
        XCTAssertEqual(alert.message, "needs Hugs")
        XCTAssertEqual(alert.senderName, "Alice")
        XCTAssertEqual(alert.state, .sent)
        XCTAssertNil(alert.acknowledgedAt)
    }

    /// A noun the sanitizer rejects has to fall back, not produce "needs ".
    func testOutgoingFallsBackWhenTheNounIsUnusable() {
        XCTAssertEqual(
            DemoSession.outgoing(from: "d", senderName: "A", noun: nil).message,
            "needs attention"
        )
        XCTAssertEqual(
            DemoSession.outgoing(from: "d", senderName: "A", noun: "   ").message,
            "needs attention"
        )
    }

    func testIncomingComesFromTheScriptedPartner() {
        let alert = DemoSession.incoming()
        XCTAssertEqual(alert.senderName, DemoSession.partnerName)
        XCTAssertEqual(alert.senderDeviceID, DemoSession.partnerDeviceID)
        XCTAssertEqual(alert.state, .sent)
    }

    /// The demo partner must never collide with a real one. `DeviceIdentity.id` is a
    /// UUID string, so a non-UUID sentinel cannot be mistaken for one.
    func testDemoPartnerIdentityCannotBeARealDevice() {
        XCTAssertNil(UUID(uuidString: DemoSession.partnerDeviceID))
        XCTAssertNotEqual(DemoSession.partnerDeviceID, DeviceIdentity.id)
    }

    /// Nothing the demo builds carries a pair key. If one ever did, it would mean a demo
    /// record had been shaped like something writable into a real zone.
    func testDemoRecordsCarryNoPairKey() {
        for alert in [
            DemoSession.outgoing(from: "d", senderName: "A", noun: nil),
            DemoSession.incoming()
        ] {
            XCTAssertTrue(alert.pairKey.isEmpty)
        }
    }

    /// Demo record names are namespaced, so one appearing anywhere it shouldn't is
    /// identifiable on sight rather than looking like an ordinary record.
    func testDemoRecordNamesAreIdentifiable() {
        XCTAssertTrue(DemoSession.incoming().id.recordName.hasPrefix("demo-"))
    }

    // MARK: - The scripted timeline

    func testAdvanceToSeenSetsOnlySeenAt() {
        let sent = DemoSession.incoming()
        let seen = DemoSession.advanced(sent, to: .seen)
        XCTAssertEqual(seen.state, .seen)
        XCTAssertNotNil(seen.seenAt)
        XCTAssertNil(seen.acknowledgedAt)
        XCTAssertNil(seen.ackEmoji)
        XCTAssertEqual(seen.id, sent.id, "advancing must not mint a new record")
    }

    func testAdvanceToAcknowledgedCarriesTheEmoji() {
        let acked = DemoSession.advanced(DemoSession.incoming(), to: .acknowledged, emoji: "👍")
        XCTAssertEqual(acked.state, .acknowledged)
        XCTAssertEqual(acked.ackEmoji, "👍")
        XCTAssertNotNil(acked.acknowledgedAt)
    }

    /// Acknowledging straight from `.sent` — what the inline banner actions do — must
    /// still leave a `seenAt`, or the status pill has an acknowledgement that was
    /// never seen.
    func testAcknowledgingWithoutSeeingBackfillsSeenAt() {
        let acked = DemoSession.advanced(DemoSession.incoming(), to: .acknowledged, emoji: "🤗")
        XCTAssertNotNil(acked.seenAt)
    }

    func testAdvancingKeepsTheOriginalSeenAt() {
        let at = Date(timeIntervalSince1970: 1_000)
        let seen = DemoSession.advanced(DemoSession.incoming(), to: .seen, at: at)
        let acked = DemoSession.advanced(seen, to: .acknowledged, emoji: "❤️")
        XCTAssertEqual(acked.seenAt, at)
    }

    /// The sequence the send script actually runs, pinned as a unit.
    ///
    /// Every step of this was already covered individually and the script still got it
    /// wrong: it acknowledged from the original `.sent` record rather than the `.seen`
    /// one it had just built, so `seenAt ?? date` backfilled the acknowledgement time and
    /// the demo showed a partner who answered the instant they noticed. Testing the
    /// pieces did not catch a caller that chained them wrongly, so the chain is a test.
    func testSentThenSeenThenAcknowledgedKeepsTheTwoTimestampsApart() {
        let sentAt = Date(timeIntervalSince1970: 1_000)
        let seenAt = sentAt.addingTimeInterval(DemoSession.seenAfter)
        let ackAt = seenAt.addingTimeInterval(DemoSession.acknowledgedAfterSeen)

        let sent = DemoSession.outgoing(from: "device-A", senderName: "Alice", noun: nil)
        let seen = DemoSession.advanced(sent, to: .seen, at: seenAt)
        let acked = DemoSession.advanced(seen, to: .acknowledged, emoji: "❤️", at: ackAt)

        XCTAssertEqual(acked.seenAt, seenAt, "noticing must keep its own timestamp")
        XCTAssertEqual(acked.acknowledgedAt, ackAt)
        XCTAssertNotEqual(acked.seenAt, acked.acknowledgedAt)
    }

    /// The shape of the mistake above, so the reason the caller must chain is visible
    /// here rather than only in a comment at the call site.
    func testAcknowledgingStraightFromSentCollapsesBothTimestamps() {
        let at = Date(timeIntervalSince1970: 2_000)
        let acked = DemoSession.advanced(DemoSession.incoming(), to: .acknowledged,
                                         emoji: "❤️", at: at)
        XCTAssertEqual(acked.seenAt, at)
        XCTAssertEqual(acked.acknowledgedAt, at)
    }

    /// The demo is a value-type script, so advancing returns a copy and leaves the
    /// original alone — which is what lets a cancelled timer's result be discarded.
    func testAdvancingDoesNotMutateTheOriginal() {
        let sent = DemoSession.incoming()
        _ = DemoSession.advanced(sent, to: .acknowledged, emoji: "❤️")
        XCTAssertEqual(sent.state, .sent)
        XCTAssertNil(sent.acknowledgedAt)
    }
}
