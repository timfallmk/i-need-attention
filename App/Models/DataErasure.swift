import Foundation
import UserNotifications

/// Every store on this device that holds something about the user, in one list.
///
/// The point of gathering them here rather than leaving them at their call sites is that
/// "Erase all my data" is a promise, and a promise is only as good as the audit you can
/// run against it. A new persisted store means a new line here; forgetting one is a
/// broken promise rather than a missing feature, which is why `DataErasureTests` asserts
/// against the list rather than against the button.
///
/// Local only — the inbox zone is torn down by `PairingService.eraseRemoteData()`, which
/// can fail on a bad network and must not take the local half down with it.
///
/// What no part of the erase touches is the *partner's* zone. The alerts you sent live
/// there, in storage they own, and reaching into it would be this device deleting someone
/// else's records. 2.0 is what makes that defensible rather than a gap: those records are
/// sealed under the pair key, and dropping the key is part of what happens here — what
/// stays behind in their zone is ciphertext nothing on this device can open again.
enum DataErasure {
    /// `PairState.clear()` and `PendingInvite.clear()` drop their keychain items as part
    /// of clearing, so the live pair key and any un-accepted invite key go with them; the
    /// stashed pre-2.0 key has no owner that clears it, so it is removed directly.
    static func eraseLocalData(settings: UserSettings) {
        PairState.clear()
        PendingInvite.clear()
        CutoverNotice.needsRepair = false
        PartnerUnpairedNotice.happened = false
        UnpairedElsewhereNotice.happened = false
        AccountIdentityPublished.done = false
        DismissedOutgoing.clear()

        LegacyPairing.clear()
        LegacyHistoryCaptureState.clear()
        PairSecrets.store.removeSecret(for: Constants.Keychain.legacyHistoryKeyAccount)

        PairingArchive.clear()
        LegacyHistoryArchive.clear()

        SnoozeState.clear()
        MetricKitSummary.clear()

        settings.resetToDefaults()
        DeviceIdentity.reset()
        AccountIdentity.clear()

        // Last, so the defaults `resetToDefaults` just mirrored into the suite go too.
        // The getters there fall back to the same values, so the NSE reads an erased
        // suite identically to a first-launch one.
        SharedSettings.clearAll()
    }

    /// Notifications already delivered quote the partner's name and message, so they are
    /// user data sitting outside every store above — on the lock screen, at that.
    static func clearNotifications() {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
    }
}
