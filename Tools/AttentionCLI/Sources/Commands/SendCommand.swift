import Foundation

enum SendCommand {
    static func run(_ args: [String]) async throws {
        let parsed = Args(args)
        let message = parsed["message"] ?? "needs attention"
        guard let state = CLIState.load() else { throw CLIError.noState }

        let client = CLIClient()
        let alert = try await client.sendAlert(
            pairKey: state.pairKey,
            senderDeviceID: state.myDeviceID,
            senderName: state.myName,
            message: message
        )
        print("Sent: \(alert.id.recordName)")
        print("  message: \(alert.message)")
        print("  state:   \(alert.state.rawValue)")
    }
}
