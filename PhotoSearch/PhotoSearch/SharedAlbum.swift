import CloudKit
import Foundation
import os

// MARK: - Diagnostics

/// Unified-logging channel for the whole shared-albums stack. CloudKit is
/// device-only (unavailable on the simulator / in tests), so when a real device
/// run misbehaves the *only* signal we get is the Console. These logs pinpoint
/// where a contribute/reload breaks — payload built (count), records to save,
/// per-record save result + CKError code, fetched count, save-vs-fetch. We log
/// counts, record names, zone names, DB scope, and error descriptions only —
/// NEVER photo bytes, thumbnails, or face data.
enum SharedAlbumLog {
    static let logger = Logger(subsystem: "com.photovault.sharedalbums",
                               category: "sharedalbums")
}

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
    /// A server change token is too old to advance (`CKError.changeTokenExpired`).
    /// The sync layer recovers by clearing the offending token and refetching
    /// from scratch rather than wedging on the stale token. Kept as a distinct
    /// case (not folded into `.cloudKit`) so the store can detect it.
    case changeTokenExpired
    /// The record zone is gone (`CKError.zoneNotFound` / `.userDeletedZone`) —
    /// deleted by its owner, or our access was revoked. Distinct case so the
    /// sync layer can treat it as "album deleted" instead of a generic failure.
    case zoneNotFound
    /// The requested username already belongs to a DIFFERENT iCloud user, so the
    /// directory claim was refused. Distinct case so the onboarding UI can show
    /// a "try another name" message rather than a generic CloudKit error.
    case usernameTaken
    /// An add-photos call is already running for this album. Distinct case so
    /// the share-folder flow can show "still adding…" instead of an error.
    case uploadAlreadyInProgress

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason):       return reason
        case .malformedRecord(let what):     return "Unexpected data from iCloud (\(what))."
        case .cloudKit(let msg):             return msg
        case .retryExhausted(let msg):       return "iCloud kept failing: \(msg)"
        case .changeTokenExpired:            return "iCloud sync needs a full refresh."
        case .zoneNotFound:                  return "This shared album is no longer available."
        case .usernameTaken:                 return "That username is already taken. Try another."
        case .uploadAlreadyInProgress:       return "Photos are still being added to this album. Try again when that finishes."
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

// MARK: - SharedPhoto value type (metadata; bytes live in CKAssets on the record)

/// A photo inside a shared album, as the view layer sees it. This is the
/// METADATA projection: the actual image bytes ship as two CKAssets on the
/// underlying "SharedPhoto" record (a full-res JPEG and a ~256px thumbnail).
/// We deliberately do NOT carry the CKAsset file handles on this value type —
/// the detail grid fetches records with `desiredKeys` that exclude the full
/// image and loads thumbnail/full bytes through CloudKitService on demand, so
/// the SwiftUI layer never touches CloudKit file handles directly. Staying a
/// pure value type keeps diffing cheap and the type trivially Codable for the
/// local cache.
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
    /// Content hash for dedupe on upload (sha256 hex of the full-res bytes).
    var contentHash: String?
    /// "video" when the fullImage asset is a movie file; nil/"image" otherwise.
    /// Optional String (not Bool) for Codable/CKRecord back-compat with photos
    /// uploaded before video support existed.
    var mediaType: String?
    /// Seconds, videos only.
    var duration: Double?

    var isVideo: Bool { mediaType == "video" }
    var durationText: String {
        let s = Int(duration ?? 0)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    var albumZoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: albumZoneName, ownerName: albumZoneOwnerName)
    }

    var recordID: CKRecord.ID {
        CKRecord.ID(recordName: id, zoneID: albumZoneID)
    }
}

// MARK: - AlbumParticipant value type

/// One person on an album's zone-wide CKShare, as the view layer sees it. Pure
/// value type (no CKShare.Participant reference escapes the store) so the
/// People sheet stays cheap to diff and trivially previewable.
struct AlbumParticipant: Identifiable, Equatable {
    /// Stable identity: the participant's user record name when known, else a
    /// minted UUID (pending email/phone invitees have no record ID yet).
    let id: String
    /// Best display name CloudKit gives us (name components → email → phone).
    /// The view layer upgrades this to a friend's @username when it can.
    var displayName: String
    /// The participant's iCloud user record name, when resolved.
    var userRecordID: String?
    var isOwner: Bool
    var isMe: Bool
    /// Human-readable acceptance state: "Joined", "Invited", or "" (unknown).
    var status: String
    var canWrite: Bool
}

/// The bytes + metadata for ONE photo about to be uploaded. Built by the store
/// from a local PHAsset (full-res JPEG + thumbnail written to temp files) and
/// handed to CloudKitService, which materializes the CKRecord + CKAssets. Kept
/// separate from `SharedPhoto` so the value type the view sees never holds file
/// URLs or CloudKit handles.
struct SharedPhotoUploadPayload {
    /// Temp-file URL of the full-resolution JPEG (or the movie file for
    /// videos). Deleted after upload.
    let fullImageURL: URL
    /// Temp-file URL of the ~256px thumbnail JPEG. Deleted after upload.
    let thumbnailURL: URL
    var contributorID: String?
    var captureDate: Date?
    var latitude: Double?
    var longitude: Double?
    var originalFilename: String?
    var contentHash: String?
    var isVideo: Bool = false
    var duration: Double?
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

    /// Field names on the "SharedPhoto" record. One place so the CloudKit
    /// dashboard schema and both the read/write sites stay in lockstep.
    enum PhotoField {
        static let album = "album"               // CKRecord.Reference -> album root
        static let fullImage = "fullImage"       // CKAsset (full-res JPEG, or the movie file for videos)
        static let thumbnail = "thumbnail"       // CKAsset (~256px JPEG; poster frame for videos)
        static let contributorID = "contributorID"
        static let captureDate = "captureDate"
        static let latitude = "latitude"
        static let longitude = "longitude"
        static let originalFilename = "originalFilename"
        static let contentHash = "contentHash"
        static let mediaType = "mediaType"       // "image" / "video"
        static let duration = "duration"         // Double seconds, videos only
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
    /// Build the METADATA value from a fetched "SharedPhoto" record. Failable so
    /// a malformed / wrong-type record degrades to nil (the loader skips it and
    /// reports a partial result) instead of crashing. Note this reads only the
    /// metadata + asset-presence; it never touches the CKAsset file handles, so
    /// it is safe whether the record was fetched with the full image or with
    /// `desiredKeys` that excluded it.
    init?(record: CKRecord) {
        guard record.recordType == SharedAlbum.RecordType.photo else { return nil }

        self.id = record.recordID.recordName
        self.albumZoneName = record.recordID.zoneID.zoneName
        self.albumZoneOwnerName = record.recordID.zoneID.ownerName
        self.contributorID = record[SharedAlbum.PhotoField.contributorID] as? String
        self.captureDate = record[SharedAlbum.PhotoField.captureDate] as? Date
        self.latitude = record[SharedAlbum.PhotoField.latitude] as? Double
        self.longitude = record[SharedAlbum.PhotoField.longitude] as? Double
        self.originalFilename = record[SharedAlbum.PhotoField.originalFilename] as? String
        self.contentHash = record[SharedAlbum.PhotoField.contentHash] as? String
        self.mediaType = record[SharedAlbum.PhotoField.mediaType] as? String
        self.duration = record[SharedAlbum.PhotoField.duration] as? Double
    }

    /// Materialize a "SharedPhoto" CKRecord from an upload payload, into the
    /// album's zone. Cascade-links it to the album-root record via a field
    /// reference (NOT a parent reference — see below).
    ///
    /// - The record ID is minted in `zoneID` so the photo lands in the album's
    ///   custom zone (the unit of sharing), never the default zone.
    /// - We do NOT set `record.parent`. These albums use ZONE-WIDE sharing
    ///   (`CKShare(recordZoneID:)`), where every record in the zone is shared by
    ///   virtue of living in the zone. `parent` is record *chaining*, which
    ///   CloudKit permits ONLY under hierarchical sharing (`CKShare(rootRecord:)`)
    ///   — setting a parent in a zone-wide-shared zone fails the save with
    ///   "Chaining supported for hierarchical sharing only". So sharing is
    ///   carried entirely by the zone; no parent hierarchy is needed or allowed.
    /// - When `albumRootRef` is non-nil we still set the user-defined `album`
    ///   field to a `.deleteSelf` reference (a normal cascade reference, not
    ///   chaining) so deleting the album-root deletes its photos. When it's nil
    ///   (the album-root isn't resolvable in the target zone/DB) the reference is
    ///   omitted — referencing a non-existent record would fail the save with
    ///   `CKError.referenceViolation`; the photo still lands in the zone and is
    ///   shared, it just won't cascade-delete with the album.
    /// - Both image fields are CKAssets pointing at the payload's temp files.
    static func makeRecord(from payload: SharedPhotoUploadPayload,
                           inZone zoneID: CKRecordZone.ID,
                           albumRootRef: CKRecord.Reference?) -> CKRecord {
        let recordID = CKRecord.ID(recordName: "photo-\(UUID().uuidString)", zoneID: zoneID)
        let rec = CKRecord(recordType: SharedAlbum.RecordType.photo, recordID: recordID)

        // Cascade-delete link only. NO `rec.parent` — parent chaining is illegal
        // in a zone-wide-shared zone (CloudKit: "Chaining supported for
        // hierarchical sharing only"). The `album` field is an ordinary
        // `.deleteSelf` reference, which is allowed and gives the cascade.
        if let albumRootRef {
            rec[SharedAlbum.PhotoField.album] =
                CKRecord.Reference(recordID: albumRootRef.recordID, action: .deleteSelf)
        }

        rec[SharedAlbum.PhotoField.fullImage] = CKAsset(fileURL: payload.fullImageURL)
        rec[SharedAlbum.PhotoField.thumbnail] = CKAsset(fileURL: payload.thumbnailURL)

        if let v = payload.contributorID { rec[SharedAlbum.PhotoField.contributorID] = v as CKRecordValue }
        if let v = payload.captureDate { rec[SharedAlbum.PhotoField.captureDate] = v as CKRecordValue }
        if let v = payload.latitude { rec[SharedAlbum.PhotoField.latitude] = v as CKRecordValue }
        if let v = payload.longitude { rec[SharedAlbum.PhotoField.longitude] = v as CKRecordValue }
        if let v = payload.originalFilename { rec[SharedAlbum.PhotoField.originalFilename] = v as CKRecordValue }
        if let v = payload.contentHash { rec[SharedAlbum.PhotoField.contentHash] = v as CKRecordValue }
        rec[SharedAlbum.PhotoField.mediaType] = (payload.isVideo ? "video" : "image") as CKRecordValue
        if let v = payload.duration { rec[SharedAlbum.PhotoField.duration] = v as CKRecordValue }

        return rec
    }
}
