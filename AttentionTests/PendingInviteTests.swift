import XCTest

final class PendingInviteTests: XCTestCase {

    private var secrets: InMemoryPairSecretStore!

    override func setUp() {
        super.setUp()
        secrets = InMemoryPairSecretStore()
        PairSecrets.store = secrets
        removeStoredBlobs()
    }

    override func tearDown() {
        removeStoredBlobs()
        PairSecrets.store = InMemoryPairSecretStore()
        secrets = nil
        super.tearDown()
    }

    private func removeStoredBlobs() {
        UserDefaults.standard.removeObject(forKey: PendingInvite.storageKey)
        for key in PendingInvite.legacyStorageKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private let shareURL = URL(string: "https://www.icloud.com/share/0ABCdef")!

    private func makeInvite(createdAt: Date = Date()) -> PendingInvite {
        PendingInvite(
            pairKey: "test-pair-key",
            myDeviceID: "device-123",
            myName: "Tim",
            shareURL: shareURL,
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

    // MARK: - Secret storage

    func testSaveKeepsPairKeyOutOfUserDefaults() {
        var invite = makeInvite()
        invite.pairKey = "top-secret"
        invite.save()
        let data = UserDefaults.standard.data(forKey: PendingInvite.storageKey)
        XCTAssertNotNil(data)
        XCTAssertFalse(String(data: data!, encoding: .utf8)!.contains("top-secret"))
        XCTAssertEqual(secrets.secret(for: Constants.Keychain.pendingInviteKeyAccount), "top-secret")
    }

    func testInviteAndPairUseSeparateSecretAccounts() {
        makeInvite().save()
        XCTAssertNil(secrets.secret(for: Constants.Keychain.pairKeyAccount))
    }

    func testLoadReturnsNilWhenSecretIsMissing() {
        makeInvite().save()
        secrets.removeSecret(for: Constants.Keychain.pendingInviteKeyAccount)
        XCTAssertNil(PendingInvite.load())
    }

    func testSaveWritesNothingWhenTheSecretStoreRefuses() {
        secrets.writesSucceed = false
        XCTAssertFalse(makeInvite().save())
        XCTAssertNil(UserDefaults.standard.data(forKey: PendingInvite.storageKey))
        XCTAssertNil(PendingInvite.load())
    }

    func testClearRemovesTheSecret() {
        makeInvite().save()
        PendingInvite.clear()
        XCTAssertNil(secrets.secret(for: Constants.Keychain.pendingInviteKeyAccount))
    }

    // MARK: - Pre-2.0 invites are not resurrected

    func testALegacyInviteDoesNotLoad() {
        let blob: [String: String] = [
            "pairKey": "legacy-key",
            "myDeviceID": "device-123",
            "myName": "Tim",
            "recordName": "record-abc"
        ]
        let data = try! JSONSerialization.data(withJSONObject: blob)
        UserDefaults.standard.set(data, forKey: PendingInvite.legacyStorageKeys[0])
        XCTAssertNil(PendingInvite.load())
    }

    func testClearRemovesLegacyInvitesToo() {
        UserDefaults.standard.set(Data("{}".utf8), forKey: PendingInvite.legacyStorageKeys[0])
        UserDefaults.standard.set(Data("{}".utf8), forKey: PendingInvite.legacyStorageKeys[1])
        PendingInvite.clear()
        for key in PendingInvite.legacyStorageKeys {
            XCTAssertNil(UserDefaults.standard.data(forKey: key))
        }
    }

    func testDerivedInviteCarriesTheShareURL() {
        XCTAssertEqual(makeInvite().invite.shareURL, shareURL)
    }
}
