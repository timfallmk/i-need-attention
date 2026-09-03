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

    /// Observable mirror of `CutoverNotice.needsRepair`, which is a plain `UserDefaults`
    /// read and so invisible to SwiftUI. Set here rather than in `bootstrap()`: that runs
    /// from a `.task`, which fires *after* the first render, so the pairing screen drew
    /// itself before the flag existed and nothing told it to draw again.
    var needsRepairAfterCutover: Bool

    init() {
        // First thing, before any view can render and before anything can re-pair. It is
        // synchronous and touches only local storage.
        LegacyHistoryCapture.prepare()
        // Also before anything can read the zone name, since minting one is what makes
        // a stale pairing indistinguishable from a fresh install.
        InboxZone.resetPairingPredatingPerPairingZones()
        self.needsRepairAfterCutover = CutoverNotice.needsRepair

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

        if pair != nil || pendingInvite != nil {
            SharedSettings.partnerName = pair?.partnerName
            // Subscriptions are on our own zone and carry no pair-specific predicate,
            // so an outstanding invite needs them registered too: the joiner's profile
            // record is what closes the handshake, and its push arrives on the same
            // subscription a completed pair uses.
            try? await CloudKitService.shared.registerSubscriptions()
            refreshSubscriptionDiagnostics()
        }
        if pair == nil {
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
        await reconcileHalfFormedPair()
        await refreshPartnerName()
        await LegacyHistoryCapture.run()
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
            // Direction is the zone now, not a senderDeviceID predicate: what we sent
            // lives in their zone, what they sent lives in ours.
            async let outgoingFetch = CloudKitService.shared.fetchMostRecentOutgoing(pair: pair)
            async let incomingFetch = CloudKitService.shared.fetchMostRecentIncoming(pair: pair)
            let (outgoing, incoming) = try await (outgoingFetch, incomingFetch)
            let dismissedName = DismissedOutgoing.recordName
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
            // Read the live displayName so renaming yourself in Settings takes effect
            // on the next outgoing alert without needing to re-pair.
            var sender = pair
            sender.myName = UntrustedText.name(settings.displayName)
            let record = try await CloudKitService.shared.sendAlert(
                pair: sender,
                message: body,
                critical: false
            )
            DismissedOutgoing.clear()
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

        if alert.senderDeviceID == pair.myDeviceID {
            // Shouldn't arrive any more — our own alerts live in the partner's zone and
            // nothing subscribes there — but harmless to keep for a record fetched some
            // other way.
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
                let updated = try await CloudKitService.shared.markAlertSeen(recordID: alert.id, pair: pair)
                lastIncoming = updated
            } catch {
                log.error("markAlertSeen: \(error.localizedDescription)")
            }
        }
        pushWatchSnapshot()
    }

    /// The partner told us what they did with an alert we sent. The notice is the push
    /// carrier; the alert record in their zone stays canonical, so this updates only the
    /// live pill rather than trying to be a second source of truth.
    func applyOutgoingStatus(alertRecordName: String, state: Constants.AlertState, emoji: String?) async {
        // Both guards are legitimate — a notice about an alert we are no longer showing,
        // or one we already applied — but they are also the two ways a delivered push can
        // change nothing, which is indistinguishable from a push that never arrived.
        guard var outgoing = pendingOutgoing, outgoing.id.recordName == alertRecordName else {
            // Read out before interpolating: os_log's interpolation is an escaping
            // autoclosure, and giving it a property to reach for later rather than a
            // value is how the same call site broke once already.
            let showing = pendingOutgoing?.id.recordName ?? "nothing"
            log.notice("Status for \(alertRecordName, privacy: .public) ignored; showing \(showing, privacy: .public)")
            return
        }
        guard state != outgoing.state else {
            log.notice("Status for \(alertRecordName, privacy: .public) already \(state.rawValue, privacy: .public)")
            return
        }

        outgoing.state = state
        if let emoji { outgoing.ackEmoji = emoji }
        switch state {
        case .seen: Haptics.tick()
        case .acknowledged: Haptics.success()
        case .sent: break
        }
        pendingOutgoing = outgoing
        pushWatchSnapshot()
    }

    func acknowledgeIncoming(emoji: String?) async {
        guard let alert = lastIncoming else { return }
        // Acknowledging supersedes any snooze — cancel the pending re-notification so it
        // can't fire after the user has already responded. (removeAllDeliveredNotifications
        // below only clears *delivered* ones; the scheduled request needs explicit cancel.)
        cancelSnooze()
        do {
            guard let pair else { return }
            let updated = try await CloudKitService.shared.acknowledgeAlert(recordID: alert.id, emoji: emoji, pair: pair)
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
        DismissedOutgoing.recordName = outgoing.id.recordName
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
            guard let state = try await PairingService.shared.completeInviterPairing() else { return }
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
    ///
    /// Returns false rather than swallowing the failure: the paste affordance has no
    /// other way to tell a malformed payload from a working app doing nothing, which is
    /// exactly how it read.
    @discardableResult
    func handleIncomingURL(_ url: URL) -> Bool {
        guard let invite = PairingInvite.from(qrPayload: url.absoluteString) else {
            log.notice("Ignoring URL that isn't a pairing invite: \(url.scheme ?? "-", privacy: .public)://\(url.host ?? "-", privacy: .public)")
            return false
        }
        incomingJoinInvite = invite
        return true
    }

    // MARK: - Pairing wrapper

    func applyPair(_ state: PairState) {
        self.pair = state
        // Whatever the cutover cost them, they've paid it.
        CutoverNotice.needsRepair = false
        needsRepairAfterCutover = false
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
        // The last read that will ever succeed against the partner's zone. Half of this
        // pairing's history lives there — the alerts we sent — and leaving the share is
        // what makes it unreachable, so the sweep has to come before the teardown.
        if let pair {
            let pairingID = InboxZone.currentName
            if let live = try? await CloudKitService.shared.fetchRecentAlerts(
                pair: pair, limit: PairingArchive.sweepLimit
            ) {
                PairingArchive.absorb(live, pairingID: pairingID, partnerName: pair.partnerName)
            }
            PairingArchive.close(pairingID: pairingID)
        }
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

    /// Everything this device holds, gone. Deliberately *not* an unpair with extra steps:
    /// unpair archives the pairing on its way out, because history surviving a pairing is
    /// the point of `PairingArchive`. Here the archive is one of the things being
    /// destroyed, so the sweep would be work done only to undo it.
    ///
    /// Remote first, while the pair key that reaches the zone is still in the keychain.
    /// It is also the half that can fail — a signed-out account, no network — and the
    /// local half runs either way: a device that stopped at the first CloudKit error
    /// would keep the archives it was asked to destroy, which is the worse failure.
    func eraseAllData() async {
        await PairingService.shared.eraseRemoteData()
        DataErasure.eraseLocalData(settings: settings)
        DataErasure.clearNotifications()

        pair = nil
        pendingInvite = nil
        incomingJoinInvite = nil
        pendingOutgoing = nil
        lastIncoming = nil
        snooze = nil
        needsRepairAfterCutover = false
        cooldownEnds = nil
        bannerMessage = nil
        outgoingAckSubscriptionUnavailable = false
        outgoingAckSubscriptionFailureReason = nil
        try? await UNUserNotificationCenter.current().setBadgeCount(0)
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

    /// Pushes a display-name change to the partner by updating our profile record in
    /// their zone — the one place we can write and they can read. Local state updates
    /// either way: a failed write is retried on the next rename or carried by the next
    /// alert, which also names its sender.
    func syncMyDisplayName() async {
        guard var pair else { return }
        let newName = UntrustedText.name(settings.displayName)
        guard !newName.isEmpty, newName != pair.myName else { return }

        pair.myName = newName
        pair.save()
        self.pair = pair
        Haptics.light()
        pushWatchSnapshot()

        guard let zone = pair.outgoingZone else { return }
        do {
            try await CloudKitService.shared.writeProfile(
                into: zone.zoneID,
                deviceID: pair.myDeviceID,
                name: newName,
                shareURL: nil,
                pairKey: pair.pairKey
            )
        } catch {
            log.error("profile name write: \(error.localizedDescription)")
        }
    }

    /// Finishes a pairing that only went one way. The inviter is waiting for the
    /// joiner's share to arrive in its zone; the joiner is waiting to learn that the
    /// inviter accepted theirs. Both recover without the user doing anything, so this
    /// runs on launch and on every foreground until it has nothing left to do.
    func reconcileHalfFormedPair() async {
        guard let pair, !pair.isComplete else { return }

        if !pair.canSend, let completed = try? await PairingService.shared.completeInviterPairing() {
            applyPair(completed)
            Haptics.success()
            return
        }
        if let updated = await PairingService.shared.refreshPartnerReachability(pair) {
            self.pair = updated
            pushWatchSnapshot()
        }
    }

    /// Polls until both directions are live, for as long as the one-way banner is up.
    ///
    /// The pair-profile push is supposed to close this window, and now does. But it
    /// cannot be the only thing that does: the joiner registers its subscriptions as the
    /// *last* step of `completePairing`, while the inviter writes the profile that would
    /// trigger the push as soon as its 2-second poll sees the joiner's. The inviter wins
    /// that race often, and the push the joiner needed is then one it was never
    /// subscribed for — which is exactly the state that left the banner up until the
    /// screen locked. So the joiner asks as well as listens.
    ///
    /// Each pass is one fetch of a share we own. Bounded because a partner who never
    /// finishes is a pairing to abandon, not to poll forever.
    func awaitPartnerReachability(timeout: TimeInterval = 120) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !Task.isCancelled, Date() < deadline {
            guard let pair, !pair.isComplete else { return }
            await reconcileHalfFormedPair()
            guard self.pair?.isComplete != true else { return }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }

    /// Pulls a partner rename out of our own zone. Cheap enough to run on every
    /// foreground; the profile subscription is what makes it immediate.
    func refreshPartnerName() async {
        guard let pair else { return }
        guard let updated = await PairingService.shared.refreshPartnerName(pair) else { return }
        self.pair = updated
        SharedSettings.partnerName = updated.partnerName
        pushWatchSnapshot()
    }

}
