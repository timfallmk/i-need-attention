import Foundation
import os.log

/// One-shot copy of the pre-2.0 public-database history into a local snapshot.
///
/// Ordering is the whole point: the records are reachable only while this device
/// still holds the pre-2.0 pair key, and re-pairing under 2.0 mints a new one. So the
/// key is stashed under its own keychain account on the first 2.0 launch — before the
/// user can re-pair — and the fetch retries across launches against that copy rather
/// than against `PairState`, which by then describes a different pairing entirely.
@MainActor
enum LegacyHistoryCapture {
    private static let log = Logger(subsystem: "com.timfallmk.attention", category: "LegacyHistory")

    /// Rows to keep. There is no second chance at this, so it is well above the 30 the
    /// history sheet shows; a single page, since a pair that has pressed the button
    /// more times than this can lose the tail of it.
    static let limit = 200

    /// Stashes the pre-2.0 pair key. Synchronous and called first thing at launch, so
    /// the key is safe before the user can reach any UI that re-pairs — `run()` may
    /// then take as long as the network does. Safe to call on every launch.
    static func prepare(existingPair: PairState?) {
        guard LegacyHistoryCaptureState.load() == nil else { return }

        // An install with no pairing has nothing in the public database that belongs
        // to it, so there is nothing to come back for.
        guard let existingPair else {
            LegacyHistoryCaptureState(phase: .done).save()
            return
        }
        PairSecrets.store.setSecret(existingPair.pairKey, for: Constants.Keychain.legacyHistoryKeyAccount)
        LegacyHistoryCaptureState(phase: .pending).save()
    }

    /// Safe to call on every launch: it no-ops once the capture is done, exhausted, or
    /// there was never a pre-2.0 pairing to capture. Requires a preceding `prepare`.
    static func run(cloud: CloudKitService = .shared) async {
        guard var state = LegacyHistoryCaptureState.load(), state.phase == .pending else { return }

        guard let pairKey = PairSecrets.store.secret(for: Constants.Keychain.legacyHistoryKeyAccount) else {
            // Stashing the key is what makes the capture possible; without it there is
            // nothing to retry against.
            finish(&state)
            return
        }

        do {
            let alerts = try await cloud.fetchRecentAlerts(pairKey: pairKey, limit: limit)
            let archive = LegacyHistoryArchive(alerts: alerts.map(ArchivedAlert.init), capturedAt: Date())
            guard archive.save() else {
                record(failure: "archive could not be written", into: &state)
                return
            }
            log.notice("Archived \(alerts.count, privacy: .public) pre-2.0 alerts")
            finish(&state)
        } catch {
            record(failure: String(describing: error), into: &state)
        }
    }

    private static func record(failure: String, into state: inout LegacyHistoryCaptureState) {
        if state.recordFailure() {
            log.error("Giving up on pre-2.0 history after \(state.failedAttempts, privacy: .public) attempts: \(failure, privacy: .public)")
            finish(&state)
        } else {
            log.notice("Pre-2.0 history capture failed, will retry: \(failure, privacy: .public)")
            state.save()
        }
    }

    /// Terminal either way — the stashed key is dropped, so a later launch can't retry
    /// and can't leave a dead secret behind.
    private static func finish(_ state: inout LegacyHistoryCaptureState) {
        PairSecrets.store.removeSecret(for: Constants.Keychain.legacyHistoryKeyAccount)
        state.phase = .done
        state.save()
    }
}
