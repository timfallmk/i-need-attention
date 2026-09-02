import SwiftUI

/// Recent attention exchanges, newest first. Read-only — fetched lazily from CloudKit
/// each time the sheet opens; nothing is cached or mutated here.
struct HistoryView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var alerts: [AlertRecord] = []
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
        } else if alerts.isEmpty {
            ContentUnavailableView {
                Label("No history yet", systemImage: "clock")
            } description: {
                Text("Alerts you send and receive will show up here.")
            }
        } else {
            List(alerts) { alert in
                HistoryRow(alert: alert, isMine: (appState.pair?.myDeviceID ?? DeviceIdentity.id) == alert.senderDeviceID)
            }
            .listStyle(.plain)
            .refreshable { await load() }
        }
    }

    @MainActor
    private func load() async {
        let archived = LegacyHistoryArchive.load()?.alerts ?? []
        guard let pair = appState.pair else {
            // An unpaired device can still have pre-2.0 history worth showing — that
            // is the state a user is in between the cutover and re-pairing.
            alerts = LegacyHistoryArchive.merged(live: [], archived: archived)
            loadFailed = false
            isLoading = false
            return
        }
        // Keep the current list visible during a pull-to-refresh; only show the
        // full-screen spinner on the first load.
        isLoading = alerts.isEmpty
        loadFailed = false
        do {
            let live = try await CloudKitService.shared.fetchRecentAlerts(pair: pair)
            alerts = LegacyHistoryArchive.merged(live: live, archived: archived)
        } catch {
            // Don't wipe an already-loaded list on a refresh failure; only surface
            // the full-screen error state when there's nothing to show. The archive
            // needs no network, so it stands in on its own.
            alerts = LegacyHistoryArchive.merged(live: alerts, archived: archived)
            loadFailed = alerts.isEmpty
        }
        isLoading = false
    }
}

private struct HistoryRow: View {
    let alert: AlertRecord
    let isMine: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isMine ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                .font(.system(size: 22))
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
                    .font(.system(size: 20))
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
