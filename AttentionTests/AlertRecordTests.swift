import CloudKit
import XCTest

final class AlertRecordTests: XCTestCase {

    /// Builds an Alert `CKRecord` with each field independently omittable, so the failable
    /// parser's required-field guards and default fallbacks can be exercised.
    private func makeRecord(
        pairKey: String? = "PK",
        senderDeviceID: String? = "SENDER",
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
        if let senderName { r[Constants.AlertField.senderName] = senderName as CKRecordValue }
        if let message { r[Constants.AlertField.message] = message as CKRecordValue }
        if let state { r[Constants.AlertField.state] = state as CKRecordValue }
        if let critical { r[Constants.AlertField.critical] = critical as CKRecordValue }
        if let seenAt { r[Constants.AlertField.seenAt] = seenAt as CKRecordValue }
        if let acknowledgedAt { r[Constants.AlertField.acknowledgedAt] = acknowledgedAt as CKRecordValue }
        if let ackEmoji { r[Constants.AlertField.ackEmoji] = ackEmoji as CKRecordValue }
        return r
    }

    // MARK: - Happy path

    func testParsesFullyPopulatedRecord() {
        let seen = Date(timeIntervalSince1970: 1000)
        let acked = Date(timeIntervalSince1970: 2000)
        let record = makeRecord(critical: 1, seenAt: seen, acknowledgedAt: acked, ackEmoji: "❤️")
        let model = AlertRecord(record: record)
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
        XCTAssertEqual(AlertRecord(record: record)?.id, record.recordID)
    }

    func testOptionalFieldsAbsentAreNil() {
        let model = AlertRecord(record: makeRecord())
        XCTAssertNil(model?.seenAt)
        XCTAssertNil(model?.acknowledgedAt)
        XCTAssertNil(model?.ackEmoji)
    }

    // MARK: - Default fallbacks

    func testSenderNameDefaultsToEmpty() {
        XCTAssertEqual(AlertRecord(record: makeRecord(senderName: nil))?.senderName, "")
    }

    func testMessageDefaultsToNeedsAttention() {
        XCTAssertEqual(AlertRecord(record: makeRecord(message: nil))?.message, "needs attention")
    }

    // MARK: - critical Int -> Bool

    func testCriticalZeroIsFalse() {
        XCTAssertEqual(AlertRecord(record: makeRecord(critical: 0))?.critical, false)
    }

    func testCriticalOneIsTrue() {
        XCTAssertEqual(AlertRecord(record: makeRecord(critical: 1))?.critical, true)
    }

    func testMissingCriticalDefaultsToFalse() {
        XCTAssertEqual(AlertRecord(record: makeRecord(critical: nil))?.critical, false)
    }

    // MARK: - Required-field guards (return nil)

    func testMissingPairKeyReturnsNil() {
        XCTAssertNil(AlertRecord(record: makeRecord(pairKey: nil)))
    }

    func testMissingSenderDeviceIDReturnsNil() {
        XCTAssertNil(AlertRecord(record: makeRecord(senderDeviceID: nil)))
    }

    func testMissingStateReturnsNil() {
        XCTAssertNil(AlertRecord(record: makeRecord(state: nil)))
    }

    func testUnknownStateReturnsNil() {
        XCTAssertNil(AlertRecord(record: makeRecord(state: "not-a-state")))
    }

    func testEachValidStateParses() {
        XCTAssertEqual(AlertRecord(record: makeRecord(state: "sent"))?.state, .sent)
        XCTAssertEqual(AlertRecord(record: makeRecord(state: "seen"))?.state, .seen)
        XCTAssertEqual(AlertRecord(record: makeRecord(state: "acknowledged"))?.state, .acknowledged)
    }
}
