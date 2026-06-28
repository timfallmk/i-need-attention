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

        // The Unicode License requires the full copyright + permission notice to
        // travel with the data. Assert a key phrase from every paragraph of the
        // notice so dropping or mangling any whole block (heading, copyright,
        // NOTICE TO USER, permission grant, the (a)/(b) condition, the warranty
        // disclaimer, the liability block, or the trademark clause) fails the
        // test. The copyright line is matched without pinning the end year, which
        // Unicode bumps annually, so the guard doesn't churn every January.
        let requiredFragments = [
            "UNICODE LICENSE V3",
            "COPYRIGHT AND PERMISSION NOTICE",
            "Copyright © 1991-",
            "Unicode, Inc.",
            "NOTICE TO USER: Carefully read the following legal agreement.",
            "Permission is hereby granted, free of charge",
            "this copyright and permission notice appear with all copies",
            "THE DATA FILES AND SOFTWARE ARE PROVIDED \"AS IS\"",
            "NONINFRINGEMENT OF",
            "IN NO EVENT SHALL THE COPYRIGHT HOLDER",
            "Except as contained in this notice, the name of a copyright holder",
        ]
        for fragment in requiredFragments {
            XCTAssertTrue(
                unicode.licenseText.contains(fragment),
                "Unicode notice is missing required text: \(fragment)"
            )
        }
    }
}
