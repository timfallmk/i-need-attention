import XCTest

/// Behavioural coverage of `UserSettings`: it persists to `UserDefaults.standard` on each
/// `didSet` and mirrors the NSE-relevant toggles into the App Group (`SharedSettings`).
/// Tests are written against observable behaviour (a fresh instance re-reads persisted
/// values) so they don't need the type's private `Keys`.
final class UserSettingsTests: XCTestCase {

    private struct Baseline {
        var name: String
        var cooldown: Int
        var customSound: Bool
        var timeSensitive: Bool
        var ackBanners: Bool
        var acceptCritical: Bool
    }
    private var baseline: Baseline!

    override func setUp() {
        super.setUp()
        let s = UserSettings()
        baseline = Baseline(
            name: s.displayName, cooldown: s.cooldownSeconds,
            customSound: s.customSoundEnabled, timeSensitive: s.timeSensitiveEnabled,
            ackBanners: s.ackBannersEnabled, acceptCritical: s.acceptCriticalAlerts
        )
    }

    override func tearDown() {
        // Restore the pre-test values so these tests don't leak into UserDefaults.standard
        // or the App Group mirror (setting through UserSettings re-persists + re-mirrors).
        let s = UserSettings()
        s.displayName = baseline.name
        s.cooldownSeconds = baseline.cooldown
        s.customSoundEnabled = baseline.customSound
        s.timeSensitiveEnabled = baseline.timeSensitive
        s.ackBannersEnabled = baseline.ackBanners
        s.acceptCriticalAlerts = baseline.acceptCritical
        baseline = nil
        super.tearDown()
    }

    func testDisplayNamePersistsAcrossInstances() {
        let name = "Zephyr-\(UUID().uuidString.prefix(6))"
        let a = UserSettings()
        a.displayName = name
        XCTAssertEqual(UserSettings().displayName, name)
    }

    func testCooldownPersistsAcrossInstances() {
        let a = UserSettings()
        a.cooldownSeconds = 45
        XCTAssertEqual(UserSettings().cooldownSeconds, 45)
    }

    // MARK: - App Group mirroring

    func testCustomSoundMirrorsToSharedSettings() {
        let s = UserSettings()
        s.customSoundEnabled = false
        XCTAssertFalse(SharedSettings.customSoundEnabled)
        s.customSoundEnabled = true
        XCTAssertTrue(SharedSettings.customSoundEnabled)
    }

    func testTimeSensitiveMirrorsToSharedSettings() {
        let s = UserSettings()
        s.timeSensitiveEnabled = false
        XCTAssertFalse(SharedSettings.timeSensitiveEnabled)
        s.timeSensitiveEnabled = true
        XCTAssertTrue(SharedSettings.timeSensitiveEnabled)
    }

    func testAckBannersMirrorsToSharedSettings() {
        let s = UserSettings()
        s.ackBannersEnabled = false
        XCTAssertFalse(SharedSettings.ackBannersEnabled)
        s.ackBannersEnabled = true
        XCTAssertTrue(SharedSettings.ackBannersEnabled)
    }

    func testAcceptCriticalMirrorsToSharedSettings() {
        let s = UserSettings()
        s.acceptCriticalAlerts = true
        XCTAssertTrue(SharedSettings.acceptCriticalAlerts)
        s.acceptCriticalAlerts = false
        XCTAssertFalse(SharedSettings.acceptCriticalAlerts)
    }

    /// `init()` re-syncs persisted values to the App Group (so the NSE sees them even if it
    /// runs before any toggle is touched). Diverge the shared copy, then a fresh instance
    /// should overwrite it from `UserDefaults.standard`.
    func testInitReSyncsPersistedValueToSharedSettings() {
        let a = UserSettings()
        a.customSoundEnabled = false
        SharedSettings.customSoundEnabled = true   // diverge the shared copy
        _ = UserSettings()                          // init should re-mirror the persisted false
        XCTAssertFalse(SharedSettings.customSoundEnabled)
    }
}
