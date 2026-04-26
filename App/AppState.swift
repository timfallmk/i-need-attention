import CloudKit
import Foundation
import SwiftUI
import os.log

/// Single source of truth for the UI. Mutations happen on the main actor; CloudKit calls
/// run on background queues via async/await but state is always written here on @MainActor.
@MainActor
@Observable
final class AppState {
    // Pairing
    var pair: PairState?

    // Settings (persisted via @Observable hooks)
    let settings: UserSettings

    // Live alert state
    var pendingOutgoing: AlertRecord?
    var lastIncoming: AlertRecord?
    var iCloudStatus: CKAccountStatus = .couldNotDetermine
    var notificationsAuthorized: Bool = false

    // UI feedback
    var bannerMessage: String?
    var cooldownEnds: Date?

    private let log = Logger(subsystem: "com.example.attention", category: "AppState")

    init() {
        self.settings = UserSettings()
        self.pair = PairState.load()
    }

    // MARK: - Boot

    func bootstrap() async {
        do {
            iCloudStatus = try await CloudKitService.shared.accountStatus()
        } catch {
            log.error("account status: \(error.localizedDescription)")
        }
        if let pair {
            SharedSettings.partnerName = pair.partnerName
            // Re-register subscriptions in case they were dropped
            try? await CloudKitService.shared.registerSubscriptions(
                pairKey: pair.pairKey,
                myDeviceID: pair.myDeviceID
            )
            // Pull latest alert so the status indicator is accurate on cold start
            if let recent = try? await CloudKitService.shared.fetchMostRecentAlert(pairKey: pair.pairKey) {
                if recent.senderDeviceID == pair.myDeviceID {
                    pendingOutgoing = recent
                } else {
                    lastIncoming = recent
                }
            }
        }
        let auth = await PushNotifications.shared.currentSettings()
        notificationsAuthorized = auth.authorizationStatus == .authorized || auth.authorizationStatus == .provisional
    }

    // MARK: - Sending

    var isOnCooldown: Bool {
        guard let end = cooldownEnds else { return false }
        return Date() < end
    }

    func sendAttention(critical: Bool = false) async {
        guard let pair else {
            bannerMessage = AttentionError.noPair.errorDescription
            return
        }
        guard !isOnCooldown else { return }

        Haptics.press()
        do {
            let record = try await CloudKitService.shared.sendAlert(
                pairKey: pair.pairKey,
                senderDeviceID: pair.myDeviceID,
                senderName: pair.myName,
                message: "needs attention",
                critical: critical
            )
            pendingOutgoing = record
            cooldownEnds = Date().addingTimeInterval(TimeInterval(settings.cooldownSeconds))
            Haptics.success()
        } catch {
            log.error("sendAttention: \(error.localizedDescription)")
            bannerMessage = error.localizedDescription
            Haptics.warning()
        }
    }

    // MARK: - Receiving

    /// Called by PushNotifications when a new alert (or alert update) arrives.
    func handleIncomingChange(_ alert: AlertRecord) async {
        guard let pair else { return }
        guard alert.pairKey == pair.pairKey else { return }

        if alert.senderDeviceID == pair.myDeviceID {
            // It's an update to one of my outgoing alerts (seen / acknowledged).
            if pendingOutgoing?.id == alert.id {
                pendingOutgoing = alert
                if alert.state == .seen { Haptics.tick() }
                if alert.state == .acknowledged { Haptics.success() }
            }
        } else if alert.senderDeviceID == pair.partnerDeviceID {
            // The partner sent something new — record it and mark seen.
            lastIncoming = alert
            do {
                let updated = try await CloudKitService.shared.markAlertSeen(recordID: alert.id)
                lastIncoming = updated
            } catch {
                log.error("markAlertSeen: \(error.localizedDescription)")
            }
        }
    }

    func acknowledgeIncoming(emoji: String?) async {
        guard let alert = lastIncoming else { return }
        do {
            let updated = try await CloudKitService.shared.acknowledgeAlert(recordID: alert.id, emoji: emoji)
            lastIncoming = updated
            Haptics.success()
        } catch {
            log.error("ack: \(error.localizedDescription)")
        }
    }

    // MARK: - Pairing wrapper

    func applyPair(_ state: PairState) {
        self.pair = state
        SharedSettings.partnerName = state.partnerName
    }

    func unpair() async {
        await PairingService.shared.unpair()
        pair = nil
        pendingOutgoing = nil
        lastIncoming = nil
        SharedSettings.partnerName = nil
    }
}
