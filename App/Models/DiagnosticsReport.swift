import CryptoKit
import Foundation

/// What a user can send the author when something is wrong.
///
/// After the move to private databases the author can no longer look at anyone's records,
/// so a field failure is only visible through what the app reports about itself. That makes
/// this the whole debugging surface rather than a convenience.
///
/// A name, a message, an emoji or a pair key cannot reach this type: identities are stored
/// as truncated fingerprints and settings as booleans, and every remaining string is either
/// one this app produced itself (versions, account and authorization status, alert state) or
/// — in the single case of a CloudKit error description — scrubbed on the way in. That last
/// field is the only one carrying text from outside, so it is the only one where the
/// guarantee rests on `redactedFailureReason` rather than on the shape of the type.
///
/// Redaction happens when the report is built rather than when it is rendered, so a later
/// caller cannot leak by formatting carelessly.
struct DiagnosticsReport: Equatable {
    enum Direction: String, Equatable {
        case incoming
        case outgoing
    }

    /// One alert reduced to its timing and lifecycle. Deliberately carries no content:
    /// `hadEmoji` records that an emoji was chosen, never which one.
    /// One of the app's four subscriptions, and whether it is any use.
    ///
    /// `staleZone` is the state worth having a name for: the subscription IDs are
    /// constants while the inbox zone is per-pairing, so one left over from a previous
    /// pairing looks present everywhere except in the pushes it never delivers. Reads
    /// and writes keep working, which is what makes it so hard to see from the outside.
    struct SubscriptionState: Equatable {
        enum Status: String {
            case ok
            case staleZone = "STALE ZONE"
            case missing = "MISSING"
        }

        var id: String
        var status: Status
    }

    struct Event: Equatable {
        var direction: Direction
        var state: String
        var createdAt: Date
        var seenAt: Date?
        var acknowledgedAt: Date?
        var critical: Bool
        var hadEmoji: Bool
    }

    var appVersion: String
    var buildVersion: String
    var systemVersion: String
    var generatedAt: Date

    /// What MetricKit has reported, if anything. Covers the loud failures — crashes, hangs,
    /// resource exceptions — which the rest of this report cannot see because they never
    /// reach the code that would record them.
    var metrics: MetricKitSummary?

    var accountStatus: String
    var pairFingerprint: String?
    var myDeviceFingerprint: String?
    var partnerDeviceFingerprint: String?
    var hasPartnerName: Bool

    var notificationAuthorization: String
    var acceptCriticalAlerts: Bool
    var timeSensitiveEnabled: Bool
    var customSoundEnabled: Bool
    var ackBannersEnabled: Bool

    var ackSubscriptionUnavailable: Bool
    var ackSubscriptionFailureReason: String?

    /// What is actually subscribed. Defaulted so a report can be built without a
    /// CloudKit round trip; the gatherer always fills it.
    var subscriptions: [SubscriptionState] = []

    var events: [Event]

    /// Eight characters of the same SHA-256 that `PairCrypto.lookupHash` produces, so a
    /// pair fingerprint here lines up with the lookup value on the records themselves.
    /// Enough to tell two reports from the same pair apart from two unrelated ones;
    /// nowhere near enough to recover the input.
    static func fingerprint(of value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        let digest = Data(SHA256.hash(data: Data(value.utf8)))
        let encoded = digest.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return String(encoded.prefix(8))
    }

    /// CloudKit error descriptions are safe to keep locally but not to hand to someone
    /// else: a subscription save that fails can echo the predicate back, and the predicate
    /// carries the pair key. Strip it before the text leaves the device.
    static func redactedFailureReason(_ raw: String?, pairKey: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        guard let pairKey, !pairKey.isEmpty else { return raw }
        return raw.replacingOccurrences(of: pairKey, with: "<pairKey>")
    }

    /// Plain text, fixed section order, so two reports from the same install can be diffed.
    func render() -> String {
        var out: [String] = []
        out.append("Attention diagnostics")
        out.append("Generated: \(Self.timestamp(generatedAt))")
        out.append("")

        out.append("[App]")
        out.append("Version: \(appVersion) (\(buildVersion))")
        out.append("System: \(systemVersion)")
        out.append("")

        out.append("[Device diagnostics]")
        out.append(contentsOf: Self.metricLines(metrics))
        out.append("")

        out.append("[Pairing]")
        out.append("iCloud account: \(accountStatus)")
        out.append("Pair: \(pairFingerprint ?? "not paired")")
        out.append("This device: \(myDeviceFingerprint ?? "unknown")")
        out.append("Partner device: \(partnerDeviceFingerprint ?? "unknown")")
        out.append("Partner name set: \(hasPartnerName ? "yes" : "no")")
        out.append("")

        out.append("[Notifications]")
        out.append("Authorization: \(notificationAuthorization)")
        out.append("Accept critical: \(acceptCriticalAlerts ? "on" : "off")")
        out.append("Time sensitive: \(timeSensitiveEnabled ? "on" : "off")")
        out.append("Custom sound: \(customSoundEnabled ? "on" : "off")")
        out.append("Ack banners: \(ackBannersEnabled ? "on" : "off")")
        out.append("")

        out.append("[Subscriptions]")
        for subscription in subscriptions {
            out.append("\(subscription.id): \(subscription.status.rawValue)")
        }
        out.append("Ack subscription: \(ackSubscriptionUnavailable ? "UNAVAILABLE" : "ok")")
        if let reason = ackSubscriptionFailureReason {
            out.append("Last failure: \(reason)")
        }
        out.append("")

        out.append("[Recent alerts] (\(events.count))")
        if events.isEmpty {
            out.append("none")
        } else {
            for event in events {
                out.append(Self.line(for: event))
            }
        }

        return out.joined(separator: "\n")
    }

    private static func metricLines(_ metrics: MetricKitSummary?) -> [String] {
        guard let metrics, !metrics.isEmpty else {
            return ["MetricKit: nothing received yet"]
        }
        var lines = ["MetricKit payloads: \(metrics.payloadsReceived)"]
        if let last = metrics.lastReceivedAt {
            lines.append("Last payload: \(timestamp(last))")
        }
        var crashLine = "Crashes: \(metrics.crashes)"
        if let at = metrics.lastCrashAt { crashLine += "  last=\(timestamp(at))" }
        if let reason = metrics.lastCrashReason { crashLine += "  reason=\(reason)" }
        lines.append(crashLine)
        lines.append("Hangs: \(metrics.hangs)")
        lines.append("Disk write exceptions: \(metrics.diskWriteExceptions)")
        lines.append("CPU exceptions: \(metrics.cpuExceptions)")
        return lines
    }

    private static func line(for event: Event) -> String {
        var parts = [
            timestamp(event.createdAt),
            event.direction.rawValue,
            event.state
        ]
        if event.critical { parts.append("critical") }
        if let seenAt = event.seenAt { parts.append("seen=\(timestamp(seenAt))") }
        if let ackedAt = event.acknowledgedAt { parts.append("acked=\(timestamp(ackedAt))") }
        if event.hadEmoji { parts.append("emoji") }
        return parts.joined(separator: "  ")
    }

    /// ISO 8601 rather than a localized style: this text is read by a developer comparing
    /// it against server-side timing, not by the person who exported it.
    ///
    /// Built once. Configuring a date formatter is expensive and `render` calls this up to
    /// three times per event; a formatter that is configured at creation and never mutated
    /// afterwards is safe to format from anywhere.
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    private static func timestamp(_ date: Date) -> String {
        formatter.string(from: date)
    }
}
