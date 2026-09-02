import Foundation

/// An invite the local device created but the partner hasn't accepted yet. Persisted so
/// the inviter can share the link, leave, and still complete pairing later — via the
/// pair-update silent push when the app is alive, or the launch/foreground reconcile
/// otherwise. Cleared on completion or user-initiated cancel.
struct PendingInvite: Codable, Equatable {
    var pairKey: String
    var myDeviceID: String
    var myName: String
    var recordName: String     // CKRecord.ID.recordName of the half-empty Pair record
    var createdAt: Date

    static let storageKey = "attention.pendingInvite.v2"

    /// The pre-2.0 blob, which carried the pair key in the clear.
    static let legacyStorageKey = "attention.pendingInvite.v1"

    /// Invites older than this are surfaced as expired in the UI (renew or cancel).
    /// They still work server-side — staleness is a UX signal, not a security boundary.
    static let expiryInterval: TimeInterval = 24 * 60 * 60

    var isExpired: Bool {
        Date().timeIntervalSince(createdAt) > Self.expiryInterval
    }

    /// The shareable invite this pending record was created from. The URL payload is
    /// identical to what the QR encodes.
    var invite: PairingInvite {
        PairingInvite(pairKey: pairKey, inviterDeviceID: myDeviceID, inviterName: myName)
    }

    /// The half of `PendingInvite` that isn't secret and stays in `UserDefaults`.
    /// The pair key of a live invite is as sensitive as a completed pairing's, so it
    /// goes to the keychain too — under its own account, so cancelling an invite
    /// can't disturb an existing pair.
    private struct Stored: Codable {
        var myDeviceID: String
        var myName: String
        var recordName: String
        var createdAt: Date
    }

    static func load() -> PendingInvite? {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let stored = try? JSONDecoder().decode(Stored.self, from: data),
           let pairKey = PairSecrets.store.secret(for: Constants.Keychain.pendingInviteKeyAccount) {
            return PendingInvite(
                pairKey: pairKey,
                myDeviceID: stored.myDeviceID,
                myName: stored.myName,
                recordName: stored.recordName,
                createdAt: stored.createdAt
            )
        }
        return migrateLegacy()
    }

    /// Conditional on the key landing, for the reason `PairState.save()` gives: a
    /// persisted invite with no key is one that can never be loaded again.
    @discardableResult
    func save() -> Bool {
        let stored = Stored(
            myDeviceID: myDeviceID,
            myName: myName,
            recordName: recordName,
            createdAt: createdAt
        )
        guard let data = try? JSONEncoder().encode(stored),
              PairSecrets.store.setSecret(pairKey, for: Constants.Keychain.pendingInviteKeyAccount) else {
            return false
        }
        UserDefaults.standard.set(data, forKey: PendingInvite.storageKey)
        return true
    }

    static func clear() {
        PairSecrets.store.removeSecret(for: Constants.Keychain.pendingInviteKeyAccount)
        UserDefaults.standard.removeObject(forKey: storageKey)
        UserDefaults.standard.removeObject(forKey: legacyStorageKey)
    }

    /// See `PairState.migrateLegacy` — same shape, same reason for only dropping the
    /// plaintext copy once the key reads back.
    private static func migrateLegacy() -> PendingInvite? {
        guard let data = UserDefaults.standard.data(forKey: legacyStorageKey),
              let invite = try? JSONDecoder().decode(PendingInvite.self, from: data) else { return nil }
        invite.save()
        if PairSecrets.store.secret(for: Constants.Keychain.pendingInviteKeyAccount) == invite.pairKey {
            UserDefaults.standard.removeObject(forKey: legacyStorageKey)
        }
        return invite
    }
}
