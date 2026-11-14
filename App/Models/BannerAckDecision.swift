import CloudKit
import Foundation

/// What to do with an ack action tapped on a notification.
///
/// A notification outlives the moment it was delivered in. It sits in Notification
/// Center until somebody touches it, with its ack buttons live, while the alert it names
/// gets answered some other way — in the app, from the watch, or by answering a later
/// alert instead. The in-app and watch paths can only ever reach the alert on screen;
/// this is the same judgement for the one path that takes its target from the
/// notification itself.
///
/// Every refusal needs positive evidence. `newestIncoming` comes from a query, and a
/// CloudKit query can lag a record that was written a moment ago or fail outright, so
/// "the query didn't mention it" never counts against an ack: an acknowledgement the
/// partner never receives is a worse failure than a redundant one.
enum BannerAckDecision: Equatable {
    case acknowledge
    /// Already answered. Acknowledging again changes nothing the user can see and used
    /// to push the sender a second "Got back to you" for it.
    case alreadyAcknowledged
    /// A later alert has been answered since. The partner has their reply; one more
    /// for the request before it reads as a reply to something they never sent.
    case supersededByAnAnsweredAlert

    static func decide(tapped: AlertRecord, newestIncoming: AlertRecord?) -> BannerAckDecision {
        if tapped.state == .acknowledged { return .alreadyAcknowledged }
        if let newest = newestIncoming,
           newest.id.recordName != tapped.id.recordName,
           newest.createdAt > tapped.createdAt,
           newest.state == .acknowledged {
            return .supersededByAnAnsweredAlert
        }
        return .acknowledge
    }

    /// Whether a pending snooze should be dropped now that `tapped` has been
    /// acknowledged from its banner.
    ///
    /// The app holds one snooze, and only for the newest incoming alert — a newer one
    /// arriving cancels it in `AppState.handleIncomingChange`. That rule is enforced by
    /// code a banner-only user never runs, so it is enforced again here: a snooze
    /// survives an ack only when it belongs to a newer alert than the one just answered.
    /// Otherwise its reminder fires later as a request for attention nobody made.
    static func shouldCancelSnooze(on snoozedRecordName: String,
                                   afterAcknowledging tapped: AlertRecord,
                                   newestIncoming: AlertRecord?) -> Bool {
        if snoozedRecordName == tapped.id.recordName { return true }
        guard let newest = newestIncoming else { return false }
        let snoozedIsNewerThanTapped = newest.id.recordName == snoozedRecordName
            && newest.createdAt > tapped.createdAt
        return !snoozedIsNewerThanTapped
    }
}
