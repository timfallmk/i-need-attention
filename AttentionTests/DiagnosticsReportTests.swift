import Foundation
import XCTest

final class DiagnosticsReportTests: XCTestCase {
    private let pairKey = "3q2-7wAAAAAAAAAAAAAAAA"
    private let myDeviceID = "1E9F5C6A-0000-4000-8000-000000000001"
    private let partnerDeviceID = "1E9F5C6A-0000-4000-8000-000000000002"

    // MARK: - Fingerprints

    func testFingerprintIsDeterministic() {
        XCTAssertEqual(DiagnosticsReport.fingerprint(of: pairKey),
                       DiagnosticsReport.fingerprint(of: pairKey))
    }

    func testFingerprintDiffersPerInput() {
        XCTAssertNotEqual(DiagnosticsReport.fingerprint(of: myDeviceID),
                          DiagnosticsReport.fingerprint(of: partnerDeviceID))
    }

    func testFingerprintIsShortAndDoesNotContainTheInput() {
        let printed = DiagnosticsReport.fingerprint(of: pairKey)
        XCTAssertEqual(printed?.count, 8)
        XCTAssertNotNil(printed)
        XCTAssertFalse(printed?.contains(pairKey) ?? true)
    }

    func testFingerprintIsNilWhenThereIsNothingToPrint() {
        XCTAssertNil(DiagnosticsReport.fingerprint(of: nil))
        XCTAssertNil(DiagnosticsReport.fingerprint(of: ""))
    }

    func testPairFingerprintMatchesTheLookupHashUsedOnRecords() {
        // The point of matching: a report can be lined up against the records it describes
        // without either carrying the pair key.
        let expected = String(PairCrypto.lookupHash(pairKey: pairKey).prefix(8))
        XCTAssertEqual(DiagnosticsReport.fingerprint(of: pairKey), expected)
    }

    // MARK: - Failure-reason redaction

    func testFailureReasonHasThePairKeyStripped() {
        // A subscription save that fails can echo the predicate, and the predicate carries
        // the pair key. Safe in local settings; not safe in a report the user sends on.
        let raw = "BAD_REQUEST: predicate pairKey == \"\(pairKey)\" rejected"
        let redacted = DiagnosticsReport.redactedFailureReason(raw, pairKey: pairKey)
        XCTAssertNotNil(redacted)
        XCTAssertFalse(redacted!.contains(pairKey))
        XCTAssertTrue(redacted!.contains("<pairKey>"))
        XCTAssertTrue(redacted!.contains("BAD_REQUEST"))
    }

    func testFailureReasonStripsEveryOccurrence() {
        let raw = "\(pairKey) then \(pairKey) again"
        let redacted = DiagnosticsReport.redactedFailureReason(raw, pairKey: pairKey)
        XCTAssertFalse(redacted?.contains(pairKey) ?? true)
    }

    func testFailureReasonPassesThroughWhenThereIsNoPairKey() {
        XCTAssertEqual(DiagnosticsReport.redactedFailureReason("plain error", pairKey: nil),
                       "plain error")
        XCTAssertEqual(DiagnosticsReport.redactedFailureReason("plain error", pairKey: ""),
                       "plain error")
    }

    func testFailureReasonIsNilWhenAbsent() {
        XCTAssertNil(DiagnosticsReport.redactedFailureReason(nil, pairKey: pairKey))
        XCTAssertNil(DiagnosticsReport.redactedFailureReason("", pairKey: pairKey))
    }

    // MARK: - The invariant this type exists for

    func testRenderedReportLeaksNothingPrivate() {
        let secrets = [
            pairKey,
            myDeviceID,
            partnerDeviceID,
            "Tim Fall",
            "needs coffee",
            "\u{2764}\u{FE0F}"
        ]
        let rendered = makeReport(
            failureReason: "BAD_REQUEST: pairKey == \"\(pairKey)\"",
            events: [acknowledgedEvent()]
        ).render()

        for secret in secrets {
            XCTAssertFalse(rendered.contains(secret), "report leaked \(secret)")
        }
    }

    func testRenderIsStableForTheSameInput() {
        // Two exports from an unchanged install should diff to nothing.
        let report = makeReport(events: [acknowledgedEvent()])
        XCTAssertEqual(report.render(), report.render())
    }

    // MARK: - Rendering

    func testRenderIncludesEverySection() {
        let rendered = makeReport().render()
        for section in ["[App]", "[Device diagnostics]", "[Pairing]", "[Notifications]",
                        "[Subscriptions]", "[Recent alerts]"] {
            XCTAssertTrue(rendered.contains(section), "missing \(section)")
        }
    }

    func testUnpairedReportSaysSoRatherThanShowingBlanks() {
        let rendered = makeReport(paired: false).render()
        XCTAssertTrue(rendered.contains("Pair: not paired"))
    }

    func testNoEventsRendersAsNone() {
        let rendered = makeReport(events: []).render()
        XCTAssertTrue(rendered.contains("[Recent alerts] (0)"))
        XCTAssertTrue(rendered.contains("none"))
    }

    func testEventLineCarriesLifecycleButNotContent() {
        let rendered = makeReport(events: [acknowledgedEvent()]).render()
        XCTAssertTrue(rendered.contains("incoming"))
        XCTAssertTrue(rendered.contains("acknowledged"))
        XCTAssertTrue(rendered.contains("critical"))
        XCTAssertTrue(rendered.contains("emoji"))
        XCTAssertTrue(rendered.contains("seen="))
        XCTAssertTrue(rendered.contains("acked="))
    }

    func testTimestampsAreISO8601UTC() {
        let rendered = makeReport().render()
        XCTAssertTrue(rendered.contains("1970-01-01T00:00:00Z"))
    }

    func testSubscriptionFailureIsCalledOutLoudly() {
        let ok = makeReport().render()
        XCTAssertTrue(ok.contains("Ack subscription: ok"))

        let broken = makeReport(failureReason: "CKError 15").render()
        XCTAssertTrue(broken.contains("Ack subscription: UNAVAILABLE"))
        XCTAssertTrue(broken.contains("CKError 15"))
    }

    // MARK: - MetricKit section

    func testMetricsSectionSaysSoWhenNothingHasArrived() {
        let rendered = makeReport(metrics: nil).render()
        XCTAssertTrue(rendered.contains("MetricKit: nothing received yet"))

        let empty = makeReport(metrics: .empty).render()
        XCTAssertTrue(empty.contains("MetricKit: nothing received yet"))
    }

    func testMetricsSectionRendersWhatArrived() {
        var summary = MetricKitSummary.empty
        summary.record(receivedAt: Date(timeIntervalSince1970: 0), crashes: 2, hangs: 1,
                       diskWriteExceptions: 0, cpuExceptions: 3, crashReason: "SIGSEGV")
        let rendered = makeReport(metrics: summary).render()

        XCTAssertTrue(rendered.contains("MetricKit payloads: 1"))
        XCTAssertTrue(rendered.contains("Crashes: 2"))
        XCTAssertTrue(rendered.contains("reason=SIGSEGV"))
        XCTAssertTrue(rendered.contains("Hangs: 1"))
        XCTAssertTrue(rendered.contains("CPU exceptions: 3"))
    }

    // MARK: - Helpers

    private func acknowledgedEvent() -> DiagnosticsReport.Event {
        DiagnosticsReport.Event(
            direction: .incoming,
            state: "acknowledged",
            createdAt: Date(timeIntervalSince1970: 0),
            seenAt: Date(timeIntervalSince1970: 60),
            acknowledgedAt: Date(timeIntervalSince1970: 120),
            critical: true,
            hadEmoji: true
        )
    }

    /// Builds a report the way the app would — through the redacting helpers — so the
    /// leak test exercises the real path rather than a hand-redacted shortcut.
    private func makeReport(
        paired: Bool = true,
        failureReason: String? = nil,
        events: [DiagnosticsReport.Event] = [],
        metrics: MetricKitSummary? = nil
    ) -> DiagnosticsReport {
        DiagnosticsReport(
            appVersion: "2.0.0",
            buildVersion: "1",
            systemVersion: "iOS 17.0",
            generatedAt: Date(timeIntervalSince1970: 0),
            metrics: metrics,
            accountStatus: "available",
            pairFingerprint: paired ? DiagnosticsReport.fingerprint(of: pairKey) : nil,
            myDeviceFingerprint: paired ? DiagnosticsReport.fingerprint(of: myDeviceID) : nil,
            partnerDeviceFingerprint: paired ? DiagnosticsReport.fingerprint(of: partnerDeviceID) : nil,
            hasPartnerName: paired,
            notificationAuthorization: "authorized",
            acceptCriticalAlerts: false,
            timeSensitiveEnabled: true,
            customSoundEnabled: false,
            ackBannersEnabled: true,
            ackSubscriptionUnavailable: failureReason != nil,
            ackSubscriptionFailureReason: DiagnosticsReport.redactedFailureReason(
                failureReason,
                pairKey: paired ? pairKey : nil
            ),
            events: events
        )
    }
}
