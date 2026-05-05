import XCTest

final class PairStateTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: PairState.storageKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: PairState.storageKey)
        super.tearDown()
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
}
