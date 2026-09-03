import Foundation

/// The durable, local copy of everything this device has exchanged, grouped by pairing.
///
/// It exists because CloudKit structurally cannot hold a complete history. Your history
/// has two halves with two different owners: alerts you *received* live in the zone you
/// own, but alerts you *sent* live in your partner's zone, where you are a guest. Unpair
/// and that half stops being readable; they can delete it whenever. So the zones are the
/// current pairing's working set, and this file is the record.
///
/// It never leaves the device — no CloudKit, no sharing. A later partner can no more read
/// it than they can read your Photos. What they *could* read, before zones became
/// per-pairing, was the previous partner's records sitting in a zone whose share they had
/// just been granted; `InboxZone` is the other half of that fix.
///
/// The pre-2.0 snapshot is deliberately *not* folded in here. `LegacyHistoryArchive` is a
/// frozen one-shot against a database that no longer exists, with its own retry budget
/// and its own stashed key; merging the two would put a migration that has already run on
/// real devices back in the blast radius of every change to this one.
struct PairingArchive: Codable, Equatable {
    /// Newest pairing first.
    var pairings: [ArchivedPairing] = []

    /// How many rows the final sweep at unpair asks for. Well above the 30 the history
    /// sheet shows: it is the last read that will ever succeed against the partner's
    /// zone, so it is worth paying for depth once. The fetch pages to reach it.
    static let sweepLimit = 5_000

    /// Scoped per CloudKit environment for the same reason `LegacyHistoryArchive` is: a
    /// Debug build and a Release build own different zones in different environments, and
    /// one must not archive over the other's rows.
    private static var fileName: String {
        #if DEBUG
        "pairing-history-v1-development.json"
        #else
        "pairing-history-v1.json"
        #endif
    }

    private static var fileURL: URL? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ) else { return nil }
        return base.appendingPathComponent(fileName)
    }

    static func load() -> PairingArchive {
        guard let url = fileURL, let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(PairingArchive.self, from: data) else {
            return PairingArchive()
        }
        return decoded
    }

    @discardableResult
    func save() -> Bool {
        guard let url = Self.fileURL, let data = try? JSONEncoder().encode(self) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    /// Folds a fetch into the archive. Idempotent by record name, and last-write-wins on
    /// the row: a re-fetched alert may have gained a `seenAt` or an acknowledgement since
    /// the copy already held.
    ///
    /// `pairingID` is the zone name. The zone is already minted once per pairing and
    /// already persisted, so it is the pairing's identity with nothing extra to store.
    @discardableResult
    static func absorb(_ alerts: [AlertRecord], pairingID: String, partnerName: String) -> PairingArchive {
        var archive = load()
        let rows = alerts.map(ArchivedAlert.init)

        if let index = archive.pairings.firstIndex(where: { $0.id == pairingID }) {
            archive.pairings[index].merge(rows)
            // Renames land here rather than needing their own write path.
            if !partnerName.isEmpty { archive.pairings[index].partnerName = partnerName }
        } else if !rows.isEmpty {
            archive.pairings.insert(
                ArchivedPairing(
                    id: pairingID,
                    partnerName: partnerName,
                    startedAt: rows.map(\.createdAt).min() ?? Date(),
                    endedAt: nil,
                    alerts: rows.sorted { $0.createdAt > $1.createdAt }
                ),
                at: 0
            )
        }
        archive.save()
        return archive
    }

    /// Whether anything has ever been archived. Cheap enough for a settings row that
    /// needs to know whether History has something to show.
    static var isEmpty: Bool {
        load().pairings.allSatisfy { $0.alerts.isEmpty }
    }

    static func clear() {
        guard let url = fileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Marks a pairing finished. Only affects how it is labelled — the rows stay.
    static func close(pairingID: String, at date: Date = Date()) {
        var archive = load()
        guard let index = archive.pairings.firstIndex(where: { $0.id == pairingID }),
              archive.pairings[index].endedAt == nil else { return }
        archive.pairings[index].endedAt = date
        archive.save()
    }
}

struct ArchivedPairing: Codable, Equatable, Identifiable {
    /// The record zone name this pairing used.
    var id: String
    var partnerName: String
    var startedAt: Date
    var endedAt: Date?
    /// Newest first.
    var alerts: [ArchivedAlert]

    var isOpen: Bool { endedAt == nil }

    mutating func merge(_ incoming: [ArchivedAlert]) {
        var byName = Dictionary(alerts.map { ($0.recordName, $0) }, uniquingKeysWith: { _, new in new })
        for row in incoming { byName[row.recordName] = row }
        alerts = byName.values.sorted { $0.createdAt > $1.createdAt }
        if let earliest = alerts.map(\.createdAt).min(), earliest < startedAt { startedAt = earliest }
    }
}
