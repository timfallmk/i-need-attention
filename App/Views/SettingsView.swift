import CloudKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingUnpair = false

    var body: some View {
        @Bindable var settings = appState.settings

        NavigationStack {
            Form {
                Section("You") {
                    TextField("Display name", text: $settings.displayName)
                    if let pair = appState.pair {
                        LabeledContent("Paired with", value: pair.partnerName)
                    }
                }

                Section("Alert behavior") {
                    Toggle("Custom sound", isOn: $settings.customSoundEnabled)

                    Toggle("Critical Alerts", isOn: $settings.requestCriticalAlerts)
                    Text("Critical Alerts pierce silent mode and Focus. Requires an entitlement granted by Apple — until then this toggle has no effect and notifications fall back to Time-Sensitive.")
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
                    Task { await appState.unpair() }
                    dismiss()
                }
            } message: {
                Text("Both phones need to unpair separately for the pairing to be fully reset.")
            }
        }
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
