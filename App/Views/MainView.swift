import SwiftUI
import UIKit

struct MainView: View {
    @Environment(AppState.self) private var appState
    @State private var showSettings = false
    @State private var showAckSheet = false
    @State private var showNounPicker = false
    @State private var now = Date()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        @Bindable var bindable = appState

        ZStack {
            backdrop.ignoresSafeArea()

            VStack(spacing: 24) {
                topBar

                if appState.notificationsDenied {
                    NotificationsDeniedBanner()
                        .padding(.horizontal, 16)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                StatusIndicatorView(
                    outgoing: appState.pendingOutgoing,
                    incoming: appState.lastIncoming,
                    isOnCooldown: appState.isOnCooldown,
                    onClear: { appState.clearOutgoing() }
                )
                .padding(.top, 8)

                Spacer(minLength: 0)

                AttentionButton(
                    isCoolingDown: appState.isOnCooldown,
                    cooldownRemaining: cooldownRemaining,
                    cooldownTotal: TimeInterval(appState.settings.cooldownSeconds),
                    isSending: appState.pendingOutgoing?.state == .sent,
                    onPress: { await appState.sendAttention() },
                    onLongPress: { showNounPicker = true }
                )

                Text("Long-press to choose")
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
        .sheet(isPresented: $showNounPicker) {
            NounPickerSheet(
                onPick: { noun in
                    showNounPicker = false
                    Task { await appState.sendAttention(noun: noun) }
                },
                onCancel: { showNounPicker = false }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.hidden)
        }
        .onReceive(timer) { now = $0 }
        .banner($bindable.bannerMessage, tone: .error)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: appState.notificationsDenied)
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

private struct NotificationsDeniedBanner: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "bell.slash.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 18, weight: .semibold))
            VStack(alignment: .leading, spacing: 1) {
                Text("Notifications are off")
                    .font(.system(size: 14, weight: .semibold))
                Text("You won't see incoming alerts until you turn them on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            Button("Turn On") {
                if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                    UIApplication.shared.open(url)
                } else if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .font(.system(size: 13, weight: .semibold))
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(.orange)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.orange.opacity(0.3), lineWidth: 1)
        )
    }
}

private struct AckSheet: View {
    let onPick: (String?) -> Void
    private let emojis = ["❤️", "👍", "🤗", "🙏", "🚨", "⏳"]

    @State private var showFullPicker = false
    @State private var toneSelection: ToneSelection?

    var body: some View {
        VStack(spacing: 18) {
            Capsule()
                .fill(.tertiary)
                .frame(width: 36, height: 4)
                .padding(.top, 10)
            Text("Acknowledge")
                .font(.headline)
            Text("Pick a quick reaction so they know you're on it. Long-press for skin tones, or tap + for any emoji.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            HStack(spacing: 6) {
                ForEach(emojis, id: \.self) { emoji in
                    emojiButton(emoji)
                }
                moreButton
            }
            Button("Just acknowledge") {
                onPick(nil)
            }
            .font(.subheadline)
            .padding(.bottom, 12)
        }
        .padding(.horizontal, 12)
        .sheet(isPresented: $showFullPicker) {
            EmojiPickerView { emoji in
                onPick(emoji)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $toneSelection) { selection in
            ToneStripSheet(base: selection.base) { toned in
                toneSelection = nil
                onPick(toned)
            }
            .presentationDetents([.height(180)])
            .presentationDragIndicator(.visible)
        }
    }

    private func emojiButton(_ emoji: String) -> some View {
        let supportsTones = EmojiCatalog.fitzpatrickBase.contains(emoji)
        return Text(emoji)
            .font(.system(size: 28))
            .frame(width: 44, height: 44)
            .background(.ultraThinMaterial, in: Circle())
            .contentShape(Circle())
            .onTapGesture {
                Haptics.select()
                onPick(emoji)
            }
            .onLongPressGesture(minimumDuration: 0.4) {
                guard supportsTones else { return }
                Haptics.tick()
                toneSelection = ToneSelection(base: emoji)
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(Text(emoji))
            .accessibilityHint(supportsTones ? Text("Long-press for skin tones") : Text(""))
    }

    private var moreButton: some View {
        Button {
            Haptics.select()
            showFullPicker = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("More emoji")
    }
}

private struct ToneSelection: Identifiable {
    let id = UUID()
    let base: String
}

private struct ToneStripSheet: View {
    let base: String
    let onPick: (String) -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Skin tone")
                .font(.headline)
                .padding(.top, 18)
            HStack(spacing: 8) {
                button(for: base, label: "default")
                ForEach(SkinTone.allCases) { tone in
                    button(for: EmojiCatalog.toned(base, tone), label: tone.rawValue)
                }
            }
            .padding(.horizontal, 12)
            Spacer(minLength: 0)
        }
    }

    private func button(for emoji: String, label: String) -> some View {
        Button {
            Haptics.select()
            onPick(emoji)
        } label: {
            Text(emoji)
                .font(.system(size: 30))
                .frame(width: 48, height: 48)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }
}
