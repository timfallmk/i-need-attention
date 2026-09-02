import Foundation

/// The name of the record zone this device currently owns.
///
/// It is per-pairing, not per-install, and that is the whole point. A zone-wide share
/// grants its participant the *entire* zone, so reusing one name across successive
/// partners would hand each new partner read access to every record the previous one
/// left behind. The contents stay sealed under a key they never had, but the plaintext
/// structural fields — who sent what, when, whether it was answered, how fast — are
/// readable, and in this app that is exactly the data worth protecting.
///
/// So unpairing deletes the zone (after `AppState.unpair` has archived it locally) and
/// clears this value; the next pairing mints a fresh name and starts empty.
enum InboxZone {
    private static let storageKey = "attention.inboxZone.v1"

    /// Installs that paired before per-pairing zones existed own a zone under the fixed
    /// name and have a live share on it. Defaulting to it keeps them working — the
    /// rotation only ever happens on the far side of an unpair.
    static var currentName: String {
        UserDefaults.standard.string(forKey: storageKey) ?? Constants.Zone.legacyInbox
    }

    /// Called on the next `ensureInboxZone` after an unpair. Returns the new name.
    @discardableResult
    static func rotate() -> String {
        let name = "attention-inbox-" + UUID().uuidString.lowercased()
        UserDefaults.standard.set(name, forKey: storageKey)
        return name
    }

    /// Whether a name has been minted, as opposed to falling back to the legacy one.
    static var isMinted: Bool {
        UserDefaults.standard.string(forKey: storageKey) != nil
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }
}
