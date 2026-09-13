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
/// fallback name: a name is either minted here or adopted from a zone this Apple ID
/// already owns, and `adopt` will only take a zone the current pair key can open — so
/// there is still no path by which two *pairings* end up sharing a zone.
///
/// Per-pairing is not the same as per-install, and the difference is the whole of #68.
/// Several devices signed into one Apple ID share one private database, one pair key and
/// one pairing, so they must share one zone; discovery is how the second device finds the
/// first one's instead of minting a rival that would then fight it over the
/// account-wide subscriptions.
enum InboxZone {
    private static let storageKey = "attention.inboxZone.v1"
    private static let lock = NSLock()

    /// Every name this app has ever minted starts with this, which is what makes a zone
    /// belonging to this app distinguishable from anything else in the private database.
    /// `CloudKitService.adoptableInboxZone` needs that to find the zone a *different*
    /// device on the same Apple Account already owns, instead of minting a rival one.
    static let namePrefix = "attention-inbox-"

    /// Minted on first use and persisted. The mint is behind a lock because this is
    /// reached from `CloudKitService`, which is not actor-isolated: two concurrent
    /// first-reads would otherwise mint two names and hand one caller a zone the other
    /// just overwrote.
    static var currentName: String {
        lock.lock()
        defer { lock.unlock() }
        if let stored = UserDefaults.standard.string(forKey: storageKey) {
            mirrorLocked(stored)
            return stored
        }
        return mintLocked()
    }

    /// The stored name, without minting one. The difference from `currentName` matters
    /// in exactly one place and it is load-bearing: a device that has not yet synced the
    /// pair key must be able to ask "do I have a zone?" and get "no" rather than silently
    /// becoming the owner of a second one.
    static var storedName: String? {
        lock.lock()
        defer { lock.unlock() }
        let stored = UserDefaults.standard.string(forKey: storageKey)
        if let stored { mirrorLocked(stored) }
        return stored
    }

    /// Keeps the App Group copy level with the one in this process's `UserDefaults`.
    ///
    /// Mirrored on *read* as well as on write, which is not belt-and-braces. The only
    /// writers are minting, adopting and clearing, none of which an ordinary upgrade
    /// runs — so every install paired before 2.2.0 has a name here and nothing in the
    /// App Group, and the NSE's zone filter would simply never engage for any of them.
    /// It fails open (a name it cannot read means "deliver anyway", because a push this
    /// app cannot classify must never become silence), so the gap is invisible.
    ///
    /// Only a name is mirrored, never the absence of one: clearing stays the explicit
    /// job of `clear()`, and a read path that could blank the extension's copy would be
    /// a new way to lose the filter rather than a way to keep it.
    private static func mirrorLocked(_ name: String) {
        guard SharedSettings.inboxZoneName != name else { return }
        SharedSettings.inboxZoneName = name
    }

    /// Takes over a zone this Apple ID already owns, found by discovery rather than
    /// minted here. Reached through `CloudKitService.adoptInboxZone(named:)`, and only
    /// for a zone whose `PairProfile` opened under the pair key this account currently
    /// holds — the prefix alone is not enough, because a failed teardown can leave a
    /// previous pairing's zone behind under the same prefix.
    static func adopt(_ name: String) {
        lock.lock()
        defer { lock.unlock() }
        UserDefaults.standard.set(name, forKey: storageKey)
        SharedSettings.inboxZoneName = name
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
        SharedSettings.inboxZoneName = nil
    }

    /// Caller holds `lock`.
    private static func mintLocked() -> String {
        let name = namePrefix + UUID().uuidString.lowercased()
        UserDefaults.standard.set(name, forKey: storageKey)
        // Mirrored for the notification service extension, which is a separate process
        // and cannot read this one's `UserDefaults`. See `SharedSettings.inboxZoneName`.
        SharedSettings.inboxZoneName = name
        return name
    }
}
