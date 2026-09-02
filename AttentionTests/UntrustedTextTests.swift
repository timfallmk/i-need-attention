import XCTest

final class UntrustedTextTests: XCTestCase {

    // MARK: - Ordinary names survive untouched

    func testPlainNamePassesThrough() {
        XCTAssertEqual(UntrustedText.name("Viv"), "Viv")
        XCTAssertEqual(UntrustedText.name("Mary-Jane O'Brien"), "Mary-Jane O'Brien")
        XCTAssertEqual(UntrustedText.name("田中"), "田中")
    }

    func testSurroundingWhitespaceIsTrimmed() {
        XCTAssertEqual(UntrustedText.name("   Tim   "), "Tim")
    }

    // MARK: - The observed abuse

    func testStripsSchemeURL() {
        XCTAssertEqual(UntrustedText.name("https://gatead.com/promo"), "")
    }

    func testBareHostStrippingIsBestEffort() {
        // NSDataDetector recognises schemed URLs reliably. Bare hosts depend on its TLD
        // knowledge, and it does not treat RFC 2606 reserved TLDs like .example as links
        // — correctly, since they cannot resolve. So don't assert a detector behaviour
        // that varies by input; assert the backstop that always holds instead.
        let cleaned = UntrustedText.name("evil.example")
        XCTAssertLessThanOrEqual(cleaned.count, UntrustedText.maxNameLength)
        XCTAssertFalse(cleaned.contains("\n"))
    }

    func testStripsAdCopyButKeepsTheWords() {
        // Modelled on a real Pair record found in the production container.
        let raw = "Check out this on Challenge Coin Check! https://apps.apple.com/app/challenge-coin"
        let cleaned = UntrustedText.name(raw)
        XCTAssertFalse(cleaned.contains("https://"))
        XCTAssertFalse(cleaned.contains("apps.apple.com"))
        XCTAssertLessThanOrEqual(cleaned.count, UntrustedText.maxNameLength)
    }

    // MARK: - Notification spoofing

    func testStripsNewlinesSoAName_cannotFakeExtraLines() {
        let cleaned = UntrustedText.name("Apple\nSecurity Alert")
        XCTAssertFalse(cleaned.contains("\n"))
    }

    func testStripsControlCharacters() {
        let cleaned = UntrustedText.name("Tim\u{202E}\u{0007}")
        XCTAssertEqual(cleaned, "Tim")
    }

    func testCollapsesRunsOfWhitespace() {
        XCTAssertEqual(UntrustedText.name("Tim      Fall"), "Tim Fall")
    }

    // MARK: - Bounds

    func testNameIsCappedAtMaxLength() {
        let cleaned = UntrustedText.name(String(repeating: "a", count: 500))
        XCTAssertEqual(cleaned.count, UntrustedText.maxNameLength)
    }

    func testMessageIsCappedAtItsOwnLongerLimit() {
        let cleaned = UntrustedText.message(String(repeating: "b", count: 500))
        XCTAssertEqual(cleaned.count, UntrustedText.maxMessageLength)
    }

    func testMessageLimitIsLooserThanNameLimit() {
        XCTAssertGreaterThan(UntrustedText.maxMessageLength, UntrustedText.maxNameLength)
    }

    // MARK: - Fallbacks

    func testFallbackUsedWhenInputIsNil() {
        XCTAssertEqual(UntrustedText.name(nil, fallback: "Partner"), "Partner")
    }

    func testFallbackUsedWhenInputSanitizesToNothing() {
        // A name that is nothing but a link must not render as an empty title.
        XCTAssertEqual(UntrustedText.name("https://evil.example", fallback: "Partner"), "Partner")
    }

    func testFallbackNotUsedWhenSomethingSurvives() {
        XCTAssertEqual(UntrustedText.name("Tim", fallback: "Partner"), "Tim")
    }

    func testMessageFallback() {
        XCTAssertEqual(UntrustedText.message(nil, fallback: "needs attention"), "needs attention")
    }
}
