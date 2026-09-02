import Foundation

/// An invite the local device created but the partner hasn't accepted yet. Persisted so
/// the inviter can share the link, leave, and still finish pairing later — the joiner's
/// half of the handshake lands in our own inbox zone, and the launch/foreground
/// reconcile picks it up whenever we next run.
///
/// v3 is the 2.0 shape. Earlier versions described a half-empty `Pair` record in the
/// public database, which no longer exists; like a pre-2.0 `PairState`, one of those is
/// not resurrected — it would offer a QR code nobody can act on.
struct PendingInvite: Codable, Equatable {
    var pairKey: String
    var myDeviceID: String
    var myName: String
    /// The bearer link to our inbox zone that the QR code encodes. Held so the invite
    /// can be redisplayed without minting a second share.
    var shareURL: URL
    var createdAt: Date

    static let storageKey = "attention.pendingInvite.v3"

    /// Pre-2.0 shapes, cleared rather than migrated.
    static let legacyStorageKeys = ["attention.pendingInvite.v2", "attention.pendingInvite.v1"]

    /// Invites older than this are surfaced as expired in the UI (renew or cancel).
    /// They still work server-side — staleness is a UX signal, not a security boundary.
    static let expiryInterval: TimeInterval = 24 * 60 * 60

    var isExpired: Bool {
        Date().timeIntervalSince(createdAt) > Self.expiryInterval
    }

    /// The shareable invite this pending record was created from. The URL payload is
    /// identical to what the QR encodes.
    var invite: PairingInvite {
        PairingInvite(pairKey: pairKey,
                      inviterDeviceID: myDeviceID,
                      inviterName: myName,
                      shareURL: shareURL)
    }

    /// The half of `PendingInvite` that isn't secret and stays in `UserDefaults`.
    /// The pair key of a live invite is as sensitive as a completed pairing's, so it
    /// goes to the keychain too — under its own account, so cancelling an invite
    /// can't disturb an existing pair.
    private struct Stored: Codable {
        var myDeviceID: String
        var myName: String
        var shareURL: URL
        var createdAt: Date
    }

    static func load() -> PendingInvite? {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let stored = try? JSONDecoder().decode(Stored.self, from: data),
              let pairKey = PairSecrets.store.secret(for: Constants.Keychain.pendingInviteKeyAccount) else {
            return nil
        }
        return PendingInvite(
            pairKey: pairKey,
            myDeviceID: stored.myDeviceID,
            myName: stored.myName,
            shareURL: stored.shareURL,
            createdAt: stored.createdAt
        )
    }

    /// Conditional on the key landing, for the reason `PairState.save()` gives: a
    /// persisted invite with no key is one that can never be loaded again.
    @discardableResult
    func save() -> Bool {
        let stored = Stored(
            myDeviceID: myDeviceID,
            myName: myName,
            shareURL: shareURL,
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
        for key in legacyStorageKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
