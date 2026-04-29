import CloudKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingUnpair = false
    @State private var nameSyncTask: Task<Void, Never>?

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

                    Toggle("Acknowledgement banners", isOn: $settings.ackBannersEnabled)
                    Text("Notify you with a banner when your partner gets back to you. The in-app indicator updates either way.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Toggle(criticalToggleLabel, isOn: $settings.acceptCriticalAlerts)
                    Text("When you allow this, alerts your partner sends with **Send as Critical** (long-press the button) will pierce silent mode and Focus. Requires Apple to grant the Critical Alerts entitlement; until then, criticals fall back to Time-Sensitive.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Stepper(
                        "Cooldown: \(settings.cooldownSeconds)s",
                        value: $settings.cooldownSeconds,
                        in: 0...300,
                        step: 5
                    )
                }

                Section("Diagnostics") {
                    LabeledContent("iCloud", value: iCloudStatusLabel)
                    LabeledContent("Notifications", value: appState.notificationsAuthorized ? "Allowed" : "Off")
                }

                if appState.pair != nil {
                    Section {
                        Button(role: .destructive) {
                            Haptics.warning()
                            confirmingUnpair = true
                        } label: {
                            Label("Unpair this phone", systemImage: "link.badge.minus")
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

    private var criticalToggleLabel: String {
        if let name = appState.pair?.partnerName, !name.isEmpty {
            return "Accept Critical Alerts from \(name)"
        }
        return "Accept Critical Alerts"
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
