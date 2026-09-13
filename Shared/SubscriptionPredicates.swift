import Foundation

/// Pure builders for the four CKQuerySubscription predicates. Extracted from
/// `CloudKitService` so the exact predicate — where a single wrong operator silently
/// stops push delivery — is unit-testable without a live `CKDatabase`. Only `NSPredicate`
/// (Foundation), no CloudKit, so it compiles into every target.
///
/// From 2.0 every subscription is scoped to this device's own inbox zone, and only the
/// partner can write there, so most of the filtering the pre-2.0 predicates did — "this
/// pair", "not my own device" — is the zone's job now. What is left is the one
/// distinction the zone can't make: which status change deserves a banner.
enum SubscriptionPredicates {
    /// Everything in the zone, for subscriptions where the zone is the whole filter.
    ///
    /// A record type plus a zone is the entire condition, so this is deliberately
    /// `TRUEPREDICATE` rather than a contrived always-true comparison. It is one of the
    /// things a two-device run has to confirm: CloudKit accepts it for zone-scoped query
    /// subscriptions, but that is not the kind of claim to take on trust.
    static var everythingInZone: NSPredicate {
        NSPredicate(value: true)
    }

    /// Incoming alerts: any Alert in our own zone. Only the partner can write there.
    static func incomingAlerts() -> NSPredicate {
        everythingInZone
    }

    /// Outgoing status: any AlertStatus the partner leaves us — silent push, so it
    /// covers "seen" as well as the acknowledgement the ack subscription also catches.
    static func outgoingStatus() -> NSPredicate {
        everythingInZone
    }

    /// Outgoing ack: the AlertStatus that says they acknowledged, which is the only one
    /// that earns a visible banner.
    static func outgoingAck() -> NSPredicate {
        NSPredicate(
            format: "%K == %@",
            Constants.AlertStatusField.state, Constants.AlertState.acknowledged.rawValue
        )
    }

    /// Incoming answered: an Alert in our own zone that has reached `acknowledged`.
    ///
    /// The same field and value as `outgoingAck` but on the other record type, which is
    /// the difference between "they answered something I sent" and "something sent to me
    /// has been answered, by one of my devices". Only the second can clear a banner.
    static func incomingAnswered() -> NSPredicate {
        NSPredicate(
            format: "%K == %@",
            Constants.AlertField.state, Constants.AlertState.acknowledged.rawValue
        )
    }

    /// Pair profile: the partner introducing themselves or renaming themselves. One per
    /// zone, so again the zone is the filter.
    static func pairProfile() -> NSPredicate {
        everythingInZone
    }
}
