import SwiftUI

/// Confirmation sheet for a tapped `attention://pair` invite link. Pairing never happens
/// without an explicit confirmation here — any app or webpage can fire the URL scheme, so
/// the tap itself proves nothing about intent.
struct JoinInviteSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let invite: PairingInvite

    @State private var displayName: String = DeviceIdentity.name
    @State private var working = false
    @State private var error: String?

    private var trimmedName: String {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 20) {
            Capsule()
                .fill(.tertiary)
                .frame(width: 36, height: 4)
                .padding(.top, 10)

            if appState.pair != nil {
                alreadyPaired
            } else {
                joinForm
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .interactiveDismissDisabled(working)
    }

    private var alreadyPaired: some View {
        VStack(spacing: 14) {
            Image(systemName: "link.circle.fill")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.secondary)
            Text("Already paired")
                .font(.title3.weight(.semibold))
            Text("This phone is paired with \(appState.pair?.partnerName ?? "someone"). To accept \(inviterLabel)'s invite, unpair first in Settings.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("OK") { dismiss() }
                .buttonStyle(.bordered)
                .padding(.top, 6)
        }
        .padding(.top, 20)
    }

    private var joinForm: some View {
        VStack(spacing: 18) {
            Image(systemName: "person.2.wave.2.fill")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.red)
                .padding(.top, 10)

            VStack(spacing: 6) {
                Text("Pair with \(inviterLabel)?")
                    .font(.title3.weight(.semibold))
                Text("They'll be able to send you attention requests, and you them.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            NameField(displayName: $displayName)

            if let error {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.footnote)
                }
                .multilineTextAlignment(.center)
            }

            HStack(spacing: 12) {
                Button(role: .cancel) {
                    dismiss()
                } label: {
                    Text("Cancel")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)
                .disabled(working)

                Button {
                    Task { await join() }
                } label: {
                    HStack {
                        if working { ProgressView().controlSize(.small) }
                        Text(working ? "Pairing…" : "Pair")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(working || trimmedName.isEmpty)
            }
        }
    }

    private var inviterLabel: String {
        invite.inviterName.isEmpty ? "your partner" : invite.inviterName
    }

    @MainActor
    private func join() async {
        guard !working else { return }
        working = true
        defer { working = false }
        error = nil
        DeviceIdentity.name = trimmedName
        do {
            let state = try await PairingService.shared.completePairing(
                payload: invite.qrPayload,
                myName: trimmedName
            )
            Haptics.success()
            appState.applyPair(state)
            dismiss()
        } catch {
            Haptics.warning()
            self.error = error.localizedDescription
        }
    }
}
