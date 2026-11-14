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
/// Every refusal needs positive evidence. `recentIncoming` comes from a query, and a
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

    /// `recentIncoming` rather than only the newest alert, because the answered one
    /// need not be the newest: with a third request waiting on top, the newest alert is
    /// unanswered and says nothing about the one in between.
    static func decide(tapped: AlertRecord, recentIncoming: [AlertRecord]) -> BannerAckDecision {
        if tapped.state == .acknowledged { return .alreadyAcknowledged }
        let answeredSince = recentIncoming.contains { other in
            other.id.recordName != tapped.id.recordName
                && other.createdAt > tapped.createdAt
                && other.state == .acknowledged
        }
        return answeredSince ? .supersededByAnAnsweredAlert : .acknowledge
    }

    /// Whether a pending snooze should be dropped now that `tapped` has been
    /// acknowledged from its banner.
    ///
    /// A snooze on an alert no newer than the one just answered is spent: its reminder
    /// would fire later as a request for attention nobody made. `AppState` enforces the
    /// same thing when a newer alert arrives, but in code a banner-only user never runs.
    ///
    /// `snoozedAlert` is the snoozed record fetched by ID, which is consistent where a
    /// query is not. Nil means it could not be read, and then the snooze is kept:
    /// cancelling the reminder for an alert that is still waiting is the worse mistake.
    static func shouldCancelSnooze(on snoozedRecordName: String,
                                   snoozedAlert: AlertRecord?,
                                   afterAcknowledging tapped: AlertRecord) -> Bool {
        if snoozedRecordName == tapped.id.recordName { return true }
        guard let snoozedAlert else { return false }
        return snoozedAlert.createdAt <= tapped.createdAt
    }
}
