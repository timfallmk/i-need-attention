import SwiftUI

/// Shown when a pairing exists but this device can't send yet.
///
/// The handshake makes the two directions live at different moments: whoever scanned can
/// send immediately, while whoever showed the code has to wait for their partner's half
/// to arrive and be accepted. That gap is usually a second or two, and it resolves with
/// no help from anyone — but it can outlive a launch if the app was killed in between,
/// so it needs a screen rather than a spinner. Offering the button here would mean a
/// press that goes nowhere, which is the one thing this app must never do.
struct FinishingSetupView: View {
    @Environment(AppState.self) private var appState
    @State private var retrying = false

    var body: some View {
        VStack(spacing: 18) {
            Spacer()

            Image(systemName: "link.badge.plus")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(.secondary)
                .symbolEffect(.pulse, options: .repeating)

            VStack(spacing: 8) {
                Text("Finishing setup")
                    .font(.title2.weight(.semibold))
                Text("\(partnerName) has to finish connecting from their side. This usually takes a moment and doesn't need anything from you.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 36)
            }

            Spacer()

            VStack(spacing: 12) {
                Button {
                    Task {
                        retrying = true
                        await appState.reconcileHalfFormedPair()
                        retrying = false
                    }
                } label: {
                    HStack {
                        if retrying { ProgressView().controlSize(.small) }
                        Text(retrying ? "Checking…" : "Check again")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(retrying)

                Button("Start over", role: .destructive) {
                    Task { await appState.unpair() }
                }
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 32)
        }
        .readableWidth()
        .task { await appState.reconcileHalfFormedPair() }
    }

    private var partnerName: String {
        let name = appState.pair?.partnerName ?? ""
        return name.isEmpty ? "Your partner" : name
    }
}
