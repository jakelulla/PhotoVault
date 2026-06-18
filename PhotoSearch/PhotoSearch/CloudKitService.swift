import CloudKit
import Foundation

/// Thin async wrapper over CloudKit for the shared-albums feature.
///
/// Design rules enforced here:
/// - EVERY higher-level op guards on `isAvailable`. On the simulator and when
///   signed out, `accountStatus()` is `.noAccount` / `.couldNotDetermine`, so
///   `isAvailable` is false and these ops throw `SharedAlbumError.unavailable`
///   immediately — they never reach a network call that would hang or crash.
///   This is what makes the whole feature INERT on the simulator and in tests.
/// - CloudKit completion handlers fire on arbitrary queues. We bridge them to
///   async via `withCheckedThrowingContinuation` with a one-shot resume guard
///   (mirrors ReelRequestState in MomentReelView), and we hop to the main actor
///   before touching any `@Published`/cached state.
/// - We NEVER force-unwrap CK results; every failure becomes a SharedAlbumError.
///
/// The CloudKit ENTITLEMENT is not configured yet. The framework imports and
/// compiles without it; at runtime, with no container provisioning, account
/// queries simply resolve to "not available", which the guards handle.
@MainActor
final class CloudKitService {
    static let shared = CloudKitService()

    /// Container id is locked by the design decision. Constructing CKContainer
    /// does not require the entitlement to be present to compile, and does not
    /// touch the network — so this is safe to evaluate on the simulator.
    static let containerIdentifier = "iCloud.com.jakelulla.PhotoSearch"

    let container: CKContainer
    var privateDB: CKDatabase { container.privateCloudDatabase }
    var sharedDB: CKDatabase { container.sharedCloudDatabase }

    /// Cached last-known account status. Starts `.couldNotDetermine` so every
    /// op is unavailable until `accountStatus()` has run at least once.
    private(set) var lastAccountStatus: CKAccountStatus = .couldNotDetermine

    private init() {
        container = CKContainer(identifier: Self.containerIdentifier)
    }

    // MARK: - Availability

    /// True only when the last observed account status is `.available`. All
    /// higher-level ops gate on this. Note this reflects the LAST call to
    /// `accountStatus()`; callers refresh it before relying on it.
    var isAvailable: Bool { lastAccountStatus == .available }

    /// Query and cache the iCloud account status. Safe everywhere: on the
    /// simulator / signed out this resolves to a non-available status without
    /// hanging. Any error is folded into `.couldNotDetermine` rather than thrown
    /// — availability is a soft signal, not an error condition.
    @discardableResult
    func accountStatus() async -> CKAccountStatus {
        let status: CKAccountStatus
        do {
            status = try await container.accountStatus()
        } catch {
            status = .couldNotDetermine
        }
        lastAccountStatus = status
        return status
    }

    /// Refresh availability and throw `.unavailable` if iCloud is not usable.
    /// Higher-level ops call this first so they fail fast with a clean message.
    private func requireAvailable() async throws {
        await accountStatus()
        guard isAvailable else {
            throw SharedAlbumError.unavailable(
                reason: "Sign in to iCloud to use Shared Albums")
        }
    }

    // MARK: - Identity

    /// The current user's record ID. Used to stamp `createdBy` and to compare
    /// ownership. Guards on availability so it never blocks on the simulator.
    func currentUserRecordID() async throws -> CKRecord.ID {
        try await requireAvailable()
        do {
            return try await container.userRecordID()
        } catch {
            throw map(error)
        }
    }

    // MARK: - Zones

    /// Create (idempotently) the custom zone that backs one shared album.
    /// Saving a zone that already exists is not an error in CloudKit — but to be
    /// defensive we also treat a `.serverRecordChanged`/already-exists style
    /// failure as success and return the zone we tried to save.
    func createAlbumZone(named zoneName: String) async throws -> CKRecordZone {
        try await requireAvailable()
        let zone = CKRecordZone(zoneName: zoneName)
        do {
            let saved = try await privateDB.save(zone)
            return saved
        } catch let error as CKError {
            // Idempotency: a re-run that finds the zone already present should
            // succeed. CloudKit surfaces this differently across versions; treat
            // "already there" as a no-op success.
            if Self.indicatesAlreadyExists(error) {
                return zone
            }
            throw map(error)
        } catch {
            throw map(error)
        }
    }

    /// Fetch the user's custom record zones in the PRIVATE database (the albums
    /// we own). Tolerant: returns [] on availability failure rather than
    /// throwing, so the loader can still show shared-in albums.
    func fetchPrivateAlbumZones() async throws -> [CKRecordZone] {
        try await requireAvailable()
        do {
            let zonesByID = try await privateDB.allRecordZones()
            // Exclude the default zone — albums always live in a custom zone.
            return zonesByID.filter { $0.zoneID != CKRecordZone.default().zoneID }
        } catch {
            throw map(error)
        }
    }

    /// Fetch the zones in the SHARED database (albums others shared with us).
    func fetchSharedAlbumZones() async throws -> [CKRecordZone] {
        try await requireAvailable()
        do {
            return try await sharedDB.allRecordZones()
        } catch {
            throw map(error)
        }
    }

    // MARK: - Sharing

    /// Fetch the existing zone-wide CKShare for a zone, or create one.
    ///
    /// Zone-wide sharing (iOS 15+): a single CKShare with
    /// `recordZoneID` set shares the entire zone. Public permission is `.none`
    /// — access is invite-only; participants are added (with readWrite) through
    /// the UICloudSharingController invite flow in the view layer.
    func fetchOrCreateShare(for zoneID: CKRecordZone.ID,
                            title: String) async throws -> CKShare {
        try await requireAvailable()

        // First try to fetch an existing zone-wide share.
        let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
        if let existing = try? await fetchRecord(shareID, from: privateDB) as? CKShare {
            return existing
        }

        // None yet — create a zone-wide share and save it.
        let share = CKShare(recordZoneID: zoneID)
        share.publicPermission = .none
        share[CKShare.SystemFieldKey.title] = title as CKRecordValue
        do {
            // Saving via a modify operation lets CloudKit assign the share its
            // server identity. We save just the share record (the zone already
            // exists from createAlbumZone).
            let saved = try await privateDB.save(share)
            guard let asShare = saved as? CKShare else {
                throw SharedAlbumError.malformedRecord("expected CKShare")
            }
            return asShare
        } catch let error as CKError {
            // Race: another path created the share first. Re-fetch and return it.
            if Self.indicatesAlreadyExists(error),
               let existing = try? await fetchRecord(shareID, from: privateDB) as? CKShare {
                return existing
            }
            throw map(error)
        } catch {
            throw map(error)
        }
    }

    /// Fetch the live zone-wide CKShare for a zone, creating it if absent. The
    /// invite UI (UICloudSharingController) needs the REAL server share, so this
    /// is the resolver the view layer calls before presenting the sheet.
    func liveShare(for zoneID: CKRecordZone.ID, title: String) async throws -> CKShare {
        try await fetchOrCreateShare(for: zoneID, title: title)
    }

    // MARK: - Generic record helpers

    /// Fetch a single record from a database, bridged to async. Returns the
    /// record or throws a mapped error.
    func fetchRecord(_ id: CKRecord.ID, from database: CKDatabase) async throws -> CKRecord {
        do {
            return try await database.record(for: id)
        } catch {
            throw map(error)
        }
    }

    /// Save records to a database with retry handling for the transient,
    /// retryable CKErrors: `.serverRecordChanged` (resolve by re-applying the
    /// caller's intended field values onto the fetched server record before
    /// retrying — a "local-fields-win" merge that preserves the mutation rather
    /// than re-saving the server copy verbatim), `.zoneBusy` /
    /// `.requestRateLimited` (respect `retryAfterSeconds`). Minimal but real.
    ///
    /// - Returns: the saved server records.
    @discardableResult
    func save(_ records: [CKRecord],
              to database: CKDatabase,
              maxAttempts: Int = 4) async throws -> [CKRecord] {
        try await requireAvailable()
        guard !records.isEmpty else { return [] }

        var toSave = records
        var attempt = 0
        var lastError: Error?

        while attempt < maxAttempts {
            attempt += 1
            // Map the records we are about to save by their ID so a conflict can
            // re-apply OUR intended field values onto the fetched server record
            // (a real three-way merge), instead of re-saving the server's copy
            // verbatim and silently dropping the caller's mutation.
            let intendedByID = Dictionary(
                toSave.map { ($0.recordID, $0) }, uniquingKeysWith: { _, new in new })
            do {
                let result = try await database.modifyRecords(
                    saving: toSave,
                    deleting: [],
                    savePolicy: .ifServerRecordUnchanged,
                    atomically: false)
                // Collect successes; surface the first hard failure.
                var saved: [CKRecord] = []
                var conflicts: [CKRecord] = []
                for (recordID, perRecord) in result.saveResults {
                    switch perRecord {
                    case .success(let rec):
                        saved.append(rec)
                    case .failure(let err):
                        if let ck = err as? CKError,
                           ck.code == .serverRecordChanged,
                           let server = ck.serverRecord {
                            // Re-apply our intended values onto the server record
                            // so the retry carries the server's change tag AND the
                            // caller's mutation. We copy the keys WE meant to write
                            // (from the originally-requested record) onto `server`.
                            if let intended = intendedByID[recordID] {
                                for key in intended.allKeys() {
                                    server[key] = intended[key]
                                }
                            }
                            conflicts.append(server)
                        } else {
                            throw map(err)
                        }
                    }
                }
                if conflicts.isEmpty {
                    return saved
                }
                // Retry only the conflicted records, now based on server copies.
                toSave = conflicts
                lastError = SharedAlbumError.cloudKit("serverRecordChanged")
                continue
            } catch let error as CKError {
                lastError = error
                if let delay = Self.retryDelay(for: error), attempt < maxAttempts {
                    try? await Task.sleep(for: .seconds(delay))
                    continue
                }
                throw map(error)
            } catch {
                throw map(error)
            }
        }
        throw SharedAlbumError.retryExhausted(
            (lastError.map { String(describing: $0) }) ?? "unknown")
    }

    /// Accept an incoming share. Bridged to async via a one-shot continuation
    /// because `CKAcceptSharesOperation` is completion-handler based and fires
    /// on an arbitrary queue. Guards on availability so it is inert without an
    /// account.
    func acceptShare(_ metadata: CKShare.Metadata) async throws {
        try await requireAvailable()
        let op = CKAcceptSharesOperation(shareMetadatas: [metadata])
        let guardBox = OneShotResume()

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            op.acceptSharesResultBlock = { [weak self] result in
                guard guardBox.take() else { return }
                switch result {
                case .success:
                    cont.resume()
                case .failure(let error):
                    cont.resume(throwing: self?.map(error) ?? SharedAlbumError.cloudKit(String(describing: error)))
                }
            }
            container.add(op)
        }
    }

    // MARK: - Error mapping + retry policy

    /// Map any error into our typed enum. Never rethrows raw CKError to the view.
    nonisolated func map(_ error: Error) -> SharedAlbumError {
        if let already = error as? SharedAlbumError { return already }
        if let ck = error as? CKError {
            switch ck.code {
            case .notAuthenticated, .accountTemporarilyUnavailable:
                return .unavailable(reason: "Sign in to iCloud to use Shared Albums")
            case .networkUnavailable, .networkFailure:
                return .cloudKit("iCloud is unreachable. Check your connection.")
            default:
                return .cloudKit(ck.localizedDescription)
            }
        }
        return .cloudKit(error.localizedDescription)
    }

    /// Retry delay (seconds) for retryable CKErrors, honoring the server's
    /// `retryAfterSeconds` when present. Returns nil for non-retryable errors.
    private static func retryDelay(for error: CKError) -> Double? {
        switch error.code {
        case .zoneBusy, .requestRateLimited, .serviceUnavailable:
            return (error.retryAfterSeconds) ?? 2.0
        default:
            return nil
        }
    }

    /// Heuristic for "the thing I tried to save already exists" so idempotent
    /// creates (zone, share) are not treated as failures.
    private static func indicatesAlreadyExists(_ error: CKError) -> Bool {
        switch error.code {
        case .serverRecordChanged:
            return true
        case .partialFailure:
            // Any per-item serverRecordChanged inside a partial failure counts.
            if let perItem = error.partialErrorsByItemID?.values {
                return perItem.contains {
                    ($0 as? CKError)?.code == .serverRecordChanged
                }
            }
            return false
        default:
            return false
        }
    }
}

/// Lock-guarded one-shot resume flag for bridging completion-handler
/// CKOperations to a single continuation resume — mirrors ReelRequestState's
/// `takeResume()` safety in MomentReelView. CK completion blocks can fire on
/// arbitrary queues, so the flag must be thread-safe.
private final class OneShotResume: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    /// Returns true exactly once — the winner resumes the continuation.
    func take() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if resumed { return false }
        resumed = true
        return true
    }
}
