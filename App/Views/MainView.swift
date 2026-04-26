import SwiftUI

struct MainView: View {
    @Environment(AppState.self) private var appState
    @State private var showSettings = false
    @State private var showAckSheet = false
    @State private var now = Date()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            backdrop.ignoresSafeArea()

            VStack(spacing: 24) {
                topBar
                StatusIndicatorView(
                    outgoing: appState.pendingOutgoing,
                    incoming: appState.lastIncoming,
                    isOnCooldown: appState.isOnCooldown
                )
                .padding(.top, 8)

                Spacer(minLength: 0)

                AttentionButton(
                    isCoolingDown: appState.isOnCooldown,
                    cooldownRemaining: cooldownRemaining,
                    isSending: appState.pendingOutgoing?.state == .sent
                ) { critical in
                    await appState.sendAttention(critical: critical)
                }

                Text("Long-press for urgent")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Spacer(minLength: 0)

                if let incoming = appState.lastIncoming, shouldShowAckButton(for: incoming) {
                    Button {
                        showAckSheet = true
                    } label: {
                        Label("Let them know you're here", systemImage: "checkmark.circle.fill")
                            .font(.headline)
                            .padding(.vertical, 14)
                            .padding(.horizontal, 22)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                partnerBadge
                    .padding(.bottom, 16)
            }
            .padding(.top, 8)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environment(appState)
        }
        .sheet(isPresented: $showAckSheet) {
            AckSheet { emoji in
                Task { await appState.acknowledgeIncoming(emoji: emoji) }
                showAckSheet = false
            }
            .presentationDetents([.height(260)])
        }
        .onReceive(timer) { now = $0 }
    }

    private var topBar: some View {
        HStack {
            Text("Attention")
                .font(.system(size: 20, weight: .bold, design: .rounded))
            Spacer()
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 24)
    }

    private var partnerBadge: some View {
        Group {
            if let pair = appState.pair {
                HStack(spacing: 6) {
                    Image(systemName: "link.circle.fill")
                        .foregroundStyle(.secondary)
                    Text("paired with \(pair.partnerName)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var backdrop: some View {
        LinearGradient(
            colors: [
                Color(.systemBackground),
                Color(.systemBackground),
                Color.red.opacity(0.10)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var cooldownRemaining: TimeInterval {
        guard let end = appState.cooldownEnds else { return 0 }
        return max(0, end.timeIntervalSince(now))
    }

    private func shouldShowAckButton(for alert: AlertRecord) -> Bool {
        alert.state != .acknowledged
    }
}

private struct AckSheet: View {
    let onPick: (String?) -> Void
    private let emojis = ["❤️", "👍", "🤗", "🙏", "🚨", "⏳"]

    var body: some View {
        VStack(spacing: 18) {
            Capsule()
                .fill(.tertiary)
                .frame(width: 36, height: 4)
                .padding(.top, 10)
            Text("Acknowledge")
                .font(.headline)
            Text("Pick a quick reaction so they know you're on it.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            HStack(spacing: 12) {
                ForEach(emojis, id: \.self) { emoji in
                    Button {
                        onPick(emoji)
                    } label: {
                        Text(emoji)
                            .font(.system(size: 30))
                            .frame(width: 50, height: 50)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                }
            }
            Button("Just acknowledge") {
                onPick(nil)
            }
            .font(.subheadline)
            .padding(.bottom, 12)
        }
        .padding(.horizontal, 16)
    }
}
