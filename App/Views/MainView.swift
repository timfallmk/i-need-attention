import SwiftUI
import UIKit

struct MainView: View {
    @Environment(AppState.self) private var appState
    @State private var showSettings = false
    @State private var showHistory = false
    @State private var showAckSheet = false
    @State private var showNounPicker = false
    @State private var showSnoozeOptions = false
    @State private var now = Date()

    private let snoozeMinuteOptions = [5, 15, 30]
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        @Bindable var bindable = appState

        ZStack {
            backdrop.ignoresSafeArea()

            VStack(spacing: 24) {
                topBar

                if appState.isDemo {
                    DemoBanner { appState.endDemo() }
                        .padding(.horizontal, 16)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                if appState.notificationsDenied {
                    NotificationsDeniedBanner()
                        .padding(.horizontal, 16)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                // We can send but they can't reach us yet — the joiner's side of the
                // half-formed state. Sending works, so the button stays; saying nothing
                // would leave them wondering why nothing ever comes back.
                if let pair = appState.pair, pair.canSend, !pair.partnerCanReach {
                    OneWayBanner(partnerName: pair.partnerName)
                        .padding(.horizontal, 16)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                StatusIndicatorView(
                    outgoing: appState.pendingOutgoing,
                    incoming: appState.lastIncoming,
                    isOnCooldown: appState.isOnCooldown,
                    snoozedUntil: appState.incomingIsSnoozed ? appState.snooze?.until : nil,
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
                    incomingActions
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                partnerBadge
                    .padding(.bottom, 16)
            }
            .padding(.top, 8)
            .readableWidth()
        }
        // Self-guards and returns immediately once both directions are live, so this is
        // a no-op for every launch but the one right after pairing.
        .task { await appState.awaitPartnerReachability() }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environment(appState)
        }
        .sheet(isPresented: $showHistory) {
            HistoryView()
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
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: appState.isDemo)
    }

    @ViewBuilder
    private var incomingActions: some View {
        if appState.incomingIsSnoozed {
            HStack(spacing: 12) {
                Label("Snoozed", systemImage: "clock.badge.checkmark")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Button("Cancel") {
                    Haptics.select()
                    appState.cancelSnooze()
                }
                .font(.subheadline.weight(.semibold))
                .tint(.red)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 20)
            .background(.ultraThinMaterial, in: Capsule())
        } else {
            VStack(spacing: 10) {
                Button {
                    showAckSheet = true
                } label: {
                    Label("Let them know you're here", systemImage: "checkmark.circle.fill")
                        .font(.headline)
                        .padding(.vertical, 14)
                        .padding(.horizontal, 22)
                        .background(.ultraThinMaterial, in: Capsule())
                }

                Button {
                    Haptics.select()
                    showSnoozeOptions = true
                } label: {
                    Label("Remind me later", systemImage: "clock.arrow.circlepath")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .confirmationDialog("Remind me in…", isPresented: $showSnoozeOptions, titleVisibility: .visible) {
                    ForEach(snoozeMinuteOptions, id: \.self) { minutes in
                        Button("\(minutes) minutes") {
                            appState.snoozeIncoming(minutes: minutes)
                        }
                    }
                }
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 18) {
            Text("Attention")
                .font(.system(size: 20, weight: .bold, design: .rounded))
            Spacer()
            Button {
                showHistory = true
            } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("History")
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal, 24)
    }

    private var partnerBadge: some View {
        Group {
            if let partner = appState.partnerDisplayName {
                HStack(spacing: 6) {
                    Image(systemName: "link.circle.fill")
                        .foregroundStyle(.secondary)
                    Text("paired with \(partner)")
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
            Text("Pick a quick reaction so they know you're on it. Tap + for more emoji.")
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
            .modifier(ToneAccessibilityAction(emoji: emoji, enabled: supportsTones, onPick: { toneSelection = ToneSelection(base: $0) }))
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


/// The joiner's half of the transient one-directional window: they can send, but their
/// partner hasn't accepted their share yet, so nothing can come back. Resolves on its
/// own — the pair-profile push, and `AppState.awaitPartnerReachability` polling behind
/// this view for as long as it is up — so this explains rather than asks for anything.
private struct OneWayBanner: View {
    let partnerName: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.up.circle")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("You can reach \(displayName), not the other way round yet")
                    .font(.footnote.weight(.medium))
                Text("Their phone finishes connecting on its own.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.orange.opacity(0.12))
        )
    }

    private var displayName: String {
        partnerName.isEmpty ? "your partner" : partnerName
    }
}

/// Says plainly that nothing here is real, and offers the way out.
///
/// Permanent and unmissable rather than a dismissible toast: someone who forgets they
/// are in a demo would conclude their partner had answered them, which is the one
/// misunderstanding this feature could actually cause.
private struct DemoBanner: View {
    var onExit: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "play.circle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Demo")
                    .font(.subheadline.weight(.semibold))
                Text("\(DemoSession.partnerName) isn't real and nothing is sent. Pair with someone to use it for real.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Exit") {
                Haptics.select()
                onExit()
            }
            .font(.footnote.weight(.semibold))
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.orange.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.25), lineWidth: 1)
        )
    }
}
