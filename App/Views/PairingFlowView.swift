import CloudKit
import SwiftUI

struct PairingFlowView: View {
    @Environment(AppState.self) private var appState
    @State private var mode: Mode = .chooser
    @State private var displayName: String = DeviceIdentity.name

    enum Mode: Equatable {
        case chooser
        case showCode
        case scanCode
    }

    private var trimmedName: String {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Group {
                switch mode {
                case .chooser:
                    chooser
                case .showCode:
                    ShowCodeView(displayName: trimmedName) { mode = .chooser }
                case .scanCode:
                    ScanCodeView(displayName: trimmedName) { mode = .chooser }
                }
            }
            .navigationTitle("Pair your phones")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var chooser: some View {
        VStack(spacing: 28) {
            Spacer(minLength: 8)
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.red)

            VStack(spacing: 8) {
                Text("Two phones, one button")
                    .font(.title2.weight(.semibold))
                Text("One of you taps Show Code; the other taps Scan Code. After that, either of you can press the button.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 32)
            }

            NameField(displayName: $displayName)
                .padding(.horizontal, 24)

            VStack(spacing: 14) {
                Button {
                    Haptics.select()
                    DeviceIdentity.name = trimmedName
                    mode = .showCode
                } label: {
                    Label("Show Code", systemImage: "qrcode")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(trimmedName.isEmpty)

                Button {
                    Haptics.select()
                    DeviceIdentity.name = trimmedName
                    mode = .scanCode
                } label: {
                    Label("Scan Code", systemImage: "qrcode.viewfinder")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(trimmedName.isEmpty)
            }
            .padding(.horizontal, 28)

            Spacer()
        }
    }
}

// MARK: - Name field component

struct NameField: View {
    @Binding var displayName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Your name", systemImage: "person.crop.circle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField("How your partner sees you", text: $displayName)
                .font(.title3)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(.secondarySystemBackground))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color(.separator), lineWidth: 0.5)
                )
        }
    }
}

// MARK: - Show Code

private struct ShowCodeView: View {
    @Environment(AppState.self) private var appState
    let displayName: String
    var onCancel: () -> Void

    enum Phase: Equatable {
        case starting
        case waiting
        case failed(String)
    }

    @State private var invite: PairingInvite?
    @State private var pollingTask: Task<Void, Never>?
    @State private var qrImage: UIImage?
    @State private var phase: Phase = .starting

    var body: some View {
        VStack(spacing: 18) {
            switch phase {
            case .starting, .waiting:
                qrPanel
                statusFooter
            case .failed(let message):
                failurePanel(message: message)
            }

            Spacer()

            Button("Cancel", role: .cancel) {
                Haptics.select()
                pollingTask?.cancel()
                onCancel()
            }
            .padding(.bottom, 16)
        }
        .task {
            await start()
        }
        .onDisappear {
            pollingTask?.cancel()
        }
    }

    @ViewBuilder
    private var qrPanel: some View {
        if let qrImage {
            Image(uiImage: qrImage)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .padding(20)
                .background(.white, in: RoundedRectangle(cornerRadius: 24))
                .padding(.horizontal, 32)
                .shadow(color: .black.opacity(0.1), radius: 18, x: 0, y: 8)
                .accessibilityLabel("Pairing QR code")
        } else {
            VStack(spacing: 10) {
                ProgressView()
                Text("Reaching iCloud…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(height: 240)
        }
    }

    @ViewBuilder
    private var statusFooter: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                if phase == .waiting {
                    ProgressView().controlSize(.small)
                }
                Text(phase == .waiting ? "Waiting for the other phone…" : "Setting up…")
                    .font(.footnote.weight(.medium))
            }
            .foregroundStyle(.secondary)
            Text("Open the app on the other phone and tap Scan Code.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }

    private func failurePanel(message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.icloud")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.orange)
            Text("Couldn't start pairing")
                .font(.headline)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)

            Button {
                Task { await start() }
            } label: {
                Label("Try again", systemImage: "arrow.clockwise")
                    .font(.headline)
                    .frame(maxWidth: 220)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .padding(.top, 6)
        }
        .padding(.top, 30)
    }

    @MainActor
    private func start() async {
        pollingTask?.cancel()
        phase = .starting
        DeviceIdentity.name = displayName
        do {
            let result = try await PairingService.shared.startInviting(myName: displayName)
            self.invite = result.invite
            self.qrImage = QRCode.image(from: result.invite.qrPayload)
            self.phase = .waiting
            pollingTask = Task {
                do {
                    let state = try await PairingService.shared.waitForJoiner(record: result.record)
                    await MainActor.run {
                        Haptics.success()
                        appState.applyPair(state)
                    }
                } catch is CancellationError {
                    // expected on view dismissal
                } catch {
                    await MainActor.run {
                        Haptics.warning()
                        phase = .failed(error.localizedDescription)
                    }
                }
            }
        } catch {
            Haptics.warning()
            phase = .failed(error.localizedDescription)
        }
    }
}

// MARK: - Scan Code

private struct ScanCodeView: View {
    @Environment(AppState.self) private var appState
    let displayName: String
    var onCancel: () -> Void

    @State private var error: String?
    @State private var working = false
    @State private var rearmToken = 0

    var body: some View {
        VStack(spacing: 16) {
            QRScannerView(onCode: { code in
                Haptics.tick()
                Task { await complete(payload: code) }
            }, resetToken: rearmToken)
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .overlay(
                RoundedRectangle(cornerRadius: 24)
                    .strokeBorder(.white.opacity(0.6), lineWidth: 2)
            )
            .padding(.horizontal, 24)
            .frame(height: 320)

            if let error {
                VStack(spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.primary)
                    }
                    .multilineTextAlignment(.center)
                    Button {
                        self.error = nil
                        rearmToken &+= 1
                    } label: {
                        Label("Scan again", systemImage: "arrow.clockwise")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .controlSize(.small)
                }
                .padding(.horizontal, 24)
            } else {
                Text("Point the camera at the other phone's code.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Cancel", role: .cancel) {
                Haptics.select()
                onCancel()
            }
            .padding(.bottom, 16)
        }
        .overlay {
            if working {
                Color.black.opacity(0.35).ignoresSafeArea()
                ProgressView("Pairing…")
                    .padding(20)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    @MainActor
    private func complete(payload: String) async {
        guard !working else { return }
        working = true
        defer { working = false }
        DeviceIdentity.name = displayName
        do {
            let state = try await PairingService.shared.completePairing(payload: payload, myName: displayName)
            Haptics.success()
            appState.applyPair(state)
        } catch {
            Haptics.warning()
            self.error = error.localizedDescription
            // Don't re-arm immediately — let the user tap "Scan again" so the camera
            // doesn't keep firing the same bad payload over and over.
        }
    }
}
