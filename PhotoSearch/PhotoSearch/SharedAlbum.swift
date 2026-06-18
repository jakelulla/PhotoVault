import CloudKit
import Foundation

// MARK: - Errors

/// Typed surface for every failure path in the shared-albums stack. CloudKit
/// hands back NSError-shaped CKErrors on arbitrary queues; we never force-unwrap
/// or rethrow those raw — we map them into this enum so the view layer can show
/// a stable message and the store can decide what is retryable. `.unavailable`
/// is the simulator / signed-out case and is treated as benign (no alert spam).
enum SharedAlbumError: Error, LocalizedError, Equatable {
    /// No usable iCloud account (simulator, signed out, restricted). Higher-level
    /// ops short-circuit to this instead of hammering CloudKit.
    case unavailable(reason: String)
    /// A CKRecord could not be mapped to/from our value type (missing required
    /// field, wrong record type). Indicates schema skew, never user error.
    case malformedRecord(String)
    /// CloudKit returned an error we surface verbatim (wrapped) to the user.
    case cloudKit(String)
    /// We exhausted the retry budget on a retryable CKError.
    case retryExhausted(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason):       return reason
        case .malformedRecord(let what):     return "Unexpected data from iCloud (\(what))."
        case .cloudKit(let msg):             return msg
        case .retryExhausted(let msg):       return "iCloud kept failing: \(msg)"
        }
    }
}

// MARK: - SharedAlbum value type

/// A shared album as the view layer sees it. Deliberately a pure value type:
/// no CKRecord / CKShare / CKContainer lives here, so SwiftUI diffing stays
/// cheap and the model is trivially testable. The CloudKit objects stay inside
/// CloudKitService / SharedAlbumStore.
///
/// `id` is the album's zone name (a stable UUID string we mint at creation),
/// which is also the natural key for our local JSON cache and for matching a
/// fetched zone back to its album.
struct SharedAlbum: Identifiable, Codable, Equatable {
    /// Zone name string — stable identity across launches and DBs.
    let id: String
    var name: String
    /// Display name of the owner (nil for albums we own, or when the owner's
    /// identity hasn't been resolved yet).
    var ownerName: String?
    /// True when this album lives in OUR private DB (we created it); false when
    /// it arrived via an accepted share and lives in the shared DB.
    var isOwnedByMe: Bool
    /// Record name of the album's root "SharedAlbum" record.
    var recordName: String
    /// Owner component of the zone ID. For our own zones this is
    /// CKCurrentUserDefaultName; for shared zones it is the owner's record name.
    /// Persisted as a string so SharedAlbum stays Codable; rehydrated into a
    /// CKRecordZone.ID via `zoneID`.
    var zoneName: String
    var zoneOwnerName: String
    /// Record name of the zone-wide CKShare, when one exists. Optional because a
    /// freshly created album may not have been shared yet.
    var shareRecordName: String?
    /// Best-effort photo count for the album card. Cheap/limited query result;
    /// not authoritative.
    var photoCount: Int

    // Convenience rehydration of the CloudKit identifiers we persisted as strings.

    var zoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: zoneName, ownerName: zoneOwnerName)
    }

    var recordID: CKRecord.ID {
        CKRecord.ID(recordName: recordName, zoneID: zoneID)
    }

    var shareRecordID: CKRecord.ID? {
        shareRecordName.map { CKRecord.ID(recordName: $0, zoneID: zoneID) }
    }
}

// MARK: - SharedPhoto value type (metadata only — bytes deferred)

/// A photo inside a shared album, as the view layer sees it. Metadata only for
/// now: the actual image bytes ship as a CKAsset in the UPLOAD PHASE (later),
/// so the CKAsset reference and any local file URL are intentionally absent.
/// Fields are laid out so the upload phase can add them without reshaping the
/// type or its persistence.
struct SharedPhoto: Identifiable, Codable, Equatable {
    /// Record name of the "SharedPhoto" record.
    let id: String
    /// Zone the photo belongs to (its parent album's zone).
    var albumZoneName: String
    var albumZoneOwnerName: String
    /// Record name of the iCloud user who contributed the photo, when known.
    var contributorID: String?
    var captureDate: Date?
    var latitude: Double?
    var longitude: Double?
    var originalFilename: String?
    /// Content hash for dedupe on upload (sha256 hex). Filled in the upload phase.
    var contentHash: String?

    // TODO(upload-phase): add `assetRecordName` / a CKAsset-backed image
    // reference + a local cache URL. The CKAsset is NOT modeled here yet so the
    // view layer never touches CloudKit file handles.

    var albumZoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: albumZoneName, ownerName: albumZoneOwnerName)
    }
}

// MARK: - CKRecord <-> value mapping

extension SharedAlbum {
    /// CloudKit record type names. Kept in one place so the schema is greppable
    /// and the dashboard configuration is unambiguous.
    enum RecordType {
        static let album = "SharedAlbum"
        static let photo = "SharedPhoto"
        /// Stable record name of an album's single root record within its zone.
        /// Load-bearing: the write site (createAlbum) and the read site
        /// (albumFromZone) must agree exactly, so it lives here, not as a literal.
        static let albumRootRecordName = "album-root"
    }

    enum Field {
        static let name = "name"
        static let createdBy = "createdBy"
    }

    /// Build a value from the album's root record. Failable so a malformed /
    /// wrong-type record degrades to nil instead of crashing — the loader skips
    /// it and reports a partial result rather than throwing the whole fetch away.
    ///
    /// - Parameters:
    ///   - record: the root "SharedAlbum" record.
    ///   - share:  the zone-wide CKShare, if one was fetched alongside.
    ///   - ownedByMe: whether the record came from our private DB.
    ///   - photoCount: best-effort count (0 if not queried).
    init?(record: CKRecord, share: CKShare?, ownedByMe: Bool, photoCount: Int) {
        guard record.recordType == RecordType.album else { return nil }
        guard let name = record[Field.name] as? String else { return nil }

        self.id = record.recordID.zoneID.zoneName
        self.name = name
        self.recordName = record.recordID.recordName
        self.zoneName = record.recordID.zoneID.zoneName
        self.zoneOwnerName = record.recordID.zoneID.ownerName
        self.isOwnedByMe = ownedByMe
        self.shareRecordName = share?.recordID.recordName
        self.photoCount = photoCount

        // Owner display name: prefer the share's owner participant identity when
        // present (only meaningful for shared-in albums). Never force-unwrap.
        if let owner = share?.owner.userIdentity.nameComponents {
            self.ownerName = PersonNameComponentsFormatter().string(from: owner)
        } else if let createdBy = record[Field.createdBy] as? String, !createdBy.isEmpty {
            self.ownerName = createdBy
        } else {
            self.ownerName = nil
        }
    }

    /// Materialize the album's root record into an EXISTING zone. We always pass
    /// the zone ID explicitly so the record lands in the album's custom zone
    /// (the unit of sharing), never the default zone.
    func toRecord() -> CKRecord {
        let rec = CKRecord(recordType: RecordType.album, recordID: recordID)
        rec[Field.name] = name as CKRecordValue
        if let ownerName { rec[Field.createdBy] = ownerName as CKRecordValue }
        return rec
    }
}

extension SharedPhoto {
    // TODO(upload-phase): implement `init?(record:)` and `toRecord()` for the
    // "SharedPhoto" record type. The record carries:
    //   - a CKRecord.Reference to the parent SharedAlbum (action .deleteSelf, so
    //     deleting the album cascades to its photos),
    //   - captureDate / latitude / longitude / originalFilename / contentHash,
    //   - the image bytes as a CKAsset (the reason this is deferred — we are not
    //     uploading bytes in this phase).
    // Mapping is stubbed now so SharedPhoto compiles and the store can hold the
    // type, but no SharedPhoto records are read or written in Phase 1/2.
}
