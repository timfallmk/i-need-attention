import Foundation
import WatchConnectivity
import os.log

/// Two-way bridge with the watchOS app:
///   - Watch → phone: "press" and "ack" messages (the watch never talks to CloudKit).
///   - Phone → watch: `WatchSnapshot` updates so the watch pill mirrors the iOS pill.
///
/// State pushes use `updateApplicationContext` (always, opportunistic delivery) plus
/// a best-effort `sendMessage` when reachable so foreground updates are instant.
@MainActor
final class WatchBridge: NSObject {
    static let shared = WatchBridge()
    nonisolated private let log = Logger(subsystem: "com.timfallmk.attention", category: "Watch")
    private var pressHandler: (@MainActor () async -> Void)?
    private var ackHandler: (@MainActor (_ recordName: String, _ emoji: String?) async -> Void)?
    private var clearHandler: (@MainActor () -> Void)?
    private var activatedHandler: (@MainActor () -> Void)?

    func activate(
        onPress: @escaping @MainActor () async -> Void,
        onAck: @escaping @MainActor (_ recordName: String, _ emoji: String?) async -> Void,
        onClear: @escaping @MainActor () -> Void,
        onActivated: @escaping @MainActor () -> Void = {}
    ) {
        self.pressHandler = onPress
        self.ackHandler = onAck
        self.clearHandler = onClear
        self.activatedHandler = onActivated
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    /// Pushes the latest snapshot to the watch. Always updates the application context
    /// (replaces previous content; delivered when the watch wakes); also sends a live
    /// message when reachable for instant updates without round-tripping through APNs.
    func sendSnapshot(_ snapshot: WatchSnapshot) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        // No watch paired (or watch app uninstalled) → updateApplicationContext would
        // throw on every state mutation. Bail out quietly instead of spamming logs.
        guard session.isPaired, session.isWatchAppInstalled else { return }
        guard let data = snapshot.encode() else {
            log.error("snapshot encode failed")
            return
        }
        let context: [String: Any] = [Constants.WatchMessage.snapshotKey: data]
        do {
            try session.updateApplicationContext(context)
        } catch {
            log.error("updateApplicationContext: \(error.localizedDescription, privacy: .public)")
        }
        if session.isReachable {
            let message: [String: Any] = [
                Constants.WatchMessage.kindKey: Constants.WatchMessage.snapshotKind,
                Constants.WatchMessage.snapshotKey: data
            ]
            session.sendMessage(message, replyHandler: nil) { [weak self] error in
                self?.log.debug("snapshot sendMessage failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

extension WatchBridge: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if let error {
            log.error("WCSession activation: \(error.localizedDescription)")
        }
        if activationState == .activated {
            Task { @MainActor in
                self.activatedHandler?()
            }
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String : Any], replyHandler: @escaping ([String : Any]) -> Void) {
        let kind = message[Constants.WatchMessage.kindKey] as? String
        switch kind {
        case Constants.WatchMessage.pressKind:
            Task { @MainActor in
                await self.pressHandler?()
                replyHandler(["ok": true])
            }
        case Constants.WatchMessage.ackKind:
            let recordName = message[Constants.WatchMessage.ackRecordNameKey] as? String
            let emoji = message[Constants.WatchMessage.ackEmojiKey] as? String
            Task { @MainActor in
                if let recordName {
                    await self.ackHandler?(recordName, emoji)
                }
                replyHandler(["ok": recordName != nil])
            }
        case Constants.WatchMessage.clearKind:
            Task { @MainActor in
                self.clearHandler?()
                replyHandler(["ok": true])
            }
        default:
            replyHandler(["ok": false])
        }
    }

    /// Counterpart to the replyHandler variant — invoked when the watch sends a message
    /// without expecting a reply (which is what `WatchSession.sendPress` / `sendAck` do).
    /// Without this the reachable-watch path would drop on the floor and only the
    /// `transferUserInfo` fallback would land.
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String : Any]) {
        dispatchWatchInbound(message)
    }

    /// `transferUserInfo` from the watch lands here when the iPhone wasn't reachable at
    /// press/ack time. Without this, queued payloads would silently drop on the floor.
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String : Any] = [:]) {
        dispatchWatchInbound(userInfo)
    }

    private nonisolated func dispatchWatchInbound(_ payload: [String: Any]) {
        let kind = payload[Constants.WatchMessage.kindKey] as? String
        switch kind {
        case Constants.WatchMessage.pressKind:
            Task { @MainActor in
                await self.pressHandler?()
            }
        case Constants.WatchMessage.ackKind:
            let recordName = payload[Constants.WatchMessage.ackRecordNameKey] as? String
            let emoji = payload[Constants.WatchMessage.ackEmojiKey] as? String
            Task { @MainActor in
                if let recordName {
                    await self.ackHandler?(recordName, emoji)
                }
            }
        case Constants.WatchMessage.clearKind:
            Task { @MainActor in
                self.clearHandler?()
            }
        default:
            break
        }
    }
}
