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

    static let storageKey = "attention.pendingInvite.v1"

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

    static func load() -> PendingInvite? {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(PendingInvite.self, from: data)
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: PendingInvite.storageKey)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }
}
