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
///
/// And the delete waits for the partner. Those records are the pair's, not the property
/// of whoever upgraded first: one device deleting them takes away the other's only copy
/// of a history they both lived. So each side stamps its own profile record when it has
/// archived, and purges only once it can see the other's stamp. Whoever finishes second
/// releases both. If the partner never upgrades, the records simply stay — plaintext
/// lingering in a database is a smaller harm than deleting someone's history out from
/// under them, and the deliberate case belongs to a future "erase my data".
///
/// The stamp means "I have no further claim on these records", not "I archived them",
/// and a device that gives up stamps too. That is the same principle rather than an
/// exception to it: giving up drops the only key that could ever fetch the history, so
/// holding the partner's purge from then on protects nothing — it only leaves both
/// people's plaintext in a world-readable database for the life of the install.
@MainActor
enum LegacyHistoryCapture {
    private static let log = Logger(subsystem: "com.timfallmk.attention", category: "LegacyHistory")

    /// Rows to keep. There is no second chance at this — the originals are purged once
    /// both sides have captured — so it is a backstop against a pathological account
    /// rather than a page size. The fetch pages through the cursor to reach it.
    static let limit = 5_000

    /// Stashes the pre-2.0 pair key. Synchronous and called first thing at launch, so
    /// the key is safe before the user can reach any UI that re-pairs — `run()` may
    /// then take as long as the network does. Safe to call on every launch.
    static func prepare() {
        guard LegacyHistoryCaptureState.load() == nil else { return }

        // An install with no pre-2.0 pairing has nothing in the public database that
        // belongs to it, so there is nothing to come back for.
        guard LegacyPairing.exists else {
            LegacyHistoryCaptureState(phase: .done, outcome: .nothingToCapture).save()
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
        // Record that this device had a pairing: once it re-pairs, nothing else can tell
        // an upgrading user from a fresh install, and the pairing screen owes them an
        // explanation.
        CutoverNotice.needsRepair = true
        // The pre-2.0 pairing itself is *not* cleared here. It is the only record that
        // there was one, and clearing it before the history is safely archived means a
        // capture that failed — or ran against the wrong database — can never be retried.
        // `finish()` clears it, once there is nothing left to come back for.
        LegacyHistoryCaptureState(phase: .pending).save()
    }

    /// Safe to call on every launch. Requires a preceding `prepare`.
    ///
    /// Once the capture is over — done, exhausted, or never needed — all that is left is
    /// making sure the partner has been told, which costs nothing after it has landed.
    static func run(cloud: CloudKitService = .shared) async {
        guard var state = LegacyHistoryCaptureState.load() else { return }

        if state.phase != .done {
            guard let pairKey = PairSecrets.store.secret(for: Constants.Keychain.legacyHistoryKeyAccount) else {
                // Same pre-unlock window as prepare(), and it must not count as an attempt:
                // a run of background launches against a locked keychain would otherwise
                // spend the whole budget without ever reaching CloudKit, and give up on
                // history that was there all along. The counter exists to bound *fetch*
                // failures. Retrying forever costs one keychain read per launch.
                log.notice("Stashed pre-2.0 key not readable yet; will retry next launch")
                return
            }
            await advance(&state, pairKey: pairKey, cloud: cloud)
        }
        if state.phase == .done {
            await releasePartner(&state, cloud: cloud)
        }
    }

    private static func advance(_ state: inout LegacyHistoryCaptureState,
                                pairKey: String,
                                cloud: CloudKitService) async {
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

            // The public records belong to the pair, not to whoever upgraded first.
            // Deleting them before the partner has archived their own copy destroys the
            // only copy they will ever have, so this waits — indefinitely if it must.
            guard let pair = PairState.load(), let theirZone = pair.outgoingZone else {
                log.notice("Not re-paired yet; holding the pre-2.0 purge")
                return
            }
            // Ours first, so the partner isn't waiting on us while we wait on them.
            if try await cloud.markLegacyHistoryCaptured(in: theirZone.zoneID) {
                state.stampedZoneName = theirZone.zoneName
            }

            guard let profile = await cloud.fetchPartnerProfile(pairKey: pair.pairKey),
                  profile.legacyHistoryCapturedAt != nil else {
                log.notice("Partner hasn't released their pre-2.0 history yet; holding the purge")
                return
            }

            if try await cloud.purgeLegacyPublicRecords(pairKey: pairKey) {
                log.notice("Pre-2.0 public records are gone")
                finish(&state, outcome: .archived)
            } else {
                // A pass that deleted something says nothing about what's left. Come back
                // next launch and keep going until a pass comes up empty.
                state.save()
            }
        } catch {
            record(failure: String(describing: error), into: &state)
        }
    }

    /// Tells the partner this device has no further claim on the pre-2.0 public records,
    /// so their purge can go ahead.
    ///
    /// Runs on every launch until it lands, because the two places that used to stamp
    /// both miss a case. The capture's own stamp sits on the success path, so a device
    /// that gave up never reached it; the pairing flows stamp once, best effort, and
    /// only at pairing time. Either way the partner waited on a signal that could not
    /// arrive, and their records stayed readable to any signed-in iCloud client with
    /// nothing anywhere saying so.
    ///
    /// It also heals an install already in that state: a `.done` written before the
    /// stamp was tracked has no `stampedZoneName`, so it is stamped once here.
    private static func releasePartner(_ state: inout LegacyHistoryCaptureState,
                                       cloud: CloudKitService) async {
        guard let pair = PairState.load(), let theirZone = pair.outgoingZone,
              state.stampedZoneName != theirZone.zoneName else { return }
        do {
            guard try await cloud.markLegacyHistoryCaptured(in: theirZone.zoneID) else { return }
        } catch {
            log.notice("Could not release the partner's pre-2.0 purge, will retry: \(String(describing: error), privacy: .public)")
            return
        }
        // An erase can land inside the await above, and saving here would put back a
        // record it had just removed.
        guard LegacyHistoryCaptureState.load() != nil else { return }
        state.stampedZoneName = theirZone.zoneName
        state.save()
    }

    private static func record(failure: String, into state: inout LegacyHistoryCaptureState) {
        if state.recordFailure() {
            // Read out of the inout parameter first: os_log's interpolation is an
            // escaping autoclosure and can't capture one.
            let attempts = state.failedAttempts
            log.error("Giving up on pre-2.0 history after \(attempts, privacy: .public) attempts: \(failure, privacy: .public)")
            // Running out during the purge is not the same loss: the snapshot was
            // written before that phase began, so only the cleanup was abandoned.
            let outcome: LegacyHistoryCaptureState.Outcome = state.phase == .purging ? .archived : .gaveUp
            finish(&state, outcome: outcome)
        } else {
            log.notice("Pre-2.0 history capture failed, will retry: \(failure, privacy: .public)")
            state.save()
        }
    }

    /// Terminal either way — the stashed key is dropped, so a later launch can't retry
    /// and can't leave a dead secret behind.
    private static func finish(_ state: inout LegacyHistoryCaptureState,
                               outcome: LegacyHistoryCaptureState.Outcome) {
        PairSecrets.store.removeSecret(for: Constants.Keychain.legacyHistoryKeyAccount)

        // Not in a Debug build. Its capture ran against the Development database, where
        // an upgrading user has no history — so it has established nothing about the
        // Production records, and throwing away the pre-2.0 pairing here would take the
        // Production build's only way of finding them with it.
        #if !DEBUG
        LegacyPairing.clear()
        #endif

        state.phase = .done
        state.outcome = outcome
        state.save()
    }
}
