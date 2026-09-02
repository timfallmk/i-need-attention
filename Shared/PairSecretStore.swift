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
/// `ThisDeviceOnly` accessibility is deliberate. Keeping the key out of iCloud
/// Keychain and out of backups is the whole point; the cost is that a backup
/// restored onto a new phone arrives unpaired and has to pair again.
/// `AfterFirstUnlock` rather than `WhenUnlocked` because the NSE decrypts pushes
/// that arrive while the screen is locked.
struct KeychainPairSecretStore: PairSecretStore {
    let service: String
    let accessGroup: String?

    init(service: String = Constants.Keychain.service,
         accessGroup: String? = Constants.AppGroup.identifier) {
        self.service = service
        self.accessGroup = accessGroup
    }

    private func query(for account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    func secret(for account: String) -> String? {
        var lookup = query(for: account)
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
        let existing = query(for: account)
        let update = [kSecValueData as String: data]

        switch SecItemUpdate(existing as CFDictionary, update as CFDictionary) {
        case errSecSuccess:
            return true
        case errSecItemNotFound:
            var insert = existing
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
        default:
            return false
        }
    }

    func removeSecret(for account: String) {
        SecItemDelete(query(for: account) as CFDictionary)
    }
}

/// The process-wide store. A settable global rather than an injected dependency
/// because the callers are `PairState.load()` / `PendingInvite.load()`, which are
/// static and reached from everywhere; tests swap it in `setUp`.
enum PairSecrets {
    nonisolated(unsafe) static var store: PairSecretStore = KeychainPairSecretStore()
}
