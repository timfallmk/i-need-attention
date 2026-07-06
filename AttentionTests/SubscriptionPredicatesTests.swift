import XCTest

/// The subscription predicates decide which pushes each device receives — a wrong operator
/// here silently breaks delivery, so pin the distinguishing properties.
final class SubscriptionPredicatesTests: XCTestCase {

    func testIncomingExcludesOwnDeviceAndScopesToPair() {
        let f = SubscriptionPredicates.incomingAlerts(pairKey: "PK", myDeviceID: "ME").predicateFormat
        XCTAssertTrue(f.contains("!="), "incoming must EXCLUDE the wearer's own alerts")
        XCTAssertTrue(f.contains("\"PK\""))
        XCTAssertTrue(f.contains("\"ME\""))
    }

    func testOutgoingStatusIncludesOnlyOwnDevice() {
        let f = SubscriptionPredicates.outgoingStatus(pairKey: "PK", myDeviceID: "ME").predicateFormat
        XCTAssertFalse(f.contains("!="), "outgoing status must only match my own alerts")
        XCTAssertTrue(f.contains("=="))
    }

    /// The classic bug is swapping these two — they must never render identically.
    func testIncomingAndOutgoingStatusDiffer() {
        let incoming = SubscriptionPredicates.incomingAlerts(pairKey: "PK", myDeviceID: "ME")
        let outgoing = SubscriptionPredicates.outgoingStatus(pairKey: "PK", myDeviceID: "ME")
        XCTAssertNotEqual(incoming.predicateFormat, outgoing.predicateFormat)
    }

    func testOutgoingAckMatchesAckRecipientField() {
        let f = SubscriptionPredicates.outgoingAck(pairKey: "PK", myDeviceID: "ME").predicateFormat
        XCTAssertTrue(f.contains(Constants.AckField.recipientDeviceID))
        XCTAssertTrue(f.contains("\"ME\""))
    }

    func testPairUpdatesScopedToPairKeyOnly() {
        let f = SubscriptionPredicates.pairUpdates(pairKey: "PK").predicateFormat
        XCTAssertTrue(f.contains("\"PK\""))
        XCTAssertFalse(f.contains("AND"), "pair updates should not filter on any second field")
    }
}
