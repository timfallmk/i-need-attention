import SwiftUI

struct ToneSelection: Identifiable, Equatable {
    let id = UUID()
    let base: String
}

struct ToneAccessibilityAction: ViewModifier {
    let emoji: String
    let enabled: Bool
    let onPick: (String) -> Void

    func body(content: Content) -> some View {
        if enabled {
            content.accessibilityAction(named: Text("Pick skin tone")) {
                onPick(emoji)
            }
        } else {
            content
        }
    }
}

struct ToneStripSheet: View {
    @ScaledMetric(relativeTo: .title) private var emojiSize: CGFloat = 30
    @ScaledMetric(relativeTo: .title) private var tapTarget: CGFloat = 48
    let base: String
    let onPick: (String) -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Skin tone")
                .font(.headline)
                .padding(.top, 18)
            HStack(spacing: 8) {
                button(emoji: base, toneLabel: "default")
                ForEach(SkinTone.allCases) { tone in
                    button(emoji: EmojiCatalog.toned(base, tone), toneLabel: tone.accessibilityName)
                }
            }
            .scrollsSidewaysWhenTight()
            .padding(.horizontal, 12)
            Spacer(minLength: 0)
        }
    }

    private func button(emoji: String, toneLabel: String) -> some View {
        Button {
            Haptics.select()
            onPick(emoji)
        } label: {
            Text(emoji)
                .font(.system(size: emojiSize))
                .frame(width: tapTarget, height: tapTarget)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("\(base), \(toneLabel)"))
    }
}
