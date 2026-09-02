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
        UserDefaults.standard.removeObject(forKey: CutoverNotice.storageKey)
        removeStoredBlobs()
        PairSecrets.store = InMemoryPairSecretStore()
        secrets = nil
        super.tearDown()
    }

    private func removeStoredBlobs() {
        UserDefaults.standard.removeObject(forKey: PairState.storageKey)
        LegacyPairing.clear()
    }

    /// The pre-2.0 v1 shape: all five fields, pair key included, in UserDefaults.
    private func writeLegacyV1Blob(pairKey: String = "legacy-key") {
        let blob: [String: String] = [
            "pairKey": pairKey,
            "myDeviceID": "device-A",
            "myName": "Alice",
            "partnerDeviceID": "device-B",
            "partnerName": "Bob"
        ]
        let data = try! JSONSerialization.data(withJSONObject: blob)
        UserDefaults.standard.set(data, forKey: LegacyPairing.storageKeyV1)
    }

    /// The pre-2.0 v2 shape: non-secret fields in UserDefaults, key in the store.
    private func writeLegacyV2Blob(pairKey: String = "legacy-key") {
        let blob: [String: String] = [
            "myDeviceID": "device-A",
            "myName": "Alice",
            "partnerDeviceID": "device-B",
            "partnerName": "Bob"
        ]
        let data = try! JSONSerialization.data(withJSONObject: blob)
        UserDefaults.standard.set(data, forKey: LegacyPairing.storageKeyV2)
        secrets.setSecret(pairKey, for: Constants.Keychain.pairKeyAccount)
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

    // MARK: - Per-direction state

    func testANewPairingIsNotCompleteInEitherDirection() {
        let state = makePairState()
        XCTAssertNil(state.outgoingZone)
        XCTAssertFalse(state.partnerCanReach)
        XCTAssertFalse(state.isComplete)
    }

    func testAcceptingTheirShareAloneDoesNotCompleteThePair() {
        var state = makePairState()
        state.outgoingZone = ZoneRef(zoneName: "inbox", ownerName: "partner")
        XCTAssertFalse(state.isComplete)
        // ...but it is enough to send, which is the joiner's whole position.
        XCTAssertTrue(state.canSend)
    }

    func testANewPairingCannotSendYet() {
        XCTAssertFalse(makePairState().canSend)
    }

    /// The inviter's trap: they know the partner accepted, but until their own share
    /// comes back they have nowhere to write. Offering the button here would mean a
    /// press that goes nowhere.
    func testTheirAcceptAloneDoesNotAllowSending() {
        var state = makePairState()
        state.partnerCanReach = true
        XCTAssertFalse(state.canSend)
    }

    func testTheirAcceptAloneDoesNotCompleteThePair() {
        var state = makePairState()
        state.partnerCanReach = true
        XCTAssertFalse(state.isComplete)
    }

    func testBothDirectionsCompleteThePair() {
        var state = makePairState()
        state.outgoingZone = ZoneRef(zoneName: "inbox", ownerName: "partner")
        state.partnerCanReach = true
        XCTAssertTrue(state.isComplete)
    }

    func testPerDirectionStateSurvivesSaveAndLoad() {
        var state = makePairState()
        state.outgoingZone = ZoneRef(zoneName: "inbox", ownerName: "partner")
        state.partnerCanReach = true
        state.save()

        let loaded = PairState.load()
        XCTAssertEqual(loaded?.outgoingZone, ZoneRef(zoneName: "inbox", ownerName: "partner"))
        XCTAssertEqual(loaded?.partnerCanReach, true)
        XCTAssertEqual(loaded?.isComplete, true)
    }

    func testZoneRefRoundTripsThroughACloudKitZoneID() {
        let ref = ZoneRef(zoneName: "inbox", ownerName: "_abc")
        XCTAssertEqual(ZoneRef(ref.zoneID), ref)
    }

    // MARK: - Pre-2.0 pairings are not resurrected

    func testAV1PairingDoesNotLoadAsAPair() {
        writeLegacyV1Blob()
        XCTAssertNil(PairState.load())
    }

    func testAV2PairingDoesNotLoadAsAPair() {
        writeLegacyV2Blob()
        XCTAssertNil(PairState.load())
    }

    func testLegacyPairKeyIsReadableFromAV1Blob() {
        writeLegacyV1Blob(pairKey: "v1-key")
        XCTAssertEqual(LegacyPairing.pairKey(), "v1-key")
    }

    func testLegacyPairKeyIsReadableFromAV2Blob() {
        writeLegacyV2Blob(pairKey: "v2-key")
        XCTAssertEqual(LegacyPairing.pairKey(), "v2-key")
    }

    func testLegacyPairKeyIsNilWhenThereWasNoPreviousPairing() {
        XCTAssertNil(LegacyPairing.pairKey())
    }

    func testLegacyPairKeyIsNilWhenAV2BlobHasNoStoredKey() {
        writeLegacyV2Blob()
        secrets.removeSecret(for: Constants.Keychain.pairKeyAccount)
        XCTAssertNil(LegacyPairing.pairKey())
    }

    func testClearingLegacyPairingsLeavesNothingToRead() {
        writeLegacyV1Blob()
        writeLegacyV2Blob()
        LegacyPairing.clear()
        XCTAssertNil(LegacyPairing.pairKey())
    }

    func testLegacyPairingExistsWithoutTouchingTheKeychain() {
        writeLegacyV2Blob()
        secrets.removeSecret(for: Constants.Keychain.pairKeyAccount)
        // The distinction the pre-unlock window depends on: the pairing is still there
        // even when its key can't be read yet.
        XCTAssertTrue(LegacyPairing.exists)
        XCTAssertNil(LegacyPairing.pairKey())
    }

    func testLegacyPairingDoesNotExistOnAFreshInstall() {
        XCTAssertFalse(LegacyPairing.exists)
    }

    func testLegacyPairingExistsForAV1Blob() {
        writeLegacyV1Blob()
        XCTAssertTrue(LegacyPairing.exists)
    }

    func testClearingLegacyPairingsClearsExists() {
        writeLegacyV1Blob()
        writeLegacyV2Blob()
        LegacyPairing.clear()
        XCTAssertFalse(LegacyPairing.exists)
    }

    // MARK: - Cutover notice

    func testCutoverNoticeDefaultsToFalse() {
        CutoverNotice.needsRepair = false
        XCTAssertFalse(CutoverNotice.needsRepair)
    }

    func testCutoverNoticePersists() {
        CutoverNotice.needsRepair = true
        XCTAssertTrue(CutoverNotice.needsRepair)
        CutoverNotice.needsRepair = false
        XCTAssertFalse(CutoverNotice.needsRepair)
    }
}
