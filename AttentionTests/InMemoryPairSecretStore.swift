import Foundation

/// Stand-in for the keychain. `AttentionTests` is a hostless unit-test bundle built
/// with `CODE_SIGNING_ALLOWED=NO`, so it has no entitlements and no access group to
/// address; the real `KeychainPairSecretStore` is only exercised on a device.
final class InMemoryPairSecretStore: PairSecretStore {
    private var secrets: [String: String] = [:]

    /// Set to false to simulate a keychain that refuses to store anything — the case
    /// the legacy migration must not lose the pair key to.
    var writesSucceed = true

    func secret(for account: String) -> String? {
        secrets[account]
    }

    @discardableResult
    func setSecret(_ secret: String, for account: String) -> Bool {
        guard writesSucceed else { return false }
        secrets[account] = secret
        return true
    }

    func removeSecret(for account: String) {
        secrets[account] = nil
    }
}
