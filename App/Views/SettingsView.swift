import CloudKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingUnpair = false
    @State private var exportedReport: ExportedReport?
    @State private var isGeneratingReport = false
    @State private var nameSyncTask: Task<Void, Never>?
    #if DEBUG
    @State private var recoveryPairKey = ""
    @State private var isRecovering = false
    @State private var recoveryResult: String?
    #endif

    var body: some View {
        @Bindable var settings = appState.settings

        NavigationStack {
            Form {
                Section {
                    TextField("Your name", text: $settings.displayName)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onChange(of: settings.displayName) {
                            scheduleNameSync()
                        }
                    if let pair = appState.pair {
                        LabeledContent("Paired with", value: pair.partnerName)
                    }
                } header: {
                    Text("You")
                } footer: {
                    if appState.pair != nil {
                        Text("Your partner sees this name on every alert and in their settings. Changes sync automatically.")
                    } else {
                        Text("Your partner will see this name on every alert.")
                    }
                }

                Section("Alert behavior") {
                    Toggle("Custom sound", isOn: $settings.customSoundEnabled)

                    Toggle("Time-sensitive alerts", isOn: $settings.timeSensitiveEnabled)
                    Text("Pierce Focus and Do Not Disturb for both incoming requests and acknowledgements. Off keeps them quiet under Focus.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Toggle("Acknowledgement banners", isOn: $settings.ackBannersEnabled)
                    Text("Notify you with a banner when your partner gets back to you. The in-app indicator updates either way.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    // Critical Alerts UI commented out (Apple denied entitlement).
                    // The acceptCriticalAlerts setting + App Group mirror are kept so
                    // re-enabling is just restoring this toggle row.
                    // Toggle(criticalToggleLabel, isOn: $settings.acceptCriticalAlerts)
                    // Text("When you allow this, alerts your partner sends with **Send as Critical** (long-press the button) will pierce silent mode and Focus. Requires Apple to grant the Critical Alerts entitlement; until then, criticals fall back to Time-Sensitive.")
                    //     .font(.footnote)
                    //     .foregroundStyle(.secondary)

                    Stepper(
                        "Cooldown: \(settings.cooldownSeconds)s",
                        value: $settings.cooldownSeconds,
                        in: 0...300,
                        step: 5
                    )
                }

                Section {
                    LabeledContent("iCloud", value: iCloudStatusLabel)
                    LabeledContent("Notifications", value: appState.notificationsAuthorized ? "Allowed" : "Off")
                    if appState.pair != nil && appState.outgoingAckSubscriptionUnavailable {
                        LabeledContent("Acknowledgement push") {
                            Text("Unavailable")
                                .foregroundStyle(.orange)
                        }
                        Text("CloudKit didn't accept the subscription that delivers your partner's acknowledgement to your lock screen. The in-app indicator still updates. Check the captured error below to decide what's actually wrong: a `BAD_REQUEST` / `SubscriptionCreate` rejection points at a missing `_sub_trigger_outgoing-ack-v2` index in Production — fix it by running a **Debug** build of this app on a device once, then clicking **Deploy Schema Changes…** in CloudKit Dashboard. A network or iCloud-account error usually clears on its own; relaunching retries the registration. As a fallback, re-import `cloudkit-schema.ckdb` so the **Ack** record type and its `pairKey` / `recipientDeviceID` queryable indexes exist in Production.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if let reason = appState.outgoingAckSubscriptionFailureReason {
                            Text("CloudKit said: \(reason)")
                                .font(.footnote.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                } header: {
                    Text("Diagnostics")
                }

                #if DEBUG
                Section {
                    TextField("Pre-2.0 pair key", text: $recoveryPairKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))

                    Button {
                        Task { await recoverLegacyHistory() }
                    } label: {
                        HStack {
                            Label("Recover pre-2.0 history", systemImage: "clock.arrow.circlepath")
                            if isRecovering {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isRecovering || recoveryPairKey.trimmingCharacters(in: .whitespaces).isEmpty)

                    if let recoveryResult {
                        Text(recoveryResult)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Debug")
                } footer: {
                    Text("Rebuilds the archive of pre-2.0 alerts from a pair key, for a device "
                         + "whose one-shot capture ran against the wrong CloudKit environment. "
                         + "The key is on the Pair record in CloudKit Dashboard. This build has "
                         + "to point at the environment holding those records. Reads only — it "
                         + "deletes nothing.")
                }
                #endif

                Section("About") {
                    NavigationLink {
                        AcknowledgementsView()
                    } label: {
                        Label("Open Source", systemImage: "doc.text")
                    }
                }

                Section {
                    Button {
                        Task { await generateReport() }
                    } label: {
                        HStack {
                            Label("Export diagnostics", systemImage: "stethoscope")
                            if isGeneratingReport {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isGeneratingReport)
                } footer: {
                    Text("A short technical summary you can send if something isn't working. "
                         + "It contains no names, messages or emoji — you'll see exactly what "
                         + "it says before deciding whether to share it.")
                }

                if appState.pair != nil {
                    Section {
                        Button(role: .destructive) {
                            Haptics.warning()
                            confirmingUnpair = true
                        } label: {
                            Label("Unpair this phone", systemImage: "link.slash")
                        }
                    } footer: {
                        Text("You'll need to scan a fresh code to pair again.")
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $exportedReport) { report in
                DiagnosticsExportView(text: report.text)
            }
            .alert("Unpair?", isPresented: $confirmingUnpair) {
                Button("Cancel", role: .cancel) {}
                Button("Unpair", role: .destructive) {
                    Haptics.error()
                    Task { await appState.unpair() }
                    dismiss()
                }
            } message: {
                Text("Both phones need to unpair separately for the pairing to be fully reset.")
            }
        }
    }

    /// Debounce CloudKit writes so we don't fire one per keystroke. The didSet on
    /// settings.displayName already persists locally; this just pushes the final value
    /// to the Pair record after the user pauses typing.
    private func scheduleNameSync() {
        nameSyncTask?.cancel()
        nameSyncTask = Task { [appState] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            await appState.syncMyDisplayName()
        }
    }

    // Critical Alerts label commented out (Apple denied entitlement).
    // private var criticalToggleLabel: String {
    //     if let name = appState.pair?.partnerName, !name.isEmpty {
    //         return "Accept Critical Alerts from \(name)"
    //     }
    //     return "Accept Critical Alerts"
    // }

    /// Explicitly MainActor: it mutates `@State`, and with `SWIFT_STRICT_CONCURRENCY:
    /// minimal` the compiler will not point out that a `Task {}` in a button action is not
    /// guaranteed to inherit the isolation. It does not block the main thread — the
    /// CloudKit fetch inside the gatherer awaits a non-isolated service, so the network
    /// work still happens off it.
    #if DEBUG
    @MainActor
    private func recoverLegacyHistory() async {
        guard !isRecovering else { return }
        isRecovering = true
        recoveryResult = nil
        recoveryResult = await LegacyHistoryRecovery.recover(pairKey: recoveryPairKey).message
        isRecovering = false
    }
    #endif

    @MainActor
    private func generateReport() async {
        // `.disabled` only takes effect once the flag flips below, so a second tap can land
        // in the hop between the button action and this body running. Being on the main
        // actor makes this check-and-set atomic: there is no suspension between them.
        guard !isGeneratingReport else { return }
        isGeneratingReport = true
        defer { isGeneratingReport = false }
        let report = await DiagnosticsGatherer.gather(from: appState)
        exportedReport = ExportedReport(text: report.render())
    }

    private var iCloudStatusLabel: String {
        switch appState.iCloudStatus {
        case .available: return "Signed in"
        case .noAccount: return "Not signed in"
        case .restricted: return "Restricted"
        case .couldNotDetermine: return "Unknown"
        case .temporarilyUnavailable: return "Temporarily unavailable"
        @unknown default: return "Unknown"
        }
    }
}

/// Wrapper so the rendered text can drive `.sheet(item:)`.
private struct ExportedReport: Identifiable {
    let id = UUID()
    let text: String
}

/// Shows the report before it can be shared.
///
/// The preview is the point, not a courtesy: this is a privacy-minded app asking someone to
/// send a file about their own device, so they get to read every line first rather than
/// trusting a description of it.
private struct DiagnosticsExportView: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle("Diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: text) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
    }
}
