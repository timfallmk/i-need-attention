import Foundation
import XCTest

final class PairCryptoTests: XCTestCase {
    /// The shape `PairingInvite.generate` produces normally: 16 random bytes, base64url.
    private let keyA = "3q2-7wAAAAAAAAAAAAAAAA"
    private let keyB = "d3JvbmdrZXl3cm9uZ2tleQ"
    /// The shape it produces when SecRandomCopyBytes fails: two UUIDs, dashes stripped.
    private let fallbackShapedKey = "550E8400E29B41D4A716446655440000550E8400E29B41D4A716446655440001"

    private let field = "message"

    // MARK: - Round trip

    func testRoundTrip() throws {
        let sealed = try PairCrypto.seal("needs attention", pairKey: keyA, field: field)
        XCTAssertEqual(try PairCrypto.open(sealed, pairKey: keyA, field: field), "needs attention")
    }

    func testRoundTripPreservesUnicodeAndEmoji() throws {
        let text = "needs \u{1F917} attention \u{2014} caf\u{E9} \u{4F60}\u{597D}"
        let sealed = try PairCrypto.seal(text, pairKey: keyA, field: field)
        XCTAssertEqual(try PairCrypto.open(sealed, pairKey: keyA, field: field), text)
    }

    func testRoundTripOfEmptyString() throws {
        let sealed = try PairCrypto.seal("", pairKey: keyA, field: field)
        XCTAssertEqual(try PairCrypto.open(sealed, pairKey: keyA, field: field), "")
    }

    func testWorksWithTheFallbackPairKeyShape() throws {
        // The key derivation reads the pair key as a string precisely so this shape works.
        let sealed = try PairCrypto.seal("hello", pairKey: fallbackShapedKey, field: field)
        XCTAssertEqual(try PairCrypto.open(sealed, pairKey: fallbackShapedKey, field: field), "hello")
    }

    func testCiphertextDoesNotContainThePlaintext() throws {
        let text = "needs attention"
        let sealed = try PairCrypto.seal(text, pairKey: keyA, field: field)
        XCTAssertNil(sealed.range(of: Data(text.utf8)))
    }

    // MARK: - Nonce

    func testSealingTwiceProducesDifferentCiphertext() throws {
        // A fresh nonce per seal, so identical presses don't produce identical records.
        let first = try PairCrypto.seal("needs attention", pairKey: keyA, field: field)
        let second = try PairCrypto.seal("needs attention", pairKey: keyA, field: field)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try PairCrypto.open(first, pairKey: keyA, field: field), "needs attention")
        XCTAssertEqual(try PairCrypto.open(second, pairKey: keyA, field: field), "needs attention")
    }

    // MARK: - Rejection

    func testWrongPairKeyFails() throws {
        let sealed = try PairCrypto.seal("needs attention", pairKey: keyA, field: field)
        XCTAssertThrowsError(try PairCrypto.open(sealed, pairKey: keyB, field: field)) { error in
            XCTAssertEqual(error as? PairCrypto.Failure, .authenticationFailed)
        }
    }

    func testCiphertextCannotBeMovedToAnotherField() throws {
        // Without the field as authenticated data, a sealed senderName could be pasted
        // into the message field of the same record and would still open.
        let sealed = try PairCrypto.seal("Tim", pairKey: keyA, field: "senderName")
        XCTAssertThrowsError(try PairCrypto.open(sealed, pairKey: keyA, field: "message")) { error in
            XCTAssertEqual(error as? PairCrypto.Failure, .authenticationFailed)
        }
    }

    func testTamperedCiphertextFails() throws {
        let sealed = try PairCrypto.seal("needs attention", pairKey: keyA, field: field)
        var bytes = [UInt8](sealed)
        bytes[bytes.count - 1] ^= 0xFF
        let tampered = Data(bytes)
        XCTAssertThrowsError(try PairCrypto.open(tampered, pairKey: keyA, field: field)) { error in
            XCTAssertEqual(error as? PairCrypto.Failure, .authenticationFailed)
        }
    }

    func testGarbageBytesAreRejectedAsMalformed() {
        // What a stranger writing junk into the field actually looks like.
        let junk = Data([0x00, 0x01, 0x02])
        XCTAssertThrowsError(try PairCrypto.open(junk, pairKey: keyA, field: field)) { error in
            XCTAssertEqual(error as? PairCrypto.Failure, .malformedSealedBox)
        }
    }

    // MARK: - opened()

    func testOpenedReturnsNilInsteadOfThrowing() throws {
        let sealed = try PairCrypto.seal("needs attention", pairKey: keyA, field: field)
        XCTAssertNil(PairCrypto.opened(sealed, pairKey: keyB, field: field))
        XCTAssertNil(PairCrypto.opened(Data([0x00]), pairKey: keyA, field: field))
    }

    func testOpenedReturnsNilForNil() {
        XCTAssertNil(PairCrypto.opened(nil, pairKey: keyA, field: field))
    }

    func testOpenedReturnsTheTextWhenItOpens() throws {
        let sealed = try PairCrypto.seal("needs attention", pairKey: keyA, field: field)
        XCTAssertEqual(PairCrypto.opened(sealed, pairKey: keyA, field: field), "needs attention")
    }

    // MARK: - Lookup hash

    func testLookupHashIsDeterministic() {
        XCTAssertEqual(PairCrypto.lookupHash(pairKey: keyA), PairCrypto.lookupHash(pairKey: keyA))
    }

    func testLookupHashDiffersPerPairKey() {
        XCTAssertNotEqual(PairCrypto.lookupHash(pairKey: keyA), PairCrypto.lookupHash(pairKey: keyB))
    }

    func testLookupHashDoesNotLeakThePairKey() {
        let hash = PairCrypto.lookupHash(pairKey: keyA)
        XCTAssertFalse(hash.contains(keyA))
    }

    func testLookupHashIsURLSafeAndUnpadded() {
        // It travels in predicates and logs; keep it to an unambiguous alphabet.
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        let hash = PairCrypto.lookupHash(pairKey: keyA)
        XCTAssertFalse(hash.isEmpty)
        XCTAssertTrue(hash.unicodeScalars.allSatisfy { allowed.contains($0) })
        XCTAssertEqual(hash.count, 43) // 32 bytes of SHA-256, base64, padding stripped
    }
}
