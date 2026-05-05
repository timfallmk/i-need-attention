import XCTest

final class WatchSnapshotTests: XCTestCase {

    // MARK: - WatchSnapshot.empty

    func testEmptySnapshotIsUnpaired() {
        XCTAssertFalse(WatchSnapshot.empty.paired)
    }

    func testEmptySnapshotHasNoOutgoing() {
        XCTAssertNil(WatchSnapshot.empty.outgoing)
    }

    func testEmptySnapshotHasNoIncoming() {
        XCTAssertNil(WatchSnapshot.empty.incoming)
    }

    func testEmptySnapshotHasNoCooldown() {
        XCTAssertNil(WatchSnapshot.empty.cooldownEnds)
    }

    // MARK: - encode / decode round trips

    func testEncodeDecodeEmptySnapshot() {
        let snap = WatchSnapshot.empty
        guard let data = snap.encode() else {
            XCTFail("encode returned nil for empty snapshot")
            return
        }
        let decoded = WatchSnapshot.decode(data)
        XCTAssertEqual(snap, decoded)
    }

    func testEncodeDecodeSnapshotWithPairedFlag() {
        let snap = WatchSnapshot(paired: true, outgoing: nil, incoming: nil, cooldownEnds: nil)
        guard let data = snap.encode() else {
            XCTFail("encode returned nil")
            return
        }
        let decoded = WatchSnapshot.decode(data)
        XCTAssertEqual(snap, decoded)
    }

    func testEncodeDecodeSnapshotWithCooldown() {
        // Use a date with whole-millisecond precision to survive millisecondsSince1970 round-trip.
        let cooldown = Date(timeIntervalSince1970: 1_700_000_000.123)
        let snap = WatchSnapshot(paired: true, outgoing: nil, incoming: nil, cooldownEnds: cooldown)
        guard let data = snap.encode() else {
            XCTFail("encode returned nil")
            return
        }
        let decoded = WatchSnapshot.decode(data)
        XCTAssertEqual(snap, decoded)
        // Date round-trips to millisecond precision.
        if let decodedCooldown = decoded?.cooldownEnds {
            XCTAssertEqual(cooldown.timeIntervalSince1970, decodedCooldown.timeIntervalSince1970, accuracy: 0.001)
        }
    }

    func testEncodeDecodeOutgoingInfo() {
        let outgoing = WatchSnapshot.OutgoingInfo(
            recordName: "rec-abc",
            state: .sent,
            critical: true,
            ackEmoji: "❤️"
        )
        let snap = WatchSnapshot(paired: true, outgoing: outgoing, incoming: nil, cooldownEnds: nil)
        guard let data = snap.encode() else {
            XCTFail("encode returned nil")
            return
        }
        let decoded = WatchSnapshot.decode(data)
        XCTAssertEqual(snap, decoded)
        XCTAssertEqual(decoded?.outgoing?.recordName, "rec-abc")
        XCTAssertEqual(decoded?.outgoing?.state, .sent)
        XCTAssertTrue(decoded?.outgoing?.critical == true)
        XCTAssertEqual(decoded?.outgoing?.ackEmoji, "❤️")
    }

    func testEncodeDecodeOutgoingStates() {
        for state: WatchSnapshot.Outgoing in [.sent, .seen, .acknowledged] {
            let outgoing = WatchSnapshot.OutgoingInfo(recordName: "r", state: state, critical: false, ackEmoji: nil)
            let snap = WatchSnapshot(paired: true, outgoing: outgoing, incoming: nil, cooldownEnds: nil)
            guard let data = snap.encode() else {
                XCTFail("encode returned nil for state \(state)")
                continue
            }
            XCTAssertEqual(WatchSnapshot.decode(data)?.outgoing?.state, state)
        }
    }

    func testEncodeDecodeIncomingInfo() {
        let createdAt = Date(timeIntervalSince1970: 1_000_000)
        let incoming = WatchSnapshot.IncomingInfo(
            recordName: "incoming-1",
            senderName: "Alice",
            critical: false,
            createdAt: createdAt,
            acknowledged: false,
            message: "needs hugs"
        )
        let snap = WatchSnapshot(paired: true, outgoing: nil, incoming: incoming, cooldownEnds: nil)
        guard let data = snap.encode() else {
            XCTFail("encode returned nil")
            return
        }
        let decoded = WatchSnapshot.decode(data)
        XCTAssertEqual(snap, decoded)
        XCTAssertEqual(decoded?.incoming?.senderName, "Alice")
        XCTAssertEqual(decoded?.incoming?.message, "needs hugs")
        XCTAssertFalse(decoded?.incoming?.acknowledged ?? true)
    }

    func testEncodeDecodeFullSnapshot() {
        let createdAt = Date(timeIntervalSince1970: 1_000_000)
        let cooldown = Date(timeIntervalSince1970: 1_000_030)
        let outgoing = WatchSnapshot.OutgoingInfo(recordName: "out-1", state: .acknowledged, critical: false, ackEmoji: "👍")
        let incoming = WatchSnapshot.IncomingInfo(
            recordName: "in-1",
            senderName: "Bob",
            critical: true,
            createdAt: createdAt,
            acknowledged: true,
            message: nil
        )
        let snap = WatchSnapshot(paired: true, outgoing: outgoing, incoming: incoming, cooldownEnds: cooldown)
        guard let data = snap.encode() else {
            XCTFail("encode returned nil")
            return
        }
        XCTAssertEqual(WatchSnapshot.decode(data), snap)
    }

    func testDecodeReturnsNilForInvalidData() {
        XCTAssertNil(WatchSnapshot.decode(Data()))
        XCTAssertNil(WatchSnapshot.decode(Data("not json at all".utf8)))
        XCTAssertNil(WatchSnapshot.decode(Data("{\"wrong\":true}".utf8)))
    }

    // MARK: - Outgoing state raw values survive encode

    func testOutgoingStateRawValues() {
        XCTAssertEqual(WatchSnapshot.Outgoing.sent.rawValue, "sent")
        XCTAssertEqual(WatchSnapshot.Outgoing.seen.rawValue, "seen")
        XCTAssertEqual(WatchSnapshot.Outgoing.acknowledged.rawValue, "acknowledged")
    }

    // MARK: - Equatable

    func testSnapshotsAreEqual() {
        let a = WatchSnapshot(paired: true, outgoing: nil, incoming: nil, cooldownEnds: nil)
        let b = WatchSnapshot(paired: true, outgoing: nil, incoming: nil, cooldownEnds: nil)
        XCTAssertEqual(a, b)
    }

    func testSnapshotsDifferByPaired() {
        let a = WatchSnapshot(paired: true, outgoing: nil, incoming: nil, cooldownEnds: nil)
        let b = WatchSnapshot(paired: false, outgoing: nil, incoming: nil, cooldownEnds: nil)
        XCTAssertNotEqual(a, b)
    }
}
