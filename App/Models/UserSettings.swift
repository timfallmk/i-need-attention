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

    /// Sender-side: when off, the NSE delivers ack pushes passively — no banner,
    /// no sound — so the in-app indicator still flips to ❤️ but the device stays
    /// quiet. Defaults to true; the closing-loop banner is the point of the feature.
    var ackBannersEnabled: Bool {
        didSet {
            UserDefaults.standard.set(ackBannersEnabled, forKey: Keys.ackBanners)
            SharedSettings.ackBannersEnabled = ackBannersEnabled
        }
    }

    /// Master switch for whether the NSE delivers pushes at `.timeSensitive`
    /// (pierces Focus) vs `.active` (held by Focus). Applies to both incoming
    /// requests and ack banners. Default true.
    var timeSensitiveEnabled: Bool {
        didSet {
            UserDefaults.standard.set(timeSensitiveEnabled, forKey: Keys.timeSensitive)
            SharedSettings.timeSensitiveEnabled = timeSensitiveEnabled
        }
    }

    var cooldownSeconds: Int {
        didSet { UserDefaults.standard.set(cooldownSeconds, forKey: Keys.cooldown) }
    }

    init() {
        let d = UserDefaults.standard
        self.displayName = UserSettings.resolvedName(d)
        self.acceptCriticalAlerts = d.object(forKey: Keys.acceptCritical) as? Bool ?? Defaults.acceptCritical
        self.customSoundEnabled = d.object(forKey: Keys.customSound) as? Bool ?? Defaults.customSound
        self.ackBannersEnabled = d.object(forKey: Keys.ackBanners) as? Bool ?? Defaults.ackBanners
        self.timeSensitiveEnabled = d.object(forKey: Keys.timeSensitive) as? Bool ?? Defaults.timeSensitive
        self.cooldownSeconds = d.object(forKey: Keys.cooldown) as? Int ?? Defaults.cooldown
        // Sync to App Group on init in case the NSE runs before the toggle is touched.
        SharedSettings.acceptCriticalAlerts = self.acceptCriticalAlerts
        SharedSettings.customSoundEnabled = self.customSoundEnabled
        SharedSettings.ackBannersEnabled = self.ackBannersEnabled
        SharedSettings.timeSensitiveEnabled = self.timeSensitiveEnabled
    }

    /// One name, one key.
    ///
    /// The name had two homes: this key, which is what every outgoing record and every
    /// rename in Settings uses, and `attention.deviceName`, which only the pairing screen
    /// and the join sheet wrote. Nothing reconciled them, so they drifted in both
    /// directions — renaming yourself in Settings left the pairing screen offering the old
    /// name (#83), and pairing left the name on the wire stale until the next launch.
    ///
    /// This key wins whenever it has been written at all, including when it holds an empty
    /// string: that is someone who cleared their name on purpose, and resurrecting the old
    /// one would be the same class of bug pointing the other way. The legacy key is read
    /// once, on the first launch after this change, and retired either way.
    private static func resolvedName(_ d: UserDefaults) -> String {
        let legacy = d.string(forKey: Keys.legacyDeviceName)
        d.removeObject(forKey: Keys.legacyDeviceName)
        if let current = d.string(forKey: Keys.name) { return current }
        guard let legacy else { return "" }
        d.set(legacy, forKey: Keys.name)
        return legacy
    }

    /// Back to a first-launch state, for `DataErasure`. Assignment rather than removing
    /// the keys so the `didSet` mirrors run: the NSE reads its copy from the App Group
    /// and would otherwise keep serving the erased values until a toggle was touched.
    /// `displayName` is the only one of these that is the user's own data; the rest are
    /// preferences, and reverting them is what makes this an erase rather than a partial
    /// one.
    func resetToDefaults() {
        displayName = ""
        acceptCriticalAlerts = Defaults.acceptCritical
        customSoundEnabled = Defaults.customSound
        ackBannersEnabled = Defaults.ackBanners
        timeSensitiveEnabled = Defaults.timeSensitive
        cooldownSeconds = Defaults.cooldown
    }

    private enum Defaults {
        static let acceptCritical = false
        static let customSound = true
        static let ackBanners = true
        static let timeSensitive = true
        static let cooldown = 30
    }

    private enum Keys {
        static let name = "attention.settings.name"
        /// Retired by `resolvedName`. Nothing writes it.
        static let legacyDeviceName = "attention.deviceName"
        static let acceptCritical = "attention.settings.acceptCritical"
        static let customSound = "attention.settings.customSound"
        static let ackBanners = "attention.settings.ackBanners"
        static let timeSensitive = "attention.settings.timeSensitive"
        static let cooldown = "attention.settings.cooldown"
    }
}
