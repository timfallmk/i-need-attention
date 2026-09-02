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

    /// The partner's inbox zone, in our shared database, once we have accepted their
    /// share. Non-nil is exactly what "we can send" means — alerts are written here.
    var outgoingZone: ZoneRef?

    /// Whether the partner has accepted our share and can therefore write into our
    /// own inbox zone. Cached from the share's participants; refreshed, not trusted.
    var partnerCanReach: Bool = false

    /// Both directions live. Until this holds the UI says "finishing setup" rather
    /// than "paired", and must not offer a send button that would do nothing.
    var isComplete: Bool { outgoingZone != nil && partnerCanReach }

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
            partnerCanReach: partnerCanReach
        )
        guard let data = try? JSONEncoder().encode(stored),
              PairSecrets.store.setSecret(pairKey, for: Constants.Keychain.pairKeyAccount) else {
            return false
        }
        UserDefaults.standard.set(data, forKey: PairState.storageKey)
        return true
    }

    static func clear() {
        PairSecrets.store.removeSecret(for: Constants.Keychain.pairKeyAccount)
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
