import Foundation
import Security

/// Storage for the pair key, the one genuinely secret value this app holds — every
/// record a pair owns is reachable with it, and the plaintext copy that used to sit
/// in the app container's `UserDefaults` plist travels in an unencrypted device
/// backup. Abstracted so the tests (and `AttentionCLI`, which has no keychain
/// entitlement) can substitute an in-memory implementation.
protocol PairSecretStore {
    func secret(for account: String) -> String?
    @discardableResult func setSecret(_ secret: String, for account: String) -> Bool
    func removeSecret(for account: String)
}

/// Keychain-backed store, shared with the notification service extension.
///
/// The access group is the App Group identifier rather than a dedicated
/// `keychain-access-groups` entry: iOS counts the values of
/// `com.apple.security.application-groups` as keychain access groups, so the NSE
/// reaches the same item using an entitlement both targets already carry and no new
/// capability has to be registered in the developer portal.
///
/// The item is **synchronizable** and `AfterFirstUnlock`. Not `ThisDeviceOnly`: from
/// 2.0 the pair key is the HKDF input that decrypts every payload, so a device that
/// arrives without it cannot read history that is still sitting in CloudKit, and
/// recovery is not solo — re-pairing needs the partner and a fresh scan. Meanwhile
/// `DeviceIdentity.id` and the rest of `PairState` are in `UserDefaults`, which does
/// restore, so a device-only key would restore everything except the one value that
/// makes it usable. The exposure being closed is the plaintext copy in the app
/// container, which any keychain storage closes; device-only would only have added
/// protection against someone holding an encrypted backup *and* its password.
///
/// `AfterFirstUnlock` rather than `WhenUnlocked` because the NSE decrypts pushes that
/// arrive while the screen is locked.
struct KeychainPairSecretStore: PairSecretStore {
    let service: String
    let accessGroup: String?

    init(service: String = Constants.Keychain.service,
         accessGroup: String? = Constants.AppGroup.identifier) {
        self.service = service
        self.accessGroup = accessGroup
    }

    /// `synchronizable` has to appear in every query, not just the insert: omitting it
    /// means "non-synchronizable only", which would silently fail to find, update or
    /// delete the item we store. Reads and deletes pass `Any` so a non-synchronizable
    /// twin left by an older build is still found and still cleared; the update path
    /// passes `true` so it can't quietly write back into the twin and keep it
    /// unsynced — that case falls through to the insert, which replaces it.
    private func query(for account: String, synchronizable: Any) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: synchronizable,
            kSecUseDataProtectionKeychain as String: true
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    func secret(for account: String) -> String? {
        var lookup = query(for: account, synchronizable: kSecAttrSynchronizableAny)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    func setSecret(_ secret: String, for account: String) -> Bool {
        let data = Data(secret.utf8)
        let existing = query(for: account, synchronizable: true)
        let update = [kSecValueData as String: data]

        switch SecItemUpdate(existing as CFDictionary, update as CFDictionary) {
        case errSecSuccess:
            return true
        case errSecItemNotFound:
            // A device that ran a build storing this key as non-synchronizable has a
            // twin the update above can't see. Clear it, or the add can collide with it.
            SecItemDelete(query(for: account, synchronizable: kSecAttrSynchronizableAny) as CFDictionary)

            var insert = existing
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
        default:
            return false
        }
    }

    func removeSecret(for account: String) {
        SecItemDelete(query(for: account, synchronizable: kSecAttrSynchronizableAny) as CFDictionary)
    }
}

/// The process-wide store. A settable global rather than an injected dependency
/// because the callers are `PairState.load()` / `PendingInvite.load()`, which are
/// static and reached from everywhere; tests swap it in `setUp`.
enum PairSecrets {
    nonisolated(unsafe) static var store: PairSecretStore = KeychainPairSecretStore()
}
