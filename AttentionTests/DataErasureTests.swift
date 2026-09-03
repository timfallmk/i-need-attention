import XCTest

/// The erase is a promise about a list of stores, so these tests are written against the
/// list: fill every one, erase, and assert each is empty. A store added later that nobody
/// remembers to erase fails here as soon as it is added to `fill()` — which is the only
/// place a reviewer has to look.
final class DataErasureTests: XCTestCase {

    private var secrets: InMemoryPairSecretStore!

    override func setUp() {
        super.setUp()
        secrets = InMemoryPairSecretStore()
        PairSecrets.store = secrets
        wipe()
    }

    override func tearDown() {
        wipe()
        PairSecrets.store = InMemoryPairSecretStore()
        secrets = nil
        super.tearDown()
    }

    private func wipe() {
        DataErasure.eraseLocalData(settings: UserSettings())
        InboxZone.clear()
    }

    /// Writes something to every store `eraseLocalData` names.
    private func fill() {
        XCTAssertTrue(
            PairState(
                pairKey: "live-key", myDeviceID: "A", myName: "Alice",
                partnerDeviceID: "B", partnerName: "Bob",
                outgoingZone: ZoneRef(zoneName: "z", ownerName: "o"), partnerCanReach: true
            ).save()
        )
        XCTAssertTrue(
            PendingInvite(
                pairKey: "invite-key", myDeviceID: "A", myName: "Alice",
                shareURL: URL(string: "https://www.icloud.com/share/abc")!, createdAt: Date()
            ).save()
        )
        CutoverNotice.needsRepair = true
        PartnerUnpairedNotice.happened = true
        DismissedOutgoing.recordName = "alert-1"

        UserDefaults.standard.set(Data("{}".utf8), forKey: LegacyPairing.storageKeyV1)
        UserDefaults.standard.set(Data("{}".utf8), forKey: LegacyPairing.storageKeyV2)
        LegacyHistoryCaptureState(phase: .pending).save()
        secrets.setSecret("old-key", for: Constants.Keychain.legacyHistoryKeyAccount)

        PairingArchive.absorb(
            [AlertRecord.preview(state: .acknowledged)], pairingID: "zone-1", partnerName: "Bob"
        )
        XCTAssertTrue(LegacyHistoryArchive(alerts: [], capturedAt: Date()).save())

        SnoozeState(recordName: "alert-1", until: Date().addingTimeInterval(600)).save()
        var metrics = MetricKitSummary.empty
        metrics.record(receivedAt: Date(), crashes: 1, hangs: 0,
                       diskWriteExceptions: 0, cpuExceptions: 0, crashReason: "test")
        metrics.save()

        SharedSettings.partnerName = "Bob"
    }

    func testEraseClearsEveryLocalStore() {
        fill()
        DataErasure.eraseLocalData(settings: UserSettings())

        XCTAssertNil(PairState.load())
        XCTAssertNil(PendingInvite.load())
        XCTAssertFalse(CutoverNotice.needsRepair)
        XCTAssertFalse(PartnerUnpairedNotice.happened)
        XCTAssertNil(DismissedOutgoing.recordName)

        XCTAssertFalse(LegacyPairing.exists)
        XCTAssertNil(LegacyHistoryCaptureState.load())
        XCTAssertNil(LegacyHistoryArchive.load())
        XCTAssertTrue(PairingArchive.isEmpty)

        XCTAssertNil(SnoozeState.load())
        XCTAssertNil(MetricKitSummary.load())
        XCTAssertNil(SharedSettings.partnerName)
    }

    /// Every key in the keychain, not just the live pairing's. The pre-2.0 key is stashed
    /// under its own account precisely so it can outlive a re-pair, which means clearing
    /// `PairState` alone leaves behind the one secret that still opens old records.
    func testEraseDropsEveryKeychainAccount() {
        fill()
        DataErasure.eraseLocalData(settings: UserSettings())

        XCTAssertNil(secrets.secret(for: Constants.Keychain.pairKeyAccount))
        XCTAssertNil(secrets.secret(for: Constants.Keychain.pendingInviteKeyAccount))
        XCTAssertNil(secrets.secret(for: Constants.Keychain.legacyHistoryKeyAccount))
    }

    func testEraseReturnsSettingsToTheirDefaults() {
        let settings = UserSettings()
        settings.displayName = "Alice"
        settings.acceptCriticalAlerts = true
        settings.customSoundEnabled = false
        settings.ackBannersEnabled = false
        settings.timeSensitiveEnabled = false
        settings.cooldownSeconds = 90

        DataErasure.eraseLocalData(settings: settings)

        XCTAssertEqual(settings.displayName, "")
        XCTAssertFalse(settings.acceptCriticalAlerts)
        XCTAssertTrue(settings.customSoundEnabled)
        XCTAssertTrue(settings.ackBannersEnabled)
        XCTAssertTrue(settings.timeSensitiveEnabled)
        XCTAssertEqual(settings.cooldownSeconds, 30)

        // A fresh read has to agree, or the erase only cleared the in-memory copy.
        let reloaded = UserSettings()
        XCTAssertEqual(reloaded.displayName, "")
        XCTAssertEqual(reloaded.cooldownSeconds, 30)
    }

    /// The device id is written into every record this phone sends, so leaving it in
    /// place would tie an erased phone to alerts still sitting in a partner's zone.
    func testEraseMintsANewDeviceIdentity() {
        let before = DeviceIdentity.id
        DeviceIdentity.name = "Alice's iPhone"

        DataErasure.eraseLocalData(settings: UserSettings())

        XCTAssertEqual(DeviceIdentity.name, "")
        XCTAssertNotEqual(DeviceIdentity.id, before)
    }

    /// Erasing twice, or erasing a phone that never paired, must not trap or resurrect
    /// anything — the button is reachable from an unpaired Settings screen.
    func testEraseIsIdempotentAndSafeOnAFreshInstall() {
        DataErasure.eraseLocalData(settings: UserSettings())
        DataErasure.eraseLocalData(settings: UserSettings())

        XCTAssertNil(PairState.load())
        XCTAssertTrue(PairingArchive.isEmpty)
    }
}
