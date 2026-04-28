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
    var notificationsDenied: Bool = false

    // UI feedback
    var bannerMessage: String?
    var cooldownEnds: Date?

    private let log = Logger(subsystem: "com.timfallmk.attention", category: "AppState")

    init() {
        self.settings = UserSettings()
        self.pair = PairState.load()
    }

    // MARK: - Boot

    func bootstrap() async {
        await refreshICloudStatus()
        #if DEBUG
        // TEMPORARY: seeds _sub_trigger_sub_* into the Development schema.
        // Wipes existing subs first so the create always fires regardless of saved pair state.
        // Run once, verify subscriptions appear in CloudKit Dashboard → Development → Subscriptions,
        // Deploy Schema Changes, then delete this entire #if DEBUG block.
        log.info("DEBUG seed: wiping and re-registering subscriptions in Development")
        try? await CloudKitService.shared.removeAllSubscriptions()
        try? await CloudKitService.shared.registerSubscriptions(
            pairKey: "schema-seed",
            myDeviceID: "schema-seed-device"
        )
        log.info("DEBUG seed: done")
        return
        #endif
        if let pair {
            SharedSettings.partnerName = pair.partnerName
            // Re-register subscriptions in case they were dropped
            try? await CloudKitService.shared.registerSubscriptions(
                pairKey: pair.pairKey,
                myDeviceID: pair.myDeviceID
            )
            // Pick up any partner-name change that happened while we were killed
            await refreshPairFromCloud()
            // Pull latest alert so the status indicator is accurate on cold start
            if let recent = try? await CloudKitService.shared.fetchMostRecentAlert(pairKey: pair.pairKey) {
                if recent.senderDeviceID == pair.myDeviceID {
                    pendingOutgoing = recent
                } else {
                    lastIncoming = recent
                }
            }
        }
        await refreshNotificationStatus()
    }

    func refreshNotificationStatus() async {
        let auth = await PushNotifications.shared.currentSettings()
        notificationsAuthorized = auth.authorizationStatus == .authorized || auth.authorizationStatus == .provisional
        notificationsDenied = auth.authorizationStatus == .denied
    }

    func refreshICloudStatus() async {
        do {
            iCloudStatus = try await CloudKitService.shared.accountStatus()
        } catch {
            log.error("account status: \(error.localizedDescription)")
        }
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
            // Read the live displayName so renaming yourself in Settings takes effect on
            // the next outgoing alert without needing to re-pair.
            let record = try await CloudKitService.shared.sendAlert(
                pairKey: pair.pairKey,
                senderDeviceID: pair.myDeviceID,
                senderName: settings.displayName,
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

    // MARK: - Display name sync

    /// Pushes the current `settings.displayName` to the Pair record so the partner sees
    /// the updated name. Also updates the local copy in `pair.myName`.
    func syncMyDisplayName() async {
        guard var pair else { return }
        let newName = settings.displayName
        guard !newName.isEmpty, newName != pair.myName else { return }
        do {
            try await CloudKitService.shared.updatePairName(
                pairKey: pair.pairKey,
                myDeviceID: pair.myDeviceID,
                newName: newName
            )
            pair.myName = newName
            pair.save()
            self.pair = pair
            Haptics.light()
        } catch {
            log.error("updatePairName: \(error.localizedDescription)")
        }
    }

    /// Refetches the Pair record from CloudKit and updates the local partnerName if the
    /// partner has renamed themselves. Triggered by the Pair update silent push.
    func refreshPairFromCloud() async {
        guard var pair else { return }
        do {
            guard let record = try await CloudKitService.shared.fetchPair(pairKey: pair.pairKey) else { return }
            let deviceA = (record[Constants.PairField.deviceA] as? String) ?? ""
            let deviceB = (record[Constants.PairField.deviceB] as? String) ?? ""
            let nameA = (record[Constants.PairField.nameA] as? String) ?? ""
            let nameB = (record[Constants.PairField.nameB] as? String) ?? ""
            let partnerName: String
            if deviceA == pair.myDeviceID {
                partnerName = nameB
            } else if deviceB == pair.myDeviceID {
                partnerName = nameA
            } else {
                return
            }
            guard !partnerName.isEmpty, partnerName != pair.partnerName else { return }
            pair.partnerName = partnerName
            pair.save()
            self.pair = pair
            SharedSettings.partnerName = partnerName
        } catch {
            log.error("refreshPair: \(error.localizedDescription)")
        }
    }
}
