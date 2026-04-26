import Foundation

/// Settings the receiver-side NSE needs to consult at delivery time. Lives in the App Group
/// suite so the main app (writer) and the NSE (reader) see the same values.
enum SharedSettings {
    private static let suite = UserDefaults(suiteName: Constants.AppGroup.identifier)
        ?? .standard

    private enum Keys {
        static let acceptCriticalAlerts = "shared.acceptCriticalAlerts"
        static let partnerName = "shared.partnerName"
    }

    /// Receiver-side master switch. If false, even alerts marked critical by the sender
    /// are downgraded to .timeSensitive in the NSE.
    static var acceptCriticalAlerts: Bool {
        get { suite.bool(forKey: Keys.acceptCriticalAlerts) }
        set { suite.set(newValue, forKey: Keys.acceptCriticalAlerts) }
    }

    /// Cached partner display name so the NSE can label the toggle/notification without
    /// reaching into CloudKit.
    static var partnerName: String? {
        get { suite.string(forKey: Keys.partnerName) }
        set { suite.set(newValue, forKey: Keys.partnerName) }
    }
}
