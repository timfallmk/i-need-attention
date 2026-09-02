import CryptoKit
import Foundation

/// Seals the parts of a record that carry human-readable content, so CloudKit stores
/// ciphertext rather than text.
///
/// Two properties matter, and they are separate. Content becomes unreadable to anyone
/// who is not one of the two paired devices — Apple included, since the key never
/// leaves the phones. And a record written by someone who does not hold the key fails
/// to open at all, so hostile writes are discarded rather than merely rendered safely,
/// which is as far as `UntrustedText` can go on its own.
///
/// The pair key itself is never written to CloudKit. Where a queryable value is needed
/// — a subscription predicate, a pair lookup — `lookupHash` goes in the record instead.
enum PairCrypto {
    enum Failure: Error, Equatable {
        /// Too short or otherwise not a ChaCha20-Poly1305 box. A field a stranger wrote.
        case malformedSealedBox
        /// Wrong key, wrong field, or tampered bytes — indistinguishable by design.
        case authenticationFailed
        case notUTF8
    }

    /// Non-secret, per HKDF, but both devices must derive the same key from the same
    /// pair key, so these two constants can never change without a migration. The `v1`
    /// suffixes exist so a future scheme can be told apart rather than silently failing
    /// to open every existing record.
    private static let salt = Data("attention.pair.hkdf.v1".utf8)
    private static let info = Data("attention.pair.content.v1".utf8)

    /// Stand-in for the pair key in any field that has to be queryable. SHA-256 over a
    /// 128-bit random value is not reversible, so a reader who can see the record learns
    /// nothing that helps them decrypt it.
    static func lookupHash(pairKey: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(pairKey.utf8))))
    }

    /// `field` binds the ciphertext to the field it belongs in — pass the `Constants`
    /// value for the destination. Without it, a sealed `senderName` could be copied into
    /// the `message` field of the same record and would still open.
    static func seal(_ plaintext: String, pairKey: String, field: String) throws -> Data {
        try ChaChaPoly.seal(
            Data(plaintext.utf8),
            using: key(for: pairKey),
            authenticating: Data(field.utf8)
        ).combined
    }

    static func open(_ sealed: Data, pairKey: String, field: String) throws -> String {
        guard let box = try? ChaChaPoly.SealedBox(combined: sealed) else {
            throw Failure.malformedSealedBox
        }
        guard let plaintext = try? ChaChaPoly.open(
            box,
            using: key(for: pairKey),
            authenticating: Data(field.utf8)
        ) else {
            throw Failure.authenticationFailed
        }
        guard let text = String(data: plaintext, encoding: .utf8) else {
            throw Failure.notUTF8
        }
        return text
    }

    /// The shape read boundaries actually want. Anyone can write into a record, so a
    /// field that does not open is the expected case rather than an error to surface —
    /// it means someone without the key wrote it, and the caller should fall back to a
    /// placeholder exactly as it would for a missing field.
    static func opened(_ sealed: Data?, pairKey: String, field: String) -> String? {
        guard let sealed else { return nil }
        return try? open(sealed, pairKey: pairKey, field: field)
    }

    /// Keyed on the pair key's *string* form rather than its decoded bytes, because there
    /// is no single decoded form: `PairingInvite.generate` emits 22 characters of
    /// base64url normally, but 64 hex characters when `SecRandomCopyBytes` fails. The
    /// string is the only representation both devices are guaranteed to agree on.
    ///
    /// Derived per call rather than cached. This is two HMACs, unlike the detector in
    /// `UntrustedText`, and a cache would have to be safe to share across the app, the
    /// extension and the watch for no measurable gain.
    private static func key(for pairKey: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(pairKey.utf8)),
            salt: salt,
            info: info,
            outputByteCount: 32
        )
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
