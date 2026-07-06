import XCTest

/// The subscription predicates decide which pushes each device receives — a wrong operator
/// or field here silently breaks delivery. Each builder is pinned against a fully-specified
/// expected predicate (field names + operators + values, via `predicateFormat`) so a swapped
/// clause, operator, or field can't slip through.
final class SubscriptionPredicatesTests: XCTestCase {

    private func assertStructure(
        _ actual: NSPredicate, matches expected: NSPredicate,
        _ message: String = "", file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(actual.predicateFormat, expected.predicateFormat, message, file: file, line: line)
    }

    func testIncomingAlertsExcludesOwnDeviceInThisPair() {
        assertStructure(
            SubscriptionPredicates.incomingAlerts(pairKey: "PK", myDeviceID: "ME"),
            matches: NSPredicate(
                format: "%K == %@ AND %K != %@",
                Constants.AlertField.pairKey, "PK",
                Constants.AlertField.senderDeviceID, "ME"
            )
        )
    }

    func testOutgoingStatusMatchesOnlyOwnAlerts() {
        assertStructure(
            SubscriptionPredicates.outgoingStatus(pairKey: "PK", myDeviceID: "ME"),
            matches: NSPredicate(
                format: "%K == %@ AND %K == %@",
                Constants.AlertField.pairKey, "PK",
                Constants.AlertField.senderDeviceID, "ME"
            )
        )
    }

    func testOutgoingAckMatchesAckRecipient() {
        assertStructure(
            SubscriptionPredicates.outgoingAck(pairKey: "PK", myDeviceID: "ME"),
            matches: NSPredicate(
                format: "%K == %@ AND %K == %@",
                Constants.AckField.pairKey, "PK",
                Constants.AckField.recipientDeviceID, "ME"
            )
        )
    }

    func testPairUpdatesScopedToPairKeyOnly() {
        assertStructure(
            SubscriptionPredicates.pairUpdates(pairKey: "PK"),
            matches: NSPredicate(format: "%K == %@", Constants.PairField.pairKey, "PK")
        )
    }

    /// The classic bug is swapping incoming (`!=`) and outgoing-status (`==`) — pin that the
    /// two never render identically, independent of the exact-structure tests above.
    func testIncomingAndOutgoingStatusDiffer() {
        XCTAssertNotEqual(
            SubscriptionPredicates.incomingAlerts(pairKey: "PK", myDeviceID: "ME").predicateFormat,
            SubscriptionPredicates.outgoingStatus(pairKey: "PK", myDeviceID: "ME").predicateFormat
        )
    }
}
