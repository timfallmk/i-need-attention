import Foundation
import WatchConnectivity
import os.log

/// Listens for "press" messages from the watch app and delegates the actual alert
/// send back to the iPhone. The watch never talks to CloudKit directly — keeps things
/// simple and avoids paying twice for iCloud auth.
@MainActor
final class WatchBridge: NSObject {
    static let shared = WatchBridge()
    private let log = Logger(subsystem: "com.example.attention", category: "Watch")
    private var pressHandler: (@MainActor () async -> Void)?

    func activate(onPress: @escaping @MainActor () async -> Void) {
        self.pressHandler = onPress
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }
}

extension WatchBridge: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if let error {
            log.error("WCSession activation: \(error.localizedDescription)")
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String : Any], replyHandler: @escaping ([String : Any]) -> Void) {
        guard isPressMessage(message) else {
            replyHandler(["ok": false])
            return
        }
        Task { @MainActor in
            await self.pressHandler?()
            replyHandler(["ok": true])
        }
    }

    /// `transferUserInfo` from the watch lands here when the iPhone wasn't reachable at
    /// press time. Without this, queued presses would silently drop on the floor.
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String : Any] = [:]) {
        guard isPressMessage(userInfo) else { return }
        Task { @MainActor in
            await self.pressHandler?()
        }
    }

    private nonisolated func isPressMessage(_ payload: [String: Any]) -> Bool {
        (payload[Constants.WatchMessage.kindKey] as? String) == Constants.WatchMessage.pressKind
    }
}
