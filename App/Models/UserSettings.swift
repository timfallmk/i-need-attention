import Foundation
import SwiftUI

@Observable
final class UserSettings {
    var displayName: String {
        didSet { UserDefaults.standard.set(displayName, forKey: Keys.name) }
    }
    var requestCriticalAlerts: Bool {
        didSet { UserDefaults.standard.set(requestCriticalAlerts, forKey: Keys.critical) }
    }
    var customSoundEnabled: Bool {
        didSet { UserDefaults.standard.set(customSoundEnabled, forKey: Keys.customSound) }
    }
    var cooldownSeconds: Int {
        didSet { UserDefaults.standard.set(cooldownSeconds, forKey: Keys.cooldown) }
    }

    init() {
        let d = UserDefaults.standard
        self.displayName = d.string(forKey: Keys.name) ?? DeviceIdentity.name
        self.requestCriticalAlerts = d.bool(forKey: Keys.critical)
        self.customSoundEnabled = d.object(forKey: Keys.customSound) as? Bool ?? true
        self.cooldownSeconds = d.object(forKey: Keys.cooldown) as? Int ?? 30
    }

    private enum Keys {
        static let name = "attention.settings.name"
        static let critical = "attention.settings.critical"
        static let customSound = "attention.settings.customSound"
        static let cooldown = "attention.settings.cooldown"
    }
}
