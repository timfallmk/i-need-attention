import Combine
import Foundation
import WatchConnectivity
import WatchKit

/// Sends "press" messages to the iPhone. Uses sendMessage when reachable, transferUserInfo
/// otherwise so a tap from a wrist that's out of range still gets relayed when the phone wakes up.
final class WatchSession: NSObject, ObservableObject, WCSessionDelegate {
    @Published var phoneReachable = false
    @Published var lastResult: String?
    @Published var sending = false

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    func sendPress() {
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        sending = true
        WKInterfaceDevice.current().play(.notification)

        let message: [String: Any] = [
            Constants.WatchMessage.kindKey: Constants.WatchMessage.pressKind
        ]

        if session.isReachable {
            session.sendMessage(message, replyHandler: { [weak self] reply in
                DispatchQueue.main.async {
                    self?.sending = false
                    self?.lastResult = (reply["ok"] as? Bool == true) ? "Sent" : "Failed"
                }
            }, errorHandler: { [weak self] error in
                DispatchQueue.main.async {
                    self?.sending = false
                    self?.lastResult = "Queued"
                    session.transferUserInfo(message)
                }
            })
        } else {
            session.transferUserInfo(message)
            sending = false
            lastResult = "Queued"
        }
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async {
            self.phoneReachable = session.isReachable
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async {
            self.phoneReachable = session.isReachable
        }
    }
}
