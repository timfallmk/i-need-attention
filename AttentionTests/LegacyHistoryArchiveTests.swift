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

    // MARK: - Purge phase

    func testPurgingIsNotATerminalPhase() {
        LegacyHistoryCaptureState(phase: .purging).save()
        XCTAssertEqual(LegacyHistoryCaptureState.load()?.phase, .purging)
    }

    func testPurgingPhaseRoundTripsWithItsOwnAttemptCount() {
        LegacyHistoryCaptureState(phase: .purging, failedAttempts: 2).save()
        let loaded = LegacyHistoryCaptureState.load()
        XCTAssertEqual(loaded?.phase, .purging)
        XCTAssertEqual(loaded?.failedAttempts, 2)
    }

    /// The archive is what makes deleting the originals safe, so a state that says
    /// "purging" must never be reachable without one having been written.
    func testPurgingStillReportsExhaustionAtTheLimit() {
        var state = LegacyHistoryCaptureState(phase: .purging,
                                              failedAttempts: LegacyHistoryCaptureState.maxAttempts - 1)
        XCTAssertTrue(state.recordFailure())
    }

    // MARK: - Outcome and release (#76)

    func testOutcomeAndStampRoundTrip() {
        LegacyHistoryCaptureState(phase: .done, outcome: .gaveUp, stampedZoneName: "inbox-1").save()
        let loaded = LegacyHistoryCaptureState.load()
        XCTAssertEqual(loaded?.outcome, .gaveUp)
        XCTAssertEqual(loaded?.stampedZoneName, "inbox-1")
    }

    /// Every install already in the field has a blob without the new keys. Failing to
    /// decode it would read as "never considered" and run the one-shot capture again.
    func testAStateWrittenBeforeOutcomesStillLoads() throws {
        let legacy = Data(#"{"phase":"done","failedAttempts":10}"#.utf8)
        UserDefaults.standard.set(legacy, forKey: LegacyHistoryCaptureState.storageKey)

        let loaded = try XCTUnwrap(LegacyHistoryCaptureState.load())
        XCTAssertEqual(loaded.phase, .done)
        XCTAssertEqual(loaded.failedAttempts, 10)
        XCTAssertNil(loaded.outcome)
        // Unstamped is what makes the launch pass release the partner once.
        XCTAssertNil(loaded.stampedZoneName)
    }

    func testSummaryNamesAGiveUpLoudly() {
        let state = LegacyHistoryCaptureState(phase: .done, outcome: .gaveUp)
        XCTAssertEqual(state.diagnosticSummary(partnerZoneName: nil), "GAVE UP, not archived")
    }

    func testSummarySaysWhetherThisPartnerHasBeenReleased() {
        var state = LegacyHistoryCaptureState(phase: .done, outcome: .archived, stampedZoneName: "inbox-1")
        XCTAssertEqual(state.diagnosticSummary(partnerZoneName: "inbox-1"), "archived; partner released")
        // A stamp belongs to a pairing: a new partner's zone has not been told anything.
        XCTAssertEqual(state.diagnosticSummary(partnerZoneName: "inbox-2"),
                       "archived; partner NOT YET RELEASED")
        state.stampedZoneName = nil
        XCTAssertEqual(state.diagnosticSummary(partnerZoneName: "inbox-1"),
                       "archived; partner NOT YET RELEASED")
    }

    /// A fresh install that adopts a pairing shares one profile with the account's
    /// other devices. Stamping it on launch would release the partner's purge while
    /// one of them was still fetching.
    func testOnlyAnInstallThatRanItsOwnCaptureReleasesOnLaunch() {
        XCTAssertTrue(LegacyHistoryCaptureState(phase: .done, outcome: .archived).hasSettledItsOwnCapture)
        XCTAssertTrue(LegacyHistoryCaptureState(phase: .done, outcome: .gaveUp).hasSettledItsOwnCapture)
        XCTAssertFalse(LegacyHistoryCaptureState(phase: .done, outcome: .nothingToCapture).hasSettledItsOwnCapture)
        XCTAssertFalse(LegacyHistoryCaptureState(phase: .pending).hasSettledItsOwnCapture)
        XCTAssertFalse(LegacyHistoryCaptureState(phase: .purging).hasSettledItsOwnCapture)
    }

    /// Before outcomes were recorded, a spent budget is the only trace a give-up left —
    /// and the same blob with attempts to spare is a fresh install's.
    func testAnUnrecordedOutcomeIsReadFromTheAttemptCount() {
        let gaveUp = LegacyHistoryCaptureState(phase: .done,
                                               failedAttempts: LegacyHistoryCaptureState.maxAttempts)
        XCTAssertTrue(gaveUp.hasSettledItsOwnCapture)
        XCTAssertFalse(LegacyHistoryCaptureState(phase: .done).hasSettledItsOwnCapture)
    }

    // MARK: - Backfilling an outcome the previous build did not record

    /// A capture that succeeded before outcomes existed left a snapshot and a budget
    /// with attempts to spare. It ran its own capture, so a stamp that never landed
    /// has to be retried — reading it as a fresh install would skip it for good.
    func testASnapshotOnDiskMeansTheCaptureWasArchived() {
        var state = LegacyHistoryCaptureState(phase: .done, failedAttempts: 2)
        XCTAssertTrue(state.backfillOutcome(archiveExists: true))
        XCTAssertEqual(state.outcome, .archived)
        XCTAssertTrue(state.hasSettledItsOwnCapture)
    }

    /// The purge can run out of attempts after the snapshot is safe. That is still
    /// archived: only the cleanup was abandoned.
    func testASnapshotOutweighsASpentBudget() {
        var state = LegacyHistoryCaptureState(phase: .done,
                                              failedAttempts: LegacyHistoryCaptureState.maxAttempts)
        state.backfillOutcome(archiveExists: true)
        XCTAssertEqual(state.outcome, .archived)
    }

    func testNoSnapshotAndASpentBudgetIsAGiveUp() {
        var state = LegacyHistoryCaptureState(phase: .done,
                                              failedAttempts: LegacyHistoryCaptureState.maxAttempts)
        XCTAssertTrue(state.backfillOutcome(archiveExists: false))
        XCTAssertEqual(state.outcome, .gaveUp)
        XCTAssertTrue(state.hasSettledItsOwnCapture)
    }

    /// The fresh install: nothing was ever fetched, so nothing was written and nothing
    /// was spent. It must stay out of the launch-time stamp.
    func testNoSnapshotAndAnUnspentBudgetIsNothingToCapture() {
        var state = LegacyHistoryCaptureState(phase: .done)
        XCTAssertTrue(state.backfillOutcome(archiveExists: false))
        XCTAssertEqual(state.outcome, .nothingToCapture)
        XCTAssertFalse(state.hasSettledItsOwnCapture)
    }

    func testBackfillLeavesARecordedOutcomeAndARunningCaptureAlone() {
        var recorded = LegacyHistoryCaptureState(phase: .done, outcome: .gaveUp)
        XCTAssertFalse(recorded.backfillOutcome(archiveExists: true))
        XCTAssertEqual(recorded.outcome, .gaveUp)

        var running = LegacyHistoryCaptureState(phase: .purging)
        XCTAssertFalse(running.backfillOutcome(archiveExists: true))
        XCTAssertNil(running.outcome)
    }

    func testSummaryDoesNotAccuseAnInstallThatKeepsNoRecordOfItsStamp() {
        let fresh = LegacyHistoryCaptureState(phase: .done, outcome: .nothingToCapture)
        XCTAssertEqual(fresh.diagnosticSummary(partnerZoneName: "inbox-1"), "none to capture")
        XCTAssertEqual(LegacyHistoryCaptureState(phase: .done).diagnosticSummary(partnerZoneName: "inbox-1"),
                       "done")
    }

    func testSummaryReportsReleaseWhileThePurgeWaits() {
        let waiting = LegacyHistoryCaptureState(phase: .purging, stampedZoneName: "inbox-1")
        XCTAssertEqual(waiting.diagnosticSummary(partnerZoneName: "inbox-1"),
                       "archived, purging (0 failed); partner released")
    }

    func testSummaryCoversARunningCaptureAndAnUnrecordedOutcome() {
        XCTAssertEqual(LegacyHistoryCaptureState(phase: .pending, failedAttempts: 2)
                        .diagnosticSummary(partnerZoneName: nil), "capturing (2 failed)")
        XCTAssertEqual(LegacyHistoryCaptureState(phase: .purging)
                        .diagnosticSummary(partnerZoneName: nil), "archived, purging (0 failed)")
        XCTAssertEqual(LegacyHistoryCaptureState(phase: .done)
                        .diagnosticSummary(partnerZoneName: nil), "done")
    }
}
