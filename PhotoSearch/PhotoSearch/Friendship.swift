import CloudKit
import Foundation

// MARK: - Value types for the friends / directory / invitation layer
//
// This file holds ONLY pure value types and their CKRecord <-> value mappings.
// No CloudKit network, no @MainActor state — exactly like SharedAlbum.swift, so
// the mapping logic is trivially unit-testable in the simulator test host where
// CloudKit itself is unavailable. The networked operations live in
// DirectoryService.swift, and the @Published state in InvitationStore.swift.
//
// The records below live in CloudKit's PUBLIC database, which we use purely as a
// serverless DIRECTORY (username -> userRecordID) and INVITATION INBOX. No photo
// bytes ever land here — only a username and an invitation pointer (a share URL
// that, on its own, grants nothing, because the underlying CKShare's
// publicPermission is `.none` and the friend is added as an explicit
// participant). See DirectoryService for the access-control rationale.

// MARK: - UserProfile

/// A user's public directory entry: maps a chosen username to their CloudKit
/// user record id, so a friend can be resolved by username and added as a share
/// participant. Stored in the public DB under a DETERMINISTIC record name
/// ("profile_<lowercased username>") so claiming a username is an existence
/// check (no Queryable index needed) and lookups are a direct `record(for:)`.
struct UserProfile: Identifiable, Codable, Equatable {
    /// Original-case username as the user typed it (display/identity).
    var username: String
    /// Free-form display name (defaults to username when not provided).
    var displayName: String
    /// The owner's `CKRecord.ID.recordName` — the durable CloudKit identity we
    /// resolve into a share participant via CKUserIdentity.LookupInfo.
    var userRecordID: String
    var createdAt: Date

    /// Stable identity for SwiftUI: the normalized record name.
    var id: String { Self.recordName(for: username) }

    // MARK: record name normalization

    /// The public-DB record name for a username. Lowercased + trimmed so that
    /// usernames are case-insensitively unique ("Alice" and "alice" collide).
    /// Load-bearing: claim, lookup, and uniqueness all key off this exact form,
    /// so it lives here (not as a scattered literal) and is unit-tested.
    static func recordName(for username: String) -> String {
        "profile_" + normalizedUsername(username)
    }

    /// Canonical comparison form of a username: trimmed + lowercased. Used for
    /// the record name and for uniqueness; the original case is preserved in the
    /// `username` field for display.
    static func normalizedUsername(_ username: String) -> String {
        username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// True when a string is an acceptable username: 2–30 chars after trimming,
    /// letters/digits/._- only. Keeps record names sane and avoids empty claims.
    static func isValidUsername(_ username: String) -> Bool {
        let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2...30).contains(trimmed.count) else { return false }
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return trimmed.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}

// MARK: - Friend (local-only value type)

/// A friend in the user's LOCAL friends list. Persisted as JSON in the app's
/// documents dir (mirrors SharedAlbumStore's cache idiom). v1 is a one-way add:
/// adding a friend just records their public profile so we can invite them; the
/// album invitation is the actual consent step, so there is no mutual approval.
struct Friend: Identifiable, Codable, Equatable {
    var username: String
    var displayName: String
    var userRecordID: String

    /// Identity = the CloudKit user record name, which is unique per person.
    var id: String { userRecordID }

    init(username: String, displayName: String, userRecordID: String) {
        self.username = username
        self.displayName = displayName
        self.userRecordID = userRecordID
    }

    /// Build a Friend from a resolved public profile.
    init(profile: UserProfile) {
        self.username = profile.username
        self.displayName = profile.displayName
        self.userRecordID = profile.userRecordID
    }
}

// MARK: - Invitation (public-DB inbox record)

/// An invitation to join a shared album, written by the SENDER into the PUBLIC
/// database and read by the RECIPIENT. Carries the share URL the recipient
/// accepts; the share itself is invite-only (publicPermission `.none` + explicit
/// participant), so the URL sitting in a readable public record grants nothing
/// to anyone but the invited identity.
///
/// Identity is a UUID record name. `toUserRecordID` is the only field we query
/// on (recipient == me); everything else is read back after the fetch. We sort
/// client-side by `createdAt` to avoid depending on a Sortable index in the
/// auto-created dev schema.
struct Invitation: Identifiable, Codable, Equatable {
    /// UUID record name of the public "Invitation" record.
    var id: String
    /// Recipient's `CKRecord.ID.recordName` — the field we query on.
    var toUserRecordID: String
    var fromUserRecordID: String
    var fromUsername: String
    var albumName: String
    /// The CKShare URL the recipient accepts. Stored as a string; rehydrated to
    /// a URL via `shareURL`.
    var shareURLString: String
    var createdAt: Date

    var shareURL: URL? { URL(string: shareURLString) }
}

// MARK: - CKRecord <-> value mapping

extension UserProfile {
    enum RecordType { static let profile = "UserProfile" }

    enum Field {
        static let username = "username"
        static let displayName = "displayName"
        static let userRecordID = "userRecordID"
        static let createdAt = "createdAt"
    }

    /// Map a fetched public "UserProfile" record to the value type. Failable so a
    /// malformed/wrong-type record degrades to nil rather than crashing.
    init?(record: CKRecord) {
        guard record.recordType == RecordType.profile else { return nil }
        guard let username = record[Field.username] as? String,
              let userRecordID = record[Field.userRecordID] as? String else { return nil }
        self.username = username
        self.userRecordID = userRecordID
        self.displayName = (record[Field.displayName] as? String) ?? username
        self.createdAt = (record[Field.createdAt] as? Date) ?? Date()
    }

    /// Materialize the value into a public-DB record. The record ID is the
    /// deterministic `profile_<lower>` name in the default zone (public DB only
    /// supports the default zone), which is what makes uniqueness an existence
    /// check rather than a query.
    func toRecord() -> CKRecord {
        let id = CKRecord.ID(recordName: Self.recordName(for: username))
        let rec = CKRecord(recordType: RecordType.profile, recordID: id)
        rec[Field.username] = username as CKRecordValue
        rec[Field.displayName] = displayName as CKRecordValue
        rec[Field.userRecordID] = userRecordID as CKRecordValue
        rec[Field.createdAt] = createdAt as CKRecordValue
        return rec
    }
}

extension Invitation {
    enum RecordType { static let invitation = "Invitation" }

    enum Field {
        /// QUERYABLE — the recipient's userRecordID. fetchPendingInvitations
        /// filters on this. See DirectoryService for the required Dashboard
        /// index note.
        static let toUserRecordID = "toUserRecordID"
        static let fromUserRecordID = "fromUserRecordID"
        static let fromUsername = "fromUsername"
        static let albumName = "albumName"
        static let shareURL = "shareURL"
        static let createdAt = "createdAt"
    }

    /// Map a fetched public "Invitation" record to the value type. Failable so a
    /// malformed/wrong-type record degrades to nil (the query skips it) rather
    /// than crashing.
    init?(record: CKRecord) {
        guard record.recordType == RecordType.invitation else { return nil }
        guard let to = record[Field.toUserRecordID] as? String,
              let from = record[Field.fromUserRecordID] as? String,
              let shareURL = record[Field.shareURL] as? String else { return nil }
        self.id = record.recordID.recordName
        self.toUserRecordID = to
        self.fromUserRecordID = from
        self.fromUsername = (record[Field.fromUsername] as? String) ?? "Someone"
        self.albumName = (record[Field.albumName] as? String) ?? "a shared album"
        self.shareURLString = shareURL
        self.createdAt = (record[Field.createdAt] as? Date) ?? Date()
    }

    /// Materialize the value into a public-DB record with a UUID record name.
    func toRecord() -> CKRecord {
        let rec = CKRecord(recordType: RecordType.invitation,
                           recordID: CKRecord.ID(recordName: id))
        rec[Field.toUserRecordID] = toUserRecordID as CKRecordValue
        rec[Field.fromUserRecordID] = fromUserRecordID as CKRecordValue
        rec[Field.fromUsername] = fromUsername as CKRecordValue
        rec[Field.albumName] = albumName as CKRecordValue
        rec[Field.shareURL] = shareURLString as CKRecordValue
        rec[Field.createdAt] = createdAt as CKRecordValue
        return rec
    }

    /// Convenience constructor used by the sender. Mints a fresh UUID id and
    /// stamps `createdAt` now.
    static func make(toUserRecordID: String,
                     fromUserRecordID: String,
                     fromUsername: String,
                     albumName: String,
                     shareURL: URL) -> Invitation {
        Invitation(
            id: UUID().uuidString,
            toUserRecordID: toUserRecordID,
            fromUserRecordID: fromUserRecordID,
            fromUsername: fromUsername,
            albumName: albumName,
            shareURLString: shareURL.absoluteString,
            createdAt: Date())
    }
}

// MARK: - Handled-invitations cache (pure value type)

/// A persisted Set of invitation IDs the user has already accepted or declined,
/// so they don't re-appear in the inbox. We persist a SET of ids (not delete the
/// sender's public record — the recipient generally can't), which is why this
/// is the source of truth for "don't show this again". Pure value type so its
/// encode/decode is unit-tested without touching disk or CloudKit.
struct HandledInvitations: Codable, Equatable {
    private(set) var ids: Set<String>

    init(ids: Set<String> = []) { self.ids = ids }

    func contains(_ id: String) -> Bool { ids.contains(id) }

    mutating func mark(_ id: String) { ids.insert(id) }

    /// Filter a fetched list down to invitations not yet handled. Pure, so the
    /// inbox-dedupe logic is testable.
    func unhandled(_ invitations: [Invitation]) -> [Invitation] {
        invitations.filter { !ids.contains($0.id) }
    }
}
