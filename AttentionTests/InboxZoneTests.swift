import XCTest

final class InboxZoneTests: XCTestCase {

    private var saved: String?

    override func setUp() {
        super.setUp()
        saved = InboxZone.storedName
        InboxZone.clear()
    }

    override func tearDown() {
        if let saved {
            InboxZone.adopt(saved)
        } else {
            InboxZone.clear()
        }
        saved = nil
        super.tearDown()
    }

    /// `storedName` exists so a device can ask "do I own a zone?" without the asking
    /// making it true. `currentName` mints; this must not.
    func testStoredNameDoesNotMint() {
        XCTAssertNil(InboxZone.storedName)
        XCTAssertNil(InboxZone.storedName)
        XCTAssertFalse(InboxZone.isMinted)
    }

    func testCurrentNameMintsUnderThePrefix() {
        let name = InboxZone.currentName
        XCTAssertTrue(name.hasPrefix(InboxZone.namePrefix))
        XCTAssertEqual(InboxZone.storedName, name)
        XCTAssertTrue(InboxZone.isMinted)
    }

    func testCurrentNameIsStableOnceMinted() {
        let first = InboxZone.currentName
        XCTAssertEqual(InboxZone.currentName, first)
    }

    func testAdoptPersistsAndIsWhatEverythingElseReads() {
        let discovered = InboxZone.namePrefix + "11111111-2222-3333-4444-555555555555"
        InboxZone.adopt(discovered)

        XCTAssertEqual(InboxZone.storedName, discovered)
        XCTAssertEqual(InboxZone.currentName, discovered)
        XCTAssertTrue(InboxZone.isMinted)
    }

    /// Adoption is how a second device stops minting a rival: a name is already stored
    /// (minted before the pair key synced, say) and discovery replaces it wholesale.
    func testAdoptReplacesAPreviouslyMintedName() {
        let minted = InboxZone.currentName
        let discovered = InboxZone.namePrefix + "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        InboxZone.adopt(discovered)

        XCTAssertNotEqual(discovered, minted)
        XCTAssertEqual(InboxZone.storedName, discovered)
    }

    func testRotateMintsSomethingNewUnderThePrefix() {
        let first = InboxZone.currentName
        let second = InboxZone.rotate()

        XCTAssertNotEqual(second, first)
        XCTAssertTrue(second.hasPrefix(InboxZone.namePrefix))
        XCTAssertEqual(InboxZone.storedName, second)
    }

    /// Discovery filters candidate zones by this prefix, so every name the app can put
    /// into `UserDefaults` has to carry it — a minted one and a rotated one alike.
    func testEveryMintedNameIsDiscoverable() {
        for _ in 0..<8 {
            XCTAssertTrue(InboxZone.rotate().hasPrefix(InboxZone.namePrefix))
        }
    }
}
