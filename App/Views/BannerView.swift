import SwiftUI

/// Transient toast that appears at the top of the screen for transient errors and
/// confirmations. Auto-dismisses after `duration`. Tap to dismiss early.
struct BannerView: View {
    enum Tone {
        case error, info, success

        var tint: Color {
            switch self {
            case .error:   return .red
            case .info:    return .blue
            case .success: return .green
            }
        }

        var icon: String {
            switch self {
            case .error:   return "exclamationmark.triangle.fill"
            case .info:    return "info.circle.fill"
            case .success: return "checkmark.circle.fill"
            }
        }
    }

    let tone: Tone
    let message: String
    let action: (() -> Void)?
    let actionLabel: String?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: tone.icon)
                .foregroundStyle(tone.tint)
                .font(.headline)
                .accessibilityHidden(true)
            Text(message)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 4)
            if let action, let actionLabel {
                Button(actionLabel, action: action)
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(tone.tint)
            }
        }
        .accessibilityElement(children: .combine)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(tone.tint.opacity(reduceTransparency ? 0.55 : 0.25), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.12), radius: 12, x: 0, y: 6)
        .padding(.horizontal, 16)
    }
}

/// View modifier that overlays a banner when a String binding is non-nil. Auto-clears
/// the binding after `duration` seconds. Re-arms the timer whenever the message changes.
struct BannerModifier: ViewModifier {
    @Binding var message: String?
    var tone: BannerView.Tone = .error
    var duration: TimeInterval = 4
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let message {
                    BannerView(tone: tone, message: message, action: nil, actionLabel: nil)
                        .padding(.top, 8)
                        .onTapGesture { self.message = nil }
                        .transition(reduceMotion ? .identity : .move(edge: .top).combined(with: .opacity))
                        .task(id: message) {
                            // task(id:) cancels and restarts whenever message changes —
                            // gives every new error its own full duration.
                            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                            if !Task.isCancelled {
                                self.message = nil
                            }
                        }
                }
            }
            .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.8), value: message)
    }
}

extension View {
    func banner(_ message: Binding<String?>, tone: BannerView.Tone = .error, duration: TimeInterval = 4) -> some View {
        modifier(BannerModifier(message: message, tone: tone, duration: duration))
    }
}
