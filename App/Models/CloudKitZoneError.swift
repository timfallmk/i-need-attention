import CloudKit
import Foundation

extension Error {
    /// Whether this is CloudKit saying a record zone no longer exists.
    ///
    /// Deliberately narrow. The caller acts on this by ending a pairing, so anything
    /// short of a definite "that zone is gone" has to read as false — a dropped
    /// connection, an expired token or a signed-out account must never be mistaken for
    /// a partner who unpaired. Only `zoneNotFound` and `userDeletedZone` qualify.
    ///
    /// Checked through `partialFailure` as well, because a batch operation reports the
    /// real cause per item rather than at the top level, and both alert paths that can
    /// hit a deleted zone go through batched saves.
    var isMissingCloudKitZone: Bool {
        guard let error = self as? CKError else { return false }
        if error.isMissingZoneCode { return true }
        guard error.code == .partialFailure, let partials = error.partialErrorsByItemID else {
            return false
        }
        return partials.values.contains { ($0 as? CKError)?.isMissingZoneCode == true }
    }
}

extension Error {
    /// Whether this is CloudKit failing to answer rather than answering no: no network,
    /// the service busy or down, a rate limit. The caller retries rather than concluding
    /// anything, so this errs wide — a code missing here is one that ends a pairing over
    /// a bad connection, while one wrongly included only delays a decision to the next
    /// pass.
    var isTransientCloudKitFailure: Bool {
        guard let error = self as? CKError else { return false }
        switch error.code {
        case .networkUnavailable, .networkFailure, .serviceUnavailable,
             .requestRateLimited, .zoneBusy:
            return true
        default:
            return false
        }
    }
}

private extension CKError {
    var isMissingZoneCode: Bool {
        code == .zoneNotFound || code == .userDeletedZone
    }
}
