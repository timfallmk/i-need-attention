import Foundation
import SwiftUI

@Observable
final class UserSettings {
    var displayName: String {
        didSet { UserDefaults.standard.set(displayName, forKey: Keys.name) }
    }

    /// Receiver-side: if false, incoming alerts the sender marked critical are
    /// presented as .timeSensitive instead of .critical. Mirrored to the App Group
    /// so the NSE can read it at delivery time.
    var acceptCriticalAlerts: Bool {
        didSet {
            UserDefaults.standard.set(acceptCriticalAlerts, forKey: Keys.acceptCritical)
            SharedSettings.acceptCriticalAlerts = acceptCriticalAlerts
        }
    }

    var customSoundEnabled: Bool {
        didSet {
            UserDefaults.standard.set(customSoundEnabled, forKey: Keys.customSound)
            SharedSettings.customSoundEnabled = customSoundEnabled
        }
    }

    var cooldownSeconds: Int {
        didSet { UserDefaults.standard.set(cooldownSeconds, forKey: Keys.cooldown) }
    }

    init() {
        let d = UserDefaults.standard
        self.displayName = d.string(forKey: Keys.name) ?? DeviceIdentity.name
        self.acceptCriticalAlerts = d.bool(forKey: Keys.acceptCritical)
        self.customSoundEnabled = d.object(forKey: Keys.customSound) as? Bool ?? true
        self.cooldownSeconds = d.object(forKey: Keys.cooldown) as? Int ?? 30
        // Sync to App Group on init in case the NSE runs before the toggle is touched.
        SharedSettings.acceptCriticalAlerts = self.acceptCriticalAlerts
        SharedSettings.customSoundEnabled = self.customSoundEnabled
    }

    private enum Keys {
        static let name = "attention.settings.name"
        static let acceptCritical = "attention.settings.acceptCritical"
        static let customSound = "attention.settings.customSound"
        static let cooldown = "attention.settings.cooldown"
    }
}
