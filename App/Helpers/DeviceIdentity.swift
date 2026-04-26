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

    static var name: String {
        get { UserDefaults.standard.string(forKey: nameKey) ?? defaultName }
        set { UserDefaults.standard.set(newValue, forKey: nameKey) }
    }

    private static var defaultName: String {
        #if os(iOS)
        return UIDevice.current.name
        #else
        return "Watch"
        #endif
    }
}

#if os(iOS)
import UIKit
#endif
