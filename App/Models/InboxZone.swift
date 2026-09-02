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
/// rotates this value; the next pairing starts empty. There is deliberately no fixed
/// fallback name: a name only ever comes into existence here, which means there is no
/// second path by which two pairings could end up sharing a zone.
enum InboxZone {
    private static let storageKey = "attention.inboxZone.v1"
    private static let lock = NSLock()

    /// Minted on first use and persisted. The mint is behind a lock because this is
    /// reached from `CloudKitService`, which is not actor-isolated: two concurrent
    /// first-reads would otherwise mint two names and hand one caller a zone the other
    /// just overwrote.
    static var currentName: String {
        lock.lock()
        defer { lock.unlock() }
        if let stored = UserDefaults.standard.string(forKey: storageKey) { return stored }
        return mintLocked()
    }

    /// Called on the far side of an unpair. Returns the new name.
    @discardableResult
    static func rotate() -> String {
        lock.lock()
        defer { lock.unlock() }
        return mintLocked()
    }

    /// Whether a name exists yet. Only `resetPairingPredatingPerPairingZones` needs
    /// this, and only before anything has read `currentName`.
    static var isMinted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return UserDefaults.standard.string(forKey: storageKey) != nil
    }

    /// Ends a pairing made before zones were per-pairing.
    ///
    /// Such a device owns a zone under the old fixed name and has a live share on it,
    /// but nothing here records which zone that was — so its partner would keep writing
    /// into a zone this device no longer reads, and the pairing would look healthy while
    /// delivering nothing. A pairing that silently receives nothing is worse than no
    /// pairing, so it ends and the user pairs again.
    ///
    /// The orphaned zone and its share are left alone: reaching them needs the name this
    /// device never stored, and they are only reachable by a partner who is about to be
    /// unpaired anyway.
    static func resetPairingPredatingPerPairingZones() {
        guard !isMinted, PairState.load() != nil else { return }
        PairState.clear()
        PendingInvite.clear()
        rotate()
    }

    static func clear() {
        lock.lock()
        defer { lock.unlock() }
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    /// Caller holds `lock`.
    private static func mintLocked() -> String {
        let name = "attention-inbox-" + UUID().uuidString.lowercased()
        UserDefaults.standard.set(name, forKey: storageKey)
        return name
    }
}
