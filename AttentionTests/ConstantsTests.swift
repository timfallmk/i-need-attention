import XCTest

final class ConstantsTests: XCTestCase {

    // MARK: - NotificationAction.emoji(for:)

    func testEmojiForHeart() {
        XCTAssertEqual(Constants.NotificationAction.emoji(for: Constants.NotificationAction.heart), "❤️")
    }

    func testEmojiForThumbs() {
        XCTAssertEqual(Constants.NotificationAction.emoji(for: Constants.NotificationAction.thumbs), "👍")
    }

    func testEmojiForHug() {
        XCTAssertEqual(Constants.NotificationAction.emoji(for: Constants.NotificationAction.hug), "🤗")
    }

    func testEmojiForUrgent() {
        XCTAssertEqual(Constants.NotificationAction.emoji(for: Constants.NotificationAction.urgent), "🚨")
    }

    func testEmojiForPlainReturnsNil() {
        XCTAssertNil(Constants.NotificationAction.emoji(for: Constants.NotificationAction.plain))
    }

    func testEmojiForUnknownActionReturnsNil() {
        XCTAssertNil(Constants.NotificationAction.emoji(for: "com.unknown.action"))
    }

    func testEmojiForEmptyStringReturnsNil() {
        XCTAssertNil(Constants.NotificationAction.emoji(for: ""))
    }

    // MARK: - allAckActionIdentifiers

    func testAllAckActionIdentifiersContainsHeart() {
        XCTAssertTrue(Constants.NotificationAction.allAckActionIdentifiers.contains(Constants.NotificationAction.heart))
    }

    func testAllAckActionIdentifiersContainsThumbs() {
        XCTAssertTrue(Constants.NotificationAction.allAckActionIdentifiers.contains(Constants.NotificationAction.thumbs))
    }

    func testAllAckActionIdentifiersContainsHug() {
        XCTAssertTrue(Constants.NotificationAction.allAckActionIdentifiers.contains(Constants.NotificationAction.hug))
    }

    func testAllAckActionIdentifiersContainsUrgent() {
        XCTAssertTrue(Constants.NotificationAction.allAckActionIdentifiers.contains(Constants.NotificationAction.urgent))
    }

    func testAllAckActionIdentifiersContainsPlain() {
        XCTAssertTrue(Constants.NotificationAction.allAckActionIdentifiers.contains(Constants.NotificationAction.plain))
    }

    func testAllAckActionIdentifiersCount() {
        XCTAssertEqual(Constants.NotificationAction.allAckActionIdentifiers.count, 5)
    }

    // MARK: - AlertState raw values

    func testAlertStateSentRawValue() {
        XCTAssertEqual(Constants.AlertState.sent.rawValue, "sent")
    }

    func testAlertStateSeenRawValue() {
        XCTAssertEqual(Constants.AlertState.seen.rawValue, "seen")
    }

    func testAlertStateAcknowledgedRawValue() {
        XCTAssertEqual(Constants.AlertState.acknowledged.rawValue, "acknowledged")
    }

    func testAlertStateFromRawValueSent() {
        XCTAssertEqual(Constants.AlertState(rawValue: "sent"), .sent)
    }

    func testAlertStateFromRawValueSeen() {
        XCTAssertEqual(Constants.AlertState(rawValue: "seen"), .seen)
    }

    func testAlertStateFromRawValueAcknowledged() {
        XCTAssertEqual(Constants.AlertState(rawValue: "acknowledged"), .acknowledged)
    }

    func testAlertStateFromInvalidRawValueReturnsNil() {
        XCTAssertNil(Constants.AlertState(rawValue: "pending"))
        XCTAssertNil(Constants.AlertState(rawValue: ""))
    }

    // MARK: - Subscription IDs are non-empty strings

    func testSubscriptionIDsAreNonEmpty() {
        XCTAssertFalse(Constants.SubscriptionID.incomingAlerts.isEmpty)
        XCTAssertFalse(Constants.SubscriptionID.outgoingStatus.isEmpty)
        XCTAssertFalse(Constants.SubscriptionID.outgoingAck.isEmpty)
        XCTAssertFalse(Constants.SubscriptionID.pairProfile.isEmpty)
    }

    func testSubscriptionIDsAreUnique() {
        let ids: Set<String> = [
            Constants.SubscriptionID.incomingAlerts,
            Constants.SubscriptionID.outgoingStatus,
            Constants.SubscriptionID.outgoingAck,
            Constants.SubscriptionID.pairProfile,
        ]
        XCTAssertEqual(ids.count, 4)
    }

    // MARK: - Notification categories

    func testNotificationCategoryIsNonEmpty() {
        XCTAssertFalse(Constants.NotificationAction.category.isEmpty)
    }

    func testAckCategoryDiffersFromRequestCategory() {
        XCTAssertNotEqual(Constants.NotificationAction.category, Constants.NotificationAction.ackCategory)
    }
}
