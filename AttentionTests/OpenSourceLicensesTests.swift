import XCTest

final class OpenSourceLicensesTests: XCTestCase {

    func testManifestIsNotEmpty() {
        XCTAssertFalse(OpenSourceLicenses.all.isEmpty)
    }

    func testEveryComponentHasNameSummaryAndLicense() {
        for component in OpenSourceLicenses.all {
            XCTAssertFalse(component.name.isEmpty, "component name must not be empty")
            XCTAssertFalse(component.summary.isEmpty, "\(component.name) summary must not be empty")
            XCTAssertFalse(component.licenseName.isEmpty, "\(component.name) license name must not be empty")
            XCTAssertFalse(component.licenseText.isEmpty, "\(component.name) license text must not be empty")
        }
    }

    func testIdentifiersAreUnique() {
        let ids = OpenSourceLicenses.all.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "component ids must be unique")
    }

    func testUnicodeEmojiAttributionIsPresentAndIntact() {
        let unicode = OpenSourceLicenses.unicodeEmojiData
        XCTAssertTrue(OpenSourceLicenses.all.contains { $0.id == unicode.id })
        // The Unicode License requires the copyright + permission notice to
        // travel with the data; assert the load-bearing fragments survive edits.
        XCTAssertTrue(unicode.licenseText.contains("Copyright © 1991-2025 Unicode, Inc."))
        XCTAssertTrue(unicode.licenseText.contains("Permission is hereby granted"))
        XCTAssertTrue(unicode.licenseText.contains("this copyright and permission notice appear"))
    }
}
