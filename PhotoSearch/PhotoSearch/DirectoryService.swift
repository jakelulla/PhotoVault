import CloudKit
import Foundation

/// Networked layer for the in-app friends / invitation experience. Mirrors
/// `CloudKitService`'s idiom exactly:
/// - `@MainActor` singleton; nothing runs at init.
/// - EVERY op guards on `CloudKitService.isAvailable` (refreshed first), so on
///   the simulator / signed out it short-circuits to `.unavailable` before any
///   network call. This is what keeps the feature INERT in the test host.
/// - Completion-handler CKOperations are bridged to async via
///   `withCheckedThrowingContinuation` with a one-shot resume guard
///   (`PublicResumeGuard`), and we hop to the main actor (the whole type is
///   `@MainActor`) before mutating any state. Errors are mapped through
///   `CloudKitService.map`, never rethrown raw.
///
/// CloudKit's PUBLIC database is used here purely as a serverless DIRECTORY
/// (username -> userRecordID) and INVITATION INBOX. No photos go here. Albums and
/// their photos stay in the private/shared zones; the public DB only carries a
/// username and an invitation pointer (a CKShare URL). The share is invite-only
/// (publicPermission `.none`) and the friend is added as an EXPLICIT participant,
/// so even though the URL sits in a readable public record, only the invited
/// iCloud identity can actually accept it.
///
/// ──────────────────────────────────────────────────────────────────────────
/// CLOUDKIT DASHBOARD CONFIGURATION REQUIRED (PUBLIC database):
///
/// Record type "UserProfile" (public DB, default zone). Fields:
///   - username      (String)
///   - displayName   (String)
///   - userRecordID  (String)
///   - createdAt     (Date/Time)
///   No Queryable indexes required: profiles are addressed by deterministic
///   record name ("profile_<lowercased username>") via record(for:), never
///   queried.
///
/// Record type "Invitation" (public DB, default zone). Fields:
///   - toUserRecordID   (String)  ←  REQUIRES a QUERYABLE index (we filter on it)
///   - fromUserRecordID (String)
///   - fromUsername     (String)
///   - albumName        (String)
///   - shareURL         (String)
///   - createdAt        (Date/Time)
///   ONLY `toUserRecordID` needs a Queryable index. We deliberately do NOT sort
///   server-side (would need a Sortable index on createdAt that the auto-created
///   dev schema doesn't provide), so we sort the results client-side. The same
///   `toUserRecordID == me` predicate also backs the CKQuerySubscription.
/// ──────────────────────────────────────────────────────────────────────────
@MainActor
final class DirectoryService {
    static let shared = DirectoryService()

    private let cloud = CloudKitService.shared

    /// The PUBLIC database — our serverless directory + invitation inbox.
    private var publicDB: CKDatabase { cloud.container.publicCloudDatabase }

    /// Subscription id for the invitation-inbox push. Idempotent registration.
    static let invitationSubscriptionID = "public-invitations-for-me"

    private init() {}

    // MARK: - Availability (delegates to CloudKitService's gate)

    /// Refresh + require an available iCloud account, throwing `.unavailable`
    /// otherwise. Identical contract to CloudKitService.requireAvailable (which
    /// is private), so the public-DB ops fail fast and stay inert without an
    /// account.
    private func requireAvailable() async throws {
        await cloud.accountStatus()
        guard cloud.isAvailable else {
            throw SharedAlbumError.unavailable(
                reason: "Sign in to iCloud to use Friends")
        }
    }

    /// My CloudKit user record name (the durable identity behind a profile /
    /// invitation). Thin pass-through to CloudKitService.
    func myUserRecordID() async throws -> String {
        try await cloud.currentUserRecordID().recordName
    }

    // MARK: - Username claim / profile lookup

    /// Claim (or update) a public username for the current user.
    ///
    /// Behavior:
    ///   - No record at "profile_<lower>" → create it for me.
    ///   - Record exists and its userRecordID == mine → update displayName/case.
    ///   - Record exists and belongs to someone else → throw `.usernameTaken`.
    ///
    /// TOCTOU: between the existence check and the save, another device could
    /// claim the same name. We accept that small race (the loser's save would
    /// overwrite, but two strangers racing the exact same brand-new username at
    /// the same instant is vanishingly rare for a personal directory); a stronger
    /// guarantee would need a server-side uniqueness constraint CloudKit doesn't
    /// offer on the public DB. Documented rather than over-engineered.
    @discardableResult
    func claimUsername(_ username: String, displayName: String?) async throws -> UserProfile {
        try await requireAvailable()
        guard UserProfile.isValidUsername(username) else {
            throw SharedAlbumError.cloudKit(
                "Usernames must be 2–30 characters: letters, numbers, . _ -")
        }
        let myID = try await myUserRecordID()
        let trimmedName = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let display = (displayName?.trimmingCharacters(in: .whitespacesAndNewlines))
            .flatMap { $0.isEmpty ? nil : $0 } ?? trimmedName

        // Existence check by deterministic record name.
        let recordID = CKRecord.ID(recordName: UserProfile.recordName(for: trimmedName))
        if let existing = try? await publicDB.record(for: recordID),
           let profile = UserProfile(record: existing) {
            if profile.userRecordID == myID {
                // Mine already — update case/displayName and re-save the SAME
                // server record (carries its change tag, so no conflict).
                existing[UserProfile.Field.username] = trimmedName as CKRecordValue
                existing[UserProfile.Field.displayName] = display as CKRecordValue
                _ = try await save(existing, to: publicDB)
                return UserProfile(record: existing) ?? profile
            } else {
                throw SharedAlbumError.usernameTaken
            }
        }

        // Free — create it.
        let profile = UserProfile(
            username: trimmedName,
            displayName: display,
            userRecordID: myID,
            createdAt: Date())
        do {
            _ = try await save(profile.toRecord(), to: publicDB)
        } catch let error as CKError where Self.indicatesAlreadyExists(error) {
            // Lost the TOCTOU race: re-fetch and decide.
            if let existing = try? await publicDB.record(for: recordID),
               let other = UserProfile(record: existing) {
                if other.userRecordID == myID { return other }
                throw SharedAlbumError.usernameTaken
            }
            throw cloud.map(error)
        }
        return profile
    }

    /// Look up the current user's profile by their userRecordID. Returns nil if
    /// they haven't claimed a username yet (or iCloud is unavailable). Because we
    /// don't query by userRecordID (no index dependency), the caller passes the
    /// username they remember locally; if none is known this returns nil and the
    /// UI offers onboarding. (See InvitationStore, which caches the profile.)
    func profile(forUsername username: String) async -> UserProfile? {
        try? await findProfile(username: username)
    }

    /// Fetch a public profile by username (deterministic record-name lookup, no
    /// query/index). Returns nil when no such username exists.
    func findProfile(username: String) async throws -> UserProfile? {
        try await requireAvailable()
        let recordID = CKRecord.ID(recordName: UserProfile.recordName(for: username))
        do {
            let record = try await publicDB.record(for: recordID)
            return UserProfile(record: record)
        } catch let error as CKError where error.code == .unknownItem {
            return nil   // no such username
        } catch {
            throw cloud.map(error)
        }
    }

    // MARK: - Invitations

    /// Write an Invitation into the public DB so the recipient's inbox can show
    /// it. The share URL points at an invite-only CKShare (see `shareAlbum`).
    func sendInvitation(toUserRecordID: String,
                        fromUsername: String,
                        album: SharedAlbum,
                        shareURL: URL) async throws {
        try await requireAvailable()
        let myID = try await myUserRecordID()
        let invitation = Invitation.make(
            toUserRecordID: toUserRecordID,
            fromUserRecordID: myID,
            fromUsername: fromUsername,
            albumName: album.name,
            shareURL: shareURL)
        _ = try await save(invitation.toRecord(), to: publicDB)
    }

    /// Query the public DB for invitations addressed to me, sorted client-side by
    /// `createdAt` (newest first). Requires a QUERYABLE index on
    /// `toUserRecordID` (documented in the file header). We never sort
    /// server-side, so no Sortable index is needed.
    func fetchPendingInvitations() async throws -> [Invitation] {
        try await requireAvailable()
        let myID = try await myUserRecordID()
        let predicate = NSPredicate(format: "%K == %@", Invitation.Field.toUserRecordID, myID)
        let query = CKQuery(recordType: Invitation.RecordType.invitation, predicate: predicate)
        // NOTE: no sortDescriptors — sorting server-side would require a Sortable
        // index on createdAt that the auto-created dev schema does not provide.
        do {
            let (matchResults, _) = try await publicDB.records(
                matching: query, desiredKeys: nil, resultsLimit: CKQueryOperation.maximumResults)
            let invitations: [Invitation] = matchResults.compactMap { _, result in
                guard case .success(let record) = result else { return nil }
                return Invitation(record: record)
            }
            // Client-side sort, newest first.
            return invitations.sorted { $0.createdAt > $1.createdAt }
        } catch {
            throw cloud.map(error)
        }
    }

    /// Accept an invitation: resolve its share metadata and accept the share, so
    /// the album appears in the shared DB. Reuses CloudKitService.acceptShare for
    /// the actual CKAcceptSharesOperation. The caller marks the invitation handled
    /// locally and triggers an album refresh.
    func acceptInvitation(_ invitation: Invitation) async throws {
        try await requireAvailable()
        guard let url = invitation.shareURL else {
            throw SharedAlbumError.malformedRecord("invitation share URL")
        }
        let metadata = try await fetchShareMetadata(for: url)
        try await cloud.acceptShare(metadata)
        // Best-effort: as the RECIPIENT we generally can't delete the sender's
        // public record, so cleanup is the sender's job. We rely on the local
        // handled-invitations set (owned by InvitationStore) to keep it from
        // re-showing.
    }

    /// Best-effort: the SENDER deletes its own Invitation record after the
    /// recipient has joined. Low priority — failures are swallowed because the
    /// recipient's local handled-set already prevents re-display. Never throws.
    func deleteSentInvitation(id: String) async {
        guard (try? await requireAvailable()) != nil else { return }
        let recordID = CKRecord.ID(recordName: id)
        _ = try? await publicDB.deleteRecord(withID: recordID)
    }

    // MARK: - Programmatic sharing (no share sheet)

    /// Share an album with a friend identified by their userRecordID, fully
    /// programmatically (no UICloudSharingController). Ensures the album has a
    /// zone-wide CKShare (publicPermission `.none`), resolves the friend's iCloud
    /// identity to a share participant, adds them with `.readWrite`, saves the
    /// share, and returns the share URL the caller passes to `sendInvitation`.
    ///
    /// Access control: because publicPermission is `.none` and we add the friend
    /// as an EXPLICIT participant, the returned URL only works for that invited
    /// identity — it is safe to drop into the (publicly readable) Invitation
    /// record.
    func shareAlbum(_ album: SharedAlbum, toUserRecordID: String) async throws -> URL {
        try await requireAvailable()

        // Only the owner can manage an album's share/participants — the share
        // and its zone live in the owner's PRIVATE database. The UI already
        // gates the in-app invite on ownership; enforce the invariant here too,
        // where the privateDB assumption actually lives.
        guard album.isOwnedByMe else {
            throw SharedAlbumError.cloudKit("You can only invite people to albums you own.")
        }

        // 1. Ensure (or fetch) the zone-wide share. Invite-only by construction.
        let share = try await cloud.fetchOrCreateShare(for: album.zoneID, title: album.name)
        share.publicPermission = .none

        // 2. Resolve the friend's iCloud identity into a share participant —
        //    unless they're already one. Re-inviting the same friend would
        //    otherwise duplicate the participant / be rejected on save; the
        //    existing share already grants them access, so we just re-send the
        //    invitation record below.
        let alreadyParticipant = share.participants.contains {
            $0.userIdentity.userRecordID?.recordName == toUserRecordID
        }
        if !alreadyParticipant {
            let participant = try await fetchParticipant(forUserRecordID: toUserRecordID)
            participant.permission = .readWrite
            participant.role = .privateUser
            share.addParticipant(participant)
        }

        // 3. Save JUST the share record via a modify op. This is a ZONE-WIDE
        //    share (created with `CKShare(recordZoneID:)`), so it is NOT rooted
        //    on the album-root record — the whole zone is the unit of sharing.
        //    We therefore save only the share (which carries its server change
        //    tag from `fetchOrCreateShare`, so the participant add applies
        //    cleanly); we deliberately do NOT re-save `album.toRecord()`, which
        //    would carry no change tag and could conflict with the live root.
        try await modifySharing(saving: [share], in: cloud.privateDB)

        guard let url = share.url else {
            throw SharedAlbumError.cloudKit("Share has no URL yet. Try again.")
        }
        return url
    }

    // MARK: - CKOperation bridges (one-shot continuation, main-actor hop)

    /// Resolve a CKShare URL into its metadata (needed to accept). Bridged from
    /// CKFetchShareMetadataOperation with a one-shot resume guard.
    private func fetchShareMetadata(for url: URL) async throws -> CKShare.Metadata {
        let op = CKFetchShareMetadataOperation(shareURLs: [url])
        op.qualityOfService = .userInitiated
        let guardBox = PublicResumeGuard()
        var fetched: CKShare.Metadata?
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<CKShare.Metadata, Error>) in
            op.perShareMetadataResultBlock = { _, result in
                if case .success(let metadata) = result { fetched = metadata }
            }
            op.fetchShareMetadataResultBlock = { [weak self] result in
                guard guardBox.take() else { return }
                switch result {
                case .success:
                    if let fetched {
                        cont.resume(returning: fetched)
                    } else {
                        cont.resume(throwing: SharedAlbumError.malformedRecord("share metadata"))
                    }
                case .failure(let error):
                    cont.resume(throwing: self?.cloud.map(error)
                        ?? SharedAlbumError.cloudKit(String(describing: error)))
                }
            }
            cloud.container.add(op)
        }
    }

    /// Resolve a userRecordID into a CKShare.Participant via
    /// CKFetchShareParticipantsOperation + CKUserIdentity.LookupInfo. Bridged
    /// with a one-shot resume guard.
    private func fetchParticipant(forUserRecordID userRecordID: String) async throws -> CKShare.Participant {
        let lookup = CKUserIdentity.LookupInfo(
            userRecordID: CKRecord.ID(recordName: userRecordID))
        let op = CKFetchShareParticipantsOperation(userIdentityLookupInfos: [lookup])
        op.qualityOfService = .userInitiated
        let guardBox = PublicResumeGuard()
        var participant: CKShare.Participant?
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<CKShare.Participant, Error>) in
            op.perShareParticipantResultBlock = { _, result in
                if case .success(let p) = result { participant = p }
            }
            op.fetchShareParticipantsResultBlock = { [weak self] result in
                guard guardBox.take() else { return }
                switch result {
                case .success:
                    if let participant {
                        cont.resume(returning: participant)
                    } else {
                        cont.resume(throwing: SharedAlbumError.cloudKit(
                            "Couldn't find that friend's iCloud account to invite."))
                    }
                case .failure(let error):
                    cont.resume(throwing: self?.cloud.map(error)
                        ?? SharedAlbumError.cloudKit(String(describing: error)))
                }
            }
            cloud.container.add(op)
        }
    }

    /// Save sharing records (a zone-wide CKShare) via CKModifyRecordsOperation,
    /// bridged with a one-shot resume guard. Used by `shareAlbum` to persist the
    /// share after adding a participant. We use a CKModifyRecordsOperation rather
    /// than `database.save(_:)` because adding a participant to a share is the
    /// canonical "save the share record" path and keeps the bridge consistent
    /// with the rest of the CK plumbing.
    private func modifySharing(saving records: [CKRecord], in database: CKDatabase) async throws {
        let op = CKModifyRecordsOperation(recordsToSave: records, recordIDsToDelete: nil)
        op.savePolicy = .changedKeys
        op.qualityOfService = .userInitiated
        op.isAtomic = true
        let guardBox = PublicResumeGuard()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            op.modifyRecordsResultBlock = { [weak self] result in
                guard guardBox.take() else { return }
                switch result {
                case .success:
                    cont.resume()
                case .failure(let error):
                    cont.resume(throwing: self?.cloud.map(error)
                        ?? SharedAlbumError.cloudKit(String(describing: error)))
                }
            }
            database.add(op)
        }
    }

    // MARK: - Invitation subscription (silent push)

    /// Register a CKQuerySubscription on the public DB "Invitation" record type,
    /// filtered to invitations addressed to me, as a SILENT push
    /// (shouldSendContentAvailable, no alert/badge). Idempotent: an
    /// "already exists" error is success. Caller gates on isAvailable AND
    /// !runningTests, identical to the existing database-subscription trigger, so
    /// this never runs at launch or in the test host.
    func registerInvitationSubscription() async throws {
        try await requireAvailable()
        let myID = try await myUserRecordID()
        let predicate = NSPredicate(format: "%K == %@", Invitation.Field.toUserRecordID, myID)
        let subscription = CKQuerySubscription(
            recordType: Invitation.RecordType.invitation,
            predicate: predicate,
            subscriptionID: Self.invitationSubscriptionID,
            options: [.firesOnRecordCreation])
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true   // silent — no alert/badge
        subscription.notificationInfo = info
        do {
            _ = try await publicDB.save(subscription)
        } catch let error as CKError {
            // A duplicate CKQuerySubscription (same subscriptionID, every launch
            // after the first) is rejected with .serverRejectedRequest — NOT
            // .serverRecordChanged — so treat that as success to stay idempotent.
            if error.code == .serverRejectedRequest || Self.indicatesAlreadyExists(error) { return }
            throw cloud.map(error)
        } catch {
            throw cloud.map(error)
        }
    }

    // MARK: - Save helper (record-level, public DB)

    /// Save a single record with a tiny transient-error retry, mirroring
    /// CloudKitService.save's spirit (without the zone-merge complexity — public
    /// directory records are last-writer-wins by design). Returns the saved
    /// server record.
    @discardableResult
    private func save(_ record: CKRecord, to database: CKDatabase,
                      maxAttempts: Int = 3) async throws -> CKRecord {
        var attempt = 0
        var lastError: Error?
        while attempt < maxAttempts {
            attempt += 1
            do {
                return try await database.save(record)
            } catch let error as CKError {
                lastError = error
                if let delay = Self.retryDelay(for: error), attempt < maxAttempts {
                    try? await Task.sleep(for: .seconds(delay))
                    continue
                }
                throw cloud.map(error)
            } catch {
                throw cloud.map(error)
            }
        }
        throw SharedAlbumError.retryExhausted(
            (lastError.map { String(describing: $0) }) ?? "unknown")
    }

    // MARK: - Retry / already-exists helpers (mirror CloudKitService)

    private static func retryDelay(for error: CKError) -> Double? {
        switch error.code {
        case .zoneBusy, .requestRateLimited, .serviceUnavailable:
            return error.retryAfterSeconds ?? 2.0
        default:
            return nil
        }
    }

    private static func indicatesAlreadyExists(_ error: CKError) -> Bool {
        switch error.code {
        case .serverRecordChanged:
            return true
        case .partialFailure:
            if let perItem = error.partialErrorsByItemID?.values {
                return perItem.contains { ($0 as? CKError)?.code == .serverRecordChanged }
            }
            return false
        default:
            return false
        }
    }
}

/// Lock-guarded one-shot resume flag for bridging completion-handler
/// CKOperations to a single continuation resume. Mirrors CloudKitService's
/// `OneShotResume` (which is private to that file). CK completion blocks can fire
/// on arbitrary queues, so the flag must be thread-safe.
private final class PublicResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    func take() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if resumed { return false }
        resumed = true
        return true
    }
}
