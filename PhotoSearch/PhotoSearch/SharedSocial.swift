import CloudKit
import Foundation

/// Reactions + comments on shared photos. Both live as small records in the
/// SAME album zone as the photos they annotate — zone-wide sharing means every
/// participant can read and write them, and deleting the photo cascades them
/// away (`.deleteSelf` reference). Pure value types + CKRecord mappings, in the
/// SharedAlbum.swift idiom, so they stay unit-testable without CloudKit.
enum SharedSocial {
    enum RecordType {
        static let reaction = "SharedReaction"
        static let comment = "SharedComment"
    }

    /// Field names, shared by both record types where they overlap. Distinct
    /// from SharedPhoto's fields so the combined `desiredKeys` list never
    /// collides across record types in the same zone fetch.
    enum Field {
        static let photoRef = "photoRef"       // Reference → SharedPhoto (.deleteSelf)
        static let emoji = "emoji"             // reaction only
        static let commentText = "commentText" // comment only
        static let authorID = "authorID"       // contributor's userRecordID
        static let authorName = "authorName"   // best-effort display name at write time
        static let createdAt = "socialCreatedAt"
    }

    /// Deterministic reaction record name: one reaction per (photo, author) —
    /// tapping the heart twice toggles the SAME record rather than stacking
    /// duplicates. The author component is hashed so record names stay short.
    static func reactionRecordName(photoID: String, authorID: String) -> String {
        "reaction-\(photoID)-\(stableHash(authorID))"
    }

    static func commentRecordName() -> String { "comment-\(UUID().uuidString)" }

    /// Short, stable, non-cryptographic hash for record-name components.
    private static func stableHash(_ s: String) -> String {
        var h: UInt64 = 5381
        for b in s.utf8 { h = (h << 5) &+ h &+ UInt64(b) }
        return String(h, radix: 36)
    }
}

/// One person's reaction to one shared photo (v1: a single ❤️; the emoji field
/// is stored so future reactions don't need a schema change).
struct SharedReaction: Identifiable, Codable, Equatable {
    /// Record name ("reaction-<photoID>-<authorHash>").
    let id: String
    var photoID: String
    var emoji: String
    var authorID: String
    var createdAt: Date

    init(id: String, photoID: String, emoji: String, authorID: String, createdAt: Date) {
        self.id = id
        self.photoID = photoID
        self.emoji = emoji
        self.authorID = authorID
        self.createdAt = createdAt
    }

    init?(record: CKRecord) {
        guard record.recordType == SharedSocial.RecordType.reaction,
              let ref = record[SharedSocial.Field.photoRef] as? CKRecord.Reference,
              let author = record[SharedSocial.Field.authorID] as? String else { return nil }
        self.id = record.recordID.recordName
        self.photoID = ref.recordID.recordName
        self.emoji = (record[SharedSocial.Field.emoji] as? String) ?? "\u{2764}\u{FE0F}"
        self.authorID = author
        self.createdAt = (record[SharedSocial.Field.createdAt] as? Date) ?? Date()
    }

    /// Materialize into the album's zone, cascade-linked to the photo.
    func toRecord(inZone zoneID: CKRecordZone.ID) -> CKRecord {
        let recordID = CKRecord.ID(recordName: id, zoneID: zoneID)
        let rec = CKRecord(recordType: SharedSocial.RecordType.reaction, recordID: recordID)
        let photoRecordID = CKRecord.ID(recordName: photoID, zoneID: zoneID)
        rec[SharedSocial.Field.photoRef] = CKRecord.Reference(recordID: photoRecordID, action: .deleteSelf)
        rec[SharedSocial.Field.emoji] = emoji as CKRecordValue
        rec[SharedSocial.Field.authorID] = authorID as CKRecordValue
        rec[SharedSocial.Field.createdAt] = createdAt as CKRecordValue
        return rec
    }
}

/// One comment on one shared photo.
struct SharedComment: Identifiable, Codable, Equatable {
    /// Record name ("comment-<uuid>").
    let id: String
    var photoID: String
    var text: String
    var authorID: String
    /// Display name captured at write time so readers don't need a directory
    /// round-trip (falls back to participant resolution when absent).
    var authorName: String?
    var createdAt: Date

    init(id: String, photoID: String, text: String, authorID: String,
         authorName: String?, createdAt: Date) {
        self.id = id
        self.photoID = photoID
        self.text = text
        self.authorID = authorID
        self.authorName = authorName
        self.createdAt = createdAt
    }

    init?(record: CKRecord) {
        guard record.recordType == SharedSocial.RecordType.comment,
              let ref = record[SharedSocial.Field.photoRef] as? CKRecord.Reference,
              let text = record[SharedSocial.Field.commentText] as? String,
              let author = record[SharedSocial.Field.authorID] as? String else { return nil }
        self.id = record.recordID.recordName
        self.photoID = ref.recordID.recordName
        self.text = text
        self.authorID = author
        self.authorName = record[SharedSocial.Field.authorName] as? String
        self.createdAt = (record[SharedSocial.Field.createdAt] as? Date) ?? Date()
    }

    func toRecord(inZone zoneID: CKRecordZone.ID) -> CKRecord {
        let recordID = CKRecord.ID(recordName: id, zoneID: zoneID)
        let rec = CKRecord(recordType: SharedSocial.RecordType.comment, recordID: recordID)
        let photoRecordID = CKRecord.ID(recordName: photoID, zoneID: zoneID)
        rec[SharedSocial.Field.photoRef] = CKRecord.Reference(recordID: photoRecordID, action: .deleteSelf)
        rec[SharedSocial.Field.commentText] = text as CKRecordValue
        rec[SharedSocial.Field.authorID] = authorID as CKRecordValue
        if let authorName { rec[SharedSocial.Field.authorName] = authorName as CKRecordValue }
        rec[SharedSocial.Field.createdAt] = createdAt as CKRecordValue
        return rec
    }
}
