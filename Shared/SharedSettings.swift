import Foundation

/// Settings the NSE consults at notification delivery time. Lives in the App Group suite so
/// the main app (writer) and the NSE process (reader) see the same values. Covers both
/// receiver-side settings (incoming alert priority and sound) and sender-side settings
/// (whether outgoing-ack banners are shown as active-level interruptions).
enum SharedSettings {
    private static let suite = UserDefaults(suiteName: Constants.AppGroup.identifier)
        ?? .standard

    private enum Keys {
        static let acceptCriticalAlerts = "shared.acceptCriticalAlerts"
        static let customSoundEnabled = "shared.customSoundEnabled"
        static let partnerName = "shared.partnerName"
        static let ackBannersEnabled = "shared.ackBannersEnabled"
        static let timeSensitiveEnabled = "shared.timeSensitiveEnabled"
        static let outgoingAckUnavailable = "shared.outgoingAckUnavailable"
        static let outgoingAckFailureReason = "shared.outgoingAckFailureReason"
    }

    /// Receiver-side master switch. If false, even alerts marked critical by the sender
    /// are downgraded to .timeSensitive in the NSE.
    static var acceptCriticalAlerts: Bool {
        get { suite.bool(forKey: Keys.acceptCriticalAlerts) }
        set { suite.set(newValue, forKey: Keys.acceptCriticalAlerts) }
    }

    /// When true the NSE plays the bundled `needs-attention.caf`; when false it uses the
    /// system default sound. Defaults to true on first read so the bundled sound (if
    /// present) plays before the user has touched Settings.
    static var customSoundEnabled: Bool {
        get { suite.object(forKey: Keys.customSoundEnabled) as? Bool ?? true }
        set { suite.set(newValue, forKey: Keys.customSoundEnabled) }
    }

    /// Cached partner display name so the NSE can label the toggle/notification without
    /// reaching into CloudKit.
    static var partnerName: String? {
        get { suite.string(forKey: Keys.partnerName) }
        set { suite.set(newValue, forKey: Keys.partnerName) }
    }

    /// Sender-side: if false, the NSE downgrades the outgoing-ack banner to
    /// `.passive` (no banner pop, no sound, still recorded in Notification Center).
    /// The underlying state update still propagates via the silent outgoing-status
    /// subscription, so the in-app indicator flips to ❤️ either way. Defaults to
    /// true on first read — closing the loop is the whole point of the feature.
    static var ackBannersEnabled: Bool {
        get { suite.object(forKey: Keys.ackBannersEnabled) as? Bool ?? true }
        set { suite.set(newValue, forKey: Keys.ackBannersEnabled) }
    }

    /// Master switch governing whether the NSE delivers pushes at `.timeSensitive`
    /// (pierces Focus / Do Not Disturb) or the default `.active` level. Applies
    /// to both incoming attention requests and sender-side ack banners. Critical
    /// alerts still win over this when sender-flagged + receiver-accepted +
    /// entitlement granted; ack-banners-disabled still forces `.passive`.
    /// Defaults to true — the whole product is "this should pierce Focus".
    static var timeSensitiveEnabled: Bool {
        get { suite.object(forKey: Keys.timeSensitiveEnabled) as? Bool ?? true }
        set { suite.set(newValue, forKey: Keys.timeSensitiveEnabled) }
    }

    /// True when the most recent attempt to register `outgoing-ack-v2` was rejected
    /// by CloudKit. The Alert update path still drives the in-app indicator, but the
    /// lock-screen "got back to you" banner won't fire until Production has the
    /// `_sub_trigger_outgoing-ack-v2` index. Surfaced in the Settings → Diagnostics
    /// row so a silently-degraded feature stays visible.
    static var outgoingAckSubscriptionUnavailable: Bool {
        get { suite.bool(forKey: Keys.outgoingAckUnavailable) }
        set { suite.set(newValue, forKey: Keys.outgoingAckUnavailable) }
    }

    /// `String(describing:)` of the CKError captured the last time `outgoing-ack-v2`
    /// failed to save. Cleared on a successful save or when the subscription is
    /// already present server-side. Surfaced beneath the Diagnostics explainer so
    /// the actual server reason is visible without having to plug into Console.app.
    static var outgoingAckSubscriptionFailureReason: String? {
        get { suite.string(forKey: Keys.outgoingAckFailureReason) }
        set { suite.set(newValue, forKey: Keys.outgoingAckFailureReason) }
    }
}
