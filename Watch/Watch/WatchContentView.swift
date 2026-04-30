import SwiftUI
import WatchKit

struct WatchContentView: View {
    @EnvironmentObject var session: WatchSession
    @State private var pulse = false
    @State private var showAckSheet = false
    @State private var now = Date()

    var body: some View {
        ZStack {
            RadialGradient(
                colors: [.red.opacity(0.35), .clear],
                center: .center,
                startRadius: 4,
                endRadius: 120
            )
            .ignoresSafeArea()

            VStack(spacing: 6) {
                WatchStatusPill(snapshot: session.snapshot, now: now)
                    .padding(.horizontal, 4)

                Button {
                    guard !isCoolingDown else { return }
                    session.sendPress()
                    pulse.toggle()
                } label: {
                    ZStack {
                        Circle()
                            .fill(buttonGradient)
                            .shadow(color: .red.opacity(0.6), radius: 10)
                        VStack(spacing: 2) {
                            Image(systemName: "hand.raised.fill")
                                .font(.system(size: 22, weight: .bold))
                            Text("Need\nattention")
                                .font(.system(size: 12, weight: .heavy, design: .rounded))
                                .multilineTextAlignment(.center)
                        }
                        .foregroundStyle(.white)
                        .opacity(isCoolingDown ? 0.55 : 1.0)
                    }
                }
                .buttonStyle(.plain)
                .disabled(isCoolingDown)
                .scaleEffect(pulse ? 0.94 : 1.0)
                .animation(.spring(response: 0.25, dampingFraction: 0.55), value: pulse)

                if showsAckButton {
                    Button {
                        showAckSheet = true
                    } label: {
                        Label("Acknowledge", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.vertical, 4)
                            .padding(.horizontal, 10)
                    }
                    .buttonStyle(.plain)
                    .background(.ultraThinMaterial, in: Capsule())
                }

                if showsClearButton {
                    Button {
                        session.sendClear()
                    } label: {
                        Label("Clear", systemImage: "xmark.circle.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.vertical, 4)
                            .padding(.horizontal, 10)
                    }
                    .buttonStyle(.plain)
                    .background(.ultraThinMaterial, in: Capsule())
                }
            }
            .padding(.vertical, 4)
        }
        .task(id: session.snapshot?.cooldownEnds) {
            // Only tick while a cooldown is actively winding down — outside that
            // window the 1Hz timer would just burn watch battery for no UI change.
            guard let end = session.snapshot?.cooldownEnds, end > Date() else {
                now = Date()
                return
            }
            while !Task.isCancelled {
                now = Date()
                if Date() >= end { return }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .sheet(isPresented: $showAckSheet) {
            WatchAckSheet { emoji in
                session.sendAck(emoji: emoji)
                showAckSheet = false
            }
        }
    }

    private var buttonGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 1.00, green: 0.36, blue: 0.36),
                Color(red: 0.78, green: 0.10, blue: 0.14)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var isCoolingDown: Bool {
        guard let end = session.snapshot?.cooldownEnds else { return false }
        return end > now
    }

    private var showsAckButton: Bool {
        guard let incoming = session.snapshot?.incoming else { return false }
        return !incoming.acknowledged
    }

    private var showsClearButton: Bool {
        !showsAckButton && session.snapshot?.outgoing?.state == .acknowledged
    }
}
