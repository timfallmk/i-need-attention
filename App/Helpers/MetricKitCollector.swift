import Foundation
import MetricKit

/// Folds MetricKit's payloads into `MetricKitSummary` so they can ride out with the
/// diagnostics export.
///
/// MetricKit delivers to the app rather than to a dashboard, which usually means you need a
/// server to collect anything. Here that is the point: subscribing costs one call and no
/// backend, and the result reaches the author through the export the user already sends.
///
/// Payloads arrive at most once every 24 hours and only while the app is running, so a
/// freshly broken install may have nothing to report yet. Everything here is additive —
/// nothing about the app's behaviour depends on a payload ever arriving.
final class MetricKitCollector: NSObject, MXMetricManagerSubscriber {
    static let shared = MetricKitCollector()

    private override init() {
        super.init()
    }

    func start() {
        MXMetricManager.shared.add(self)
    }

    /// Required by the protocol. The aggregated performance metrics are not what this app
    /// needs — the diagnostics below are — so this deliberately does nothing.
    func didReceive(_ payloads: [MXMetricPayload]) {}

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        guard !payloads.isEmpty else { return }

        var summary = MetricKitSummary.load() ?? .empty
        let receivedAt = Date()
        for payload in payloads {
            let crashes = payload.crashDiagnostics ?? []
            summary.record(
                receivedAt: receivedAt,
                crashes: crashes.count,
                hangs: payload.hangDiagnostics?.count ?? 0,
                diskWriteExceptions: payload.diskWriteExceptionDiagnostics?.count ?? 0,
                cpuExceptions: payload.cpuExceptionDiagnostics?.count ?? 0,
                // The call stacks are dropped: large, and this binary's own symbols rather
                // than anything a person typed. The termination reason is the one piece
                // worth keeping, and `record` bounds its length.
                crashReason: crashes.last?.terminationReason
            )
        }
        summary.save()
    }
}
