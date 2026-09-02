import Foundation
import XCTest

final class MetricKitSummaryTests: XCTestCase {
    private let first = Date(timeIntervalSince1970: 1_000)
    private let second = Date(timeIntervalSince1970: 2_000)

    func testEmptyStartsAtZero() {
        let summary = MetricKitSummary.empty
        XCTAssertTrue(summary.isEmpty)
        XCTAssertEqual(summary.payloadsReceived, 0)
        XCTAssertEqual(summary.crashes, 0)
        XCTAssertNil(summary.lastReceivedAt)
        XCTAssertNil(summary.lastCrashAt)
        XCTAssertNil(summary.lastCrashReason)
    }

    func testRecordingAPayloadAccumulates() {
        var summary = MetricKitSummary.empty
        summary.record(receivedAt: first, crashes: 1, hangs: 2, diskWriteExceptions: 3,
                       cpuExceptions: 4, crashReason: "SIGSEGV")

        XCTAssertFalse(summary.isEmpty)
        XCTAssertEqual(summary.payloadsReceived, 1)
        XCTAssertEqual(summary.crashes, 1)
        XCTAssertEqual(summary.hangs, 2)
        XCTAssertEqual(summary.diskWriteExceptions, 3)
        XCTAssertEqual(summary.cpuExceptions, 4)
        XCTAssertEqual(summary.lastReceivedAt, first)
    }

    func testCountsAccumulateAcrossPayloads() {
        var summary = MetricKitSummary.empty
        summary.record(receivedAt: first, crashes: 1, hangs: 1, diskWriteExceptions: 0,
                       cpuExceptions: 0, crashReason: nil)
        summary.record(receivedAt: second, crashes: 2, hangs: 0, diskWriteExceptions: 1,
                       cpuExceptions: 0, crashReason: nil)

        XCTAssertEqual(summary.payloadsReceived, 2)
        XCTAssertEqual(summary.crashes, 3)
        XCTAssertEqual(summary.hangs, 1)
        XCTAssertEqual(summary.diskWriteExceptions, 1)
        XCTAssertEqual(summary.lastReceivedAt, second)
    }

    // MARK: - Crash bookkeeping

    func testCrashDetailsAreSetOnlyWhenThereWasACrash() {
        var summary = MetricKitSummary.empty
        summary.record(receivedAt: first, crashes: 0, hangs: 1, diskWriteExceptions: 0,
                       cpuExceptions: 0, crashReason: nil)
        XCTAssertNil(summary.lastCrashAt)

        summary.record(receivedAt: second, crashes: 1, hangs: 0, diskWriteExceptions: 0,
                       cpuExceptions: 0, crashReason: "SIGABRT")
        XCTAssertEqual(summary.lastCrashAt, second)
        XCTAssertEqual(summary.lastCrashReason, "SIGABRT")
    }

    func testACrashFreePayloadDoesNotBlankTheLastKnownCrash() {
        // A daily payload with nothing wrong in it must not erase yesterday's crash.
        var summary = MetricKitSummary.empty
        summary.record(receivedAt: first, crashes: 1, hangs: 0, diskWriteExceptions: 0,
                       cpuExceptions: 0, crashReason: "SIGSEGV")
        summary.record(receivedAt: second, crashes: 0, hangs: 0, diskWriteExceptions: 0,
                       cpuExceptions: 0, crashReason: nil)

        XCTAssertEqual(summary.lastCrashAt, first)
        XCTAssertEqual(summary.lastCrashReason, "SIGSEGV")
        XCTAssertEqual(summary.lastReceivedAt, second)
    }

    func testCrashReasonIsBounded() {
        var summary = MetricKitSummary.empty
        summary.record(receivedAt: first, crashes: 1, hangs: 0, diskWriteExceptions: 0,
                       cpuExceptions: 0, crashReason: String(repeating: "x", count: 500))
        XCTAssertEqual(summary.lastCrashReason?.count, MetricKitSummary.maxReasonLength)
    }

    func testANewCrashWithoutAReasonClearsTheOldReason() {
        // lastCrashAt and lastCrashReason describe the same crash. Leaving the previous
        // reason attached to a newer timestamp would report a cause that never happened,
        // which is worse in a diagnostic than reporting no cause at all.
        var summary = MetricKitSummary.empty
        summary.record(receivedAt: first, crashes: 1, hangs: 0, diskWriteExceptions: 0,
                       cpuExceptions: 0, crashReason: "SIGSEGV")
        summary.record(receivedAt: second, crashes: 1, hangs: 0, diskWriteExceptions: 0,
                       cpuExceptions: 0, crashReason: "")

        XCTAssertNil(summary.lastCrashReason)
        XCTAssertEqual(summary.lastCrashAt, second)
        XCTAssertEqual(summary.crashes, 2)
    }

    func testANewCrashWithoutAReasonAlsoClearsWhenNil() {
        var summary = MetricKitSummary.empty
        summary.record(receivedAt: first, crashes: 1, hangs: 0, diskWriteExceptions: 0,
                       cpuExceptions: 0, crashReason: "SIGSEGV")
        summary.record(receivedAt: second, crashes: 1, hangs: 0, diskWriteExceptions: 0,
                       cpuExceptions: 0, crashReason: nil)

        XCTAssertNil(summary.lastCrashReason)
        XCTAssertEqual(summary.lastCrashAt, second)
    }

    func testNegativeCountsCannotDriveTotalsBackwards() {
        var summary = MetricKitSummary.empty
        summary.record(receivedAt: first, crashes: 2, hangs: 0, diskWriteExceptions: 0,
                       cpuExceptions: 0, crashReason: nil)
        summary.record(receivedAt: second, crashes: -5, hangs: -1, diskWriteExceptions: 0,
                       cpuExceptions: 0, crashReason: nil)

        XCTAssertEqual(summary.crashes, 2)
        XCTAssertEqual(summary.hangs, 0)
    }

    // MARK: - Persistence shape

    func testCodableRoundTrip() throws {
        var summary = MetricKitSummary.empty
        summary.record(receivedAt: first, crashes: 1, hangs: 2, diskWriteExceptions: 0,
                       cpuExceptions: 1, crashReason: "SIGSEGV")

        let data = try JSONEncoder().encode(summary)
        let decoded = try JSONDecoder().decode(MetricKitSummary.self, from: data)
        XCTAssertEqual(decoded, summary)
    }
}
