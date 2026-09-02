import XCTest

final class PairingInviteTests: XCTestCase {

    private let shareURL = URL(string: "https://www.icloud.com/share/0ABCdef")!
    private var share: String { shareURL.absoluteString }

    private func makeInvite(pairKey: String = "key123",
                            deviceID: String = "dev456",
                            name: String = "Alice") -> PairingInvite {
        PairingInvite(pairKey: pairKey, inviterDeviceID: deviceID, inviterName: name, shareURL: shareURL)
    }

    // MARK: - qrPayload structure (parsed via URLComponents)

    private func components(for invite: PairingInvite) -> URLComponents? {
        guard let url = URL(string: invite.qrPayload) else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)
    }

    private func queryValue(_ name: String, in invite: PairingInvite) -> String? {
        components(for: invite)?.queryItems?.first(where: { $0.name == name })?.value
    }

    func testQRPayloadUsesAttentionScheme() {
        let invite = makeInvite()
        XCTAssertEqual(components(for: invite)?.scheme, "attention")
    }

    func testQRPayloadUsesHostPair() {
        let invite = makeInvite()
        XCTAssertEqual(components(for: invite)?.host, "pair")
    }

    func testQRPayloadContainsPairKey() {
        let invite = makeInvite(pairKey: "abc-key", deviceID: "dev", name: "Me")
        XCTAssertEqual(queryValue("k", in: invite), "abc-key")
    }

    func testQRPayloadContainsDeviceID() {
        let invite = makeInvite(pairKey: "k", deviceID: "device-99", name: "Me")
        XCTAssertEqual(queryValue("id", in: invite), "device-99")
    }

    func testQRPayloadContainsName() {
        let invite = makeInvite(pairKey: "k", deviceID: "d", name: "Charlie")
        XCTAssertEqual(queryValue("n", in: invite), "Charlie")
    }

    // MARK: - from(qrPayload:) — happy path

    func testRoundTripParsing() {
        let original = makeInvite(pairKey: "roundtrip-key", deviceID: "device-A", name: "Bob")
        let parsed = PairingInvite.from(qrPayload: original.qrPayload)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.pairKey, original.pairKey)
        XCTAssertEqual(parsed?.inviterDeviceID, original.inviterDeviceID)
        XCTAssertEqual(parsed?.inviterName, original.inviterName)
    }

    func testParsingWithSpecialCharactersInName() {
        let invite = makeInvite(pairKey: "k", deviceID: "d", name: "O'Brien")
        let parsed = PairingInvite.from(qrPayload: invite.qrPayload)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.inviterName, "O'Brien")
    }

    // MARK: - from(qrPayload:) — missing name defaults to "Friend"

    func testMissingNameDefaultsToFriend() {
        let payload = "attention://pair?k=somekey&id=somedevice&s=\(share)"
        let parsed = PairingInvite.from(qrPayload: payload)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.inviterName, "Friend")
    }

    // MARK: - from(qrPayload:) — required fields

    func testMissingKeyReturnsNil() {
        let payload = "attention://pair?id=device&n=Alice&s=\(share)"
        XCTAssertNil(PairingInvite.from(qrPayload: payload))
    }

    func testMissingDeviceIDReturnsNil() {
        let payload = "attention://pair?k=somekey&n=Alice&s=\(share)"
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
        let payload = "https://pair?k=somekey&id=device&s=\(share)"
        XCTAssertNil(PairingInvite.from(qrPayload: payload))
    }

    func testWrongHostReturnsNil() {
        let payload = "attention://notpair?k=somekey&id=device&s=\(share)"
        XCTAssertNil(PairingInvite.from(qrPayload: payload))
    }

    func testNoSchemeReturnsNil() {
        let payload = "pair?k=somekey&id=device&s=\(share)"
        XCTAssertNil(PairingInvite.from(qrPayload: payload))
    }

    // MARK: - from(qrPayload:) — untrusted input: duplicate keys take first value

    func testDuplicatePairKeyUsesFirst() {
        let payload = "attention://pair?k=first&k=second&id=device&s=\(share)"
        let parsed = PairingInvite.from(qrPayload: payload)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.pairKey, "first")
    }

    func testDuplicateDeviceIDUsesFirst() {
        let payload = "attention://pair?k=somekey&id=first-device&id=second-device&s=\(share)"
        let parsed = PairingInvite.from(qrPayload: payload)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.inviterDeviceID, "first-device")
    }

    func testDuplicateNameUsesFirst() {
        let payload = "attention://pair?k=somekey&id=device&n=Alice&n=Bob&s=\(share)"
        let parsed = PairingInvite.from(qrPayload: payload)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.inviterName, "Alice")
    }

    // MARK: - generate

    func testGenerateProducesNonEmptyPairKey() {
        let invite = PairingInvite.generate(myDeviceID: "my-device", myName: "Me", shareURL: shareURL)
        XCTAssertFalse(invite.pairKey.isEmpty)
    }

    func testGenerateSetsDeviceID() {
        let invite = PairingInvite.generate(myDeviceID: "device-xyz", myName: "Me", shareURL: shareURL)
        XCTAssertEqual(invite.inviterDeviceID, "device-xyz")
    }

    func testGenerateSetsName() {
        let invite = PairingInvite.generate(myDeviceID: "d", myName: "TestUser", shareURL: shareURL)
        XCTAssertEqual(invite.inviterName, "TestUser")
    }

    func testGenerateProducesParseablePayload() {
        let invite = PairingInvite.generate(myDeviceID: "device-123", myName: "Alice", shareURL: shareURL)
        let parsed = PairingInvite.from(qrPayload: invite.qrPayload)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.pairKey, invite.pairKey)
        XCTAssertEqual(parsed?.inviterDeviceID, invite.inviterDeviceID)
        XCTAssertEqual(parsed?.inviterName, invite.inviterName)
    }

    func testGenerateProducesUniquePairKeys() {
        let a = PairingInvite.generate(myDeviceID: "d", myName: "Me", shareURL: shareURL)
        let b = PairingInvite.generate(myDeviceID: "d", myName: "Me", shareURL: shareURL)
        XCTAssertNotEqual(a.pairKey, b.pairKey)
    }

    // MARK: - from(qrPayload:) — the share URL is untrusted input

    func testPayloadCarriesTheShareURL() {
        XCTAssertEqual(queryValue("s", in: makeInvite()), share)
    }

    func testShareURLRoundTrips() {
        XCTAssertEqual(PairingInvite.from(qrPayload: makeInvite().qrPayload)?.shareURL, shareURL)
    }

    func testMissingShareURLReturnsNil() {
        XCTAssertNil(PairingInvite.from(qrPayload: "attention://pair?k=somekey&id=device"))
    }

    func testNonCloudKitShareURLReturnsNil() {
        let payload = "attention://pair?k=somekey&id=device&s=https://evil.example/share/abc"
        XCTAssertNil(PairingInvite.from(qrPayload: payload))
    }

    func testHTTPShareURLReturnsNil() {
        let payload = "attention://pair?k=somekey&id=device&s=http://www.icloud.com/share/abc"
        XCTAssertNil(PairingInvite.from(qrPayload: payload))
    }

    func testLookalikeShareHostReturnsNil() {
        let payload = "attention://pair?k=somekey&id=device&s=https://icloud.com.evil.example/share/abc"
        XCTAssertNil(PairingInvite.from(qrPayload: payload))
    }

    func testBareICloudShareHostIsAccepted() {
        let payload = "attention://pair?k=somekey&id=device&s=https://icloud.com/share/abc"
        XCTAssertNotNil(PairingInvite.from(qrPayload: payload))
    }
}
