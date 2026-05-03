import Foundation

enum WatchCommand {
    static func run(_ args: [String]) async throws {
        let parsed = Args(args)
        let interval = Int(parsed["interval"] ?? "3") ?? 3
        guard let state = CLIState.load() else { throw CLIError.noState }

        let client = CLIClient()
        // Start window 30s in the past to catch very recent records on startup.
        var since = Date(timeIntervalSinceNow: -30)
        var seenAlerts: Set<String> = []
        var seenAcks: Set<String> = []

        print("Watching pair '\(state.partnerName)' (interval: \(interval)s, Ctrl+C to stop)…")

        while true {
            let alerts = try await client.pollIncomingAlerts(pairKey: state.pairKey, myDeviceID: state.myDeviceID, since: since)
            let acks   = try await client.pollIncomingAcks(  pairKey: state.pairKey, myDeviceID: state.myDeviceID, since: since)

            // Advance window with 1s overlap so records created during the sleep are not lost.
            since = Date(timeIntervalSinceNow: -(Double(interval) + 1))

            for alert in alerts.reversed() {
                guard seenAlerts.insert(alert.id.recordName).inserted else { continue }
                print("[\(ts(alert.createdAt))] ALERT  \(alert.senderName): \(alert.message)  [\(alert.id.recordName)]")
            }
            for (recordID, emoji, createdAt) in acks.reversed() {
                guard seenAcks.insert(recordID.recordName).inserted else { continue }
                let emojiStr = emoji.map { " \($0)" } ?? ""
                print("[\(ts(createdAt))] ACK\(emojiStr)  [\(recordID.recordName)]")
            }

            try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
        }
    }

    private static func ts(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }
}
