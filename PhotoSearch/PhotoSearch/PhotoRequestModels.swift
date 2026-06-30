import CloudKit
import Foundation

// MARK: - Value types for the "photo request" feature
//
// A user asks a friend for photos: a DESCRIPTION ("concert"), a DATE or DATE
// RANGE, and an optional FACE FILTER. The friend's device searches THEIR library
// and shares a candidate album back. This file holds ONLY pure value types and
// their CKRecord <-> value mappings — no CloudKit network, no @MainActor state —
// exactly like Friendship.swift / SharedAlbum.swift, so the mapping logic is
// trivially unit-testable in the simulator test host where CloudKit is
// unavailable. The networked ops live in DirectoryService (RequestService
// section); the @Published state lives in RequestStore.
//
// ──────────────────────────────────────────────────────────────────────────
// PRIVACY — THE BIOMETRIC FACE EMBEDDING NEVER LIVES IN THE PUBLIC DATABASE.
//
// The public `PhotoRequest` record (below) carries the description, dates, the
// face-filter mode (a string), and — ONLY when the filter needs a face — a
// `faceShareURL`: a CKShare URL pointing at an EPHEMERAL private record zone the
// requester owns. The 512-d ArcFace embedding is written into THAT zone as a
// `FacePayload` record, shared invite-only (publicPermission .none) with just the
// target friend. So the embedding (biometric) travels through the private/shared
// database machinery, friends-only, and the public record holds only a URL that
// grants nothing to anyone but the invited identity. The requester best-effort
// deletes the ephemeral zone afterwards (RequestService.deleteEphemeralFaceZone);
// the friend never has to.
// ──────────────────────────────────────────────────────────────────────────

// MARK: - FaceFilter (3-way)

/// How the requester wants their own face to constrain the friend's results.
/// The raw values are the strings persisted in the public `PhotoRequest` record
/// (faceFilter field), so they are part of the on-the-wire schema and unit-tested.
enum FaceFilter: String, Codable, CaseIterable, Equatable, Hashable {
    /// No face constraint — every description+date match is a candidate.
    case any
    /// Only photos the REQUESTER appears in.
    case onlyMe
    /// Only photos the requester does NOT appear in.
    case withoutMe

    /// True when this filter requires the requester's face embedding (and hence
    /// the ephemeral face share). `any` needs nothing biometric.
    var needsFace: Bool { self != .any }

    /// Human label for the compose UI segmented control.
    var label: String {
        switch self {
        case .onlyMe:    return "Only photos I'm in"
        case .withoutMe: return "Only photos I'm not in"
        case .any:       return "Any photos"
        }
    }
}

// MARK: - PhotoRequest (public-DB inbox record)

/// A request for photos, written by the REQUESTER into the PUBLIC database and
/// read by the FRIEND. Carries the search criteria and — when the face filter
/// needs it — a URL to the ephemeral, invite-only face share. NO embedding and
/// NO photo bytes ever land on this record.
///
/// Identity is a UUID record name. `toUserRecordID` is the only field we query
/// on (recipient == me); everything else is read back after the fetch. We sort
/// client-side by `createdAt` to avoid depending on a Sortable index in the
/// auto-created dev schema (mirrors Invitation).
struct PhotoRequest: Identifiable, Codable, Equatable, Hashable {
    /// UUID record name of the public "PhotoRequest" record.
    var id: String
    /// Recipient (the friend asked to build the album) — the field we QUERY on.
    var toUserRecordID: String
    /// Requester identity + display, so the friend's inbox can show who asked.
    var fromUserRecordID: String
    var fromUsername: String
    /// What the requester is asking for ("concert", "beach day").
    var requestDescription: String
    /// Inclusive date window the friend searches within. A single-day request
    /// sets start == startOfDay and end == endOfDay for that one day.
    var startDate: Date
    var endDate: Date
    /// The 3-way face filter, persisted as its raw string.
    var faceFilter: FaceFilter
    /// CKShare URL of the ephemeral private face-embedding zone. Present iff
    /// `faceFilter.needsFace`; nil for `.any`. Stored as a string; rehydrated via
    /// `faceShareURL`.
    var faceShareURLString: String?
    var createdAt: Date

    var faceShareURL: URL? { faceShareURLString.flatMap(URL.init(string:)) }
}

// MARK: - FacePayload (EPHEMERAL private-zone record — the biometric lives here)

/// The requester's own ArcFace face embedding, computed on-device from their
/// PRIVATE profile photo. Written as a single record into an ephemeral private
/// CKRecordZone the requester owns, then shared invite-only with one friend.
/// This is the ONLY place the biometric embedding is ever persisted to CloudKit,
/// and it is never in the public DB. A pure value type so its encode/decode round
/// trip is unit-testable without a container.
struct FacePayload: Equatable {
    /// 512-d L2-normalized ArcFace embedding of the requester's face.
    var embedding: [Float]

    init(embedding: [Float]) { self.embedding = embedding }
}

// MARK: - CKRecord <-> value mapping

extension PhotoRequest {
    enum RecordType { static let request = "PhotoRequest" }

    enum Field {
        /// QUERYABLE — the recipient's userRecordID. fetchPendingRequests filters
        /// on this. See DirectoryService for the required Dashboard index note.
        static let toUserRecordID = "toUserRecordID"
        static let fromUserRecordID = "fromUserRecordID"
        static let fromUsername = "fromUsername"
        static let description = "requestDescription"
        static let startDate = "startDate"
        static let endDate = "endDate"
        static let faceFilter = "faceFilter"
        static let faceShareURL = "faceShareURL"
        static let createdAt = "createdAt"
    }

    /// Map a fetched public "PhotoRequest" record to the value type. Failable so
    /// a malformed / wrong-type record degrades to nil (the query skips it)
    /// rather than crashing. An unknown faceFilter string degrades to `.any`
    /// (the safe, no-biometric mode) instead of dropping the whole request.
    init?(record: CKRecord) {
        guard record.recordType == RecordType.request else { return nil }
        guard let to = record[Field.toUserRecordID] as? String,
              let from = record[Field.fromUserRecordID] as? String,
              let desc = record[Field.description] as? String,
              let start = record[Field.startDate] as? Date,
              let end = record[Field.endDate] as? Date else { return nil }
        self.id = record.recordID.recordName
        self.toUserRecordID = to
        self.fromUserRecordID = from
        self.fromUsername = (record[Field.fromUsername] as? String) ?? "Someone"
        self.requestDescription = desc
        self.startDate = start
        self.endDate = end
        let rawFilter = (record[Field.faceFilter] as? String) ?? FaceFilter.any.rawValue
        self.faceFilter = FaceFilter(rawValue: rawFilter) ?? .any
        self.faceShareURLString = record[Field.faceShareURL] as? String
        self.createdAt = (record[Field.createdAt] as? Date) ?? Date()
    }

    /// Materialize the value into a public-DB record with a UUID record name.
    /// NOTE: deliberately writes NO embedding and NO photo — only the criteria
    /// and (optionally) the face-share URL.
    func toRecord() -> CKRecord {
        let rec = CKRecord(recordType: RecordType.request,
                           recordID: CKRecord.ID(recordName: id))
        rec[Field.toUserRecordID] = toUserRecordID as CKRecordValue
        rec[Field.fromUserRecordID] = fromUserRecordID as CKRecordValue
        rec[Field.fromUsername] = fromUsername as CKRecordValue
        rec[Field.description] = requestDescription as CKRecordValue
        rec[Field.startDate] = startDate as CKRecordValue
        rec[Field.endDate] = endDate as CKRecordValue
        rec[Field.faceFilter] = faceFilter.rawValue as CKRecordValue
        if let faceShareURLString {
            rec[Field.faceShareURL] = faceShareURLString as CKRecordValue
        }
        return rec
    }

    /// Convenience constructor used by the requester. Mints a fresh UUID id and
    /// stamps `createdAt` now. `faceShareURL` is nil for `.any`.
    static func make(toUserRecordID: String,
                     fromUserRecordID: String,
                     fromUsername: String,
                     description: String,
                     startDate: Date,
                     endDate: Date,
                     faceFilter: FaceFilter,
                     faceShareURL: URL?) -> PhotoRequest {
        PhotoRequest(
            id: UUID().uuidString,
            toUserRecordID: toUserRecordID,
            fromUserRecordID: fromUserRecordID,
            fromUsername: fromUsername,
            requestDescription: description,
            startDate: startDate,
            endDate: endDate,
            faceFilter: faceFilter,
            faceShareURLString: faceShareURL?.absoluteString,
            createdAt: Date())
    }
}

extension FacePayload {
    enum RecordType { static let payload = "FacePayload" }

    /// Stable record name of the single payload record inside the ephemeral face
    /// zone. Load-bearing: the write site (RequestService) and the read site
    /// (acceptFaceShare) must agree exactly, so it lives here, not as a literal.
    static let recordName = "face-payload"

    enum Field {
        /// The embedding shipped as a Data blob (little-endian Float32 bytes) so
        /// no biometric ever sits in a queryable scalar field — and so a single
        /// asset-free record carries it. Decoded back to [Float] on the friend's
        /// device for matching. The public DB never sees this; the record lives
        /// only in the ephemeral PRIVATE shared zone.
        static let embedding = "embedding"
    }

    /// Materialize the embedding into a record inside the given EPHEMERAL zone.
    /// The record ID is the deterministic `face-payload` name so the friend can
    /// read it by name after accepting the share.
    func toRecord(inZone zoneID: CKRecordZone.ID) -> CKRecord {
        let recordID = CKRecord.ID(recordName: Self.recordName, zoneID: zoneID)
        let rec = CKRecord(recordType: RecordType.payload, recordID: recordID)
        rec[Field.embedding] = Self.encode(embedding) as CKRecordValue
        return rec
    }

    /// Map a fetched "FacePayload" record back to the embedding. Failable so a
    /// malformed / wrong-type record degrades to nil rather than crashing.
    init?(record: CKRecord) {
        guard record.recordType == RecordType.payload else { return nil }
        guard let data = record[Field.embedding] as? Data,
              let floats = Self.decode(data) else { return nil }
        self.embedding = floats
    }

    // MARK: [Float] <-> Data (little-endian Float32)

    /// Pack a Float32 vector to raw little-endian bytes. Pure, so the round-trip
    /// is unit-tested without a CloudKit record.
    static func encode(_ vector: [Float]) -> Data {
        var data = Data(capacity: vector.count * MemoryLayout<Float32>.size)
        for v in vector {
            var le = Float32(v).bitPattern.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// Unpack little-endian Float32 bytes back to a vector. Returns nil if the
    /// byte count isn't a whole number of Float32s (corrupt/truncated blob).
    static func decode(_ data: Data) -> [Float]? {
        let stride = MemoryLayout<Float32>.size
        guard data.count % stride == 0 else { return nil }
        var out = [Float]()
        out.reserveCapacity(data.count / stride)
        var i = data.startIndex
        while i < data.endIndex {
            var bits: UInt32 = 0
            for byte in 0..<stride {
                bits |= UInt32(data[i + byte]) << (8 * byte)
            }
            out.append(Float(bitPattern: UInt32(littleEndian: bits)))
            i += stride
        }
        return out
    }
}

// MARK: - Pending ephemeral face-zone cache (pure value type)

/// A persisted set of ephemeral face-zone IDs the REQUESTER created but has not
/// yet confirmed deleted. The biometric embedding lives in these zones, so the
/// "ephemeral" privacy guarantee depends on them being torn down. A 600s timer
/// is only a fast-path; it does NOT survive app suspension. So we ALSO persist
/// the pending zone IDs here and SWEEP them at next launch (a gated startup task
/// deletes each and clears the set). Pure value type — its encode/decode and the
/// add/remove logic are unit-testable without disk or CloudKit.
///
/// A `CKRecordZone.ID` isn't Codable, so we persist the two strings that
/// reconstruct it: `zoneName` + `ownerName`. (Ephemeral face zones always live in
/// the requester's OWN private DB, so `ownerName` is the current-user default,
/// but we store it explicitly to reconstruct the exact ID.)
struct PendingFaceZones: Codable, Equatable {
    /// One pending ephemeral face zone, by the two strings that rebuild its ID.
    struct ZoneRef: Codable, Equatable, Hashable {
        var zoneName: String
        var ownerName: String
    }

    private(set) var zones: [ZoneRef]

    init(zones: [ZoneRef] = []) { self.zones = zones }

    var isEmpty: Bool { zones.isEmpty }

    /// Add a zone (idempotent — never stores a duplicate ref).
    mutating func add(_ ref: ZoneRef) {
        if !zones.contains(ref) { zones.append(ref) }
    }

    /// Remove a zone once it has been deleted (or confirmed gone).
    mutating func remove(_ ref: ZoneRef) {
        zones.removeAll { $0 == ref }
    }
}

// MARK: - Handled-requests cache (pure value type)

/// A persisted Set of request IDs the friend has already built/dismissed, so
/// they don't re-appear in the inbox. Mirrors HandledInvitations: we persist a
/// SET of ids (the friend generally can't delete the requester's public record),
/// which is the source of truth for "don't show this again". Pure value type so
/// its encode/decode is unit-tested without touching disk or CloudKit.
struct HandledRequests: Codable, Equatable {
    private(set) var ids: Set<String>

    init(ids: Set<String> = []) { self.ids = ids }

    func contains(_ id: String) -> Bool { ids.contains(id) }

    mutating func mark(_ id: String) { ids.insert(id) }

    /// Filter a fetched list down to requests not yet handled. Pure, so the
    /// inbox-dedupe logic is testable.
    func unhandled(_ requests: [PhotoRequest]) -> [PhotoRequest] {
        requests.filter { !ids.contains($0.id) }
    }
}
