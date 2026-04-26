import SwiftUI
import WatchKit

struct WatchContentView: View {
    @EnvironmentObject var session: WatchSession
    @State private var pulse = false

    var body: some View {
        ZStack {
            RadialGradient(
                colors: [.red.opacity(0.35), .clear],
                center: .center,
                startRadius: 4,
                endRadius: 120
            )
            .ignoresSafeArea()

            VStack(spacing: 8) {
                Button {
                    session.sendPress()
                    pulse.toggle()
                } label: {
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color(red: 1.00, green: 0.36, blue: 0.36),
                                        Color(red: 0.78, green: 0.10, blue: 0.14)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .shadow(color: .red.opacity(0.6), radius: 10)
                        VStack(spacing: 2) {
                            Image(systemName: "hand.raised.fill")
                                .font(.system(size: 22, weight: .bold))
                            Text("Need\nattention")
                                .font(.system(size: 12, weight: .heavy, design: .rounded))
                                .multilineTextAlignment(.center)
                        }
                        .foregroundStyle(.white)
                    }
                }
                .buttonStyle(.plain)
                .scaleEffect(pulse ? 0.94 : 1.0)
                .animation(.spring(response: 0.25, dampingFraction: 0.55), value: pulse)

                if let result = session.lastResult {
                    Text(result)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
