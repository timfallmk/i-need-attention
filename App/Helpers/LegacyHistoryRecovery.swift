#if DEBUG
import Foundation
import os.log

/// Rebuilds the pre-2.0 history archive from a pair key typed in by hand.
///
/// Debug-only, and deliberately so — it exists for one situation. The normal capture is
/// a one-shot that clears the pre-2.0 pairing when it finishes, so a device whose
/// capture ran against the wrong CloudKit environment ends up with an empty archive and
/// no way to find those records again. The pair key is still legible in the Production
/// `Pair` record via CloudKit Dashboard, which is where the operator gets it.
///
/// To use it, the build has to be pointed at the container environment that holds the
/// records — for pre-2.0 history that means Production, via
/// `com.apple.developer.icloud-container-environment` in the entitlements. Hence
/// `saveForProductionBuilds`: whatever build performs the recovery, the result has to
/// land where a Release build will look.
///
/// It only ever reads and writes locally. Nothing here deletes a CloudKit record — the
/// gated purge is the only thing that does, and this must not become a second path to it.
@MainActor
enum LegacyHistoryRecovery {
    private static let log = Logger(subsystem: "com.timfallmk.attention", category: "LegacyHistory")

    enum Outcome: Equatable {
        case recovered(count: Int)
        case foundNothing
        case couldNotWrite
        case failed(String)

        var message: String {
            switch self {
            case .recovered(let count):
                return "Recovered \(count) alert\(count == 1 ? "" : "s"). Reopen History to see them."
            case .foundNothing:
                return "No records for that pair key in this build's CloudKit environment. "
                     + "Check the key, and that this build points at the environment holding them."
            case .couldNotWrite:
                return "Fetched the records but couldn't write the archive."
            case .failed(let reason):
                return reason
            }
        }
    }

    static func recover(pairKey rawKey: String,
                        cloud: CloudKitService = .shared) async -> Outcome {
        let pairKey = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pairKey.isEmpty else { return .failed("Enter the pre-2.0 pair key first.") }

        do {
            let alerts = try await cloud.fetchLegacyPublicAlerts(
                pairKey: pairKey,
                limit: LegacyHistoryCapture.limit
            )
            guard !alerts.isEmpty else { return .foundNothing }

            let archive = LegacyHistoryArchive(alerts: alerts.map(ArchivedAlert.init), capturedAt: Date())
            // Both paths: this build reads one, a later Release build reads the other.
            guard archive.save(), archive.saveForProductionBuilds() else { return .couldNotWrite }

            log.notice("Recovered \(alerts.count, privacy: .public) pre-2.0 alerts by hand")
            return .recovered(count: alerts.count)
        } catch {
            return .failed(String(describing: error))
        }
    }
}
#endif
