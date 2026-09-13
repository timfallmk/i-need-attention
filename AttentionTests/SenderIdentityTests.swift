import XCTest

/// The whole point of this type is one copy of a fallback rule that has to be right in
/// four places, so these are the cases that copy has to get right.
final class SenderIdentityTests: XCTestCase {

    private let withAccount = SenderIdentity(deviceID: "device-A", userID: "_user-A")
    private let deviceOnly = SenderIdentity(deviceID: "device-A", userID: nil)

    // MARK: - Account identity wins when both ends have one

    func testMatchesOnAccountIdentity() {
        XCTAssertTrue(withAccount.matches(userID: "_user-A", deviceID: "device-A"))
    }

    /// The case the whole change exists for: this person's *other* device. Same account,
    /// a device ID we have never seen. Before, this read as the partner.
    func testMatchesThisPersonsOtherDevice() {
        XCTAssertTrue(withAccount.matches(userID: "_user-A", deviceID: "some-other-iPad"))
    }

    /// And its mirror: the partner's second device. Before, it matched neither side and
    /// was dropped without a trace.
    func testDoesNotMatchAnotherAccountOnAnyDevice() {
        XCTAssertFalse(withAccount.matches(userID: "_user-B", deviceID: "device-B"))
        XCTAssertFalse(withAccount.matches(userID: "_user-B", deviceID: "device-A"))
    }

    // MARK: - Falling back

    /// A record from before per-account identity carries no userID. Comparing our
    /// present value against its absent one would answer "not mine" for every alert this
    /// person ever sent, so the absence has to send us to the device comparison.
    func testFallsBackWhenTheRecordHasNoAccountIdentity() {
        XCTAssertTrue(withAccount.matches(userID: nil, deviceID: "device-A"))
        XCTAssertFalse(withAccount.matches(userID: nil, deviceID: "device-B"))
    }

    /// The reverse: a pairing that has not learned ours yet, reading a record that has
    /// one. Also a fallback, for the same reason in the other direction.
    func testFallsBackWhenWeHaveNoAccountIdentity() {
        XCTAssertTrue(deviceOnly.matches(userID: "_user-A", deviceID: "device-A"))
        XCTAssertFalse(deviceOnly.matches(userID: "_user-A", deviceID: "device-B"))
    }

    func testFallsBackWhenNeitherSideHasOne() {
        XCTAssertTrue(deviceOnly.matches(userID: nil, deviceID: "device-A"))
        XCTAssertFalse(deviceOnly.matches(userID: nil, deviceID: "device-B"))
    }

    /// An empty string is a value, not an absence, and must not be treated as one — two
    /// records that both lack an identity would otherwise match each other.
    func testEmptyStringIsAValueAndNotAnAbsence() {
        let empty = SenderIdentity(deviceID: "device-A", userID: "")
        XCTAssertTrue(empty.matches(userID: "", deviceID: "device-B"))
        XCTAssertFalse(empty.matches(userID: "_user-A", deviceID: "device-A"))
    }
}
