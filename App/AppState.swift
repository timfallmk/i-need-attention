import CloudKit
import Foundation
import SwiftUI
import UserNotifications
import os.log

/// Single source of truth for the UI. Mutations happen on the main actor; CloudKit calls
/// run on background queues via async/await but state is always written here on @MainActor.
@MainActor
@Observable
final class AppState {
    // Pairing
    var pair: PairState?

    /// Invite this device created that the partner hasn't accepted yet (remote sharing).
    /// Mirrors the UserDefaults-persisted `PendingInvite` so SwiftUI can observe it.
    var pendingInvite: PendingInvite?

    /// Parsed `attention://pair` link awaiting the user's confirmation (joiner side).
    /// Set by the URL handler; drives the join confirmation sheet in RootView.
    var incomingJoinInvite: PairingInvite?

    /// Locally-snoozed incoming alert (#49). Observable mirror of the persisted `SnoozeState`.
    /// Only meaningful while it matches `lastIncoming` and `isActive`.
    var snooze: SnoozeState?

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

    /// Mirrors `SharedSettings.outgoingAckSubscriptionUnavailable` so SwiftUI can
    /// observe it. Refreshed after every `registerSubscriptions` call.
    var outgoingAckSubscriptionUnavailable: Bool = false

    /// Mirrors `SharedSettings.outgoingAckSubscriptionFailureReason` so the
    /// captured CKError appears under the Diagnostics row without polling.
    var outgoingAckSubscriptionFailureReason: String?

    private let log = Logger(subsystem: "com.timfallmk.attention", category: "AppState")

    // Record name of the most recently user-dismissed acknowledged alert. Persisted so
    // reconcileLatestAlert doesn't re-surface it after backgrounding/relaunch.
    private static let dismissedOutgoingKey = "attention.dismissedOutgoingRecordName"

    init() {
        self.settings = UserSettings()
        self.pair = PairState.load()
        self.pendingInvite = PendingInvite.load()
        self.snooze = SnoozeState.load()
        self.outgoingAckSubscriptionUnavailable = SharedSettings.outgoingAckSubscriptionUnavailable
        self.outgoingAckSubscriptionFailureReason = SharedSettings.outgoingAckSubscriptionFailureReason
    }

    // MARK: - Boot

    func bootstrap() async {
        await refreshICloudStatus()

        #if DEBUG
        // Seeds the CloudKit-internal `_sub_trigger_<subscriptionID>` records into
        // the Development environment for every subscription this app declares.
        // Production rejects schema mutations from devices, so those triggers must
        // exist in Dev before "Deploy Schema Changes…" can promote them — without
        // this, every newly-introduced subscription ID is rejected in Production
        // with BAD_REQUEST. Gated on `pair == nil` so it never shadows a real Dev
        // pair's predicates (registerSubscriptions is idempotent on subscription ID) —
        // and on `pendingInvite == nil`, because an in-flight remote invite registers
        // real-predicate subscriptions under the same IDs before the pair completes.
        if pair == nil && pendingInvite == nil {
            try? await CloudKitService.shared.registerSubscriptions(
                pairKey: "schema-seed",
                myDeviceID: "schema-seed-device"
            )
        }
        #endif

        if let pair {
            SharedSettings.partnerName = pair.partnerName
            #if DEBUG
            // The unpaired seeder above writes placeholder-predicate subs under
            // the real subscription IDs. registerSubscriptions is idempotent on
            // ID, so without this purge the placeholders would survive pairing
            // and silently swallow real-pair pushes in Dev.
            try? await CloudKitService.shared.purgeSeededSubscriptions()
            #endif
            // Re-register subscriptions in case they were dropped
            try? await CloudKitService.shared.registerSubscriptions(
                pairKey: pair.pairKey,
                myDeviceID: pair.myDeviceID
            )
            refreshSubscriptionDiagnostics()
            // Pick up any partner-name change that happened while we were killed
            await refreshPairFromCloud()
        } else {
            // A pending remote invite may have been accepted while this app was gone —
            // the silent push never reaches a force-quit app, so reconcile on launch.
            await reconcilePendingInvite()
            if pair == nil && pendingInvite == nil {
                // No pair and no in-flight invite = no subscriptions = no useful
                // diagnostic. Clear any stale flag. (A pending invite's registrations
                // are real, so their diagnostics stay.)
                SharedSettings.outgoingAckSubscriptionUnavailable = false
                SharedSettings.outgoingAckSubscriptionFailureReason = nil
                refreshSubscriptionDiagnostics()
            }
        }
        // Run after the pair branch so unpaired users still get the badge swept,
        // and so paired users get an initial sync without depending on a later
        // scenePhase change firing (.onChange skips the initial value).
        await reconcileLatestAlert()
        await refreshNotificationStatus()
        pushWatchSnapshot()
    }

    /// Refetches the most recent alert in each direction and reconciles local state.
    /// Querying both directions independently means a recent incoming alert can't mask
    /// a stale pendingOutgoing (and vice-versa). Also sweeps any stuck NSE-set badge
    /// when nothing is pending an ack.
    ///
    /// Silent pushes for outgoing-status updates are best-effort and routinely coalesced
    /// by APNs / iOS background throttling — calling this on foreground is what keeps
    /// the "Sent waiting" indicator from staying stale after the partner has acked.
    func reconcileLatestAlert() async {
        // Sender-side ack banners are informational; once the app is foregrounded the
        // StatusIndicatorView already shows the ack emoji, so the lock-screen banner
        // has done its job. Sweep them regardless of pair state.
        await Self.clearDeliveredAckNotifications()

        guard let pair else {
            // Unpaired: there's nothing to fetch, but a badge set before unpair would
            // otherwise persist with no way to clear it.
            pendingOutgoing = nil
            lastIncoming = nil
            reconcileSnoozeState()
            try? await UNUserNotificationCenter.current().setBadgeCount(0)
            pushWatchSnapshot()
            return
        }
        do {
            async let outgoingFetch = CloudKitService.shared.fetchMostRecentAlert(
                pairKey: pair.pairKey, senderDeviceID: pair.myDeviceID
            )
            async let incomingFetch = CloudKitService.shared.fetchMostRecentAlert(
                pairKey: pair.pairKey, senderDeviceID: pair.partnerDeviceID
            )
            let (outgoing, incoming) = try await (outgoingFetch, incomingFetch)
            let dismissedName = UserDefaults.standard.string(forKey: Self.dismissedOutgoingKey)
            let wasDismissed = outgoing?.state == .acknowledged && outgoing?.id.recordName == dismissedName
            pendingOutgoing = wasDismissed ? nil : outgoing
            lastIncoming = incoming
            reconcileSnoozeState()
            if incoming == nil || incoming?.state == .acknowledged {
                try? await UNUserNotificationCenter.current().setBadgeCount(0)
            }
        } catch {
            log.error("reconcile: \(error.localizedDescription)")
        }
        pushWatchSnapshot()
    }

    private static func clearDeliveredAckNotifications() async {
        let center = UNUserNotificationCenter.current()
        let delivered = await center.deliveredNotifications()
        let ackIDs = delivered
            .filter { $0.request.content.categoryIdentifier == Constants.NotificationAction.ackCategory }
            .map(\.request.identifier)
        guard !ackIDs.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers: ackIDs)
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

    func sendAttention(noun: String? = nil) async {
        guard let pair else {
            bannerMessage = AttentionError.noPair.errorDescription
            return
        }
        guard !isOnCooldown else { return }

        let resolvedNoun = noun.flatMap(NounPresets.sanitize) ?? "attention"
        let body = "needs \(resolvedNoun)"

        Haptics.press()
        do {
            // Read the live displayName so renaming yourself in Settings takes effect on
            // the next outgoing alert without needing to re-pair.
            let record = try await CloudKitService.shared.sendAlert(
                pairKey: pair.pairKey,
                senderDeviceID: pair.myDeviceID,
                senderName: UntrustedText.name(settings.displayName),
                message: body,
                critical: false
            )
            UserDefaults.standard.removeObject(forKey: Self.dismissedOutgoingKey)
            pendingOutgoing = record
            cooldownEnds = Date().addingTimeInterval(TimeInterval(settings.cooldownSeconds))
            Haptics.success()
            pushWatchSnapshot()
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
            // The partner sent something new — a snooze on a *previous* incoming no longer
            // applies, so cancel its pending re-notification before it can fire.
            if let current = snooze, current.recordName != alert.id.recordName {
                cancelSnooze()
            }
            // Record it and mark seen.
            lastIncoming = alert
            do {
                let updated = try await CloudKitService.shared.markAlertSeen(recordID: alert.id)
                lastIncoming = updated
            } catch {
                log.error("markAlertSeen: \(error.localizedDescription)")
            }
        }
        pushWatchSnapshot()
    }

    func acknowledgeIncoming(emoji: String?) async {
        guard let alert = lastIncoming else { return }
        // Acknowledging supersedes any snooze — cancel the pending re-notification so it
        // can't fire after the user has already responded. (removeAllDeliveredNotifications
        // below only clears *delivered* ones; the scheduled request needs explicit cancel.)
        cancelSnooze()
        do {
            let updated = try await CloudKitService.shared.acknowledgeAlert(recordID: alert.id, emoji: emoji)
            lastIncoming = updated
            Haptics.success()
            try? await UNUserNotificationCenter.current().setBadgeCount(0)
            UNUserNotificationCenter.current().removeAllDeliveredNotifications()
            pushWatchSnapshot()
        } catch {
            log.error("ack: \(error.localizedDescription)")
        }
    }

    /// Forwarded from the watch via WatchBridge. Guards the recordName against the
    /// current `lastIncoming` so a userInfo-queued ack from a previous alert can't
    /// mark a newer one acknowledged.
    func acknowledgeIncomingFromWatch(recordName: String, emoji: String?) async {
        guard let alert = lastIncoming, alert.id.recordName == recordName else {
            log.debug("dropping stale watch ack for record \(recordName, privacy: .public)")
            return
        }
        guard alert.state != .acknowledged else { return }
        await acknowledgeIncoming(emoji: emoji)
    }

    // MARK: - Snooze (#49)

    /// Defer the current incoming alert: schedule a local re-notification `minutes` out and
    /// dismiss the delivered banner. Local-only — the sender isn't told.
    func snoozeIncoming(minutes: Int) {
        guard let alert = lastIncoming, alert.state != .acknowledged else { return }
        let until = Date().addingTimeInterval(TimeInterval(minutes * 60))
        let recordName = alert.id.recordName
        LocalNotifications.scheduleSnooze(
            recordName: recordName,
            title: alert.senderName.isEmpty ? "Attention" : alert.senderName,
            body: alert.message,
            until: until
        )
        // Clear the currently-showing banner for this alert (the reminder replaces it).
        Task { await LocalNotifications.removeDelivered(matchingRecordName: recordName) }
        let state = SnoozeState(recordName: recordName, until: until)
        state.save()
        snooze = state
        Haptics.light()
        pushWatchSnapshot()
    }

    func cancelSnooze() {
        guard let current = snooze else { return }
        LocalNotifications.cancelSnooze(recordName: current.recordName)
        SnoozeState.clear()
        snooze = nil
        pushWatchSnapshot()
    }

    /// Forwarded from the watch. `minutes == 0` means cancel; otherwise snooze. Guarded
    /// against a stale `recordName` like `acknowledgeIncomingFromWatch`.
    func snoozeIncomingFromWatch(recordName: String, minutes: Int) {
        guard let alert = lastIncoming, alert.id.recordName == recordName else {
            log.debug("dropping stale watch snooze for record \(recordName, privacy: .public)")
            return
        }
        if minutes <= 0 {
            cancelSnooze()
        } else {
            snoozeIncoming(minutes: minutes)
        }
    }

    /// Reconciles the persisted snooze against `lastIncoming`. Called from
    /// `reconcileLatestAlert`. Drops the state when it no longer applies; cancels the
    /// pending re-notification only when the alert was handled or replaced (not when the
    /// snooze simply fired — that delivered reminder should stay).
    private func reconcileSnoozeState() {
        snooze = SnoozeState.load()
        guard let current = snooze else { return }
        let matchesIncoming = lastIncoming?.id.recordName == current.recordName
        let incomingAcked = lastIncoming?.state == .acknowledged
        if !matchesIncoming || incomingAcked {
            LocalNotifications.cancelSnooze(recordName: current.recordName)
            SnoozeState.clear()
            snooze = nil
        } else if !current.isActive {
            // Fired already — leave the delivered reminder, just drop the state so the
            // pill reverts from "Snoozed" to "pending".
            SnoozeState.clear()
            snooze = nil
        }
    }

    /// True when `lastIncoming` is currently snoozed (state matches and hasn't fired).
    var incomingIsSnoozed: Bool {
        guard let current = snooze, current.isActive,
              current.recordName == lastIncoming?.id.recordName else { return false }
        return true
    }

    func clearOutgoing(recordName: String? = nil) {
        guard let outgoing = pendingOutgoing, outgoing.state == .acknowledged else { return }
        if let recordName, outgoing.id.recordName != recordName {
            log.debug("dropping stale watch clear for record \(recordName, privacy: .public)")
            return
        }
        UserDefaults.standard.set(outgoing.id.recordName, forKey: Self.dismissedOutgoingKey)
        pendingOutgoing = nil
        pushWatchSnapshot()
    }

    // MARK: - Remote invite lifecycle

    /// One-shot inviter-side completion check. The pair-update silent push is the fast
    /// path; this is the reliable one — called from bootstrap, foreground, and the push
    /// handler itself. Also re-syncs the observable mirror with the persisted invite
    /// (PairingService writes it directly).
    func reconcilePendingInvite() async {
        pendingInvite = PendingInvite.load()
        guard pair == nil, let pending = pendingInvite else { return }
        do {
            guard let record = try await CloudKitService.shared.fetchPair(pairKey: pending.pairKey),
                  let state = try await PairingService.shared.completeInviterPairing(from: record)
            else { return }
            Haptics.success()
            pendingInvite = nil
            applyPair(state)
        } catch {
            log.error("pending invite reconcile: \(error.localizedDescription)")
        }
    }

    /// Called by ShowCodeView after PairingService persists a fresh invite.
    func refreshPendingInvite() {
        pendingInvite = PendingInvite.load()
    }

    func cancelPendingInvite() async {
        guard let pending = pendingInvite else { return }
        await PairingService.shared.cancelInvite(pending)
        // On success the service cleared the persisted copy; on a failed cleanup it
        // survives as the retry handle and the waiting card stays visible.
        pendingInvite = PendingInvite.load()
    }

    /// Entry point for tapped `attention://pair` links. The payload is untrusted — exactly
    /// as untrusted as a scanned QR — so it goes through the same defensive parser, and
    /// nothing happens without the user confirming in the join sheet.
    func handleIncomingURL(_ url: URL) {
        guard let invite = PairingInvite.from(qrPayload: url.absoluteString) else { return }
        incomingJoinInvite = invite
    }

    // MARK: - Pairing wrapper

    func applyPair(_ state: PairState) {
        self.pair = state
        // Completing a pair consumes any pending invite (the service layer clears the
        // persisted copy); re-sync the observable mirror.
        self.pendingInvite = PendingInvite.load()
        SharedSettings.partnerName = state.partnerName
        // PairingService.{waitForJoiner,completePairing} runs registerSubscriptions
        // immediately before returning the PairState that lands here; pull the latest
        // diagnostic flag now so SettingsView reflects the just-attempted save.
        refreshSubscriptionDiagnostics()
        pushWatchSnapshot()
    }

    /// Mirrors the App-Group flag onto the @Observable property so SwiftUI re-renders.
    /// Cheap and idempotent; safe to call from every code path that registers (or
    /// would have registered) subscriptions.
    func refreshSubscriptionDiagnostics() {
        outgoingAckSubscriptionUnavailable = SharedSettings.outgoingAckSubscriptionUnavailable
        outgoingAckSubscriptionFailureReason = SharedSettings.outgoingAckSubscriptionFailureReason
    }

    func unpair() async {
        await PairingService.shared.unpair()
        pair = nil
        pendingOutgoing = nil
        lastIncoming = nil
        SharedSettings.partnerName = nil
        // No pair means no subscription means the diagnostic doesn't apply. Clear it
        // so reverting to unpaired state resets the warning.
        SharedSettings.outgoingAckSubscriptionUnavailable = false
        SharedSettings.outgoingAckSubscriptionFailureReason = nil
        refreshSubscriptionDiagnostics()
        pushWatchSnapshot()
    }

    // MARK: - Watch snapshot

    /// Snapshot the watch needs to render its status pill. Mirrors the iOS
    /// StatusIndicatorView decision matrix.
    func currentWatchSnapshot() -> WatchSnapshot {
        let outgoingInfo: WatchSnapshot.OutgoingInfo? = pendingOutgoing.map { alert in
            let mappedState: WatchSnapshot.Outgoing
            switch alert.state {
            case .sent: mappedState = .sent
            case .seen: mappedState = .seen
            case .acknowledged: mappedState = .acknowledged
            }
            return WatchSnapshot.OutgoingInfo(
                recordName: alert.id.recordName,
                state: mappedState,
                critical: alert.critical,
                ackEmoji: alert.ackEmoji
            )
        }
        let incomingInfo: WatchSnapshot.IncomingInfo? = lastIncoming.map { alert in
            // Match StatusIndicatorView's "done" predicate: either the explicit state
            // or a non-nil acknowledgedAt timestamp counts. Guards against records that
            // somehow have one signal but not the other.
            let acked = alert.state == .acknowledged || alert.acknowledgedAt != nil
            let snoozedUntil: Date? = (snooze?.recordName == alert.id.recordName && snooze?.isActive == true)
                ? snooze?.until
                : nil
            return WatchSnapshot.IncomingInfo(
                recordName: alert.id.recordName,
                senderName: alert.senderName,
                critical: alert.critical,
                createdAt: alert.createdAt,
                acknowledged: acked,
                message: alert.message,
                snoozedUntil: snoozedUntil
            )
        }
        return WatchSnapshot(
            paired: pair != nil,
            outgoing: outgoingInfo,
            incoming: incomingInfo,
            cooldownEnds: cooldownEnds
        )
    }

    func pushWatchSnapshot() {
        WatchBridge.shared.sendSnapshot(currentWatchSnapshot())
    }

    // MARK: - Display name sync

    /// Pushes the current `settings.displayName` to the Pair record so the partner sees
    /// the updated name. Also updates the local copy in `pair.myName`.
    func syncMyDisplayName() async {
        guard var pair else { return }
        let newName = UntrustedText.name(settings.displayName)
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
            pushWatchSnapshot()
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
            pushWatchSnapshot()
        } catch {
            log.error("refreshPair: \(error.localizedDescription)")
        }
    }
}
