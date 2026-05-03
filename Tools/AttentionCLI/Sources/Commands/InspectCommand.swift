import Foundation

enum InspectCommand {
    static func run(_ args: [String]) async throws {
        guard let state = CLIState.load() else { throw CLIError.noState }
        let client = CLIClient()

        // Pair record
        if let pair = try await client.fetchPair(pairKey: state.pairKey) {
            print("Pair  \(pair.recordID.recordName)")
            print("  pairKey: \(pair[Constants.PairField.pairKey] as? String ?? "")")
            print("  deviceA: \(pair[Constants.PairField.deviceA] as? String ?? "")  name: \(pair[Constants.PairField.nameA] as? String ?? "")")
            print("  deviceB: \(pair[Constants.PairField.deviceB] as? String ?? "")  name: \(pair[Constants.PairField.nameB] as? String ?? "")")
        } else {
            print("Pair record not found (pairKey: \(state.pairKey))")
        }

        // Last 10 alerts
        let alerts = try await client.fetchRecentAlerts(pairKey: state.pairKey, limit: 10)
        print("\nAlerts (\(alerts.count)):")
        for a in alerts {
            let dir = a.senderDeviceID == state.myDeviceID ? "→" : "←"
            print("  \(dir) [\(ts(a.createdAt))]  \(a.senderName): \(a.message)  \(a.state.rawValue)\(a.ackEmoji.map { "  \($0)" } ?? "")  [\(a.id.recordName)]")
        }

        // Last 10 acks
        let acks = try await client.fetchRecentAcks(pairKey: state.pairKey, limit: 10)
        print("\nAcks (\(acks.count)):")
        for (emoji, alertRef, createdAt) in acks {
            let emojiStr = emoji.map { " \($0)" } ?? ""
            print("  [\(ts(createdAt))]\(emojiStr)  → alert: \(alertRef)")
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private static func ts(_ date: Date) -> String { timeFormatter.string(from: date) }
}
