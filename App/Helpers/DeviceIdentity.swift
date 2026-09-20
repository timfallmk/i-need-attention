import Foundation

/// Stable per-install identifier. Persisted in UserDefaults so it survives app restarts
/// but is regenerated on uninstall — which is the behavior we want for pairing.
///
/// Deliberately holds no name. It used to, under `attention.deviceName`, alongside the
/// one `UserSettings` keeps — see `UserSettings.resolvedName` for why there is now one.
enum DeviceIdentity {
    private static let idKey = "attention.deviceID"

    static var id: String {
        if let existing = UserDefaults.standard.string(forKey: idKey) {
            return existing
        }
        let new = UUID().uuidString
        UserDefaults.standard.set(new, forKey: idKey)
        return new
    }

    /// Forgets this install's identity, for `DataErasure`. The id is written into every
    /// record this device sends, so it is the one value that still ties an erased phone
    /// to alerts sitting in a partner's zone; the next read mints a fresh one.
    static func reset() {
        UserDefaults.standard.removeObject(forKey: idKey)
    }
}

/// The CloudKit user record name for the Apple Account this device is signed into, as
/// last seen. Per *account*, where `DeviceIdentity.id` is per install.
///
/// Cached here only so synchronous readers can use it — the history sheet decides which
/// rows are yours while building sections, with no place to await a network call. The
/// authority is `CloudKitService.currentUserID()`, which writes through to this.
///
/// Stale is harmless and self-correcting: it is refreshed on the next launch that reaches
/// CloudKit, and a wrong value can only make an archived row render on the wrong side of
/// the history sheet. Nothing routes an alert by it.
enum AccountIdentity {
    private static let key = "attention.accountUserID"

    static var id: String? {
        get { UserDefaults.standard.string(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
