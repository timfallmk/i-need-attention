import CloudKit
import XCTest

final class AlertRecordTests: XCTestCase {

    /// Builds an Alert `CKRecord` with each field independently omittable, so the failable
    /// parser's required-field guards and default fallbacks can be exercised.
    private func makeRecord(
        pairKey: String? = "PK",
        senderDeviceID: String? = "SENDER",
        senderUserID: String? = nil,
        senderName: String? = "Sam",
        message: String? = "needs coffee",
        state: String? = "sent",
        critical: Int? = 0,
        seenAt: Date? = nil,
        acknowledgedAt: Date? = nil,
        ackEmoji: String? = nil
    ) -> CKRecord {
        let r = CKRecord(recordType: Constants.RecordType.alert)
        if let pairKey { r[Constants.AlertField.pairKey] = pairKey as CKRecordValue }
        if let senderDeviceID { r[Constants.AlertField.senderDeviceID] = senderDeviceID as CKRecordValue }
        if let senderUserID { r[Constants.AlertField.senderUserID] = senderUserID as CKRecordValue }
        if let senderName { r[Constants.AlertField.senderName] = senderName as CKRecordValue }
        if let message { r[Constants.AlertField.message] = message as CKRecordValue }
        if let state { r[Constants.AlertField.state] = state as CKRecordValue }
        if let critical { r[Constants.AlertField.critical] = critical as CKRecordValue }
        if let seenAt { r[Constants.AlertField.seenAt] = seenAt as CKRecordValue }
        if let acknowledgedAt { r[Constants.AlertField.acknowledgedAt] = acknowledgedAt as CKRecordValue }
        if let ackEmoji { r[Constants.AlertField.ackEmoji] = ackEmoji as CKRecordValue }
        return r
    }

    // MARK: - Account identity

    /// The field the whole of #68 turns on. If the parser stopped reading it, every
    /// alert would quietly fall back to the per-install device ID and multi-device
    /// classification would regress without a single test going red.
    func testParsesSenderUserID() {
        let model = AlertRecord(record: makeRecord(senderUserID: "_account"), pairKey: nil)
        XCTAssertEqual(model?.senderUserID, "_account")
    }

    /// Absent on every record written before per-account identity, and it has to arrive
    /// as nil rather than "" — `SenderIdentity` falls back only on nil, and an empty
    /// string would compare equal to another empty string and match the wrong person.
    func testSenderUserIDIsNilWhenTheRecordHasNone() {
        let model = AlertRecord(record: makeRecord(), pairKey: nil)
        XCTAssertNil(model?.senderUserID)
    }

    /// Archiving is what history reads back, so an identity dropped on the way in or out
    /// would show every row on the wrong side of the sheet.
    func testSenderUserIDSurvivesTheArchiveRoundTrip() {
        guard let model = AlertRecord(record: makeRecord(senderUserID: "_account"), pairKey: nil) else {
            return XCTFail("record should parse")
        }
        XCTAssertEqual(AlertRecord(archived: ArchivedAlert(model)).senderUserID, "_account")

        guard let legacy = AlertRecord(record: makeRecord(), pairKey: nil) else {
            return XCTFail("record should parse")
        }
        XCTAssertNil(AlertRecord(archived: ArchivedAlert(legacy)).senderUserID)
    }

    // MARK: - Happy path

    func testParsesFullyPopulatedRecord() {
        let seen = Date(timeIntervalSince1970: 1000)
        let acked = Date(timeIntervalSince1970: 2000)
        let record = makeRecord(critical: 1, seenAt: seen, acknowledgedAt: acked, ackEmoji: "❤️")
        let model = AlertRecord(record: record, pairKey: nil)
        XCTAssertEqual(model?.pairKey, "PK")
        XCTAssertEqual(model?.senderDeviceID, "SENDER")
        XCTAssertEqual(model?.senderName, "Sam")
        XCTAssertEqual(model?.message, "needs coffee")
        XCTAssertEqual(model?.state, .sent)
        XCTAssertEqual(model?.seenAt, seen)
        XCTAssertEqual(model?.acknowledgedAt, acked)
        XCTAssertEqual(model?.ackEmoji, "❤️")
        XCTAssertEqual(model?.critical, true)
    }

    func testIdMatchesRecordID() {
        let record = makeRecord()
        XCTAssertEqual(AlertRecord(record: record, pairKey: nil)?.id, record.recordID)
    }

    func testOptionalFieldsAbsentAreNil() {
        let model = AlertRecord(record: makeRecord(), pairKey: nil)
        XCTAssertNil(model?.seenAt)
        XCTAssertNil(model?.acknowledgedAt)
        XCTAssertNil(model?.ackEmoji)
    }

    // MARK: - Default fallbacks

    func testSenderNameDefaultsToEmpty() {
        XCTAssertEqual(AlertRecord(record: makeRecord(senderName: nil), pairKey: nil)?.senderName, "")
    }

    func testMessageDefaultsToNeedsAttention() {
        XCTAssertEqual(AlertRecord(record: makeRecord(message: nil), pairKey: nil)?.message, "needs attention")
    }

    // MARK: - critical Int -> Bool

    func testCriticalZeroIsFalse() {
        XCTAssertEqual(AlertRecord(record: makeRecord(critical: 0), pairKey: nil)?.critical, false)
    }

    func testCriticalOneIsTrue() {
        XCTAssertEqual(AlertRecord(record: makeRecord(critical: 1), pairKey: nil)?.critical, true)
    }

    func testMissingCriticalDefaultsToFalse() {
        XCTAssertEqual(AlertRecord(record: makeRecord(critical: nil), pairKey: nil)?.critical, false)
    }

    // MARK: - Required-field guards (return nil)

    func testMissingPairKeyReturnsNil() {
        // 2.0 records carry no pairKey at all — zone membership is the boundary — so
        // its absence is no longer a reason to reject a record.
        XCTAssertEqual(AlertRecord(record: makeRecord(pairKey: nil), pairKey: nil)?.pairKey, "")
    }

    func testMissingSenderDeviceIDReturnsNil() {
        XCTAssertNil(AlertRecord(record: makeRecord(senderDeviceID: nil), pairKey: nil))
    }

    func testMissingStateReturnsNil() {
        XCTAssertNil(AlertRecord(record: makeRecord(state: nil), pairKey: nil))
    }

    func testUnknownStateReturnsNil() {
        XCTAssertNil(AlertRecord(record: makeRecord(state: "not-a-state"), pairKey: nil))
    }

    func testEachValidStateParses() {
        XCTAssertEqual(AlertRecord(record: makeRecord(state: "sent"), pairKey: nil)?.state, .sent)
        XCTAssertEqual(AlertRecord(record: makeRecord(state: "seen"), pairKey: nil)?.state, .seen)
        XCTAssertEqual(AlertRecord(record: makeRecord(state: "acknowledged"), pairKey: nil)?.state, .acknowledged)
    }

    // MARK: - Sealed fields (2.0)

    private let key = "test-pair-key"

    private func makeSealedRecord(name: String? = "Sam",
                                  message: String? = "needs coffee",
                                  ackEmoji: String? = nil) throws -> CKRecord {
        let record = makeRecord(senderName: nil, message: nil, ackEmoji: nil)
        try AlertRecord.seal(name: name, message: message, ackEmoji: ackEmoji,
                             into: record, pairKey: key)
        return record
    }

    func testSealedFieldsOpenWithThePairKey() throws {
        let model = AlertRecord(record: try makeSealedRecord(ackEmoji: "❤️"), pairKey: key)
        XCTAssertEqual(model?.senderName, "Sam")
        XCTAssertEqual(model?.message, "needs coffee")
        XCTAssertEqual(model?.ackEmoji, "❤️")
    }

    func testSealingLeavesNoPlaintextOnTheRecord() throws {
        let record = try makeSealedRecord()
        XCTAssertNil(record[Constants.AlertField.senderName])
        XCTAssertNil(record[Constants.AlertField.message])
        XCTAssertNotNil(record[Constants.AlertField.senderNameSealed] as? Data)
    }

    func testSealedFieldsStayShutWithoutTheKey() throws {
        let model = AlertRecord(record: try makeSealedRecord(), pairKey: nil)
        XCTAssertEqual(model?.senderName, "")
        XCTAssertEqual(model?.message, "needs attention")
    }

    func testSealedFieldsStayShutWithTheWrongKey() throws {
        let model = AlertRecord(record: try makeSealedRecord(), pairKey: "not-the-key")
        XCTAssertEqual(model?.senderName, "")
        XCTAssertEqual(model?.message, "needs attention")
    }

    /// An unreadable record is still a real press from the partner — it must not vanish.
    func testARecordWhoseCiphertextWontOpenStillParses() throws {
        XCTAssertNotNil(AlertRecord(record: try makeSealedRecord(), pairKey: "not-the-key"))
    }

    func testNilFieldsAreNotSealedIntoTheRecord() throws {
        let record = try makeSealedRecord(ackEmoji: nil)
        XCTAssertNil(record[Constants.AlertField.ackEmojiSealed])
    }

    func testEmptyFieldsAreNotSealedIntoTheRecord() throws {
        let record = try makeSealedRecord(ackEmoji: "")
        XCTAssertNil(record[Constants.AlertField.ackEmojiSealed])
    }

    func testPreTwoPointZeroPlaintextIsStillRead() {
        let model = AlertRecord(record: makeRecord(senderName: "Rae", message: "needs tea"),
                                pairKey: key)
        XCTAssertEqual(model?.senderName, "Rae")
        XCTAssertEqual(model?.message, "needs tea")
    }
}
