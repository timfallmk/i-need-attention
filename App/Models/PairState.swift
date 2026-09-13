import Foundation
import Security

/// What the local device knows about its pairing.
///
/// From 2.0 the two directions are tracked separately, because the handshake makes
/// them live at different moments: the joiner can send as soon as they accept the
/// inviter's share, while the inviter cannot send until the joiner's share comes back
/// over that same channel and is accepted. A pair is only "paired" once both hold.
///
/// Storage is split three ways: the non-secret fields are JSON in `UserDefaults`, the
/// pair key is a keychain item (`PairSecrets.store`), and the records themselves live
/// in CloudKit zones this state points at.
struct PairState: Codable, Equatable {
    var pairKey: String        // 22-char URL-safe base64, the shared secret
    var myDeviceID: String     // copy of DeviceIdentity.id at time of pairing
    var myName: String
    var partnerDeviceID: String
    var partnerName: String

    /// Account-scoped identities — `CKContainer.userRecordID().recordName` for each
    /// side — and the reason they are optional is the whole of the migration.
    ///
    /// The device IDs above answer "which phone", and everything that reads them is
    /// really asking "which of us". That was the same question while each person had
    /// one device and stopped being one the moment they could have two: an alert sent
    /// from your iPad reads as *incoming* on your iPhone, and an alert from your
    /// partner's second device matches neither side and is dropped without a trace.
    ///
    /// Nil means "not learned yet", which is every pairing made before this and is
    /// handled by falling back to the device comparison rather than by a migration
    /// step. A pairing fills them in the first time each side writes a profile under a
    /// build that carries one; until then it behaves exactly as it did before.
    var myUserID: String?
    var partnerUserID: String?

    /// The partner's inbox zone, in our shared database, once we have accepted their
    /// share. Non-nil is exactly what "we can send" means — alerts are written here.
    var outgoingZone: ZoneRef?

    /// Whether the partner has accepted our share and can therefore write into our
    /// own inbox zone. Cached from the share's participants; refreshed, not trusted.
    var partnerCanReach: Bool = false

    /// Whether pressing the button would actually reach anyone. The joiner has this the
    /// moment they accept; the inviter only once the joiner's share comes back.
    var canSend: Bool { outgoingZone != nil }

    /// Both directions live. Until this holds the UI says "finishing setup" rather than
    /// "paired", and must never offer a button that would silently do nothing.
    var isComplete: Bool { canSend && partnerCanReach }

    /// Who counts as "me" for this pairing.
    var me: SenderIdentity { SenderIdentity(deviceID: myDeviceID, userID: myUserID) }

    /// Whether a record came from this person, given whichever identifiers it carries.
    ///
    /// Note what it does *not* do: conclude "theirs" from "not mine". A record in the
    /// zone we own can only have been written by a share participant, so the caller that
    /// knows which zone a record came from is better placed to decide than a device-ID
    /// match — which is exactly what silently dropped a partner's second phone.
    func isMine(senderUserID: String?, senderDeviceID: String) -> Bool {
        me.matches(userID: senderUserID, deviceID: senderDeviceID)
    }

    /// v3 is the 2.0 shape. v1 and v2 described pairings in the public database, which
    /// 2.0 abandons — `LegacyPairing` reads those, and only to salvage their history.
    static let storageKey = "attention.pair.v3"

    /// The half of `PairState` that isn't secret and stays in `UserDefaults`.
    private struct Stored: Codable {
        var myDeviceID: String
        var myName: String
        var partnerDeviceID: String
        var partnerName: String
        var outgoingZone: ZoneRef?
        var partnerCanReach: Bool
        /// Optional in the Swift sense *and* absent from blobs written by earlier
        /// builds, which decode fine because `Codable` treats a missing optional as nil.
        /// That is what lets this ship without a storage version bump.
        var myUserID: String?
        var partnerUserID: String?
    }

    /// Returns nil when the keychain has no key for a stored pairing. Real causes are
    /// a push handled before the first unlock after a reboot (the item is
    /// `AfterFirstUnlock`) and a fresh device where iCloud Keychain hasn't synced yet.
    /// Both read as "not paired", which is accurate while it lasts: without the key
    /// nothing can be sent, read or decrypted. Neither is destructive — the v3 blob
    /// stays put, so a later launch that can reach the key loads normally.
    static func load() -> PairState? {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let stored = try? JSONDecoder().decode(Stored.self, from: data),
              let pairKey = PairSecrets.store.secret(for: Constants.Keychain.pairKeyAccount) else {
            return nil
        }
        return PairState(
            pairKey: pairKey,
            myDeviceID: stored.myDeviceID,
            myName: stored.myName,
            partnerDeviceID: stored.partnerDeviceID,
            partnerName: stored.partnerName,
            myUserID: stored.myUserID,
            partnerUserID: stored.partnerUserID,
            outgoingZone: stored.outgoingZone,
            partnerCanReach: stored.partnerCanReach
        )
    }

    /// The `UserDefaults` half is written only once the key is stored, so a keychain
    /// that refuses the write leaves the device consistently unpaired rather than
    /// holding a pairing it can never load.
    @discardableResult
    func save() -> Bool {
        let stored = Stored(
            myDeviceID: myDeviceID,
            myName: myName,
            partnerDeviceID: partnerDeviceID,
            partnerName: partnerName,
            outgoingZone: outgoingZone,
            partnerCanReach: partnerCanReach,
            myUserID: myUserID,
            partnerUserID: partnerUserID
        )
        guard let data = try? JSONEncoder().encode(stored),
              PairSecrets.store.setSecret(pairKey, for: Constants.Keychain.pairKeyAccount) else {
            return false
        }
        UserDefaults.standard.set(data, forKey: PairState.storageKey)
        return true
    }

    /// Whether a pairing blob is on disk, regardless of whether its key can be read.
    ///
    /// `load()` needs both and returns nil without the key, which makes it exactly the
    /// wrong question to ask about a pairing another device may have ended: unpairing
    /// drops the synchronizable keychain item and that deletion propagates, so the
    /// device being told loses the key *first* and reads as never-paired. The blob
    /// outlives the key and is the only key-independent evidence that this install
    /// thought it was paired.
    ///
    /// Not evidence that it still is — a locked device before first unlock looks
    /// identical — so callers pair it with something that is (the zone being gone).
    static var hasStoredBlob: Bool {
        UserDefaults.standard.data(forKey: storageKey) != nil
    }

    static func clear() {
        PairSecrets.store.removeSecret(for: Constants.Keychain.pairKeyAccount)
        UserDefaults.standard.removeObject(forKey: storageKey)
        // Pairing-scoped, so it goes with the pairing rather than living on to tell the
        // next partner's zone that it has already been told who we are.
        UserDefaults.standard.removeObject(forKey: AccountIdentityPublished.storageKey)
    }
}

/// Whether this device arrived at 2.0 carrying a pairing that no longer works.
///
/// The 2.0 cutover doesn't migrate old pairings — it can't, since they describe records
/// in a database the app has stopped using — so an upgrading user opens the app and
/// finds themselves unpaired with no explanation. This is the flag that lets the pairing
/// screen say why, and it is deliberately separate from `LegacyPairing`, whose blobs are
/// cleared as soon as the history capture has taken what it needs.
enum CutoverNotice {
    static let storageKey = "attention.cutover.needsRepair.v1"

    static var needsRepair: Bool {
        get { UserDefaults.standard.bool(forKey: storageKey) }
        set { UserDefaults.standard.set(newValue, forKey: storageKey) }
    }
}

/// Records that a pairing ended because the *partner* ended it, so the pairing screen
/// can explain why the app is suddenly asking them to pair again.
///
/// Separate from `CutoverNotice`: that one is a one-time 2.0 migration artifact, this one
/// can happen at any time and repeatedly. Both answer the same user question — "why am I
/// unpaired?" — which has no answer at all without them.
enum PartnerUnpairedNotice {
    static let storageKey = "attention.partnerUnpaired.v1"

    static var happened: Bool {
        get { UserDefaults.standard.bool(forKey: storageKey) }
        set { UserDefaults.standard.set(newValue, forKey: storageKey) }
    }
}

/// Who "me" is when deciding whether a record was sent by this person.
///
/// One type rather than the comparison written out at each site, because the fallback is
/// the subtle part and four copies of it would not stay identical. The account identity
/// wins whenever *both* ends of the comparison have one; anything else falls back to the
/// per-install identity, which is all a record written before this carries.
///
/// Both halves of that condition matter. A `userID` on our side but not on the record
/// means an older record and must fall back; the reverse means an older pairing that has
/// not learned ours yet, and must fall back too. Comparing a present value against a nil
/// one would answer "not mine" for every alert this person ever sent.
struct SenderIdentity: Equatable {
    let deviceID: String
    let userID: String?

    func matches(userID sender: String?, deviceID senderDevice: String) -> Bool {
        if let userID, let sender { return sender == userID }
        return senderDevice == deviceID
    }
}

/// Whether this device has written a profile carrying its account identity into the
/// partner's zone, for this pairing.
///
/// Pairing-scoped rather than install-scoped, which is why `PairState.clear()` drops it:
/// a new pairing is a new partner with a new zone and nothing published into it yet.
enum AccountIdentityPublished {
    static let storageKey = "attention.accountIdentityPublished.v1"

    static var done: Bool {
        get { UserDefaults.standard.bool(forKey: storageKey) }
        set { UserDefaults.standard.set(newValue, forKey: storageKey) }
    }
}

/// Records that a pairing ended because *another device signed into this Apple ID*
/// ended it, so the pairing screen can explain why this device is suddenly asking to
/// pair again.
///
/// A third flavour of the same user question, and it needs its own flag rather than
/// reusing `PartnerUnpairedNotice` because the answer is different and the difference
/// matters: nobody left, and there is nothing to talk to the partner about. The pairing
/// is simply over for this person, on every device they own, which is what unpairing
/// from any one of them now means.
///
/// The signal is the inbox zone: it lives in the private database, which is per Apple ID
/// rather than per install, so a device that unpairs deletes the zone every device on
/// that account was reading. See `InboxZoneResolution.vanished`.
enum UnpairedElsewhereNotice {
    static let storageKey = "attention.unpairedElsewhere.v1"

    static var happened: Bool {
        get { UserDefaults.standard.bool(forKey: storageKey) }
        set { UserDefaults.standard.set(newValue, forKey: storageKey) }
    }
}

/// Record name of the most recently user-dismissed acknowledged alert, so
/// `reconcileLatestAlert` doesn't re-surface it after a background/relaunch.
enum DismissedOutgoing {
    static let storageKey = "attention.dismissedOutgoingRecordName"

    static var recordName: String? {
        get { UserDefaults.standard.string(forKey: storageKey) }
        set { UserDefaults.standard.set(newValue, forKey: storageKey) }
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }
}

/// A pre-2.0 pairing, read only to salvage the history it left in the public database.
///
/// These are *not* migrated into a `PairState`: 2.0 moves records into per-user private
/// zones under a new key, so an old pairing describes storage the app no longer uses.
/// Surfacing one as a live pair would show a paired device that cannot send anything.
enum LegacyPairing {
    /// v1 carried the pair key in the clear alongside the rest; v2 split it into the
    /// keychain, so for v2 the blob's presence is all that has to be decoded — the key
    /// itself comes from the store. Both are read, newest first.
    static let storageKeyV2 = "attention.pair.v2"
    static let storageKeyV1 = "attention.pair.v1"

    private struct StoredV1: Codable {
        var pairKey: String
        var myDeviceID: String
        var myName: String
        var partnerDeviceID: String
        var partnerName: String
    }

    /// Whether this device ever had a pre-2.0 pairing. Deliberately does not touch the
    /// keychain: an `AfterFirstUnlock` item is unreadable until the first unlock after a
    /// reboot, and a push can launch this app before then. "No key right now" and "never
    /// had a pairing" have to stay distinguishable, or a background launch at the wrong
    /// moment looks like an install that never paired.
    static var exists: Bool {
        UserDefaults.standard.data(forKey: storageKeyV2) != nil
            || UserDefaults.standard.data(forKey: storageKeyV1) != nil
    }

    /// The pre-2.0 pair key. Nil when there was no pairing *or* when the keychain can't
    /// be read yet — callers pair this with `exists` to tell those apart.
    static func pairKey() -> String? {
        if UserDefaults.standard.data(forKey: storageKeyV2) != nil,
           let key = PairSecrets.store.secret(for: Constants.Keychain.pairKeyAccount) {
            return key
        }
        guard let data = UserDefaults.standard.data(forKey: storageKeyV1),
              let stored = try? JSONDecoder().decode(StoredV1.self, from: data) else { return nil }
        return stored.pairKey
    }

    /// Dropped once the history capture is finished with them, successfully or not.
    static func clear() {
        UserDefaults.standard.removeObject(forKey: storageKeyV2)
        UserDefaults.standard.removeObject(forKey: storageKeyV1)
    }
}

/// Encoded into the QR code shown by the inviting device (and, identically, into the
/// shareable `attention://pair` link).
///
/// Carries two things the joiner needs: the share URL that lets them into the
/// inviter's inbox zone, and the pair key that decrypts what they find there. They
/// travel together because neither is useful alone — the share bounds *who* can read
/// the zone, the key bounds *what* they can make of it.
struct PairingInvite: Codable, Identifiable {
    let pairKey: String
    let inviterDeviceID: String
    let inviterName: String
    let shareURL: URL

    var qrPayload: String {
        // attention://pair?k=<pairKey>&s=<shareURL>&id=<deviceID>&n=<name>
        var components = URLComponents()
        components.scheme = "attention"
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "k", value: pairKey),
            URLQueryItem(name: "s", value: shareURL.absoluteString),
            URLQueryItem(name: "id", value: inviterDeviceID),
            URLQueryItem(name: "n", value: inviterName)
        ]
        return components.url?.absoluteString ?? ""
    }

    static func from(qrPayload: String) -> PairingInvite? {
        guard let url = URL(string: qrPayload),
              url.scheme == "attention",
              url.host == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            return nil
        }
        // QR payload is untrusted — duplicate query item names must not trap.
        // Take the first value for each name.
        var map: [String: String] = [:]
        for item in items {
            guard let value = item.value, map[item.name] == nil else { continue }
            map[item.name] = value
        }
        guard let key = map["k"], let id = map["id"] else { return nil }
        // Accepting a share means joining whatever zone the URL names, so a scanned
        // code doesn't get to point this anywhere it likes.
        guard let raw = map["s"], let shareURL = URL(string: raw), shareURL.isCloudKitShare else {
            return nil
        }
        // The name renders in the "Pair with …?" sheet, so a link or a wall of ad copy
        // here is a spam vector carried by the invite itself.
        let name = UntrustedText.name(map["n"], fallback: "Friend")
        return PairingInvite(pairKey: key, inviterDeviceID: id, inviterName: name, shareURL: shareURL)
    }

    /// Identity for SwiftUI sheet presentation: one invite per pairKey.
    var id: String { pairKey }

    static func generate(myDeviceID: String, myName: String, shareURL: URL) -> PairingInvite {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let key: String
        if status == errSecSuccess {
            key = Data(bytes).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        } else {
            // SecRandom failed — fall back to two UUIDs (~122 bits of entropy each)
            // concatenated. Weaker than the CSPRNG path but never the predictable
            // all-zero key the previous implementation could produce.
            key = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "")
        }
        return PairingInvite(pairKey: key, inviterDeviceID: myDeviceID, inviterName: myName, shareURL: shareURL)
    }
}
