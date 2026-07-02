import XCTest

final class PendingInviteTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: PendingInvite.storageKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: PendingInvite.storageKey)
        super.tearDown()
    }

    private func makeInvite(createdAt: Date = Date()) -> PendingInvite {
        PendingInvite(
            pairKey: "test-pair-key",
            myDeviceID: "device-123",
            myName: "Tim",
            recordName: "record-abc",
            createdAt: createdAt
        )
    }

    // MARK: - Persistence round-trip

    func testLoadReturnsNilWhenNothingStored() {
        XCTAssertNil(PendingInvite.load())
    }

    func testSaveThenLoadRoundTrips() {
        let original = makeInvite()
        original.save()
        let loaded = PendingInvite.load()
        XCTAssertEqual(loaded, original)
    }

    func testSaveOverwritesPrevious() {
        makeInvite().save()
        var second = makeInvite()
        second.pairKey = "another-key"
        second.save()
        XCTAssertEqual(PendingInvite.load()?.pairKey, "another-key")
    }

    func testClearRemovesStoredInvite() {
        makeInvite().save()
        PendingInvite.clear()
        XCTAssertNil(PendingInvite.load())
    }

    // MARK: - Expiry

    func testFreshInviteIsNotExpired() {
        XCTAssertFalse(makeInvite().isExpired)
    }

    func testInviteOlderThanIntervalIsExpired() {
        let old = makeInvite(createdAt: Date().addingTimeInterval(-PendingInvite.expiryInterval - 60))
        XCTAssertTrue(old.isExpired)
    }

    func testInviteJustUnderIntervalIsNotExpired() {
        let recent = makeInvite(createdAt: Date().addingTimeInterval(-PendingInvite.expiryInterval + 60))
        XCTAssertFalse(recent.isExpired)
    }

    // MARK: - Invite derivation

    func testDerivedInviteCarriesStoredFields() {
        let pending = makeInvite()
        let invite = pending.invite
        XCTAssertEqual(invite.pairKey, pending.pairKey)
        XCTAssertEqual(invite.inviterDeviceID, pending.myDeviceID)
        XCTAssertEqual(invite.inviterName, pending.myName)
    }

    func testDerivedInvitePayloadRoundTrips() {
        // The persisted invite must reproduce the exact same shareable/QR payload —
        // the link and the on-screen code stay interchangeable across a resume.
        let pending = makeInvite()
        let parsed = PairingInvite.from(qrPayload: pending.invite.qrPayload)
        XCTAssertEqual(parsed?.pairKey, pending.pairKey)
        XCTAssertEqual(parsed?.inviterDeviceID, pending.myDeviceID)
        XCTAssertEqual(parsed?.inviterName, pending.myName)
    }
}
