import CloudKit
import Foundation
import UIKit

/// Populates a `DiagnosticsReport` from live state.
///
/// Every value that could carry something private is passed through `DiagnosticsReport`'s
/// redacting helpers here rather than being handed over raw — this is the one place that
/// sees both the pair key and the report, so it is the one place the redaction can be got
/// wrong.
@MainActor
enum DiagnosticsGatherer {
    static func gather(from state: AppState) async -> DiagnosticsReport {
        let pair = state.pair

        return DiagnosticsReport(
            appVersion: bundleString("CFBundleShortVersionString"),
            buildVersion: bundleString("CFBundleVersion"),
            systemVersion: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
            generatedAt: Date(),
            metrics: MetricKitSummary.load(),
            accountStatus: describe(state.iCloudStatus),
            pairFingerprint: DiagnosticsReport.fingerprint(of: pair?.pairKey),
            myDeviceFingerprint: DiagnosticsReport.fingerprint(of: pair?.myDeviceID),
            partnerDeviceFingerprint: DiagnosticsReport.fingerprint(of: pair?.partnerDeviceID),
            hasPartnerName: !(pair?.partnerName ?? "").isEmpty,
            notificationAuthorization: describeAuthorization(state),
            acceptCriticalAlerts: state.settings.acceptCriticalAlerts,
            timeSensitiveEnabled: state.settings.timeSensitiveEnabled,
            customSoundEnabled: state.settings.customSoundEnabled,
            ackBannersEnabled: state.settings.ackBannersEnabled,
            ackSubscriptionUnavailable: state.outgoingAckSubscriptionUnavailable,
            ackSubscriptionFailureReason: DiagnosticsReport.redactedFailureReason(
                state.outgoingAckSubscriptionFailureReason,
                pairKey: pair?.pairKey
            ),
            subscriptions: await CloudKitService.shared.subscriptionStates(),
            ownedInboxZones: await CloudKitService.shared.ownedInboxZoneCount(),
            events: await recentEvents(pair: pair)
        )
    }

    /// Best effort. A history fetch that fails degrades the report rather than blocking the
    /// export — a user exporting diagnostics is quite likely to be someone whose CloudKit
    /// access is not working, which is exactly when the rest of the report matters most.
    private static func recentEvents(pair: PairState?) async -> [DiagnosticsReport.Event] {
        guard let pair else { return [] }
        guard let alerts = try? await CloudKitService.shared.fetchRecentAlerts(
            pair: pair,
            limit: 20
        ) else {
            return []
        }
        return alerts.map { alert in
            DiagnosticsReport.Event(
                direction: pair.isMine(senderUserID: alert.senderUserID,
                                       senderDeviceID: alert.senderDeviceID) ? .outgoing : .incoming,
                state: alert.state.rawValue,
                createdAt: alert.createdAt,
                seenAt: alert.seenAt,
                acknowledgedAt: alert.acknowledgedAt,
                critical: alert.critical,
                // Presence only. Which emoji was chosen is content.
                hadEmoji: !(alert.ackEmoji ?? "").isEmpty
            )
        }
    }

    private static func bundleString(_ key: String) -> String {
        Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "unknown"
    }

    private static func describe(_ status: CKAccountStatus) -> String {
        switch status {
        case .available: return "available"
        case .noAccount: return "no account"
        case .restricted: return "restricted"
        case .couldNotDetermine: return "could not determine"
        case .temporarilyUnavailable: return "temporarily unavailable"
        @unknown default: return "unknown (\(status.rawValue))"
        }
    }

    private static func describeAuthorization(_ state: AppState) -> String {
        if state.notificationsDenied { return "denied" }
        if state.notificationsAuthorized { return "authorized" }
        return "not determined"
    }
}
