import Combine
import Foundation
import os.log
import WatchConnectivity
import WatchKit

/// Sends "press" and "ack" messages to the iPhone, and receives `WatchSnapshot` updates
/// so the watch UI mirrors the iPhone status pill. Uses sendMessage when reachable and
/// transferUserInfo otherwise so taps from a wrist out of range still get relayed when
/// the phone wakes up.
final class WatchSession: NSObject, ObservableObject, WCSessionDelegate {
    @Published var phoneReachable = false
    @Published var snapshot: WatchSnapshot?

    private let log = Logger(subsystem: "com.timfallmk.attention.watch", category: "WatchSession")

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    // MARK: - Outbound

    func sendPress() {
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        WKInterfaceDevice.current().play(.notification)

        let message: [String: Any] = [
            Constants.WatchMessage.kindKey: Constants.WatchMessage.pressKind
        ]

        if session.isReachable {
            session.sendMessage(message, replyHandler: nil, errorHandler: { [weak self] _ in
                session.transferUserInfo(message)
                self?.log.debug("press: queued via userInfo (sendMessage failed)")
            })
        } else {
            session.transferUserInfo(message)
        }
    }

    /// Acknowledges the current incoming alert. Optimistically flips the local snapshot
    /// so the pill changes immediately; the phone's next snapshot reconciles.
    func sendAck(emoji: String?) {
        guard let recordName = snapshot?.incoming?.recordName else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }

        var payload: [String: Any] = [
            Constants.WatchMessage.kindKey: Constants.WatchMessage.ackKind,
            Constants.WatchMessage.ackRecordNameKey: recordName
        ]
        if let emoji {
            payload[Constants.WatchMessage.ackEmojiKey] = emoji
        }

        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil, errorHandler: { [weak self] _ in
                session.transferUserInfo(payload)
                self?.log.debug("ack: queued via userInfo (sendMessage failed)")
            })
        } else {
            session.transferUserInfo(payload)
        }

        WKInterfaceDevice.current().play(.success)
        applyOptimisticAck()
    }

    private func applyOptimisticAck() {
        guard var snap = snapshot, var incoming = snap.incoming else { return }
        incoming.acknowledged = true
        snap.incoming = incoming
        snapshot = snap
    }

    // MARK: - WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async {
            self.phoneReachable = session.isReachable
            // Surface whatever the phone sent us last while we were inactive.
            self.absorbContext(session.receivedApplicationContext)
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async {
            self.phoneReachable = session.isReachable
        }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String : Any]) {
        DispatchQueue.main.async {
            self.absorbContext(applicationContext)
        }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String : Any]) {
        DispatchQueue.main.async {
            self.absorbMessage(message)
        }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String : Any], replyHandler: @escaping ([String : Any]) -> Void) {
        DispatchQueue.main.async {
            self.absorbMessage(message)
            replyHandler(["ok": true])
        }
    }

    private func absorbContext(_ payload: [String: Any]) {
        guard let data = payload[Constants.WatchMessage.snapshotKey] as? Data,
              let snap = WatchSnapshot.decode(data) else { return }
        snapshot = snap
    }

    private func absorbMessage(_ payload: [String: Any]) {
        let kind = payload[Constants.WatchMessage.kindKey] as? String
        if kind == Constants.WatchMessage.snapshotKind {
            absorbContext(payload)
        }
    }
}
