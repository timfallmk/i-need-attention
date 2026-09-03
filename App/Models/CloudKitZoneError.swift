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

private extension CKError {
    var isMissingZoneCode: Bool {
        code == .zoneNotFound || code == .userDeletedZone
    }
}
