import Foundation
import os.log

/// One-shot copy of the pre-2.0 public-database history into a local snapshot, followed
/// by deleting the originals.
///
/// Ordering is the whole point: the records are reachable only while this device
/// still holds the pre-2.0 pair key, and re-pairing under 2.0 mints a new one. So the
/// key is stashed under its own keychain account on the first 2.0 launch — before the
/// user can re-pair — and the fetch retries across launches against that copy rather
/// than against `PairState`, which by then describes a different pairing entirely.
///
/// The delete is second for the same reason it exists at all. 2.0 stops new data going
/// somewhere every signed-in iCloud account can read; it does nothing by itself about
/// the plaintext names, messages and pair keys already sitting there. Archiving first is
/// what makes removing them cleanup rather than data loss — never reorder these.
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
    static func prepare() {
        guard LegacyHistoryCaptureState.load() == nil else { return }

        // An install with no pre-2.0 pairing has nothing in the public database that
        // belongs to it, so there is nothing to come back for.
        guard LegacyPairing.exists else {
            LegacyHistoryCaptureState(phase: .done).save()
            return
        }
        // A pairing that's there but unreadable is not the same thing. Before the first
        // unlock after a reboot — which a background launch from a push can hit — the
        // keychain hands back nothing, and recording "done" there would discard the
        // history for good.
        guard let pairKey = LegacyPairing.pairKey() else {
            log.notice("Pre-2.0 pair key not readable yet; will retry next launch")
            return
        }
        // Marking this pending without the key stashed would strand the capture: the
        // next launch sees state and skips prepare, then run() finds no key and gives
        // up. Leaving the state absent instead means the next launch tries again — and
        // the pre-2.0 blobs stay put, since they are what the retry reads.
        guard PairSecrets.store.setSecret(pairKey,
                                          for: Constants.Keychain.legacyHistoryKeyAccount) else {
            log.error("Could not stash the pre-2.0 pair key; will retry next launch")
            return
        }
        // Record that this device had a pairing before the pre-2.0 blobs are cleared —
        // afterwards nothing else can tell an upgrading user from a fresh install, and
        // the pairing screen owes them an explanation.
        CutoverNotice.needsRepair = true
        // The key is copied, so the pre-2.0 pairing itself can go. Leaving it would
        // make `LegacyPairing.pairKey()` ambiguous once a 2.0 pairing writes the same
        // keychain account.
        LegacyPairing.clear()
        LegacyHistoryCaptureState(phase: .pending).save()
    }

    /// Safe to call on every launch: it no-ops once the capture is done, exhausted, or
    /// there was never a pre-2.0 pairing to capture. Requires a preceding `prepare`.
    static func run(cloud: CloudKitService = .shared) async {
        guard var state = LegacyHistoryCaptureState.load(),
              state.phase == .pending || state.phase == .purging else { return }

        guard let pairKey = PairSecrets.store.secret(for: Constants.Keychain.legacyHistoryKeyAccount) else {
            // Same pre-unlock window as prepare(), and it must not count as an attempt:
            // a run of background launches against a locked keychain would otherwise
            // spend the whole budget without ever reaching CloudKit, and give up on
            // history that was there all along. The counter exists to bound *fetch*
            // failures. Retrying forever costs one keychain read per launch.
            log.notice("Stashed pre-2.0 key not readable yet; will retry next launch")
            return
        }

        do {
            if state.phase == .pending {
                let alerts = try await cloud.fetchLegacyPublicAlerts(pairKey: pairKey, limit: limit)
                let archive = LegacyHistoryArchive(alerts: alerts.map(ArchivedAlert.init), capturedAt: Date())
                guard archive.save() else {
                    record(failure: "archive could not be written", into: &state)
                    return
                }
                log.notice("Archived \(alerts.count, privacy: .public) pre-2.0 alerts")

                // Committed before the first delete, so a crash mid-purge resumes purging
                // rather than re-archiving over a good snapshot with a half-emptied
                // database. The attempt counter resets: the fetch's failures aren't the
                // purge's, and the purge has its own budget to spend.
                state.phase = .purging
                state.failedAttempts = 0
                state.save()
            }

            if try await cloud.purgeLegacyPublicRecords(pairKey: pairKey) {
                log.notice("Pre-2.0 public records are gone")
                finish(&state)
            } else {
                // A pass that deleted something says nothing about what's left. Come back
                // next launch and keep going until a pass comes up empty.
                state.save()
            }
        } catch {
            record(failure: String(describing: error), into: &state)
        }
    }

    private static func record(failure: String, into state: inout LegacyHistoryCaptureState) {
        if state.recordFailure() {
            // Read out of the inout parameter first: os_log's interpolation is an
            // escaping autoclosure and can't capture one.
            let attempts = state.failedAttempts
            log.error("Giving up on pre-2.0 history after \(attempts, privacy: .public) attempts: \(failure, privacy: .public)")
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
