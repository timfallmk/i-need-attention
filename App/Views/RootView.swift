import CloudKit
import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Group {
            if appState.iCloudStatus == .noAccount || appState.iCloudStatus == .restricted {
                ICloudGateView()
            } else if appState.pair == nil {
                PairingFlowView()
            } else {
                MainView()
            }
        }
        .animation(.easeInOut(duration: 0.25), value: appState.pair?.pairKey)
    }
}

private struct ICloudGateView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "icloud.slash")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(.secondary)
            Text("iCloud Required")
                .font(.title2.weight(.semibold))
            Text("Open Settings, sign in to iCloud, then come back.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 40)
        }
    }
}
