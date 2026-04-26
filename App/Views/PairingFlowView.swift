import CloudKit
import SwiftUI

struct PairingFlowView: View {
    @Environment(AppState.self) private var appState
    @State private var mode: Mode = .chooser

    enum Mode: Equatable {
        case chooser
        case showCode
        case scanCode
    }

    var body: some View {
        NavigationStack {
            Group {
                switch mode {
                case .chooser: chooser
                case .showCode: ShowCodeView { mode = .chooser }
                case .scanCode: ScanCodeView { mode = .chooser }
                }
            }
            .navigationTitle("Pair your phones")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var chooser: some View {
        VStack(spacing: 32) {
            Spacer(minLength: 20)
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(.red)

            VStack(spacing: 8) {
                Text("Two phones, one button")
                    .font(.title2.weight(.semibold))
                Text("One of you taps Show Code; the other taps Scan Code. After that, either of you can press the button.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 32)
            }

            VStack(spacing: 14) {
                Button {
                    mode = .showCode
                } label: {
                    Label("Show Code", systemImage: "qrcode")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)

                Button {
                    mode = .scanCode
                } label: {
                    Label("Scan Code", systemImage: "qrcode.viewfinder")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }
            .padding(.horizontal, 28)

            Spacer()
        }
    }
}

// MARK: - Show Code

private struct ShowCodeView: View {
    @Environment(AppState.self) private var appState
    var onCancel: () -> Void

    enum Phase: Equatable {
        case starting
        case waiting
        case failed(String)
    }

    @State private var displayName: String = DeviceIdentity.name
    @State private var invite: PairingInvite?
    @State private var pollingTask: Task<Void, Never>?
    @State private var qrImage: UIImage?
    @State private var phase: Phase = .starting

    var body: some View {
        VStack(spacing: 18) {
            TextField("Your name", text: $displayName)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 24)

            switch phase {
            case .starting, .waiting:
                qrPanel
                statusFooter
            case .failed(let message):
                failurePanel(message: message)
            }

            Spacer()

            Button("Cancel", role: .cancel) {
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
                        appState.applyPair(state)
                    }
                } catch is CancellationError {
                    // expected on view dismissal
                } catch {
                    await MainActor.run {
                        phase = .failed(error.localizedDescription)
                    }
                }
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

// MARK: - Scan Code

private struct ScanCodeView: View {
    @Environment(AppState.self) private var appState
    var onCancel: () -> Void

    @State private var displayName: String = DeviceIdentity.name
    @State private var error: String?
    @State private var working = false
    @State private var rearmToken = 0

    var body: some View {
        VStack(spacing: 16) {
            TextField("Your name", text: $displayName)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 24)

            QRScannerView(onCode: { code in
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
            appState.applyPair(state)
        } catch {
            self.error = error.localizedDescription
            // Don't re-arm immediately — let the user tap "Scan again" so the camera
            // doesn't keep firing the same bad payload over and over.
        }
    }
}
