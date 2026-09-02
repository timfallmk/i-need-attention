import XCTest

final class PairStateTests: XCTestCase {

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
        UserDefaults.standard.removeObject(forKey: PairState.storageKey)
        UserDefaults.standard.removeObject(forKey: PairState.legacyStorageKey)
    }

    /// Writes the pre-2.0 shape: all five fields, pair key included, in UserDefaults.
    private func writeLegacyBlob(_ state: PairState) {
        let data = try! JSONEncoder().encode(state)
        UserDefaults.standard.set(data, forKey: PairState.legacyStorageKey)
    }

    private func makePairState(
        pairKey: String = "test-pair-key",
        myDeviceID: String = "device-A",
        myName: String = "Alice",
        partnerDeviceID: String = "device-B",
        partnerName: String = "Bob"
    ) -> PairState {
        PairState(
            pairKey: pairKey,
            myDeviceID: myDeviceID,
            myName: myName,
            partnerDeviceID: partnerDeviceID,
            partnerName: partnerName
        )
    }

    // MARK: - Equatable

    func testPairStatesWithSameFieldsAreEqual() {
        let a = makePairState()
        let b = makePairState()
        XCTAssertEqual(a, b)
    }

    func testPairStatesWithDifferentPairKeyAreNotEqual() {
        let a = makePairState(pairKey: "key-1")
        let b = makePairState(pairKey: "key-2")
        XCTAssertNotEqual(a, b)
    }

    func testPairStatesWithDifferentPartnerNameAreNotEqual() {
        let a = makePairState(partnerName: "Alice")
        let b = makePairState(partnerName: "Bob")
        XCTAssertNotEqual(a, b)
    }

    // MARK: - save / load round trip

    func testSaveAndLoadRoundTrip() {
        let state = makePairState()
        state.save()
        let loaded = PairState.load()
        XCTAssertEqual(loaded, state)
    }

    func testSaveAndLoadPreservesPairKey() {
        let state = makePairState(pairKey: "my-secret-key")
        state.save()
        XCTAssertEqual(PairState.load()?.pairKey, "my-secret-key")
    }

    func testSaveAndLoadPreservesMyDeviceID() {
        let state = makePairState(myDeviceID: "device-xyz")
        state.save()
        XCTAssertEqual(PairState.load()?.myDeviceID, "device-xyz")
    }

    func testSaveAndLoadPreservesMyName() {
        let state = makePairState(myName: "Carol")
        state.save()
        XCTAssertEqual(PairState.load()?.myName, "Carol")
    }

    func testSaveAndLoadPreservesPartnerDeviceID() {
        let state = makePairState(partnerDeviceID: "partner-device")
        state.save()
        XCTAssertEqual(PairState.load()?.partnerDeviceID, "partner-device")
    }

    func testSaveAndLoadPreservesPartnerName() {
        let state = makePairState(partnerName: "Dave")
        state.save()
        XCTAssertEqual(PairState.load()?.partnerName, "Dave")
    }

    // MARK: - load when nothing stored

    func testLoadReturnsNilWhenNothingStored() {
        XCTAssertNil(PairState.load())
    }

    // MARK: - clear

    func testClearRemovesSavedState() {
        let state = makePairState()
        state.save()
        XCTAssertNotNil(PairState.load())
        PairState.clear()
        XCTAssertNil(PairState.load())
    }

    func testClearWhenNothingStoredIsNoOp() {
        PairState.clear()
        XCTAssertNil(PairState.load())
    }

    func testSaveOverwritesPreviousState() {
        let first = makePairState(pairKey: "old-key", partnerName: "Old Partner")
        first.save()
        let second = makePairState(pairKey: "new-key", partnerName: "New Partner")
        second.save()
        let loaded = PairState.load()
        XCTAssertEqual(loaded?.pairKey, "new-key")
        XCTAssertEqual(loaded?.partnerName, "New Partner")
    }

    // MARK: - storageKey

    func testStorageKeyIsNonEmpty() {
        XCTAssertFalse(PairState.storageKey.isEmpty)
    }

    // MARK: - Secret storage

    func testSaveKeepsPairKeyOutOfUserDefaults() {
        makePairState(pairKey: "top-secret").save()
        let data = UserDefaults.standard.data(forKey: PairState.storageKey)
        XCTAssertNotNil(data)
        XCTAssertFalse(String(data: data!, encoding: .utf8)!.contains("top-secret"))
    }

    func testSaveStoresPairKeyInSecretStore() {
        makePairState(pairKey: "top-secret").save()
        XCTAssertEqual(secrets.secret(for: Constants.Keychain.pairKeyAccount), "top-secret")
    }

    func testLoadReturnsNilWhenSecretIsMissing() {
        makePairState().save()
        secrets.removeSecret(for: Constants.Keychain.pairKeyAccount)
        XCTAssertNil(PairState.load())
    }

    func testSaveWritesNothingWhenTheSecretStoreRefuses() {
        secrets.writesSucceed = false
        XCTAssertFalse(makePairState().save())
        XCTAssertNil(UserDefaults.standard.data(forKey: PairState.storageKey))
        XCTAssertNil(PairState.load())
    }

    func testClearRemovesTheSecret() {
        makePairState().save()
        PairState.clear()
        XCTAssertNil(secrets.secret(for: Constants.Keychain.pairKeyAccount))
    }

    // MARK: - Migration from the pre-2.0 blob

    func testLegacyBlobIsLoaded() {
        let legacy = makePairState(pairKey: "legacy-key", partnerName: "Erin")
        writeLegacyBlob(legacy)
        XCTAssertEqual(PairState.load(), legacy)
    }

    func testLegacyBlobIsMigratedToSplitStorage() {
        writeLegacyBlob(makePairState(pairKey: "legacy-key"))
        _ = PairState.load()
        XCTAssertNil(UserDefaults.standard.data(forKey: PairState.legacyStorageKey))
        XCTAssertNotNil(UserDefaults.standard.data(forKey: PairState.storageKey))
        XCTAssertEqual(secrets.secret(for: Constants.Keychain.pairKeyAccount), "legacy-key")
    }

    func testMigratedStateSurvivesASecondLoad() {
        let legacy = makePairState(pairKey: "legacy-key")
        writeLegacyBlob(legacy)
        _ = PairState.load()
        XCTAssertEqual(PairState.load(), legacy)
    }

    func testLegacyBlobIsKeptWhenTheSecretStoreRefusesTheWrite() {
        let legacy = makePairState(pairKey: "legacy-key")
        writeLegacyBlob(legacy)
        secrets.writesSucceed = false

        XCTAssertEqual(PairState.load(), legacy)
        XCTAssertNotNil(UserDefaults.standard.data(forKey: PairState.legacyStorageKey))

        secrets.writesSucceed = true
        XCTAssertEqual(PairState.load(), legacy)
        XCTAssertNil(UserDefaults.standard.data(forKey: PairState.legacyStorageKey))
    }

    func testSplitStorageIsPreferredOverAStaleLegacyBlob() {
        makePairState(pairKey: "current-key", partnerName: "Current").save()
        writeLegacyBlob(makePairState(pairKey: "stale-key", partnerName: "Stale"))
        XCTAssertEqual(PairState.load()?.pairKey, "current-key")
        XCTAssertEqual(PairState.load()?.partnerName, "Current")
    }

    func testClearRemovesTheLegacyBlobToo() {
        writeLegacyBlob(makePairState())
        PairState.clear()
        XCTAssertNil(PairState.load())
    }
}
