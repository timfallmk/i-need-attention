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

    // MARK: - Zone-scoped subscriptions

    func testIncomingAlertsMatchesEverythingInTheZone() {
        assertStructure(SubscriptionPredicates.incomingAlerts(), matches: NSPredicate(value: true))
    }

    func testOutgoingStatusMatchesEverythingInTheZone() {
        assertStructure(SubscriptionPredicates.outgoingStatus(), matches: NSPredicate(value: true))
    }

    func testPairProfileMatchesEverythingInTheZone() {
        assertStructure(SubscriptionPredicates.pairProfile(), matches: NSPredicate(value: true))
    }

    // MARK: - The one predicate that still filters

    func testOutgoingAckMatchesOnlyAcknowledged() {
        assertStructure(
            SubscriptionPredicates.outgoingAck(),
            matches: NSPredicate(
                format: "%K == %@",
                Constants.AlertStatusField.state, Constants.AlertState.acknowledged.rawValue
            )
        )
    }

    /// The ack banner is the whole reason this predicate exists: matching "seen" too
    /// would pop a banner every time the partner's phone merely displayed the alert.
    func testOutgoingAckDoesNotMatchSeen() {
        let seen = ["state": Constants.AlertState.seen.rawValue]
        XCTAssertFalse(SubscriptionPredicates.outgoingAck().evaluate(with: seen))
    }

    func testOutgoingAckMatchesAnAcknowledgedRecord() {
        let acked = ["state": Constants.AlertState.acknowledged.rawValue]
        XCTAssertTrue(SubscriptionPredicates.outgoingAck().evaluate(with: acked))
    }

    /// `state` is the field name the schema declares queryable; a rename here would
    /// silently stop the banner rather than fail to build.
    func testOutgoingAckUsesTheStateField() {
        XCTAssertTrue(SubscriptionPredicates.outgoingAck().predicateFormat.contains(Constants.AlertStatusField.state))
    }

    // MARK: - Incoming answered

    /// It filters on `Alert.state`, not `AlertStatus.state`. The two fields are spelled
    /// the same, so a predicate built from the wrong constant would look right, compile,
    /// and watch the wrong record type.
    func testIncomingAnsweredFiltersOnTheAlertStateField() {
        XCTAssertTrue(
            SubscriptionPredicates.incomingAnswered()
                .predicateFormat.contains(Constants.AlertField.state)
        )
    }

    func testIncomingAnsweredMatchesOnlyAcknowledged() {
        for state in [Constants.AlertState.sent, .seen] {
            let record = [Constants.AlertField.state: state.rawValue]
            XCTAssertFalse(SubscriptionPredicates.incomingAnswered().evaluate(with: record),
                           "\(state.rawValue) should not fire the banner-clearing push")
        }
        let acked = [Constants.AlertField.state: Constants.AlertState.acknowledged.rawValue]
        XCTAssertTrue(SubscriptionPredicates.incomingAnswered().evaluate(with: acked))
    }
}
