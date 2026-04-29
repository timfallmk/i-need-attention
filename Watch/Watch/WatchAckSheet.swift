import SwiftUI

/// Compact emoji picker shown when the wearer wants to acknowledge an incoming alert.
/// Uses a watch-friendly subset of the iPhone AckSheet glyphs — same core reactions,
/// dropped the rarely-used 🙏 / ⏳ to keep the grid one tap-friendly screen.
struct WatchAckSheet: View {
    let onPick: (String?) -> Void
    private let emojis = ["❤️", "👍", "🤗", "🚨"]

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Text("Acknowledge")
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.top, 4)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                    ForEach(emojis, id: \.self) { emoji in
                        Button {
                            onPick(emoji)
                        } label: {
                            Text(emoji)
                                .font(.system(size: 24))
                                .frame(maxWidth: .infinity, minHeight: 40)
                        }
                        .buttonStyle(.plain)
                        .background(.gray.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
                    }
                }

                Button {
                    onPick(nil)
                } label: {
                    Text("Just acknowledge")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(.plain)
                .background(.gray.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 8)
        }
    }
}
