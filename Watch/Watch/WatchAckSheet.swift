import SwiftUI

/// Compact emoji picker shown when the wearer wants to acknowledge an incoming alert.
/// Uses a watch-friendly subset of the iPhone AckSheet glyphs — same core reactions,
/// dropped the rarely-used 🙏 / ⏳ to keep the grid one tap-friendly screen.
struct WatchAckSheet: View {
    let onPick: (String?) -> Void
    private let emojis = ["❤️", "👍", "🤗", "🚨"]
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ScaledMetric(relativeTo: .subheadline) private var headingSize: CGFloat = 14
    @ScaledMetric(relativeTo: .title2) private var emojiSize: CGFloat = 24
    @ScaledMetric(relativeTo: .title2) private var emojiRowHeight: CGFloat = 40
    @ScaledMetric(relativeTo: .caption) private var plainLabelSize: CGFloat = 12
    @ScaledMetric(relativeTo: .caption) private var plainRowHeight: CGFloat = 32

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Text("Acknowledge")
                    .font(.system(size: headingSize, weight: .semibold))
                    .padding(.top, 4)
                    .accessibilityAddTraits(.isHeader)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                    ForEach(emojis, id: \.self) { emoji in
                        Button {
                            onPick(emoji)
                        } label: {
                            Text(emoji)
                                .font(.system(size: emojiSize))
                                .frame(maxWidth: .infinity, minHeight: emojiRowHeight)
                        }
                        .buttonStyle(.plain)
                        .background(.gray.opacity(reduceTransparency ? 0.36 : 0.18), in: RoundedRectangle(cornerRadius: 10))
                        .accessibilityLabel(Text(emoji))
                    }
                }

                Button {
                    onPick(nil)
                } label: {
                    Text("Just acknowledge")
                        .font(.system(size: plainLabelSize, weight: .medium))
                        .frame(maxWidth: .infinity, minHeight: plainRowHeight)
                }
                .buttonStyle(.plain)
                .background(.gray.opacity(reduceTransparency ? 0.36 : 0.18), in: RoundedRectangle(cornerRadius: 10))
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 8)
        }
    }
}
