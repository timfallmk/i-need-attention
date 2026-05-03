import Foundation

enum WatchCommand {
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    static func run(_ args: [String]) async throws {
        let parsed = Args(args)
        let rawInterval = Int(parsed["interval"] ?? "3") ?? 3
        guard rawInterval >= 1 else {
            fputs("error: --interval must be at least 1 second\n", stderr)
            exit(1)
        }
        let interval = rawInterval
        guard let state = CLIState.load() else { throw CLIError.noState }

        let client = CLIClient()
        var alertSince = Date(timeIntervalSinceNow: -30)
        var ackSince   = Date(timeIntervalSinceNow: -30)
        // Per-poll dedup sets: replaced each iteration so memory stays bounded
        // (at most resultsLimit entries each, regardless of session length).
        var prevAlertIDs: Set<String> = []
        var prevAckIDs: Set<String> = []

        print("Watching pair '\(state.partnerName)' (interval: \(interval)s, Ctrl+C to stop)…")

        while true {
            let alerts = try await client.pollIncomingAlerts(pairKey: state.pairKey, myDeviceID: state.myDeviceID, since: alertSince)
            let acks   = try await client.pollIncomingAcks(  pairKey: state.pairKey, myDeviceID: state.myDeviceID, since: ackSince)

            var latestAlert = alertSince
            for alert in alerts.reversed() {
                guard !prevAlertIDs.contains(alert.id.recordName) else { continue }
                print("[\(ts(alert.createdAt))] ALERT  \(alert.senderName): \(alert.message)  [\(alert.id.recordName)]")
                if alert.createdAt > latestAlert { latestAlert = alert.createdAt }
            }
            // Advance with a 1 s overlap so records at the boundary aren't skipped.
            if latestAlert > alertSince { alertSince = latestAlert.addingTimeInterval(-1) }
            prevAlertIDs = Set(alerts.map(\.id.recordName))

            var latestAck = ackSince
            for (recordID, emoji, createdAt) in acks.reversed() {
                guard !prevAckIDs.contains(recordID.recordName) else { continue }
                let emojiStr = emoji.map { " \($0)" } ?? ""
                print("[\(ts(createdAt))] ACK\(emojiStr)  [\(recordID.recordName)]")
                if createdAt > latestAck { latestAck = createdAt }
            }
            if latestAck > ackSince { ackSince = latestAck.addingTimeInterval(-1) }
            prevAckIDs = Set(acks.map(\.0.recordName))

            try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
        }
    }

    private static func ts(_ date: Date) -> String { timeFormatter.string(from: date) }
}
