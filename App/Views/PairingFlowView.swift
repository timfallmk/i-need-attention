import CloudKit
import SwiftUI
import UIKit

struct PairingFlowView: View {
    @Environment(AppState.self) private var appState
    @State private var mode: Mode = .chooser
    @State private var displayName: String = DeviceIdentity.name
    @State private var showSettings = false

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
            // Settings used to be reachable only from the main screen, which needs a
            // pair — so an unpaired device had no way in at all. That is backwards for
            // the two things an unpaired user most plausibly wants: their display name,
            // and Export diagnostics, which matters most when pairing is what's failing.
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
                    .environment(appState)
            }
        }
    }

    /// An upgrading user opens 2.0 and finds themselves unpaired. Without this they'd
    /// reasonably conclude the app had lost their pairing, or broken — and the one thing
    /// they can't discover on their own is that their partner has to update too.
    private var cutoverNotice: some View {
        PairingNotice(
            title: "Pairing has changed",
            systemImage: "lock.rotation",
            explanation: "This version keeps your alerts in private iCloud storage that only the two of you can reach, and that means pairing again — once. Your history is still here.",
            reassurance: "You'll both need this version installed before it will work."
        )
    }

    /// Unpairing deletes the zone the partner writes into, so their device discovers it
    /// as a vanished zone rather than being told. Without this the app simply returns to
    /// the pairing screen with no explanation, which reads as having lost the pairing by
    /// itself — the one thing a two-person app cannot afford to look like.
    private var partnerUnpairedNotice: some View {
        PairingNotice(
            title: "Your partner unpaired",
            systemImage: "person.badge.minus",
            explanation: "They ended the pairing from their phone, so this one is unpaired too. Nothing went wrong here.",
            reassurance: "Your history is still on this phone, under Settings."
        )
    }

    /// The same question again — "why am I on this screen?" — with a third answer, and
    /// the only one where nobody else was involved. Unpairing now ends the pairing for
    /// the person rather than for the device, so a phone that did nothing at all can
    /// arrive here because an iPad did.
    private var unpairedElsewhereNotice: some View {
        PairingNotice(
            title: "Unpaired on your other device",
            systemImage: "ipad.and.iphone",
            explanation: "This pairing was ended from another device signed in to your Apple Account, so it's ended here too. Nothing went wrong here.",
            reassurance: "Your history is still on this phone, under Settings."
        )
    }

    private var chooser: some View {
        VStack(spacing: 28) {
            Spacer(minLength: 8)

            // At most one. All three answer "why am I unpaired?", most specific first:
            // this account's own action beats the partner's, which beats the upgrade —
            // each is the more recent explanation if somehow more than one applies.
            if appState.pairingEndedOnAnotherDevice {
                unpairedElsewhereNotice
            } else if appState.partnerEndedPairing {
                partnerUnpairedNotice
            } else if appState.needsRepairAfterCutover {
                cutoverNotice
            }

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

            if let pending = appState.pendingInvite {
                PendingInviteCard(
                    pending: pending,
                    onShow: { mode = .showCode },
                    onCancel: { Task { await appState.cancelPendingInvite() } }
                )
                .padding(.horizontal, 24)
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

                PasteInviteButton(beforePaste: { DeviceIdentity.name = trimmedName })
                    .padding(.top, 2)

                // Pairing needs two phones and a person willing to install something, so
                // this screen is where someone evaluating the app alone stops. It is also
                // the wall an App Review tester hits, but it is not a review carve-out:
                // a demo only Apple can find would be a hidden feature, and a visible one
                // is the better answer to both problems.
                Button {
                    Haptics.select()
                    appState.startDemo()
                } label: {
                    Label("Try it without a partner", systemImage: "play.circle")
                        .font(.footnote.weight(.medium))
                }
                .tint(.secondary)
            }
            .padding(.horizontal, 28)

            Spacer()
        }
    }
}

// MARK: - Paste an invite link

/// Fallback intake for shared invite links: some transports don't make custom-scheme URLs
/// tappable, so the joiner can copy the link and land in the same confirmation sheet a
/// tapped link produces. Also the only way through when the camera can't be used, which
/// is why it is a view rather than a method on the chooser.
private struct PasteInviteButton: View {
    @Environment(AppState.self) private var appState
    /// Runs before the pasteboard is read. The chooser uses it to commit the typed name.
    var beforePaste: () -> Void = {}

    @State private var failed = false

    var body: some View {
        VStack(spacing: 8) {
            Button {
                Haptics.select()
                beforePaste()
                failed = !acceptPastedInvite()
                if failed { Haptics.error() }
            } label: {
                Text("Got an invite link? Paste it")
                    .font(.footnote.weight(.medium))
            }
            .tint(.secondary)

            if failed {
                Text("That didn't look like an invite link. Copy the whole link your partner shared, then tap Paste again.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: failed)
    }

    /// Share sheets write a shared `URL` to the pasteboard as a `public.url` item, and
    /// `UIPasteboard.string` does not coerce one of those for a custom scheme — so
    /// reading only `string`, as this used to, missed the ordinary path from
    /// `ShareLink` → Copy and looked exactly like a no-op.
    private func acceptPastedInvite() -> Bool {
        let board = UIPasteboard.general
        if let url = board.url, appState.handleIncomingURL(url) { return true }
        if let text = board.string?.trimmingCharacters(in: .whitespacesAndNewlines),
           let url = URL(string: text) {
            return appState.handleIncomingURL(url)
        }
        return false
    }
}

// MARK: - Pending invite card

private struct PendingInviteCard: View {
    let pending: PendingInvite
    var onShow: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: pending.isExpired ? "clock.badge.exclamationmark" : "paperplane.circle.fill")
                    .foregroundStyle(pending.isExpired ? Color.orange : Color.red)
                VStack(alignment: .leading, spacing: 1) {
                    Text(pending.isExpired ? "Invite is getting stale" : "Waiting for your partner to accept")
                        .font(.subheadline.weight(.semibold))
                    Text("Started \(relativeTime(from: pending.createdAt))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 10) {
                Button {
                    Haptics.select()
                    onShow()
                } label: {
                    Text(pending.isExpired ? "Start a fresh one" : "Show or share again")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)

                Button(role: .destructive) {
                    Haptics.select()
                    onCancel()
                } label: {
                    Text("Cancel invite")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder((pending.isExpired ? Color.orange : Color.red).opacity(0.25), lineWidth: 1)
        )
    }

    private func relativeTime(from date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
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
                if phase == .waiting, let invite, let url = URL(string: invite.qrPayload) {
                    ShareLink(item: url) {
                        Label("Or share the link", systemImage: "square.and.arrow.up")
                            .font(.subheadline.weight(.medium))
                    }
                    .tint(.red)
                    .padding(.top, 2)
                }
                #if DEBUG
                if let invite {
                    VStack(spacing: 6) {
                        Text(invite.qrPayload)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 16)
                            .textSelection(.enabled)
                        Button("Copy payload") {
                            UIPasteboard.general.string = invite.qrPayload
                        }
                        .font(.caption)
                        .tint(.secondary)
                    }
                    .padding(.top, 4)
                }
                #endif
            case .failed(let message):
                failurePanel(message: message)
            }

            Spacer()

            VStack(spacing: 10) {
                Text("You can close this screen after sharing — pairing completes when they accept.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                HStack(spacing: 18) {
                    Button("Close") {
                        Haptics.select()
                        pollingTask?.cancel()
                        onCancel()
                    }
                    Button("Cancel invite", role: .destructive) {
                        Haptics.select()
                        pollingTask?.cancel()
                        Task { await appState.cancelPendingInvite() }
                        onCancel()
                    }
                }
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

        // Resume a live pending invite instead of minting a new pairKey — the shared
        // link and the on-screen QR must stay interchangeable. Expired invites fall
        // through to a fresh start (startInviting cancels the old one server-side).
        if let pending = PendingInvite.load(), !pending.isExpired {
            self.invite = pending.invite
            self.qrImage = QRCode.image(from: pending.invite.qrPayload)
            self.phase = .waiting
            startPolling()
            return
        }

        do {
            let invite = try await PairingService.shared.startInviting(myName: displayName)
            appState.refreshPendingInvite()
            self.invite = invite
            self.qrImage = QRCode.image(from: invite.qrPayload)
            self.phase = .waiting
            startPolling()
        } catch {
            Haptics.warning()
            phase = .failed(error.localizedDescription)
        }
    }

    @MainActor
    private func startPolling() {
        pollingTask = Task {
            do {
                // Effectively screen-lifetime: the task is cancelled on dismissal, and a
                // remote invite that outlives this screen completes via push/reconcile —
                // so a short timeout would surface a spurious failure.
                let state = try await PairingService.shared.waitForJoiner(timeout: 3600)
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
    }
}

// MARK: - Scan Code

private struct ScanCodeView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.scenePhase) private var scenePhase
    let displayName: String
    var onCancel: () -> Void

    @State private var error: String?
    @State private var working = false
    @State private var rearmToken = 0
    /// Nil until `CameraAccess.resolve()` answers. The scanner is not mounted before
    /// then: mounting it is what would put a black rectangle on screen while iOS decides
    /// whether to show its own permission prompt.
    @State private var access: CameraAccess.Status?

    var body: some View {
        VStack(spacing: 16) {
            switch access {
            case nil:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .authorized?:
                scanner
            case .denied?:
                CameraBlockedView(
                    title: "Attention can't use the camera",
                    message: "Scanning your partner's code needs the camera. You can turn "
                        + "it on in Settings, or have them send you an invite link instead.",
                    showsSettingsButton: true
                )
            case .unavailable?:
                // Deliberately covers two causes: no camera at all, and a camera the
                // app couldn't open because something else holds it. The second is
                // temporary, so the copy must not assert the device has no camera.
                CameraBlockedView(
                    title: "Camera unavailable",
                    message: "Another app may be using the camera, or this device doesn't "
                        + "have one. An invite link pairs you the same way.",
                    showsSettingsButton: false
                )
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
        .task { access = await CameraAccess.resolve() }
        // Granting permission happens in Settings, which backgrounds this app. Without
        // this the user comes back to the same blocked screen they left and has no
        // reason to think it worked.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, access == .denied else { return }
            Task { access = await CameraAccess.resolve() }
        }
    }

    private var scanner: some View {
        VStack(spacing: 16) {
            QRScannerView(
                onCode: { code in
                    Haptics.tick()
                    Task { await complete(payload: code) }
                },
                onUnavailable: { access = .unavailable },
                resetToken: rearmToken
            )
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

// MARK: - Camera unavailable

/// What the scan screen shows instead of a black rectangle.
///
/// Every state here still offers the paste fallback, because pairing is this app's only
/// onboarding path — a dead end at the camera is a dead end at the whole app. Open
/// Settings appears only when there is something there to change: for a device with no
/// camera it would send the user to look for a switch that does not exist.
private struct CameraBlockedView: View {
    let title: String
    let message: String
    let showsSettingsButton: Bool

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "video.slash")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                Text(title)
                    .font(.headline)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if showsSettingsButton, let settings = URL(string: UIApplication.openSettingsURLString) {
                Link(destination: settings) {
                    Label("Open Settings", systemImage: "gear")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }

            PasteInviteButton()
        }
        .padding(.horizontal, 32)
        .padding(.top, 32)
    }
}

/// The chrome every "why are you seeing the pairing screen?" card shares.
///
/// Three of them now, identical but for four strings. Three hand-maintained copies of
/// the same rounded block is the kind of thing that drifts silently, and these appear
/// one at a time so nobody would ever see two together to notice.
private struct PairingNotice: View {
    let title: String
    let systemImage: String
    let explanation: String
    let reassurance: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
            Text(explanation)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(reassurance)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.orange.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.25), lineWidth: 1)
        )
        .padding(.horizontal, 20)
    }
}
