import Foundation

/// Pure builders for the four CKQuerySubscription predicates. Extracted from
/// `CloudKitService` so the exact predicate — where a single wrong operator silently
/// stops push delivery — is unit-testable without a live `CKDatabase`. Only `NSPredicate`
/// (Foundation), no CloudKit, so it compiles into every target.
enum SubscriptionPredicates {
    /// Incoming alerts: Alert creations in this pair by the *partner* (excludes my own).
    static func incomingAlerts(pairKey: String, myDeviceID: String) -> NSPredicate {
        NSPredicate(
            format: "%K == %@ AND %K != %@",
            Constants.AlertField.pairKey, pairKey,
            Constants.AlertField.senderDeviceID, myDeviceID
        )
    }

    /// Outgoing status: updates to Alerts *I* sent (seen / acknowledged) — silent push.
    static func outgoingStatus(pairKey: String, myDeviceID: String) -> NSPredicate {
        NSPredicate(
            format: "%K == %@ AND %K == %@",
            Constants.AlertField.pairKey, pairKey,
            Constants.AlertField.senderDeviceID, myDeviceID
        )
    }

    /// Outgoing ack: an Ack record naming me as the recipient (my partner acked my alert).
    static func outgoingAck(pairKey: String, myDeviceID: String) -> NSPredicate {
        NSPredicate(
            format: "%K == %@ AND %K == %@",
            Constants.AckField.pairKey, pairKey,
            Constants.AckField.recipientDeviceID, myDeviceID
        )
    }

    /// Pair updates: any change to this pair's Pair record (partner renamed themselves).
    static func pairUpdates(pairKey: String) -> NSPredicate {
        NSPredicate(format: "%K == %@", Constants.PairField.pairKey, pairKey)
    }
}
