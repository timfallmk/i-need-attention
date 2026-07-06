import XCTest

final class SnoozeStateTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: SnoozeState.storageKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: SnoozeState.storageKey)
        super.tearDown()
    }

    private func make(until: Date) -> SnoozeState {
        SnoozeState(recordName: "alert-123", until: until)
    }

    // MARK: - Persistence round-trip

    func testLoadReturnsNilWhenNothingStored() {
        XCTAssertNil(SnoozeState.load())
    }

    func testSaveThenLoadRoundTrips() {
        let original = make(until: Date().addingTimeInterval(900))
        original.save()
        XCTAssertEqual(SnoozeState.load(), original)
    }

    func testSaveOverwritesPrevious() {
        make(until: Date().addingTimeInterval(300)).save()
        var second = make(until: Date().addingTimeInterval(1800))
        second.recordName = "alert-456"
        second.save()
        XCTAssertEqual(SnoozeState.load()?.recordName, "alert-456")
    }

    func testClearRemovesStoredState() {
        make(until: Date().addingTimeInterval(900)).save()
        SnoozeState.clear()
        XCTAssertNil(SnoozeState.load())
    }

    // MARK: - isActive

    func testFutureUntilIsActive() {
        XCTAssertTrue(make(until: Date().addingTimeInterval(60)).isActive)
    }

    func testPastUntilIsNotActive() {
        XCTAssertFalse(make(until: Date().addingTimeInterval(-60)).isActive)
    }
}
