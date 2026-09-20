import SwiftUI

/// Recent attention exchanges, newest first. Read-only — fetched lazily from CloudKit
/// each time the sheet opens; nothing is cached or mutated here.
struct HistoryView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var sections: [HistorySection] = []
    @State private var isLoading = true
    @State private var loadFailed = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("History")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
                .task { await load() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if loadFailed {
            ContentUnavailableView {
                Label("Couldn't load history", systemImage: "exclamationmark.icloud")
            } description: {
                Text("Check your connection and try again.")
            } actions: {
                Button("Retry") { Task { await load() } }
            }
        } else if sections.allSatisfy(\.alerts.isEmpty) {
            ContentUnavailableView {
                Label("No history yet", systemImage: "clock")
            } description: {
                Text("Alerts you send and receive will show up here.")
            }
        } else {
            List {
                // One section per pairing. Grouping is the point rather than decoration:
                // a flat list mixes partners with nothing to say which is which, and
                // "who was I talking to in March" is the question this sheet answers.
                ForEach(sections) { section in
                    Section {
                        ForEach(section.alerts) { alert in
                            HistoryRow(alert: alert, isMine: section.isMine(alert))
                        }
                    } header: {
                        HistorySectionHeader(section: section)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .refreshable { await load() }
        }
    }

    @MainActor
    private func load() async {
        guard let pair = appState.pair else {
            // Unpaired is a real state with real history: between the 2.0 cutover and
            // re-pairing, and after any later unpair. Everything shown here is local.
            sections = HistorySection.archivedOnly()
            loadFailed = false
            isLoading = false
            return
        }
        // Keep the current list visible during a pull-to-refresh; only show the
        // full-screen spinner on the first load.
        isLoading = sections.isEmpty
        loadFailed = false

        let pairingID = InboxZone.currentName
        do {
            let live = try await CloudKitService.shared.fetchRecentAlerts(pair: pair)
            // Fold the fetch into the local archive on the way past. This is what makes
            // the archive survive the partner tearing their zone down before we do —
            // waiting for our own unpair to copy it would be a race we could lose.
            PairingArchive.absorb(live, pairingID: pairingID, partnerName: pair.partnerName)
            sections = HistorySection.build(live: live, pair: pair, pairingID: pairingID)
        } catch {
            // A refresh failure shouldn't wipe the list. The archive needs no network,
            // so it stands in on its own and the error state is only for a blank sheet.
            sections = HistorySection.build(live: [], pair: pair, pairingID: pairingID)
            loadFailed = sections.allSatisfy(\.alerts.isEmpty)
        }
        isLoading = false
    }
}

/// One pairing's worth of history.
struct HistorySection: Identifiable {
    let id: String
    let partnerName: String
    let alerts: [AlertRecord]
    let startedAt: Date
    let endedAt: Date?
    /// Who counts as "me" for these rows. Carried per section because it is only
    /// reliably the current pairing's for the current pairing: an adopted pairing takes
    /// the device ID a *previous* device introduced this person by, so the one this
    /// install would name is not it.
    let me: SenderIdentity

    func isMine(_ alert: AlertRecord) -> Bool {
        me.matches(userID: alert.senderUserID, deviceID: alert.senderDeviceID)
    }

    var isCurrent: Bool { endedAt == nil }

    /// Live rows for the current pairing, then every closed pairing newest first, then
    /// the pre-2.0 snapshot. The current pairing renders from the fetch rather than from
    /// the archive so a pull-to-refresh shows the server's answer, not our copy of it.
    @MainActor
    static func build(live: [AlertRecord], pair: PairState, pairingID: String) -> [HistorySection] {
        var result: [HistorySection] = []
        let archive = PairingArchive.load()
        // The fetch is capped at 30 and the archive is not, so the union is the honest
        // answer — and it doubles as the fallback when the fetch failed outright.
        let current = LegacyHistoryArchive.merged(
            live: live,
            archived: archive.pairings.first { $0.id == pairingID }?.alerts ?? []
        )
        result.append(
            HistorySection(
                id: pairingID,
                partnerName: pair.partnerName,
                alerts: current,
                startedAt: current.map(\.createdAt).min() ?? Date(),
                endedAt: nil,
                me: pair.me
            )
        )
        result += closedSections(from: archive, excluding: pairingID)
        result += legacySection().map { [$0] } ?? []
        // An empty section is a header with nothing under it. A pairing with no alerts
        // at all is the "No history yet" case, which the caller renders instead.
        return result.filter { !$0.alerts.isEmpty }
    }

    @MainActor
    static func archivedOnly() -> [HistorySection] {
        closedSections(from: PairingArchive.load(), excluding: nil)
            + (legacySection().map { [$0] } ?? [])
    }

    private static func closedSections(from archive: PairingArchive, excluding currentID: String?) -> [HistorySection] {
        archive.pairings
            .filter { $0.id != currentID && !$0.alerts.isEmpty }
            .sorted { $0.startedAt > $1.startedAt }
            .map { pairing in
                HistorySection(
                    id: pairing.id,
                    partnerName: pairing.partnerName,
                    alerts: pairing.alerts.map(AlertRecord.init(archived:)),
                    startedAt: pairing.startedAt,
                    endedAt: pairing.endedAt ?? pairing.alerts.map(\.createdAt).max() ?? pairing.startedAt,
                    // A closed pairing has no `PairState` left to ask, so this is the
                    // account identity as last seen plus this install's device ID. Rows
                    // archived before per-account identity carry no `senderUserID` and
                    // fall back to the device comparison, exactly as they did before.
                    me: SenderIdentity(deviceID: DeviceIdentity.id, userID: AccountIdentity.id)
                )
            }
    }

    /// The pre-2.0 snapshot, which predates pairing IDs entirely. Its partner is
    /// recovered from the rows themselves: whoever sent the ones this device didn't.
    private static func legacySection() -> HistorySection? {
        let rows = LegacyHistoryArchive.load()?.alerts ?? []
        guard !rows.isEmpty else { return nil }
        // Pre-2.0 rows predate account identity entirely and were all written by this
        // install, so the device comparison is the only one that means anything here.
        let me = SenderIdentity(deviceID: DeviceIdentity.id, userID: nil)
        let partner = rows.first {
            !me.matches(userID: $0.senderUserID, deviceID: $0.senderDeviceID) && !$0.senderName.isEmpty
        }?.senderName
        return HistorySection(
            id: "legacy-pre-2.0",
            partnerName: partner ?? "Before this version",
            alerts: rows.map(AlertRecord.init(archived:)),
            startedAt: rows.map(\.createdAt).min() ?? Date(),
            endedAt: rows.map(\.createdAt).max() ?? Date(),
            me: me
        )
    }
}

private struct HistorySectionHeader: View {
    let section: HistorySection

    var body: some View {
        HStack(spacing: 6) {
            Text(section.partnerName)
            Text("·")
                .foregroundStyle(.tertiary)
            Text(range)
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .textCase(nil)
    }

    private var range: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM yyyy"
        let start = formatter.string(from: section.startedAt)
        guard let endedAt = section.endedAt else { return "since \(start)" }
        let end = formatter.string(from: endedAt)
        return start == end ? start : "\(start) – \(end)"
    }
}

private struct HistoryRow: View {
    let alert: AlertRecord
    let isMine: Bool
    @ScaledMetric(relativeTo: .title2) private var directionIconSize: CGFloat = 22
    @ScaledMetric(relativeTo: .title3) private var ackEmojiSize: CGFloat = 20

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isMine ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                .font(.system(size: directionIconSize))
                .foregroundStyle(isMine ? Color.blue : Color.red)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Text(relativeTime(from: alert.createdAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if alert.state == .acknowledged {
                Text(alert.ackEmoji ?? "✅")
                    .font(.system(size: ackEmojiSize))
            }
        }
        .padding(.vertical, 4)
    }

    private var title: String {
        let who = isMine
            ? String(localized: "You")
            : (alert.senderName.isEmpty ? String(localized: "Partner") : alert.senderName)
        let body = alert.message.trimmingCharacters(in: .whitespacesAndNewlines)
        let bodyText = body.isEmpty ? String(localized: "needs attention") : body
        return "\(who) · \(bodyText)"
    }

    private func relativeTime(from date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
