import XCTest

final class PairingInviteTests: XCTestCase {

    // MARK: - qrPayload format

    func testQRPayloadUsesAttentionScheme() {
        let invite = PairingInvite(pairKey: "key123", inviterDeviceID: "dev456", inviterName: "Alice")
        XCTAssertTrue(invite.qrPayload.hasPrefix("attention://"))
    }

    func testQRPayloadUsesHostPair() {
        let invite = PairingInvite(pairKey: "key123", inviterDeviceID: "dev456", inviterName: "Alice")
        XCTAssertTrue(invite.qrPayload.contains("attention://pair"))
    }

    func testQRPayloadContainsPairKey() {
        let invite = PairingInvite(pairKey: "abc-key", inviterDeviceID: "dev", inviterName: "Me")
        XCTAssertTrue(invite.qrPayload.contains("k=abc-key"))
    }

    func testQRPayloadContainsDeviceID() {
        let invite = PairingInvite(pairKey: "k", inviterDeviceID: "device-99", inviterName: "Me")
        XCTAssertTrue(invite.qrPayload.contains("id=device-99"))
    }

    func testQRPayloadContainsName() {
        let invite = PairingInvite(pairKey: "k", inviterDeviceID: "d", inviterName: "Charlie")
        XCTAssertTrue(invite.qrPayload.contains("n=Charlie"))
    }

    // MARK: - from(qrPayload:) — happy path

    func testRoundTripParsing() {
        let original = PairingInvite(pairKey: "roundtrip-key", inviterDeviceID: "device-A", inviterName: "Bob")
        let parsed = PairingInvite.from(qrPayload: original.qrPayload)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.pairKey, original.pairKey)
        XCTAssertEqual(parsed?.inviterDeviceID, original.inviterDeviceID)
        XCTAssertEqual(parsed?.inviterName, original.inviterName)
    }

    func testParsingWithSpecialCharactersInName() {
        let invite = PairingInvite(pairKey: "k", inviterDeviceID: "d", inviterName: "O'Brien")
        let parsed = PairingInvite.from(qrPayload: invite.qrPayload)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.inviterName, "O'Brien")
    }

    // MARK: - from(qrPayload:) — missing name defaults to "Friend"

    func testMissingNameDefaultsToFriend() {
        let payload = "attention://pair?k=somekey&id=somedevice"
        let parsed = PairingInvite.from(qrPayload: payload)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.inviterName, "Friend")
    }

    // MARK: - from(qrPayload:) — required fields

    func testMissingKeyReturnsNil() {
        let payload = "attention://pair?id=device&n=Alice"
        XCTAssertNil(PairingInvite.from(qrPayload: payload))
    }

    func testMissingDeviceIDReturnsNil() {
        let payload = "attention://pair?k=somekey&n=Alice"
        XCTAssertNil(PairingInvite.from(qrPayload: payload))
    }

    func testEmptyStringReturnsNil() {
        XCTAssertNil(PairingInvite.from(qrPayload: ""))
    }

    func testRandomStringReturnsNil() {
        XCTAssertNil(PairingInvite.from(qrPayload: "not a url at all"))
    }

    // MARK: - from(qrPayload:) — wrong scheme / host

    func testWrongSchemeReturnsNil() {
        let payload = "https://pair?k=somekey&id=device"
        XCTAssertNil(PairingInvite.from(qrPayload: payload))
    }

    func testWrongHostReturnsNil() {
        let payload = "attention://notpair?k=somekey&id=device"
        XCTAssertNil(PairingInvite.from(qrPayload: payload))
    }

    func testNoSchemeReturnsNil() {
        let payload = "pair?k=somekey&id=device"
        XCTAssertNil(PairingInvite.from(qrPayload: payload))
    }

    // MARK: - from(qrPayload:) — untrusted input: duplicate keys take first value

    func testDuplicatePairKeyUsesFirst() {
        let payload = "attention://pair?k=first&k=second&id=device"
        let parsed = PairingInvite.from(qrPayload: payload)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.pairKey, "first")
    }

    func testDuplicateDeviceIDUsesFirst() {
        let payload = "attention://pair?k=somekey&id=first-device&id=second-device"
        let parsed = PairingInvite.from(qrPayload: payload)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.inviterDeviceID, "first-device")
    }

    func testDuplicateNameUsesFirst() {
        let payload = "attention://pair?k=somekey&id=device&n=Alice&n=Bob"
        let parsed = PairingInvite.from(qrPayload: payload)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.inviterName, "Alice")
    }

    // MARK: - generate

    func testGenerateProducesNonEmptyPairKey() {
        let invite = PairingInvite.generate(myDeviceID: "my-device", myName: "Me")
        XCTAssertFalse(invite.pairKey.isEmpty)
    }

    func testGenerateSetsDeviceID() {
        let invite = PairingInvite.generate(myDeviceID: "device-xyz", myName: "Me")
        XCTAssertEqual(invite.inviterDeviceID, "device-xyz")
    }

    func testGenerateSetsName() {
        let invite = PairingInvite.generate(myDeviceID: "d", myName: "TestUser")
        XCTAssertEqual(invite.inviterName, "TestUser")
    }

    func testGenerateProducesParseablePayload() {
        let invite = PairingInvite.generate(myDeviceID: "device-123", myName: "Alice")
        let parsed = PairingInvite.from(qrPayload: invite.qrPayload)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.pairKey, invite.pairKey)
        XCTAssertEqual(parsed?.inviterDeviceID, invite.inviterDeviceID)
        XCTAssertEqual(parsed?.inviterName, invite.inviterName)
    }

    func testGenerateProducesUniquePairKeys() {
        let a = PairingInvite.generate(myDeviceID: "d", myName: "Me")
        let b = PairingInvite.generate(myDeviceID: "d", myName: "Me")
        XCTAssertNotEqual(a.pairKey, b.pairKey)
    }
}
