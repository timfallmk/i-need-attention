import CloudKit
import Foundation
import os.log

/// Coordinates the two sides of the pairing handshake. Reads/writes go through
/// `CloudKitService`; persistence lives in `PairState`.
@MainActor
final class PairingService {
    static let shared = PairingService()
    private let log = Logger(subsystem: "com.example.attention", category: "Pairing")
    private let cloud = CloudKitService.shared
    private init() {}

    /// Inviter side: generate a fresh secret, write the half-empty Pair record, return the invite
    /// the QR view should display. The returned record is held so we can poll for the joiner.
    func startInviting(myName: String) async throws -> (invite: PairingInvite, record: CKRecord) {
        let invite = PairingInvite.generate(myDeviceID: DeviceIdentity.id, myName: myName)
        let record = try await cloud.createPair(invite: invite)
        return (invite, record)
    }

    /// Inviter side: poll the Pair record until `deviceB` is filled, or time out.
    func waitForJoiner(record: CKRecord, timeout: TimeInterval = 120) async throws -> PairState {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            let pairKey = record[Constants.PairField.pairKey] as? String ?? ""
            if let fresh = try await cloud.fetchPair(pairKey: pairKey),
               let deviceB = fresh[Constants.PairField.deviceB] as? String,
               !deviceB.isEmpty {
                let state = PairState(
                    pairKey: pairKey,
                    myDeviceID: DeviceIdentity.id,
                    myName: fresh[Constants.PairField.nameA] as? String ?? "",
                    partnerDeviceID: deviceB,
                    partnerName: fresh[Constants.PairField.nameB] as? String ?? "Friend"
                )
                state.save()
                try await cloud.registerSubscriptions(pairKey: pairKey, myDeviceID: state.myDeviceID)
                return state
            }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        throw AttentionError.pairNotFound
    }

    /// Joiner side: take a scanned QR payload, validate, and complete the handshake.
    func completePairing(payload: String, myName: String) async throws -> PairState {
        guard let invite = PairingInvite.from(qrPayload: payload) else {
            throw AttentionError.pairNotFound
        }
        guard let record = try await cloud.fetchPair(pairKey: invite.pairKey) else {
            throw AttentionError.pairNotFound
        }
        let updated = try await cloud.joinPair(
            record: record,
            joinerDeviceID: DeviceIdentity.id,
            joinerName: myName
        )
        let state = PairState(
            pairKey: invite.pairKey,
            myDeviceID: DeviceIdentity.id,
            myName: myName,
            partnerDeviceID: invite.inviterDeviceID,
            partnerName: invite.inviterName
        )
        state.save()
        // also persist our own name onto the record now that we joined
        _ = updated
        try await cloud.registerSubscriptions(pairKey: invite.pairKey, myDeviceID: state.myDeviceID)
        return state
    }

    /// Wipes local pairing and CloudKit subscriptions. Doesn't delete the Pair record from
    /// the server — the other phone may still want to use it until it also unpairs.
    func unpair() async {
        try? await cloud.removeAllSubscriptions()
        PairState.clear()
    }
}
