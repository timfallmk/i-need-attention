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

    private static let fileName = "legacy-history-v1.json"

    private static var fileURL: URL? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ) else { return nil }
        return base.appendingPathComponent(fileName)
    }

    static func load() -> LegacyHistoryArchive? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(LegacyHistoryArchive.self, from: data)
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

    var phase: Phase
    var failedAttempts: Int = 0

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

    static let storageKey = "attention.legacyHistoryCapture.v1"

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
