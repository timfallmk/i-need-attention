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
        XCTAssertTrue(first.hasPrefix(InboxZone.namePrefix))
        XCTAssertEqual(InboxZone.currentName, first)
    }

    func testRotateMintsAFreshNameAndPersistsIt() {
        let before = InboxZone.currentName
        let minted = InboxZone.rotate()

        XCTAssertNotEqual(minted, before)
        XCTAssertEqual(InboxZone.currentName, minted)
        XCTAssertTrue(minted.hasPrefix(InboxZone.namePrefix))
    }

    /// Successive pairings must never collide: a reused name is a reused zone, which is
    /// the leak per-pairing zones exist to close.
    func testEachRotationIsDistinct() {
        let first = InboxZone.rotate()
        let second = InboxZone.rotate()

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(InboxZone.currentName, second)
    }

    // MARK: - Discovery: asking without minting, and taking over what is found

    /// `storedName` exists so a device can ask "do I own a zone?" without the asking
    /// making it true. A device whose pair key has not synced yet must get "no" here
    /// rather than silently becoming the owner of a second zone — which is #68.
    func testStoredNameDoesNotMint() {
        XCTAssertNil(InboxZone.storedName)
        XCTAssertNil(InboxZone.storedName)
        XCTAssertFalse(InboxZone.isMinted)
    }

    func testStoredNameReportsWhatCurrentNameMinted() {
        let minted = InboxZone.currentName
        XCTAssertEqual(InboxZone.storedName, minted)
    }

    // MARK: - The App Group copy the extension reads

    /// The NSE cannot read this process's `UserDefaults`, so the App Group copy is the
    /// only thing its zone filter can consult — and that filter fails open, which means
    /// a missing copy costs the protection without costing a banner. Invisible, in other
    /// words, which is why it is asserted rather than assumed.
    func testMintingPublishesTheNameToTheAppGroup() {
        let minted = InboxZone.currentName
        XCTAssertEqual(SharedSettings.inboxZoneName, minted)
    }

    func testAdoptingPublishesTheNameToTheAppGroup() {
        let discovered = InboxZone.namePrefix + "99999999-8888-7777-6666-555555555555"
        InboxZone.adopt(discovered)
        XCTAssertEqual(SharedSettings.inboxZoneName, discovered)
    }

    /// The case that made this worth a test: an install paired before 2.2.0 has a name in
    /// `UserDefaults` and nothing in the App Group, because minting, adopting and
    /// clearing are the only writers and an upgrade runs none of them. Reading the name
    /// has to be enough to repair that, or the filter never engages for an existing
    /// install.
    func testReadingTheNameRepairsAnAppGroupCopyThatWasNeverWritten() {
        let minted = InboxZone.currentName
        SharedSettings.inboxZoneName = nil

        XCTAssertEqual(InboxZone.storedName, minted)
        XCTAssertEqual(SharedSettings.inboxZoneName, minted)

        SharedSettings.inboxZoneName = nil
        XCTAssertEqual(InboxZone.currentName, minted)
        XCTAssertEqual(SharedSettings.inboxZoneName, minted)
    }

    /// Reads mirror a name, never the absence of one: blanking the extension's copy is
    /// `clear()`'s job, and a read path that could do it would be a new way to lose the
    /// filter rather than a way to keep it.
    func testReadingNoNameLeavesTheAppGroupCopyAlone() {
        let stale = InboxZone.namePrefix + "00000000-0000-4000-8000-000000000000"
        InboxZone.clear()
        SharedSettings.inboxZoneName = stale

        XCTAssertNil(InboxZone.storedName)
        XCTAssertEqual(SharedSettings.inboxZoneName, stale)
    }

    func testClearingRemovesTheAppGroupCopy() {
        _ = InboxZone.currentName
        InboxZone.clear()
        XCTAssertNil(SharedSettings.inboxZoneName)
    }

    /// Adoption is how a second device on one Apple Account stops minting a rival: the
    /// name comes from a zone the account already owns rather than from here.
    func testAdoptPersistsAndIsWhatEverythingElseReads() {
        let discovered = InboxZone.namePrefix + "11111111-2222-3333-4444-555555555555"
        InboxZone.adopt(discovered)

        XCTAssertEqual(InboxZone.storedName, discovered)
        XCTAssertEqual(InboxZone.currentName, discovered)
        XCTAssertTrue(InboxZone.isMinted)
    }

    /// A name minted before the pair key arrived is replaced wholesale, not kept
    /// alongside: its zone was never created, so there is nothing to lose.
    func testAdoptReplacesAPreviouslyMintedName() {
        let minted = InboxZone.currentName
        let discovered = InboxZone.namePrefix + "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        InboxZone.adopt(discovered)

        XCTAssertNotEqual(discovered, minted)
        XCTAssertEqual(InboxZone.storedName, discovered)
    }

    /// Discovery filters an account's zones by this prefix, so every name this app can
    /// put into `UserDefaults` has to carry it — a rotated one as much as a first mint.
    func testEveryNameThisAppMintsIsDiscoverable() {
        for _ in 0..<8 {
            XCTAssertTrue(InboxZone.rotate().hasPrefix(InboxZone.namePrefix))
        }
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
