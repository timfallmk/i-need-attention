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

    /// Scripted demo timers. Held so leaving the demo cancels them rather than letting a
    /// fictional partner answer into a screen that has moved on.
    private var demoScript: Task<Void, Never>?
    private var demoSend: Task<Void, Never>?

    /// Set when an erase completed locally but could not reach iCloud. Lives here rather
    /// than on SettingsView because that sheet does not survive the erase: clearing `pair`
    /// re-evaluates RootView, and a signed-out device swaps to the iCloud gate, tearing
    /// the sheet — and any alert it was presenting — down mid-presentation. The one
    /// message the user must not miss was the one being destroyed.
    var eraseLeftRemoteData = false

    /// True only while the self-contained demo is running. Deliberately not persisted:
    /// a relaunch ends it, so it can never be mistaken for a real pairing, and there is
    /// no stored state that a later launch would have to reconcile.
    ///
    /// `pair` stays nil throughout, which is what makes the demo safe rather than merely
    /// careful — every CloudKit path below opens with `guard let pair else { return }`.
    private(set) var isDemo = false

    /// Who the main screen says you are paired with, real or scripted.
    var partnerDisplayName: String? {
        isDemo ? DemoSession.partnerName : pair?.partnerName
    }

    /// Observable mirror of `CutoverNotice.needsRepair`, which is a plain `UserDefaults`
    /// read and so invisible to SwiftUI. Set here rather than in `bootstrap()`: that runs
    /// from a `.task`, which fires *after* the first render, so the pairing screen drew
    /// itself before the flag existed and nothing told it to draw again.
    var needsRepairAfterCutover: Bool
    var partnerEndedPairing: Bool
    var pairingEndedOnAnotherDevice: Bool

    init() {
        // First thing, before any view can render and before anything can re-pair. It is
        // synchronous and touches only local storage.
        LegacyHistoryCapture.prepare()
        // Also before anything can read the zone name, since minting one is what makes
        // a stale pairing indistinguishable from a fresh install.
        InboxZone.resetPairingPredatingPerPairingZones()
        self.needsRepairAfterCutover = CutoverNotice.needsRepair
        self.partnerEndedPairing = PartnerUnpairedNotice.happened
        self.pairingEndedOnAnotherDevice = UnpairedElsewhereNotice.happened

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
            await registerSubscriptions()
        }
        // Before anything reads the pairing as live: another device on this Apple ID may
        // have ended it while this one was gone, and the zone it deleted is the one this
        // device reads. Runs ahead of the adopt below so a person who unpaired and then
        // paired with someone else lands on the new pairing in a single pass.
        await endPairingIfOurZoneIsGone()
        if pair == nil {
            // A pending remote invite may have been accepted while this app was gone —
            // the silent push never reaches a force-quit app, so reconcile on launch.
            await reconcilePendingInvite()
            // Before concluding this install is unpaired: another device on this Apple
            // ID may already have done the pairing, in which case there is nothing to
            // ask the user for.
            await adoptPairingFromThisAccount()
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
        await refreshPartnerProfile()
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
                // The same sweep `handleAnsweredElsewhere` does, for the case its silent
                // push cannot reach: a force-quit app is never woken by one, so a device
                // closed when the alert was answered elsewhere still has that banner when
                // it next opens.
                //
                // Only this record's, deliberately. Clearing the whole category would
                // also take a banner that is still wanted: `fetchMostRecentIncoming`
                // returns the newest alert by creation date, and its being acknowledged
                // says nothing about an older one that is still `sent`. Removing a
                // notification the user has not answered is a worse failure than leaving
                // a stale one they have.
                if let answered = incoming {
                    await LocalNotifications.removeDelivered(matchingRecordName: answered.id.recordName)
                }
            }
        } catch {
            // Either fetch can raise this, and only one of them means anything: our own
            // zone missing is a gap `bootstrap` closes, the partner's means they have
            // unpaired. `endPairingIfPartnerZoneIsGone` checks which.
            if await endPairingIfPartnerZoneIsGone(error, pair: pair) { return }
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
        if isDemo {
            await runDemoSend(noun: noun)
            return
        }
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
            // A send always targets the partner's zone, so a missing one here needs no
            // further attribution — but it is still confirmed before acting, because the
            // consequence is ending the pairing.
            if await endPairingIfPartnerZoneIsGone(error, pair: pair) { return }
            log.error("sendAttention: \(error.localizedDescription)")
            bannerMessage = error.localizedDescription
            Haptics.warning()
        }
    }

    // MARK: - Receiving

    /// An alert *sent to us* has been acknowledged — possibly on this device, possibly
    /// on another one signed into the same Apple Account.
    ///
    /// It exists for the second case, and only code running on this device can serve it:
    /// `removeDeliveredNotifications` reaches the notification centre of its own process
    /// and nothing else, so a banner sitting on this phone for an alert answered on the
    /// iPad can be taken down by this phone or by nobody. In an app whose whole premise
    /// is one urgent notification, a pile of banners for things already answered is what
    /// would make a second device worse than no second device.
    ///
    /// Everything here is idempotent, because the subscription cannot filter on who
    /// wrote the change and so fires for this device's own acknowledgements too.
    func handleAnsweredElsewhere(_ alert: AlertRecord) async {
        guard let pair, alert.state == .acknowledged else { return }
        // Only ever about alerts we received. One we sent lives in the partner's zone and
        // could not have triggered a subscription on ours, but the check is free and the
        // branch below would otherwise overwrite `lastIncoming` with our own alert.
        guard !pair.isMine(senderUserID: alert.senderUserID,
                           senderDeviceID: alert.senderDeviceID) else { return }

        await LocalNotifications.removeDelivered(matchingRecordName: alert.id.recordName)
        if snooze?.recordName == alert.id.recordName { cancelSnooze() }
        // Only when it is the one we are showing. A device that never saw this alert —
        // force-quit, or the push coalesced — has nothing to update, and surfacing an
        // older alert it had already moved past would be worse than leaving it.
        if lastIncoming?.id.recordName == alert.id.recordName {
            lastIncoming = alert
        }
        // Only when nothing is still waiting. The badge belongs to the app rather than to
        // this alert, so clearing it for an older one answered on another device would
        // drop the count for a newer one this device is still showing.
        if lastIncoming == nil || lastIncoming?.state == .acknowledged {
            try? await UNUserNotificationCenter.current().setBadgeCount(0)
        }
        pushWatchSnapshot()
    }

    /// Called by PushNotifications when a new alert (or alert update) arrives.
    func handleIncomingChange(_ alert: AlertRecord) async {
        guard let pair else { return }

        if pair.isMine(senderUserID: alert.senderUserID, senderDeviceID: alert.senderDeviceID) {
            // Shouldn't arrive any more — our own alerts live in the partner's zone and
            // nothing subscribes there — but harmless to keep for a record fetched some
            // other way.
            if pendingOutgoing?.id == alert.id {
                pendingOutgoing = alert
                if alert.state == .seen { Haptics.tick() }
                if alert.state == .acknowledged { Haptics.success() }
            }
        } else if alert.id.zoneID.zoneName == InboxZone.storedName {
            // Everything else in the zone we own is theirs, and that is a claim about
            // the zone rather than about the sender: only an accepted share participant
            // can write there, and we are not writing into our own inbox. Since it is a
            // claim about the zone, the zone is checked rather than assumed — the router
            // takes the record ID straight from the push, so a subscription left on an
            // orphaned zone would otherwise deliver a previous pairing's alert here as
            // if it were current.
            //
            // The rejected case used to be `senderDeviceID == pair.partnerDeviceID`,
            // which silently dropped an alert sent from the partner's *second* device —
            // no branch, no log line, no banner. Deciding by zone cannot have that
            // failure, whether or not either side has an account identity yet.

            // A snooze on a *previous* incoming no longer applies, so cancel its pending
            // re-notification before it can fire.
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
        } else {
            // Neither ours nor from the zone we own. Logged rather than dropped in
            // silence: the only way here is a push for a zone this device no longer
            // uses, which is worth seeing in Console rather than inferring from a
            // notification that never arrived.
            let zone = alert.id.zoneID.zoneName
            log.error("Alert from unexpected zone \(zone, privacy: .public); ignoring")
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
        if isDemo {
            demoAcknowledge(emoji: emoji)
            return
        }
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
        let state = SnoozeState(recordName: recordName, until: until)
        // A demo shows the pill flip to "Snoozed" and stops there. Scheduling the real
        // reminder would outlive the demo — a notification arriving an hour later about
        // a partner who does not exist — and saving it would leave state on disk that a
        // later launch has to explain away.
        if !isDemo {
            LocalNotifications.scheduleSnooze(
                recordName: recordName,
                title: alert.senderName.isEmpty ? "Attention" : alert.senderName,
                body: alert.message,
                until: until
            )
            // Clear the currently-showing banner for this alert (the reminder replaces it).
            Task { await LocalNotifications.removeDelivered(matchingRecordName: recordName) }
            state.save()
        }
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
        if !isDemo { DismissedOutgoing.recordName = outgoing.id.recordName }
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
        // Whatever the cutover cost them, they've paid it. Same for a partner who
        // ended the last pairing — they have a partner again, so the explanation for
        // not having one is spent.
        CutoverNotice.needsRepair = false
        needsRepairAfterCutover = false
        PartnerUnpairedNotice.happened = false
        partnerEndedPairing = false
        UnpairedElsewhereNotice.happened = false
        pairingEndedOnAnotherDevice = false
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

    /// Set when subscription registration failed, so a foreground can try again.
    ///
    /// Every site that registers does it best-effort, and nothing retried until the next
    /// cold launch — which for an adopted pairing means a device that looks paired,
    /// reads and writes fine, and never receives a push. Cheap once clear: the retry
    /// only lists subscriptions while this is set.
    private var subscriptionsNeedRetry = false

    func registerSubscriptions() async {
        guard pair != nil || pendingInvite != nil else { return }
        do {
            try await CloudKitService.shared.registerSubscriptions()
            subscriptionsNeedRetry = false
        } catch {
            subscriptionsNeedRetry = true
            log.error("registerSubscriptions: \(error.localizedDescription)")
        }
        refreshSubscriptionDiagnostics()
    }

    func retrySubscriptionsIfNeeded() async {
        guard subscriptionsNeedRetry else { return }
        await registerSubscriptions()
    }

    /// Mirrors the App-Group flag onto the @Observable property so SwiftUI re-renders.
    /// Cheap and idempotent; safe to call from every code path that registers (or
    /// would have registered) subscriptions.
    func refreshSubscriptionDiagnostics() {
        outgoingAckSubscriptionUnavailable = SharedSettings.outgoingAckSubscriptionUnavailable
        outgoingAckSubscriptionFailureReason = SharedSettings.outgoingAckSubscriptionFailureReason
    }

    /// Ends the pairing when the error says the partner's zone is gone, which is what
    /// their `unpair()` leaves behind — it deletes the zone this device writes into.
    ///
    /// Two guards, because the failure mode of getting this wrong is unpairing someone
    /// who is still perfectly paired. The error itself must be a definite missing-zone
    /// code rather than any CloudKit failure, and the zone must then be *confirmed* gone
    /// by a lookup that answers "can't tell" as false. Only both together act.
    ///
    /// The confirmation also settles which zone the error was about: `reconcileLatestAlert`
    /// reads our own zone and the partner's together, and our own briefly not existing is
    /// an ordinary startup state rather than the end of a relationship.
    ///
    /// Returns true when it took over, so callers skip their own error handling.
    @discardableResult
    private func endPairingIfPartnerZoneIsGone(_ error: Error, pair: PairState) async -> Bool {
        guard error.isMissingCloudKitZone, let zone = pair.outgoingZone else { return false }
        guard await CloudKitService.shared.zoneIsMissing(zone.zoneID) else { return false }

        log.notice("Partner's inbox zone is gone; ending the pairing on this device too")
        PartnerUnpairedNotice.happened = true
        partnerEndedPairing = true
        // Archives first, as every unpair does. The sent half is already unreachable —
        // that is what got us here — but the received half is in the zone we own, and
        // `fetchRecentAlerts` tolerates one zone failing without losing the other.
        await unpair()
        Haptics.warning()
        return true
    }

    /// Ends the pairing when the zone *we* own is gone, which is what another device
    /// signed into this Apple Account leaves behind when it unpairs or erases: the
    /// private database is per account, so its `unpair()` deleted the zone every device
    /// on the account was reading.
    ///
    /// Same standard of proof as the partner-side check, for the same reason — the cost
    /// of getting it wrong is unpairing somebody who is fine. `ownedInboxZoneIsGone`
    /// lists the account's zones afresh and answers every failure as "can't tell", which
    /// does nothing. The iCloud guard is that rule one step earlier: a signed-out or
    /// not-yet-determined account is not evidence of anything.
    ///
    /// Deliberately does not gate on `pair != nil`, which would miss the case this
    /// exists for. The other device's unpair drops the synchronizable pair key, that
    /// deletion propagates, and a device without the key loads no `PairState` at all —
    /// so by the time this runs the pairing may already have gone quiet rather than
    /// ended, leaving the pairing screen with nothing to say. `hasStoredBlob` is the
    /// key-independent half; the zone being gone is what turns it from "can't read it
    /// right now" into "it is over".
    ///
    /// Clears the stored zone name rather than rotating it, because there is no zone to
    /// tear down and a name held here is what would stop `adoptPairingFromThisAccount`
    /// picking up whatever pairing this account has next.
    func endPairingIfOurZoneIsGone() async {
        guard iCloudStatus == .available else { return }
        guard pair != nil || PairState.hasStoredBlob else { return }
        guard await CloudKitService.shared.ownedInboxZoneIsGone() else { return }

        // Which of the two causes this is. Signing into a different Apple Account makes
        // our zone unfindable too, and blaming another device for that would be a plain
        // lie. `AccountIdentity.id` is the last account this install actually saw, so it
        // answers even for a pairing too old to carry `myUserID` and for one whose key
        // has already gone — the cases the pairing alone cannot speak for.
        let sameAccount: Bool
        if let known = pair?.myUserID ?? AccountIdentity.id,
           let now = await CloudKitService.shared.currentUserID() {
            sameAccount = known == now
        } else {
            sameAccount = true
        }

        log.notice("Our own inbox zone is gone; ending the pairing (same account: \(sameAccount))")
        UnpairedElsewhereNotice.happened = sameAccount
        pairingEndedOnAnotherDevice = sameAccount
        await endPairingAfterItEndedElsewhere()
        Haptics.warning()
    }

    func unpair() async {
        await archiveCurrentPairing()
        await PairingService.shared.unpair()
        forgetPairingLocally()
    }

    /// Ends a pairing that is already over, touching nothing the account shares.
    ///
    /// The difference from `unpair()` is the whole point, and getting it wrong destroys
    /// a working pairing. By the time this runs the person may have paired again from
    /// another device, and two of the things `unpair()` does are account-wide rather
    /// than local: `PairState.clear()` deletes the synchronizable pair key — which by
    /// then is the *new* pairing's, and the deletion propagates — and the teardown's
    /// `removeAllSubscriptions()` deletes every subscription in the private database,
    /// including the ones the new pairing just registered.
    ///
    /// So this archives, forgets locally, and stops. There is nothing remote left to
    /// tear down anyway: the zone this device owned is what went missing.
    private func endPairingAfterItEndedElsewhere() async {
        await archiveCurrentPairing()
        PairState.forgetLocally()
        PendingInvite.clear()
        // Cleared rather than rotated: a name held here is what would stop
        // `adoptPairingFromThisAccount` picking up whatever this account pairs with next.
        InboxZone.clear()
        forgetPairingLocally()
    }

    /// The last read that will ever succeed against the partner's zone. Half of this
    /// pairing's history lives there — the alerts we sent — and leaving the share is
    /// what makes it unreachable, so the sweep has to come before any teardown.
    private func archiveCurrentPairing() async {
        guard let pair else { return }
        let pairingID = InboxZone.currentName
        if let live = try? await CloudKitService.shared.fetchRecentAlerts(
            pair: pair, limit: PairingArchive.sweepLimit
        ) {
            PairingArchive.absorb(live, pairingID: pairingID, partnerName: pair.partnerName)
        }
        PairingArchive.close(pairingID: pairingID)
    }

    /// The observable half, shared by every way a pairing can end.
    private func forgetPairingLocally() {
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
    /// Returns false when the iCloud half didn't complete. The local half always does,
    /// so the erase is never partial on this device — but the records in the user's own
    /// iCloud may still be there, and Settings promises otherwise, so the caller has to
    /// say so rather than let a failed delete pass for a successful one.
    @discardableResult
    func eraseAllData() async -> Bool {
        // Settings is reachable from the demo, so erase can be tapped mid-script. Ending
        // it first does two things: cancels the timers, which would otherwise fire after
        // the erase and put a scripted alert back into state it had just cleared; and
        // drops `isDemo`, without which the user is told their data is gone and then left
        // on a screen still saying "paired with Sam".
        endDemo()

        let remoteSucceeded = await PairingService.shared.eraseRemoteData()
        DataErasure.eraseLocalData(settings: settings)
        DataErasure.clearNotifications()

        pair = nil
        pendingInvite = nil
        incomingJoinInvite = nil
        pendingOutgoing = nil
        lastIncoming = nil
        snooze = nil
        needsRepairAfterCutover = false
        partnerEndedPairing = false
        pairingEndedOnAnotherDevice = false
        cooldownEnds = nil
        bannerMessage = nil
        outgoingAckSubscriptionUnavailable = false
        outgoingAckSubscriptionFailureReason = nil
        try? await UNUserNotificationCenter.current().setBadgeCount(0)
        pushWatchSnapshot()
        eraseLeftRemoteData = !remoteSucceeded
        return remoteSucceeded
    }

    // MARK: - Demo

    /// Starts the self-contained walkthrough. Reachable from the pairing screen and the
    /// iCloud gate — the two places someone can otherwise get stuck.
    func startDemo() {
        guard pair == nil, !isDemo else { return }
        isDemo = true
        pendingOutgoing = nil
        lastIncoming = nil
        snooze = nil
        bannerMessage = nil
        cooldownEnds = nil

        demoScript?.cancel()
        demoScript = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(DemoSession.incomingAfter * 1_000_000_000))
            guard !Task.isCancelled, let self, self.isDemo else { return }
            self.lastIncoming = DemoSession.incoming()
            Haptics.light()
        }
    }

    /// Leaves the demo and returns to pairing. Everything it touched was in memory, so
    /// there is nothing to tear down beyond dropping it.
    func endDemo() {
        guard isDemo else { return }
        demoScript?.cancel()
        demoScript = nil
        demoSend?.cancel()
        demoSend = nil
        isDemo = false
        pendingOutgoing = nil
        lastIncoming = nil
        snooze = nil
        bannerMessage = nil
        cooldownEnds = nil
    }

    /// The scripted partner: notices, then answers. Runs on a task so the cooldown and
    /// the status pill behave exactly as they do against a real one.
    private func runDemoSend(noun: String?) async {
        guard !isOnCooldown else { return }
        Haptics.press()

        let sent = DemoSession.outgoing(
            from: DeviceIdentity.id,
            senderName: settings.displayName,
            noun: noun
        )
        pendingOutgoing = sent
        cooldownEnds = Date().addingTimeInterval(TimeInterval(settings.cooldownSeconds))

        demoSend?.cancel()
        demoSend = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(DemoSession.seenAfter * 1_000_000_000))
            guard !Task.isCancelled, let self, self.isDemo,
                  self.pendingOutgoing?.id == sent.id else { return }
            let seen = DemoSession.advanced(sent, to: .seen)
            self.pendingOutgoing = seen

            try? await Task.sleep(
                nanoseconds: UInt64(DemoSession.acknowledgedAfterSeen * 1_000_000_000)
            )
            guard !Task.isCancelled, self.isDemo,
                  self.pendingOutgoing?.id == sent.id else { return }
            // Advance from `seen`, not from `sent`. Acknowledging a record that was never
            // seen backfills seenAt with the acknowledgement time, which would show a
            // partner who answered at the same instant they noticed.
            self.pendingOutgoing = DemoSession.advanced(
                seen, to: .acknowledged, emoji: DemoSession.ackEmoji
            )
            Haptics.success()
        }
    }

    /// Answering the scripted partner's alert. Local only — there is no status record to
    /// write back to, because there is no zone and no partner.
    private func demoAcknowledge(emoji: String?) {
        guard let incoming = lastIncoming, incoming.state != .acknowledged else { return }
        lastIncoming = DemoSession.advanced(incoming, to: .acknowledged, emoji: emoji)
        snooze = nil
        Haptics.success()
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
        // The watch is a real second screen showing a real pairing. A demo snapshot would
        // put a fictional partner on someone's wrist and outlive the demo there.
        guard !isDemo else { return }
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

    /// Adopts a pairing another device signed into this Apple ID has already made.
    ///
    /// Runs on launch and on every foreground rather than once, because what it waits
    /// on — the pair key arriving over iCloud Keychain — happens on its own schedule and
    /// announces nothing. A device that comes up too early simply finds nothing and is
    /// picked up by the next pass, which is why every failure inside is silent.
    ///
    /// The user is not asked. Nothing is being granted that they have not already
    /// granted: Apple authenticated the account, the key synced under their iCloud
    /// Keychain, and the share the first device accepted was accepted for the account
    /// rather than for that install. A confirmation sheet here would be asking
    /// permission to read state that is already on the device.
    func adoptPairingFromThisAccount() async {
        // `!isDemo` for the same reason `startDemo` guards on `pair == nil`: the two are
        // alternative states, and a foreground during a walkthrough must not quietly
        // turn it into a real pairing underneath the person trying the app out.
        guard pair == nil, pendingInvite == nil, !isDemo else { return }

        // Before looking for somebody else's pairing, check whether our own has simply
        // become readable. `AppState.pair` is loaded once in `init`, and `PairState.load`
        // returns nil without the keychain — an `AfterFirstUnlock` item that a launch
        // before the first unlock, or a restore whose iCloud Keychain has not caught up,
        // will beat. Without this the blob loads fine from the next call onward and
        // nothing ever assigns it, so the device sits on the pairing screen with a
        // perfectly good pairing on disk until it is relaunched.
        if let restored = PairState.load() {
            applyPair(restored)
            return
        }

        guard let adopted = await PairingService.shared.adoptExistingPairing() else { return }

        applyPair(adopted)
        // Immediately rather than at next launch: without it the first alert the partner
        // sends would arrive silently. Tracked so a transient failure is retried on the
        // next foreground instead of leaving an apparently-paired device with no pushes.
        await registerSubscriptions()
        // A fresh install has no name of its own, and the pairing knows the one the
        // partner already sees. Only fill a blank — never overwrite a name the user has
        // typed on this device.
        if UntrustedText.name(settings.displayName).isEmpty {
            settings.displayName = adopted.myName
        }
        Haptics.success()
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

    /// Pulls whatever the partner has told us about themselves out of the zone we own:
    /// a rename, and — once — the account identity that replaces device IDs for deciding
    /// whose alert is whose. Cheap enough to run on every foreground; the profile
    /// subscription is what makes it immediate.
    ///
    /// Publishes ours in the same pass, because the exchange deadlocks otherwise: each
    /// side learns the other's by reading a profile, and nothing writes one except a
    /// rename, so whoever upgraded first would wait forever.
    func refreshPartnerProfile() async {
        guard var pair else { return }

        // Ours costs nothing after the first call — `currentUserID` caches for the life
        // of the process — and a pairing made before per-account identity has to pick it
        // up from somewhere.
        if pair.myUserID == nil, let mine = await CloudKitService.shared.currentUserID() {
            pair.myUserID = mine
            if pair.save() { self.pair = pair }
        }
        await PairingService.shared.publishAccountIdentity(pair)

        guard let updated = await PairingService.shared.refreshFromPartnerProfile(pair) else {
            return
        }
        self.pair = updated
        SharedSettings.partnerName = updated.partnerName
        pushWatchSnapshot()
    }

}
