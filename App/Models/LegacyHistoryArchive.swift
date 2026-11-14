import Foundation

/// The captured pre-2.0 history, stored as JSON in Application Support rather than
/// `UserDefaults`: it can run to a couple of hundred rows, and the defaults plist is
/// read on every launch by both this app and the NSE.
///
/// The contents are plaintext, which is not a regression — these exact rows sat
/// unencrypted in a public CloudKit database readable by any signed-in iCloud client,
/// which is the reason 2.0 exists. They are also the only copy after the cutover, so
/// they are not sealed under the pair key: re-pairing mints a new key, and a snapshot
/// no key can open is the same as no snapshot.
struct LegacyHistoryArchive: Codable, Equatable {
    var alerts: [ArchivedAlert]
    var capturedAt: Date

    /// Scoped to the CloudKit environment the build talks to. A Debug build reads the
    /// *Development* public database, where a user upgrading from TestFlight has no
    /// history at all — so without this, running one on a real device would archive an
    /// empty result over a good Production snapshot.
    ///
    /// Build configuration is the proxy for environment: Xcode's Run action produces a
    /// Debug build against Development, TestFlight and the App Store a Release build
    /// against Production.
    private static func fileName(development: Bool) -> String {
        development ? "legacy-history-v1-development.json" : "legacy-history-v1.json"
    }

    private static var isDevelopmentBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    private static func fileURL(development: Bool) -> URL? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ) else { return nil }
        return base.appendingPathComponent(fileName(development: development))
    }

    private static var fileURL: URL? { fileURL(development: isDevelopmentBuild) }

    static func load() -> LegacyHistoryArchive? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(LegacyHistoryArchive.self, from: data)
    }

    /// Whether a snapshot is on disk: true, false when it is confirmed absent, and nil
    /// when that could not be established.
    ///
    /// Not `load() != nil`, which is nil for a file that is there but cannot be read
    /// or decoded right now — before the first unlock after a reboot, say. Whoever
    /// asks this is about to record the answer for good, and "unreadable today" is not
    /// "never written".
    static var existsOnDisk: Bool? {
        guard let url = fileURL else { return nil }
        do {
            return try url.checkResourceIsReachable()
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return false
        } catch {
            return nil
        }
    }

    @discardableResult
    func save() -> Bool {
        guard let url = Self.fileURL, let data = try? JSONEncoder().encode(self) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    static func clear() {
        guard let url = fileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Archived rows and live records in one list, newest first. A live record wins
    /// over an archived copy of itself, which matters for the window where the pair
    /// still reads the public database — before the cutover both sources return the
    /// same records, and the live one is the one that can still change.
    static func merged(live: [AlertRecord], archived: [ArchivedAlert]) -> [AlertRecord] {
        let liveNames = Set(live.map(\.id.recordName))
        let extras = archived
            .filter { !liveNames.contains($0.recordName) }
            .map(AlertRecord.init(archived:))
        return (live + extras).sorted { $0.createdAt > $1.createdAt }
    }
}

/// Where the one-shot capture has got to. Absent means "not considered yet", which on
/// a 2.0 first launch is every install.
struct LegacyHistoryCaptureState: Codable, Equatable {
    enum Phase: String, Codable {
        /// The source key is stashed and the fetch hasn't succeeded yet.
        case pending
        /// Archived locally, and now deleting the public-database originals. A separate
        /// phase because the delete has to retry on its own: the archive is safe by this
        /// point, so a failure here costs cleanup rather than history, but leaving
        /// plaintext in a world-readable database is the thing 2.0 exists to stop.
        case purging
        /// Captured, or given up on, or there was never anything to capture.
        case done
    }

    /// How a capture reached `.done`. The phase alone cannot say, and the difference is
    /// the one the user is owed: `gaveUp` means their pre-2.0 history is gone for good.
    enum Outcome: String, Codable {
        /// The snapshot is on disk. Still this when the purge that follows was abandoned
        /// — that costs cleanup, not history.
        case archived
        /// The retry budget ran out before anything was saved, and the key that could
        /// have fetched it has been dropped.
        case gaveUp
        case nothingToCapture
    }

    var phase: Phase
    var failedAttempts: Int = 0

    /// Nil while the capture is still running, and on a `.done` written before outcomes
    /// were recorded — where the three are no longer distinguishable.
    var outcome: Outcome?

    /// The partner's zone whose copy of our profile is known to carry the stamp that
    /// releases their purge. A zone name rather than a flag because the stamp belongs to
    /// a pairing: a new partner has a new zone and has been told nothing.
    var stampedZoneName: String?

    /// A capture that keeps failing would otherwise retry on every launch forever,
    /// holding on to the pre-2.0 pair key indefinitely. Ten launches is far more
    /// than a stretch offline and far less than forever.
    static let maxAttempts = 10

    var isExhausted: Bool { failedAttempts >= Self.maxAttempts }

    /// Counts one failed attempt and reports whether the capture should stop retrying.
    /// The caller drops the stashed pre-2.0 key when it does.
    mutating func recordFailure() -> Bool {
        failedAttempts += 1
        return isExhausted
    }

    /// Whether this install ran a capture of its own to an end, which is what entitles
    /// it to tell the partner on launch that the claim is finished.
    ///
    /// An install with nothing to capture is deliberately not included. Its stamp is
    /// written when it pairs, and nowhere else: a fresh install that *adopts* a pairing
    /// shares one profile record with every device on the account, so stamping it from
    /// here would release the partner's purge while another of this person's devices
    /// was still fetching the history that purge deletes.
    ///
    /// A state written before outcomes were recorded says nothing here by itself, which
    /// is what `backfillOutcome` is for. The attempt count is the fallback for one that
    /// has not been backfilled yet: a spent budget is the one trace a give-up left.
    var hasSettledItsOwnCapture: Bool {
        guard phase == .done else { return false }
        switch outcome {
        case .archived?, .gaveUp?: return true
        case .nothingToCapture?: return false
        case nil: return isExhausted
        }
    }

    /// Works out how a `.done` written before outcomes were recorded got there, from
    /// what that build left behind. Returns whether it changed anything.
    ///
    /// The snapshot on disk is the recorded result: a capture that succeeded wrote one,
    /// even an empty one, and an install with nothing to capture never did. Without it
    /// the two are the same blob, and treating both alike is wrong in both directions —
    /// call them settled and a fresh install releases a sibling device's claim, call
    /// them unsettled and a finished capture whose stamp never landed is never retried.
    /// No snapshot and a spent budget is a give-up, which was otherwise invisible to
    /// History on exactly the installs that already had one.
    ///
    /// `archiveExists` is nil when the disk could not say, and then nothing is recorded
    /// so the next launch asks again. The answer is kept for good, so it has to be one.
    @discardableResult
    mutating func backfillOutcome(archiveExists: Bool?) -> Bool {
        guard phase == .done, outcome == nil, let archiveExists else { return false }
        if archiveExists {
            outcome = .archived
        } else if isExhausted {
            outcome = .gaveUp
        } else {
            outcome = .nothingToCapture
        }
        return true
    }

    /// One line for the diagnostics export. Built only from this app's own state names,
    /// so there is nothing in it to redact.
    ///
    /// `partnerZoneName` is the current pairing's; nil when unpaired, where "released"
    /// has nobody to be about. Release is reported only where this install tracks it —
    /// one with nothing to capture stamps at pairing and keeps no record, so a line
    /// there would accuse every fresh install of something it has already done.
    func diagnosticSummary(partnerZoneName: String?) -> String {
        let progress: String
        switch (phase, outcome) {
        case (.pending, _): progress = "capturing (\(failedAttempts) failed)"
        case (.purging, _): progress = "archived, purging (\(failedAttempts) failed)"
        case (.done, .archived?): progress = "archived"
        case (.done, .gaveUp?): progress = "GAVE UP, not archived"
        case (.done, .nothingToCapture?): progress = "none to capture"
        case (.done, nil): progress = "done"
        }
        guard let partnerZoneName, phase == .purging || hasSettledItsOwnCapture else { return progress }
        let released = stampedZoneName == partnerZoneName
        return "\(progress); partner \(released ? "released" : "NOT YET RELEASED")"
    }

    /// Scoped to the CloudKit environment, like the archive itself. The capture is a
    /// one-shot, and a Debug build querying Development would otherwise spend it — then
    /// a later Production build would find the marker, skip, and never archive the
    /// history that was actually there.
    static let storageKey: String = {
        #if DEBUG
        "attention.legacyHistoryCapture.v1.development"
        #else
        "attention.legacyHistoryCapture.v1"
        #endif
    }()

    static func load() -> LegacyHistoryCaptureState? {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(LegacyHistoryCaptureState.self, from: data)
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }
}

#if DEBUG
extension LegacyHistoryArchive {
    /// Writes this archive where a *Release* build will look for it, whatever build
    /// wrote it. Only `LegacyHistoryRecovery` uses it: recovering history means running
    /// a Debug build pointed at the Production container, and the point of the exercise
    /// is for the TestFlight build to find the result afterwards.
    @discardableResult
    func saveForProductionBuilds() -> Bool {
        guard let url = Self.fileURL(development: false),
              let data = try? JSONEncoder().encode(self) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }
}
#endif
