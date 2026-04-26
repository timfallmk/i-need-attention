import Foundation

/// What the local device knows about its pairing once the handshake is complete.
/// Persisted to UserDefaults — this is the only thing required to start sending alerts.
struct PairState: Codable, Equatable {
    var pairKey: String        // 22-char URL-safe base64, the shared secret
    var myDeviceID: String     // copy of DeviceIdentity.id at time of pairing
    var myName: String
    var partnerDeviceID: String
    var partnerName: String

    static let storageKey = "attention.pair.v1"

    static func load() -> PairState? {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(PairState.self, from: data)
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }
}

/// Encoded into the QR code shown by the inviting device.
struct PairingInvite: Codable {
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
        let map = Dictionary(uniqueKeysWithValues: items.compactMap { item -> (String, String)? in
            guard let value = item.value else { return nil }
            return (item.name, value)
        })
        guard let key = map["k"], let id = map["id"] else { return nil }
        return PairingInvite(pairKey: key, inviterDeviceID: id, inviterName: map["n"] ?? "Friend")
    }

    static func generate(myDeviceID: String, myName: String) -> PairingInvite {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let key = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return PairingInvite(pairKey: key, inviterDeviceID: myDeviceID, inviterName: myName)
    }
}
