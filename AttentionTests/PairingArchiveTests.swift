import XCTest

final class PairingArchiveTests: XCTestCase {

    override func setUp() {
        super.setUp()
        PairingArchive.clear()
        InboxZone.clear()
    }

    override func tearDown() {
        PairingArchive.clear()
        InboxZone.clear()
        super.tearDown()
    }

    private func row(_ recordName: String, createdAt: Date = Date(), state: Constants.AlertState = .sent) -> AlertRecord {
        var archived = ArchivedAlert(.preview(state: state))
        archived.recordName = recordName
        archived.createdAt = createdAt
        return AlertRecord(archived: archived)
    }

    // MARK: - Persistence

    func testLoadReturnsEmptyArchiveWhenNothingSaved() {
        XCTAssertTrue(PairingArchive.load().pairings.isEmpty)
    }

    func testAbsorbCreatesAPairingAndRoundTrips() {
        PairingArchive.absorb([row("a"), row("b")], pairingID: "zone-1", partnerName: "Bob")

        let loaded = PairingArchive.load()
        XCTAssertEqual(loaded.pairings.count, 1)
        XCTAssertEqual(loaded.pairings.first?.id, "zone-1")
        XCTAssertEqual(loaded.pairings.first?.partnerName, "Bob")
        XCTAssertEqual(loaded.pairings.first?.alerts.count, 2)
    }

    func testAbsorbIsIdempotentByRecordName() {
        PairingArchive.absorb([row("a")], pairingID: "zone-1", partnerName: "Bob")
        PairingArchive.absorb([row("a")], pairingID: "zone-1", partnerName: "Bob")

        XCTAssertEqual(PairingArchive.load().pairings.first?.alerts.count, 1)
    }

    /// A re-fetched alert may have gained an acknowledgement since the copy we hold.
    func testAbsorbTakesTheNewerCopyOfAnExistingRow() {
        PairingArchive.absorb([row("a", state: .sent)], pairingID: "zone-1", partnerName: "Bob")
        PairingArchive.absorb([row("a", state: .acknowledged)], pairingID: "zone-1", partnerName: "Bob")

        let alerts = PairingArchive.load().pairings.first?.alerts
        XCTAssertEqual(alerts?.count, 1)
        XCTAssertEqual(alerts?.first?.state, Constants.AlertState.acknowledged.rawValue)
    }

    func testAbsorbKeepsPairingsSeparate() {
        PairingArchive.absorb([row("a")], pairingID: "zone-1", partnerName: "Bob")
        PairingArchive.absorb([row("b")], pairingID: "zone-2", partnerName: "Carol")

        let loaded = PairingArchive.load()
        XCTAssertEqual(loaded.pairings.count, 2)
        XCTAssertEqual(Set(loaded.pairings.map(\.partnerName)), ["Bob", "Carol"])
        XCTAssertEqual(loaded.pairings.first { $0.id == "zone-1" }?.alerts.map(\.recordName), ["a"])
        XCTAssertEqual(loaded.pairings.first { $0.id == "zone-2" }?.alerts.map(\.recordName), ["b"])
    }

    func testAbsorbPicksUpARename() {
        PairingArchive.absorb([row("a")], pairingID: "zone-1", partnerName: "Bob")
        PairingArchive.absorb([row("b")], pairingID: "zone-1", partnerName: "Robert")

        XCTAssertEqual(PairingArchive.load().pairings.first?.partnerName, "Robert")
    }

    func testAbsorbIgnoresAnEmptyFetchForAnUnknownPairing() {
        PairingArchive.absorb([], pairingID: "zone-1", partnerName: "Bob")
        XCTAssertTrue(PairingArchive.load().pairings.isEmpty)
    }

    func testAlertsAreStoredNewestFirst() {
        let old = Date(timeIntervalSince1970: 1_000)
        let recent = Date(timeIntervalSince1970: 2_000)
        PairingArchive.absorb([row("old", createdAt: old), row("recent", createdAt: recent)],
                              pairingID: "zone-1", partnerName: "Bob")

        XCTAssertEqual(PairingArchive.load().pairings.first?.alerts.map(\.recordName), ["recent", "old"])
    }

    func testStartedAtTracksTheEarliestAlert() {
        let recent = Date(timeIntervalSince1970: 2_000)
        let old = Date(timeIntervalSince1970: 1_000)
        PairingArchive.absorb([row("recent", createdAt: recent)], pairingID: "zone-1", partnerName: "Bob")
        PairingArchive.absorb([row("old", createdAt: old)], pairingID: "zone-1", partnerName: "Bob")

        XCTAssertEqual(PairingArchive.load().pairings.first?.startedAt, old)
    }

    // MARK: - Emptiness

    /// Drives whether Settings offers a History row on an unpaired device. Reporting
    /// empty when a pairing has been archived hides the archive from the one state it
    /// exists to serve.
    func testIsEmptyOnAFreshInstall() {
        XCTAssertTrue(PairingArchive.isEmpty)
    }

    func testIsNotEmptyOnceAPairingIsArchived() {
        PairingArchive.absorb([row("a")], pairingID: "zone-1", partnerName: "Bob")
        XCTAssertFalse(PairingArchive.isEmpty)
    }

    func testStaysNonEmptyAfterThePairingIsClosed() {
        PairingArchive.absorb([row("a")], pairingID: "zone-1", partnerName: "Bob")
        PairingArchive.close(pairingID: "zone-1")
        XCTAssertFalse(PairingArchive.isEmpty)
    }

    // MARK: - Closing

    func testCloseStampsAnEndDate() {
        PairingArchive.absorb([row("a")], pairingID: "zone-1", partnerName: "Bob")
        PairingArchive.close(pairingID: "zone-1", at: Date(timeIntervalSince1970: 5_000))

        XCTAssertEqual(PairingArchive.load().pairings.first?.endedAt, Date(timeIntervalSince1970: 5_000))
        XCTAssertEqual(PairingArchive.load().pairings.first?.isOpen, false)
    }

    func testCloseIsIdempotent() {
        PairingArchive.absorb([row("a")], pairingID: "zone-1", partnerName: "Bob")
        PairingArchive.close(pairingID: "zone-1", at: Date(timeIntervalSince1970: 5_000))
        PairingArchive.close(pairingID: "zone-1", at: Date(timeIntervalSince1970: 9_000))

        XCTAssertEqual(PairingArchive.load().pairings.first?.endedAt, Date(timeIntervalSince1970: 5_000))
    }

    /// Rows survive an unpair — that is the whole reason the archive exists.
    func testClosingKeepsTheRows() {
        PairingArchive.absorb([row("a"), row("b")], pairingID: "zone-1", partnerName: "Bob")
        PairingArchive.close(pairingID: "zone-1")

        XCTAssertEqual(PairingArchive.load().pairings.first?.alerts.count, 2)
    }

    func testCloseOnAnUnknownPairingDoesNothing() {
        PairingArchive.close(pairingID: "never-existed")
        XCTAssertTrue(PairingArchive.load().pairings.isEmpty)
    }
}

final class InboxZoneTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // `PairState.save()` writes the pair key to the keychain; the in-memory store is
        // what keeps these tests off the real one and independent of run order.
        PairSecrets.store = InMemoryPairSecretStore()
        InboxZone.clear()
        PairState.clear()
    }

    override func tearDown() {
        InboxZone.clear()
        PairState.clear()
        PairSecrets.store = InMemoryPairSecretStore()
        super.tearDown()
    }

    private func storePairing() {
        PairState(
            pairKey: "test-pair-key",
            myDeviceID: "device-A",
            myName: "Alice",
            partnerDeviceID: "device-B",
            partnerName: "Bob"
        ).save()
    }

    func testNoNameExistsUntilOneIsAskedFor() {
        XCTAssertFalse(InboxZone.isMinted)
    }

    /// There is no fixed fallback name — a name only ever comes into existence by being
    /// minted, so there is no second path by which two pairings could share a zone.
    func testCurrentNameMintsOnFirstUseAndPersists() {
        let first = InboxZone.currentName

        XCTAssertTrue(InboxZone.isMinted)
        XCTAssertTrue(first.hasPrefix("attention-inbox-"))
        XCTAssertEqual(InboxZone.currentName, first)
    }

    func testRotateMintsAFreshNameAndPersistsIt() {
        let before = InboxZone.currentName
        let minted = InboxZone.rotate()

        XCTAssertNotEqual(minted, before)
        XCTAssertEqual(InboxZone.currentName, minted)
        XCTAssertTrue(minted.hasPrefix("attention-inbox-"))
    }

    /// Successive pairings must never collide: a reused name is a reused zone, which is
    /// the leak per-pairing zones exist to close.
    func testEachRotationIsDistinct() {
        let first = InboxZone.rotate()
        let second = InboxZone.rotate()

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(InboxZone.currentName, second)
    }

    // MARK: - Resetting a pairing that predates per-pairing zones

    func testResetEndsAPairingMadeBeforeZonesWerePerPairing() {
        storePairing()
        XCTAssertNotNil(PairState.load())

        InboxZone.resetPairingPredatingPerPairingZones()

        XCTAssertNil(PairState.load())
        XCTAssertTrue(InboxZone.isMinted)
    }

    func testResetLeavesAPairingMadeUnderAMintedZoneAlone() {
        InboxZone.rotate()
        storePairing()

        InboxZone.resetPairingPredatingPerPairingZones()

        XCTAssertNotNil(PairState.load())
    }

    func testResetDoesNothingOnAFreshInstall() {
        InboxZone.resetPairingPredatingPerPairingZones()
        XCTAssertFalse(InboxZone.isMinted)
    }
}
