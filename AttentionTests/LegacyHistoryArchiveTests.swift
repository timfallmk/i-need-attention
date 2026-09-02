import XCTest

final class LegacyHistoryArchiveTests: XCTestCase {

    override func setUp() {
        super.setUp()
        LegacyHistoryArchive.clear()
        LegacyHistoryCaptureState.clear()
    }

    override func tearDown() {
        LegacyHistoryArchive.clear()
        LegacyHistoryCaptureState.clear()
        super.tearDown()
    }

    private func archived(
        _ recordName: String,
        createdAt: Date = Date(),
        senderName: String = "Sam"
    ) -> ArchivedAlert {
        var alert = ArchivedAlert(.preview(senderName: senderName))
        alert.recordName = recordName
        alert.createdAt = createdAt
        return alert
    }

    // MARK: - Persistence

    func testLoadReturnsNilWhenNothingCaptured() {
        XCTAssertNil(LegacyHistoryArchive.load())
    }

    func testSaveAndLoadRoundTrips() {
        let archive = LegacyHistoryArchive(alerts: [archived("a"), archived("b")], capturedAt: Date())
        XCTAssertTrue(archive.save())
        XCTAssertEqual(LegacyHistoryArchive.load()?.alerts.map(\.recordName), ["a", "b"])
    }

    func testSaveOverwritesPreviousCapture() {
        LegacyHistoryArchive(alerts: [archived("old")], capturedAt: Date()).save()
        LegacyHistoryArchive(alerts: [archived("new")], capturedAt: Date()).save()
        XCTAssertEqual(LegacyHistoryArchive.load()?.alerts.map(\.recordName), ["new"])
    }

    func testClearRemovesTheCapture() {
        LegacyHistoryArchive(alerts: [archived("a")], capturedAt: Date()).save()
        LegacyHistoryArchive.clear()
        XCTAssertNil(LegacyHistoryArchive.load())
    }

    func testArchivedFieldsSurviveTheRoundTrip() {
        let source = AlertRecord.preview(state: .acknowledged, senderName: "Rae", message: "needs tea", ackEmoji: "❤️")
        LegacyHistoryArchive(alerts: [ArchivedAlert(source)], capturedAt: Date()).save()

        let loaded = LegacyHistoryArchive.load()?.alerts.first
        XCTAssertEqual(loaded?.senderName, "Rae")
        XCTAssertEqual(loaded?.message, "needs tea")
        XCTAssertEqual(loaded?.ackEmoji, "❤️")
        XCTAssertEqual(loaded?.state, Constants.AlertState.acknowledged.rawValue)
        XCTAssertEqual(loaded?.recordName, source.id.recordName)
    }

    // MARK: - Rehydration

    func testRehydratedRecordCarriesTheArchivedFields() {
        let source = AlertRecord.preview(state: .seen, senderName: "Rae", message: "needs tea")
        let rehydrated = AlertRecord(archived: ArchivedAlert(source))

        XCTAssertEqual(rehydrated.id, source.id)
        XCTAssertEqual(rehydrated.senderName, source.senderName)
        XCTAssertEqual(rehydrated.message, source.message)
        XCTAssertEqual(rehydrated.state, .seen)
        XCTAssertEqual(rehydrated.senderDeviceID, source.senderDeviceID)
    }

    func testRehydratedRecordFallsBackToSentForAnUnknownState() {
        var alert = ArchivedAlert(.preview())
        alert.state = "not-a-state"
        XCTAssertEqual(AlertRecord(archived: alert).state, .sent)
    }

    // MARK: - Merging

    func testMergedReturnsNewestFirst() {
        let now = Date()
        let merged = LegacyHistoryArchive.merged(
            live: [],
            archived: [
                archived("old", createdAt: now.addingTimeInterval(-100)),
                archived("new", createdAt: now)
            ]
        )
        XCTAssertEqual(merged.map(\.id.recordName), ["new", "old"])
    }

    func testMergedPrefersTheLiveCopyOfARecord() {
        let live = AlertRecord.preview(state: .acknowledged, senderName: "Live")
        let stale = archived(live.id.recordName, senderName: "Stale")

        let merged = LegacyHistoryArchive.merged(live: [live], archived: [stale])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.senderName, "Live")
    }

    func testMergedKeepsArchivedRecordsTheLiveFetchDidNotReturn() {
        let live = AlertRecord.preview()
        let merged = LegacyHistoryArchive.merged(live: [live], archived: [archived("only-archived")])
        XCTAssertEqual(Set(merged.map(\.id.recordName)), [live.id.recordName, "only-archived"])
    }

    func testMergedWithNothingIsEmpty() {
        XCTAssertTrue(LegacyHistoryArchive.merged(live: [], archived: []).isEmpty)
    }

    // MARK: - Capture state

    func testCaptureStateIsAbsentBeforeAnythingHappens() {
        XCTAssertNil(LegacyHistoryCaptureState.load())
    }

    func testCaptureStateRoundTrips() {
        LegacyHistoryCaptureState(phase: .pending, failedAttempts: 3).save()
        let loaded = LegacyHistoryCaptureState.load()
        XCTAssertEqual(loaded?.phase, .pending)
        XCTAssertEqual(loaded?.failedAttempts, 3)
    }

    func testCaptureIsNotExhaustedBelowTheAttemptLimit() {
        let state = LegacyHistoryCaptureState(phase: .pending,
                                              failedAttempts: LegacyHistoryCaptureState.maxAttempts - 1)
        XCTAssertFalse(state.isExhausted)
    }

    func testCaptureIsExhaustedAtTheAttemptLimit() {
        let state = LegacyHistoryCaptureState(phase: .pending,
                                              failedAttempts: LegacyHistoryCaptureState.maxAttempts)
        XCTAssertTrue(state.isExhausted)
    }

    func testRecordFailureReportsRetryUntilTheLimit() {
        var state = LegacyHistoryCaptureState(phase: .pending)
        for attempt in 1..<LegacyHistoryCaptureState.maxAttempts {
            XCTAssertFalse(state.recordFailure(), "attempt \(attempt) should still retry")
        }
        XCTAssertTrue(state.recordFailure())
    }

    func testRecordFailureCountsAttempts() {
        var state = LegacyHistoryCaptureState(phase: .pending)
        _ = state.recordFailure()
        _ = state.recordFailure()
        XCTAssertEqual(state.failedAttempts, 2)
    }
}
