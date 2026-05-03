import Foundation

enum AckCommand {
    static func run(_ args: [String]) async throws {
        let parsed = Args(args)
        let emoji = parsed["emoji"]
        guard let state = CLIState.load() else { throw CLIError.noState }

        let client = CLIClient()
        guard let alert = try await client.fetchMostRecentIncomingAlert(pairKey: state.pairKey, myDeviceID: state.myDeviceID) else {
            print("No incoming alert to acknowledge.")
            return
        }

        try await client.acknowledgeAlert(recordID: alert.id, emoji: emoji)
        let emojiStr = emoji.map { " \($0)" } ?? ""
        print("Acknowledged\(emojiStr): \(alert.id.recordName)")
        print("  from: \(alert.senderName)")
        print("  sent: \(alert.createdAt)")
    }
}
