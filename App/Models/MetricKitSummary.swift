import Foundation

/// A running tally of what MetricKit has reported about this install.
///
/// MetricKit hands diagnostics to the app rather than to a dashboard, which is normally a
/// nuisance — you need a server to collect them. Here it is the useful property: the payloads
/// can be folded into the report the user exports, so crashes and hangs reach the author
/// through the same path as everything else and without this app growing a backend.
///
/// Counts and dates only. Payloads carry call stacks, which are large and are this binary's
/// own symbols rather than anything a person typed, so they are dropped rather than stored;
/// `lastCrashReason` keeps a bounded OS-supplied termination string and nothing more.
///
/// Note what this does *not* add. MetricKit sees crashes, hangs and resource exceptions —
/// the app failing loudly. It cannot see a subscription that never registered or a push that
/// never arrived, which are this app's characteristic failures and the reason the rest of the
/// report exists.
struct MetricKitSummary: Codable, Equatable {
    var payloadsReceived: Int
    var lastReceivedAt: Date?
    var crashes: Int
    var hangs: Int
    var diskWriteExceptions: Int
    var cpuExceptions: Int
    var lastCrashAt: Date?
    var lastCrashReason: String?

    static let storageKey = "attention.metrickit.v1"
    /// Termination reasons are OS-generated and usually short, but they are not a contract.
    static let maxReasonLength = 120

    static let empty = MetricKitSummary(
        payloadsReceived: 0,
        lastReceivedAt: nil,
        crashes: 0,
        hangs: 0,
        diskWriteExceptions: 0,
        cpuExceptions: 0,
        lastCrashAt: nil,
        lastCrashReason: nil
    )

    var isEmpty: Bool {
        payloadsReceived == 0
    }

    /// Takes plain values rather than a payload so the accumulation is testable without
    /// MetricKit — the extraction from `MXDiagnosticPayload` is the only part that is not.
    mutating func record(
        receivedAt: Date,
        crashes newCrashes: Int,
        hangs newHangs: Int,
        diskWriteExceptions newDiskWrites: Int,
        cpuExceptions newCPU: Int,
        crashReason: String?
    ) {
        payloadsReceived += 1
        lastReceivedAt = receivedAt
        crashes += max(0, newCrashes)
        hangs += max(0, newHangs)
        diskWriteExceptions += max(0, newDiskWrites)
        cpuExceptions += max(0, newCPU)

        // A payload with no crash in it describes no crash, so it must leave the last one
        // we know about untouched.
        guard newCrashes > 0 else { return }

        // A payload that does report a crash replaces both fields together. They describe
        // the same crash, so carrying an older reason forward onto a newer timestamp would
        // report a cause that never happened — worse than reporting no cause at all.
        lastCrashAt = receivedAt
        lastCrashReason = crashReason
            .flatMap { $0.isEmpty ? nil : String($0.prefix(Self.maxReasonLength)) }
    }

    static func load() -> MetricKitSummary? {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(MetricKitSummary.self, from: data)
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: MetricKitSummary.storageKey)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }
}
