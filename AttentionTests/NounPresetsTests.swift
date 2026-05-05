import XCTest

final class NounPresetsTests: XCTestCase {

    // MARK: - sanitize(_: String) — valid input

    func testSanitizeReturnsSameString() {
        XCTAssertEqual(NounPresets.sanitize("hugs"), "hugs")
    }

    func testSanitizeTrimsLeadingWhitespace() {
        XCTAssertEqual(NounPresets.sanitize("  hugs"), "hugs")
    }

    func testSanitizeTrimsTrailingWhitespace() {
        XCTAssertEqual(NounPresets.sanitize("hugs  "), "hugs")
    }

    func testSanitizeTrimsBothEnds() {
        XCTAssertEqual(NounPresets.sanitize("  hugs  "), "hugs")
    }

    func testSanitizeReplacesNewlineWithSpace() {
        XCTAssertEqual(NounPresets.sanitize("some\nattention"), "some attention")
    }

    func testSanitizeReplacesCarriageReturnWithSpace() {
        XCTAssertEqual(NounPresets.sanitize("some\rattention"), "some attention")
    }

    func testSanitizeReplacesBothNewlineTypes() {
        XCTAssertEqual(NounPresets.sanitize("a\nb\rc"), "a b c")
    }

    func testSanitizeExactlyMaxLengthPassesThrough() {
        let input = String(repeating: "x", count: NounPresets.maxLength)
        XCTAssertEqual(NounPresets.sanitize(input), input)
    }

    func testSanitizeTruncatesOneOverMaxLength() {
        let input = String(repeating: "y", count: NounPresets.maxLength + 1)
        let result = NounPresets.sanitize(input)
        XCTAssertEqual(result?.count, NounPresets.maxLength)
    }

    func testSanitizeTruncatesWellOverMaxLength() {
        let input = String(repeating: "z", count: NounPresets.maxLength * 3)
        let result = NounPresets.sanitize(input)
        XCTAssertEqual(result?.count, NounPresets.maxLength)
    }

    // MARK: - sanitize(_: String) — empty / whitespace → nil

    func testSanitizeEmptyStringReturnsNil() {
        XCTAssertNil(NounPresets.sanitize(""))
    }

    func testSanitizeWhitespaceOnlyReturnsNil() {
        XCTAssertNil(NounPresets.sanitize("   "))
    }

    func testSanitizeNewlineOnlyReturnsNil() {
        XCTAssertNil(NounPresets.sanitize("\n"))
    }

    func testSanitizeTabOnlyReturnsNil() {
        XCTAssertNil(NounPresets.sanitize("\t"))
    }

    // MARK: - nounForBody

    func testNounForBodyLowercasesFirstCharacter() {
        XCTAssertEqual(NounPresets.nounForBody("Hugs"), "hugs")
    }

    func testNounForBodyPreservesRestOfString() {
        XCTAssertEqual(NounPresets.nounForBody("Some of your time"), "some of your time")
    }

    func testNounForBodyAlreadyLowercaseIsUnchanged() {
        XCTAssertEqual(NounPresets.nounForBody("kisses"), "kisses")
    }

    func testNounForBodyEmptyStringIsUnchanged() {
        XCTAssertEqual(NounPresets.nounForBody(""), "")
    }

    func testNounForBodySingleUppercaseCharacter() {
        XCTAssertEqual(NounPresets.nounForBody("A"), "a")
    }

    func testNounForBodySingleLowercaseCharacter() {
        XCTAssertEqual(NounPresets.nounForBody("a"), "a")
    }

    func testNounForBodyDoesNotTouchInternalUppercase() {
        XCTAssertEqual(NounPresets.nounForBody("SomeThing"), "someThing")
    }

    // MARK: - maxLength constant

    func testMaxLengthIsPositive() {
        XCTAssertGreaterThan(NounPresets.maxLength, 0)
    }

    // MARK: - fallback list

    func testAllPresetsAreNonEmpty() {
        XCTAssertFalse(NounPresets.all.isEmpty, "NounPresets.all should have at least the fallback entries")
    }

    func testAllPresetsAreUnique() {
        let unique = Set(NounPresets.all)
        XCTAssertEqual(unique.count, NounPresets.all.count, "NounPresets.all should not contain duplicates")
    }

    func testAllPresetsRespectMaxLength() {
        for preset in NounPresets.all {
            XCTAssertLessThanOrEqual(preset.count, NounPresets.maxLength, "Preset '\(preset)' exceeds maxLength")
        }
    }

    func testAllPresetsContainNoNewlines() {
        for preset in NounPresets.all {
            XCTAssertFalse(preset.contains("\n"), "Preset '\(preset)' contains a newline")
            XCTAssertFalse(preset.contains("\r"), "Preset '\(preset)' contains a carriage return")
        }
    }
}
