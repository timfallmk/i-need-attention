import CloudKit
import Foundation

/// A persistable `CKRecordZone.ID`. `CKRecordZone.ID` isn't `Codable`, and the two
/// strings that identify it are — the zone name, and the record name of the account
/// that owns it.
struct ZoneRef: Codable, Equatable {
    var zoneName: String
    var ownerName: String

    init(zoneName: String, ownerName: String) {
        self.zoneName = zoneName
        self.ownerName = ownerName
    }

    init(_ zoneID: CKRecordZone.ID) {
        self.zoneName = zoneID.zoneName
        self.ownerName = zoneID.ownerName
    }

    var zoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: zoneName, ownerName: ownerName)
    }
}
