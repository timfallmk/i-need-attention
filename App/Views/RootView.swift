import CloudKit
import SwiftUI
import UIKit

struct RootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var bindable = appState

        Group {
            if appState.isDemo {
                // Ahead of both gates on purpose: the demo needs neither iCloud nor a
                // partner, so making it wait behind either would be arbitrary.
                MainView()
            } else if needsICloudGate {
                ICloudGateView()
            } else if appState.pair == nil {
                PairingFlowView()
            } else if appState.pair?.canSend == false {
                // Paired, but this device's half of the handshake hasn't come back yet.
                FinishingSetupView()
            } else {
                MainView()
            }
        }
        .animation(.easeInOut(duration: 0.25), value: appState.pair?.pairKey)
        .animation(.easeInOut(duration: 0.25), value: appState.pair?.canSend)
        .animation(.easeInOut(duration: 0.25), value: appState.iCloudStatus)
        .animation(.easeInOut(duration: 0.25), value: appState.isDemo)
        // Presented from the root, not from Settings: the erase tears that sheet down on
        // its way out, so an alert owned by it never survives long enough to be read.
        .alert("Erased, but not from iCloud", isPresented: $bindable.eraseLeftRemoteData) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Everything on this device is gone. iCloud couldn't be reached, so the "
                 + "alerts stored there may still exist — but the key that reads them has "
                 + "been destroyed, so nothing can open them. To clear the storage itself, "
                 + "delete the app's data from iCloud in iOS Settings.")
        }
        .sheet(item: $bindable.incomingJoinInvite) { invite in
            JoinInviteSheet(invite: invite)
                .environment(appState)
                .presentationDetents([.medium])
        }
    }

    private var needsICloudGate: Bool {
        switch appState.iCloudStatus {
        case .noAccount, .restricted, .temporarilyUnavailable:
            return true
        default:
            return false
        }
    }
}

private struct ICloudGateView: View {
    @Environment(AppState.self) private var appState
    @State private var checking = false

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "icloud.slash")
                .font(.system(size: 72, weight: .light))
                .foregroundStyle(.secondary)
                .symbolEffect(.pulse, options: .repeating)

            VStack(spacing: 8) {
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(detail)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 36)
            }

            Spacer()

            VStack(spacing: 12) {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Label("Open Settings", systemImage: "gear")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)

                Button {
                    Task {
                        checking = true
                        await appState.refreshICloudStatus()
                        checking = false
                    }
                } label: {
                    HStack {
                        if checking { ProgressView().controlSize(.small) }
                        Text(checking ? "Checking…" : "I've signed in — try again")
                    }
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)

                // Without this the screen is a dead end for anyone who can't sign in
                // right now — which includes an App Review device.
                Button("See how it works without signing in") {
                    Haptics.select()
                    appState.startDemo()
                }
                .font(.footnote.weight(.medium))
                .tint(.secondary)
                .padding(.top, 2)
                .tint(.red)
                .disabled(checking)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 32)
        }
        .scrollsWhenTight()
        .readableWidth()
    }

    private var title: String {
        switch appState.iCloudStatus {
        case .noAccount:              return "Sign in to iCloud"
        case .restricted:             return "iCloud is restricted"
        case .temporarilyUnavailable: return "iCloud unavailable"
        default:                       return "iCloud Required"
        }
    }

    private var detail: String {
        switch appState.iCloudStatus {
        case .noAccount:
            return "Open Settings, sign in with your Apple ID, then come back here."
        case .restricted:
            return "Screen Time or a configuration profile is blocking iCloud on this device."
        case .temporarilyUnavailable:
            return "iCloud is unreachable right now. Check your connection and try again in a moment."
        default:
            return "Open Settings, sign in to iCloud, then come back."
        }
    }
}
