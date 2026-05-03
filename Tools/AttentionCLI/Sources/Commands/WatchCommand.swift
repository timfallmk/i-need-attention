import Foundation

enum WatchCommand {
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
        // High-water marks per stream: advance to newest processed record so queries
        // stay bounded and the dedup sets only cover the 1 s overlap window.
        var alertSince = Date(timeIntervalSinceNow: -30)
        var ackSince   = Date(timeIntervalSinceNow: -30)
        var seenAlerts: Set<String> = []
        var seenAcks: Set<String> = []

        print("Watching pair '\(state.partnerName)' (interval: \(interval)s, Ctrl+C to stop)…")

        while true {
            let alerts = try await client.pollIncomingAlerts(pairKey: state.pairKey, myDeviceID: state.myDeviceID, since: alertSince)
            let acks   = try await client.pollIncomingAcks(  pairKey: state.pairKey, myDeviceID: state.myDeviceID, since: ackSince)

            var latestAlert = alertSince
            for alert in alerts.reversed() {
                guard seenAlerts.insert(alert.id.recordName).inserted else { continue }
                print("[\(ts(alert.createdAt))] ALERT  \(alert.senderName): \(alert.message)  [\(alert.id.recordName)]")
                if alert.createdAt > latestAlert { latestAlert = alert.createdAt }
            }
            // Advance with a 1 s overlap so records created at exactly the high-water
            // timestamp aren't silently skipped on the next poll.
            if latestAlert > alertSince { alertSince = latestAlert.addingTimeInterval(-1) }

            var latestAck = ackSince
            for (recordID, emoji, createdAt) in acks.reversed() {
                guard seenAcks.insert(recordID.recordName).inserted else { continue }
                let emojiStr = emoji.map { " \($0)" } ?? ""
                print("[\(ts(createdAt))] ACK\(emojiStr)  [\(recordID.recordName)]")
                if createdAt > latestAck { latestAck = createdAt }
            }
            if latestAck > ackSince { ackSince = latestAck.addingTimeInterval(-1) }

            try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
        }
    }

    private static func ts(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }
}
