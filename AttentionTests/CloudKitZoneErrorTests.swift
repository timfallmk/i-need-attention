import CloudKit
import XCTest

/// The consequence of `isMissingCloudKitZone` returning true is that the app ends a
/// pairing, so these tests care as much about what it rejects as what it accepts.
final class CloudKitZoneErrorTests: XCTestCase {

    /// Built as `NSError` and bridged, which is how CloudKit's own errors arrive.
    private func cloudKitError(_ code: CKError.Code, userInfo: [String: Any] = [:]) -> Error {
        NSError(domain: CKErrorDomain, code: code.rawValue, userInfo: userInfo) as Error
    }

    // MARK: - Recognised

    func testZoneNotFoundIsMissingZone() {
        XCTAssertTrue(cloudKitError(.zoneNotFound).isMissingCloudKitZone)
    }

    /// What a partner's `unpair()` actually produces for the other device: the zone was
    /// there, its owner deleted it.
    func testUserDeletedZoneIsMissingZone() {
        XCTAssertTrue(cloudKitError(.userDeletedZone).isMissingCloudKitZone)
    }

    /// Batched saves report the real cause per item, so the top-level code is only
    /// `partialFailure` and the answer is one level down.
    func testPartialFailureWrappingZoneNotFoundIsMissingZone() {
        let inner = NSError(domain: CKErrorDomain, code: CKError.Code.zoneNotFound.rawValue)
        let error = cloudKitError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: ["item": inner]])

        XCTAssertTrue(error.isMissingCloudKitZone)
    }

    // MARK: - Rejected
    //
    // Each of these is a way to be temporarily unable to reach a zone that still exists.
    // Treating any of them as a missing zone would unpair someone over a bad connection.

    func testNetworkUnavailableIsNotMissingZone() {
        XCTAssertFalse(cloudKitError(.networkUnavailable).isMissingCloudKitZone)
    }

    func testNetworkFailureIsNotMissingZone() {
        XCTAssertFalse(cloudKitError(.networkFailure).isMissingCloudKitZone)
    }

    func testNotAuthenticatedIsNotMissingZone() {
        XCTAssertFalse(cloudKitError(.notAuthenticated).isMissingCloudKitZone)
    }

    func testRequestRateLimitedIsNotMissingZone() {
        XCTAssertFalse(cloudKitError(.requestRateLimited).isMissingCloudKitZone)
    }

    func testServiceUnavailableIsNotMissingZone() {
        XCTAssertFalse(cloudKitError(.serviceUnavailable).isMissingCloudKitZone)
    }

    func testPartialFailureWithoutAMissingZoneIsNotMissingZone() {
        let inner = NSError(domain: CKErrorDomain, code: CKError.Code.networkFailure.rawValue)
        let error = cloudKitError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: ["item": inner]])

        XCTAssertFalse(error.isMissingCloudKitZone)
    }

    func testPartialFailureWithNoInnerErrorsIsNotMissingZone() {
        XCTAssertFalse(cloudKitError(.partialFailure).isMissingCloudKitZone)
    }

    func testNonCloudKitErrorIsNotMissingZone() {
        struct SomeOtherError: Error {}
        XCTAssertFalse(SomeOtherError().isMissingCloudKitZone)
        XCTAssertFalse(URLError(.notConnectedToInternet).isMissingCloudKitZone)
    }

    /// A different domain carrying the same numeric code. CKError bridging is keyed on
    /// the domain, so this must not be mistaken for a CloudKit answer.
    func testMatchingCodeInAnotherDomainIsNotMissingZone() {
        let error = NSError(domain: "com.example.other",
                            code: CKError.Code.zoneNotFound.rawValue) as Error
        XCTAssertFalse(error.isMissingCloudKitZone)
    }
}

final class PartnerUnpairedNoticeTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: PartnerUnpairedNotice.storageKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: PartnerUnpairedNotice.storageKey)
        super.tearDown()
    }

    func testDefaultsToFalse() {
        XCTAssertFalse(PartnerUnpairedNotice.happened)
    }

    func testRoundTrips() {
        PartnerUnpairedNotice.happened = true
        XCTAssertTrue(PartnerUnpairedNotice.happened)
    }

    /// Distinct from the cutover notice — they explain different things and a device can
    /// legitimately have one without the other.
    func testUsesItsOwnStorageKey() {
        XCTAssertNotEqual(PartnerUnpairedNotice.storageKey, CutoverNotice.storageKey)
    }
}
