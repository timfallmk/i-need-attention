import SwiftUI

/// Interval picker for snoozing an incoming alert from the watch — mirrors WatchAckSheet's
/// compact style. Same 5/15/30 choices the iPhone offers, so the watch has full parity.
struct WatchSnoozeSheet: View {
    let onPick: (Int) -> Void
    private let minuteOptions = [5, 15, 30]
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ScaledMetric(relativeTo: .subheadline) private var headingSize: CGFloat = 14
    @ScaledMetric(relativeTo: .subheadline) private var optionSize: CGFloat = 15
    @ScaledMetric(relativeTo: .subheadline) private var rowHeight: CGFloat = 40

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Text("Remind me in…")
                    .font(.system(size: headingSize, weight: .semibold))
                    .padding(.top, 4)
                    .accessibilityAddTraits(.isHeader)

                ForEach(minuteOptions, id: \.self) { minutes in
                    Button {
                        onPick(minutes)
                    } label: {
                        Text("\(minutes) minutes")
                            .font(.system(size: optionSize, weight: .medium))
                            .frame(maxWidth: .infinity, minHeight: rowHeight)
                    }
                    .buttonStyle(.plain)
                    .background(.gray.opacity(reduceTransparency ? 0.36 : 0.18), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 8)
        }
    }
}

#if DEBUG
#Preview {
    WatchSnoozeSheet { _ in }
}
#endif
