import Foundation

/// A locally-snoozed incoming alert: the recipient deferred it, and a local notification is
/// scheduled to re-surface it at `until`. Persisted so it survives relaunch in lockstep with
/// the OS-persisted pending notification request. Cleared on acknowledge, on a newer incoming
/// alert, on user cancel, or once it expires. Local-only — the sender never learns of a snooze.
struct SnoozeState: Codable, Equatable {
    var recordName: String     // CKRecord.ID.recordName of the snoozed incoming alert
    var until: Date

    static let storageKey = "attention.snooze.v1"

    /// True while the snooze is still pending (re-notification hasn't fired yet).
    var isActive: Bool {
        until > Date()
    }

    static func load() -> SnoozeState? {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(SnoozeState.self, from: data)
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: SnoozeState.storageKey)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }
}
