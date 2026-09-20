import SwiftUI

/// The big red button. Pure visual — wires its press into a closure passed by the parent.
struct AttentionButton: View {
    let isCoolingDown: Bool
    let cooldownRemaining: TimeInterval
    let cooldownTotal: TimeInterval
    let isSending: Bool
    /// Tap sends the default "needs attention".
    let onPress: () async -> Void
    /// Long-press opens a picker so the user can pick or compose a different noun.
    let onLongPress: () -> Void

    @State private var pressed = false
    @State private var pulse = false
    // Text and circle scale together, so the label keeps its proportions rather than being
    // squeezed by minimumScaleFactor against a container that stayed put.
    @ScaledMetric(relativeTo: .largeTitle) private var iconSize: CGFloat = 44
    @ScaledMetric(relativeTo: .title2) private var centerTextSize: CGFloat = 22
    @ScaledMetric(relativeTo: .largeTitle) private var scaledDiameter: CGFloat = 280
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Capped because nothing else bounds the button horizontally — scrollsWhenTight only
    // rescues vertical overflow, and at the largest accessibility size an uncapped 280
    // lands near 440, wider than the narrowest phone this ships to.
    private var diameter: CGFloat { min(scaledDiameter, 320) }
    private var ringDiameter: CGFloat { diameter + 16 }

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
                .animation(haloAnimation, value: pulse)

            // Cooldown ring — drains from full to empty as the cooldown elapses.
            // Sits just outside the button, tracking it as it scales.
            if isCoolingDown {
                Circle()
                    .stroke(.gray.opacity(0.18), lineWidth: 8)
                    .frame(width: ringDiameter, height: ringDiameter)
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
                    .frame(width: ringDiameter, height: ringDiameter)
                    .animation(reduceMotion ? nil : .linear(duration: 1), value: cooldownProgress)
                    .transition(reduceMotion ? .identity : .opacity)
            }

            // The button itself
            Button {
                Task { await onPress() }
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
                            .font(.system(size: iconSize, weight: .bold))
                        Text(centerText)
                            .font(.system(size: centerTextSize, weight: .heavy, design: .rounded))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .minimumScaleFactor(0.7)
                            .padding(.horizontal, 32)
                    }
                    .foregroundStyle(.white)
                }
            }
            .buttonStyle(PressedButtonStyle(pressed: $pressed))
            .disabled(isCoolingDown)
            .scaleEffect(pressed ? 0.96 : 1.0)
            .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.55), value: pressed)
            // highPriorityGesture (rather than simultaneousGesture) ensures a
            // recognized long-press suppresses the Button's tap action — otherwise
            // a held-then-released touch could fire both the default send and open
            // the picker.
            .highPriorityGesture(
                LongPressGesture(minimumDuration: 0.4)
                    .onEnded { _ in
                        guard !isCoolingDown else { return }
                        Haptics.tick()
                        onLongPress()
                    }
            )
            // Stable label — deliberately excludes the live countdown so VoiceOver doesn't
            // re-announce the button every second while it cools down.
            .accessibilityLabel(isCoolingDown ? Text("Cooling down") : Text("I need attention"))
            .accessibilityHint(isCoolingDown ? Text("") : Text("Sends an attention request to your partner"))
            // The seconds live here rather than in the label above, which is what makes
            // the label safe to keep stable: a value is read on focus rather than
            // announced on every change.
            .accessibilityValue(isCoolingDown ? Text("\(Int(cooldownRemaining)) seconds remaining") : Text(""))
            // Long-press has no VoiceOver equivalent, so expose the noun picker as a custom action.
            .accessibilityAction(named: Text("Choose what you need")) {
                guard !isCoolingDown else { return }
                onLongPress()
            }
        }
        .frame(width: diameter, height: diameter)
        .onChange(of: isSending) { _, sending in
            pulse = sending && !reduceMotion
        }
    }

    // The one animation the setting exists for, because it repeats forever. Under
    // Reduce Motion the halo must not start rather than run slower — `pulse` stays false,
    // so the ring holds the same resting appearance it already has when idle.
    private var haloAnimation: Animation? {
        guard !reduceMotion else { return nil }
        return pulse ? .easeOut(duration: 1.2).repeatForever(autoreverses: false) : .default
    }

    private var centerText: LocalizedStringKey {
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
