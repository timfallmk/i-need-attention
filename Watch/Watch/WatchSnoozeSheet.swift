import SwiftUI

/// Interval picker for snoozing an incoming alert from the watch — mirrors WatchAckSheet's
/// compact style. Same 5/15/30 choices the iPhone offers, so the watch has full parity.
struct WatchSnoozeSheet: View {
    let onPick: (Int) -> Void
    private let minuteOptions = [5, 15, 30]

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Text("Remind me in…")
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.top, 4)

                ForEach(minuteOptions, id: \.self) { minutes in
                    Button {
                        onPick(minutes)
                    } label: {
                        Text("\(minutes) minutes")
                            .font(.system(size: 15, weight: .medium))
                            .frame(maxWidth: .infinity, minHeight: 40)
                    }
                    .buttonStyle(.plain)
                    .background(.gray.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
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
