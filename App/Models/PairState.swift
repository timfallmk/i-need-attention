import Foundation
import Security

/// What the local device knows about its pairing once the handshake is complete.
///
/// Split storage since 2.0: the four non-secret fields are JSON in `UserDefaults`,
/// the pair key is a keychain item (`PairSecrets.store`). Pre-2.0 installs wrote all
/// five to `attention.pair.v1`; `load()` migrates those on first read.
struct PairState: Codable, Equatable {
    var pairKey: String        // 22-char URL-safe base64, the shared secret
    var myDeviceID: String     // copy of DeviceIdentity.id at time of pairing
    var myName: String
    var partnerDeviceID: String
    var partnerName: String

    static let storageKey = "attention.pair.v2"

    /// The pre-2.0 blob, which carried the pair key in the clear.
    static let legacyStorageKey = "attention.pair.v1"

    /// The half of `PairState` that isn't secret and stays in `UserDefaults`.
    private struct Stored: Codable {
        var myDeviceID: String
        var myName: String
        var partnerDeviceID: String
        var partnerName: String
    }

    /// Returns nil when the keychain has no key for a stored pairing. Real causes are
    /// a push handled before the first unlock after a reboot (the item is
    /// `AfterFirstUnlock`) and a fresh device where iCloud Keychain hasn't synced yet.
    /// Both read as "not paired", which is accurate while it lasts: without the key
    /// nothing can be sent, read or decrypted. Neither is destructive — the v2 blob
    /// stays put, so a later launch that can reach the key loads normally.
    static func load() -> PairState? {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let stored = try? JSONDecoder().decode(Stored.self, from: data),
           let pairKey = PairSecrets.store.secret(for: Constants.Keychain.pairKeyAccount) {
            return PairState(
                pairKey: pairKey,
                myDeviceID: stored.myDeviceID,
                myName: stored.myName,
                partnerDeviceID: stored.partnerDeviceID,
                partnerName: stored.partnerName
            )
        }
        return migrateLegacy()
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
            partnerName: partnerName
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
        UserDefaults.standard.removeObject(forKey: legacyStorageKey)
    }

    /// Reached both by a genuine pre-2.0 install and by a migration that wrote the
    /// v2 blob but failed to store the key — in which case retrying is right, and
    /// dropping the v1 copy before the key reads back would have unpaired the device
    /// permanently.
    private static func migrateLegacy() -> PairState? {
        guard let data = UserDefaults.standard.data(forKey: legacyStorageKey),
              let state = try? JSONDecoder().decode(PairState.self, from: data) else { return nil }
        state.save()
        if PairSecrets.store.secret(for: Constants.Keychain.pairKeyAccount) == state.pairKey {
            UserDefaults.standard.removeObject(forKey: legacyStorageKey)
        }
        return state
    }
}

/// Encoded into the QR code shown by the inviting device (and, identically, into the
/// shareable `attention://pair` link).
struct PairingInvite: Codable, Identifiable {
    let pairKey: String
    let inviterDeviceID: String
    let inviterName: String

    var qrPayload: String {
        // attention://pair?k=<pairKey>&id=<deviceID>&n=<name>
        var components = URLComponents()
        components.scheme = "attention"
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "k", value: pairKey),
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
        // The name renders in the "Pair with …?" sheet, so a link or a wall of ad copy
        // here is a spam vector carried by the invite itself.
        let name = UntrustedText.name(map["n"], fallback: "Friend")
        return PairingInvite(pairKey: key, inviterDeviceID: id, inviterName: name)
    }

    /// Identity for SwiftUI sheet presentation: one invite per pairKey.
    var id: String { pairKey }

    static func generate(myDeviceID: String, myName: String) -> PairingInvite {
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
        return PairingInvite(pairKey: key, inviterDeviceID: myDeviceID, inviterName: myName)
    }
}
