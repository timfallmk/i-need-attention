import Foundation

/// Stable per-install identifier. Persisted in UserDefaults so it survives app restarts
/// but is regenerated on uninstall — which is the behavior we want for pairing.
enum DeviceIdentity {
    private static let idKey = "attention.deviceID"
    private static let nameKey = "attention.deviceName"

    static var id: String {
        if let existing = UserDefaults.standard.string(forKey: idKey) {
            return existing
        }
        let new = UUID().uuidString
        UserDefaults.standard.set(new, forKey: idKey)
        return new
    }

    /// User-chosen name. Defaults to empty so the UI can prompt for a real one rather
    /// than falling back to `UIDevice.current.name`, which on iOS 16+ returns a
    /// generic "iPhone" unless you have the `com.apple.developer.device-information.user-assigned-device-name`
    /// entitlement — which Apple grants only in narrow cases.
    static var name: String {
        get { UserDefaults.standard.string(forKey: nameKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: nameKey) }
    }
}
