import SwiftUI

/// The big red button. Pure visual — wires its press into a closure passed by the parent.
struct AttentionButton: View {
    let isCoolingDown: Bool
    let cooldownRemaining: TimeInterval
    let cooldownTotal: TimeInterval
    let isSending: Bool
    /// Tap = standard ping, long-press menu offers a critical send.
    let onPress: (_ critical: Bool) async -> Void

    @State private var pressed = false
    @State private var pulse = false

    private var cooldownProgress: Double {
        guard cooldownTotal > 0, isCoolingDown else { return 0 }
        return max(0, min(1, cooldownRemaining / cooldownTotal))
    }

    var body: some View {
        ZStack {
            // Outer pulse halo while sending or just sent
            Circle()
                .strokeBorder(
                    LinearGradient(
                        colors: [.red.opacity(0.45), .red.opacity(0.0)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 8
                )
                .scaleEffect(pulse ? 1.10 : 1.0)
                .opacity(pulse ? 0 : 0.9)
                .animation(
                    pulse
                    ? .easeOut(duration: 1.2).repeatForever(autoreverses: false)
                    : .default,
                    value: pulse
                )

            // Cooldown ring — drains from full to empty as the cooldown elapses.
            // Sits just outside the button (frame 280 → ring 296).
            if isCoolingDown {
                Circle()
                    .stroke(.gray.opacity(0.18), lineWidth: 8)
                    .frame(width: 296, height: 296)
                Circle()
                    .trim(from: 0, to: cooldownProgress)
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color(red: 1.00, green: 0.36, blue: 0.36),
                                Color(red: 0.78, green: 0.10, blue: 0.14)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        style: StrokeStyle(lineWidth: 8, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .frame(width: 296, height: 296)
                    .animation(.linear(duration: 1), value: cooldownProgress)
                    .transition(.opacity)
            }

            // The button itself
            Button {
                Task { await onPress(false) }
            } label: {
                ZStack {
                    Circle()
                        .fill(buttonGradient)
                        .overlay(
                            Circle()
                                .strokeBorder(.white.opacity(0.18), lineWidth: 2)
                        )
                        .shadow(color: .red.opacity(0.45), radius: 30, x: 0, y: 18)
                        .shadow(color: .black.opacity(0.25), radius: 8, x: 0, y: 4)

                    // Subtle inner glow
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [.white.opacity(0.25), .clear],
                                center: .init(x: 0.35, y: 0.30),
                                startRadius: 4,
                                endRadius: 140
                            )
                        )
                        .blendMode(.plusLighter)

                    VStack(spacing: 6) {
                        Image(systemName: isCoolingDown ? "hourglass" : "hand.raised.fill")
                            .font(.system(size: 44, weight: .bold))
                        Text(centerText)
                            .font(.system(size: 22, weight: .heavy, design: .rounded))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .padding(.horizontal, 32)
                    }
                    .foregroundStyle(.white)
                }
            }
            .buttonStyle(PressedButtonStyle(pressed: $pressed))
            .disabled(isCoolingDown)
            .scaleEffect(pressed ? 0.96 : 1.0)
            .animation(.spring(response: 0.28, dampingFraction: 0.55), value: pressed)
            .contextMenu {
                Button {
                    Task { await onPress(false) }
                } label: {
                    Label("Send", systemImage: "hand.raised.fill")
                }
                Button(role: .destructive) {
                    Task { await onPress(true) }
                } label: {
                    Label("Send as Critical", systemImage: "exclamationmark.triangle.fill")
                }
            }
        }
        .frame(width: 280, height: 280)
        .onChange(of: isSending) { _, sending in
            pulse = sending
        }
    }

    private var centerText: String {
        if isCoolingDown {
            return "wait \(Int(cooldownRemaining))s"
        }
        return "I need\nattention"
    }

    private var buttonGradient: LinearGradient {
        let stops: [Color] = isCoolingDown
            ? [.gray.opacity(0.85), .gray]
            : [Color(red: 1.00, green: 0.36, blue: 0.36),
               Color(red: 0.90, green: 0.16, blue: 0.20),
               Color(red: 0.66, green: 0.06, blue: 0.10)]
        return LinearGradient(colors: stops, startPoint: .top, endPoint: .bottom)
    }
}

private struct PressedButtonStyle: ButtonStyle {
    @Binding var pressed: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, newValue in
                pressed = newValue
            }
    }
}
