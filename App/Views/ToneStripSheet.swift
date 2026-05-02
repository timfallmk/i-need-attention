import SwiftUI

struct ToneSelection: Identifiable, Equatable {
    let id = UUID()
    let base: String
}

struct ToneStripSheet: View {
    let base: String
    let onPick: (String) -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Skin tone")
                .font(.headline)
                .padding(.top, 18)
            HStack(spacing: 8) {
                button(emoji: base, accessibilityLabel: "Default")
                ForEach(SkinTone.allCases) { tone in
                    button(emoji: EmojiCatalog.toned(base, tone), accessibilityLabel: tone.accessibilityName)
                }
            }
            .padding(.horizontal, 12)
            Spacer(minLength: 0)
        }
    }

    private func button(emoji: String, accessibilityLabel: String) -> some View {
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
        .accessibilityLabel(Text(accessibilityLabel))
    }
}
