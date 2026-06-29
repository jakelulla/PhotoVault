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

    // MARK: - Photo upload (Phase 3)

    /// How many photo records to push per CKModifyRecordsOperation. CloudKit's
    /// hard cap is 400 records / 2MB of metadata per op, but with CKAssets the
    /// practical limit is bandwidth, so we keep batches small (~50) to bound
    /// memory and give finer-grained progress / partial-success reporting.
    private static let uploadChunkSize = 50

    /// Upload a batch of photos into `zoneID`, each as a "SharedPhoto" record
    /// with a full-res + thumbnail CKAsset and a parent reference to the album
    /// root. Saves in chunks via `CKModifyRecordsOperation`s at
    /// `.userInitiated` QoS, honoring CKError rate-limits with the same retry
    /// policy as `save(_:to:)`. Temp files referenced by the payloads are
    /// deleted after each chunk completes (success or hard failure), so a failed
    /// upload never leaks temp files.
    ///
    /// - Returns: the count of successfully saved photo records (partial success
    ///   is tolerated — a per-record failure does not sink the whole batch).
    /// - Note: guards on availability, so it is inert on the simulator / in
    ///   tests, throwing `.unavailable` before any network work.
    @discardableResult
    func uploadPhotos(_ payloads: [SharedPhotoUploadPayload],
                      toZone zoneID: CKRecordZone.ID,
                      database: CKDatabase,
                      albumRootRef: CKRecord.Reference,
                      progress: (@MainActor (Int, Int) -> Void)? = nil) async throws -> Int {
        try await requireAvailable()
        guard !payloads.isEmpty else { return 0 }

        let total = payloads.count
        var savedCount = 0
        // Track every temp file so we can clean up even if we throw mid-batch.
        let allTempURLs = payloads.flatMap { [$0.fullImageURL, $0.thumbnailURL] }
        defer { Self.removeTempFiles(allTempURLs) }

        for chunk in payloads.chunked(into: Self.uploadChunkSize) {
            let records = chunk.map {
                SharedPhoto.makeRecord(from: $0, inZone: zoneID, albumRootRef: albumRootRef)
            }
            let saved = try await modifyLongLived(saving: records, in: database)
            savedCount += saved
            let done = savedCount
            if let progress { await MainActor.run { progress(done, total) } }
        }
        return savedCount
    }

    /// Save records via a `CKModifyRecordsOperation` (bridged to async, bounded
    /// by the foreground upload task — NOT long-lived), with the same
    /// transient-error retry policy as `save(_:to:)`. Returns the count of
    /// records that saved successfully; per-record failures are tolerated unless
    /// the whole op fails with a non-retryable error.
    private func modifyLongLived(saving records: [CKRecord],
                                 in database: CKDatabase,
                                 maxAttempts: Int = 4) async throws -> Int {
        var attempt = 0
        var lastError: Error?
        while attempt < maxAttempts {
            attempt += 1
            do {
                return try await runModifyOperation(saving: records, in: database)
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

    /// One pass of a modify operation, bridged to async. Tolerates per-record
    /// failures (counts successes); rethrows the operation-level error so the
    /// retry layer can decide.
    private func runModifyOperation(saving records: [CKRecord],
                                    in database: CKDatabase) async throws -> Int {
        let op = CKModifyRecordsOperation(recordsToSave: records, recordIDsToDelete: nil)
        op.savePolicy = .allKeys
        op.isAtomic = false
        op.qualityOfService = .userInitiated
        // NOT long-lived: this op is bridged through a withCheckedContinuation
        // bounded by the foreground upload task. A long-lived op would be
        // resumed after app suspension with no rediscovery code here, silently
        // dropping the completion (and the continuation would never resume). A
        // normal operation is the correct lifetime for this bridge.

        let guardBox = OneShotResume()
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int, Error>) in
            // Count successes; we ignore per-record failures here (they show up
            // as fewer saved records) and only fail the whole op on a hard error.
            var successes = 0
            op.perRecordSaveBlock = { _, result in
                if case .success = result { successes += 1 }
            }
            op.modifyRecordsResultBlock = { [weak self] result in
                guard guardBox.take() else { return }
                switch result {
                case .success:
                    cont.resume(returning: successes)
                case .failure(let error):
                    // A partial failure where SOME records saved is not fatal:
                    // return the success count so the caller keeps the progress.
                    if let ck = error as? CKError, ck.code == .partialFailure, successes > 0 {
                        cont.resume(returning: successes)
                    } else {
                        cont.resume(throwing: self?.map(error)
                            ?? SharedAlbumError.cloudKit(String(describing: error)))
                    }
                }
            }
            database.add(op)
        }
    }

    /// Best-effort temp-file cleanup. Never throws — a failed delete is logged
    /// in DEBUG and otherwise ignored (the OS reclaims the temp dir anyway).
    private static func removeTempFiles(_ urls: [URL]) {
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Photo loading (Phase 4)

    /// Fetch the album's photos as METADATA + thumbnail only (NOT the full
    /// image), keyed off the parent album reference. Loads thumbnails first; the
    /// full bytes are pulled lazily on tap via `fullImage(for:)`.
    ///
    /// We enumerate the zone's records with a `CKFetchRecordZoneChangesOperation`
    /// driven from a nil change token (a full enumeration of the zone). This
    /// deliberately avoids a zone-scoped `CKQuery`, which would sort/filter on
    /// custom fields (`captureDate`) and therefore require those fields be marked
    /// Queryable/Sortable in the CloudKit schema — the auto-created dev schema
    /// does NOT mark custom fields queryable or sortable, so the first real query
    /// would throw `CKError.invalidArguments`. Zone-changes enumeration needs no
    /// such indexes. We sort client-side by `captureDate` descending (nil dates
    /// last), reusing `fetchZoneChanges` and the asset-decode helper. Malformed
    /// records are skipped. Guards on availability.
    func loadPhotos(inZone zoneID: CKRecordZone.ID,
                    database: CKDatabase) async throws -> [(photo: SharedPhoto, thumbnail: Data?)] {
        try await requireAvailable()

        do {
            // Full enumeration: nil previous token ⇒ all records in the zone.
            // (Same desiredKeys — thumbnail + metadata, no fullImage — as sync.)
            let zc = try await fetchZoneChanges(zoneID, in: database, since: nil)

            // Decode CKAsset thumbnail bytes OFF the main actor so a large album
            // doesn't jank the UI, then return the mapped value types. Sorting is
            // client-side (newest first; records with no captureDate sort last).
            let records = zc.changedRecords
            let mapped: [(photo: SharedPhoto, thumbnail: Data?)] =
                await Task.detached(priority: .userInitiated) {
                    records.compactMap { record -> (photo: SharedPhoto, thumbnail: Data?)? in
                        guard let photo = SharedPhoto(record: record) else { return nil }
                        let thumb = (record[SharedAlbum.PhotoField.thumbnail] as? CKAsset)
                            .flatMap(CloudKitService.assetData)
                        return (photo, thumb)
                    }
                }.value

            return mapped.sorted { lhs, rhs in
                switch (lhs.photo.captureDate, rhs.photo.captureDate) {
                case let (l?, r?): return l > r          // newest first
                case (nil, _?):    return false           // nils sort last
                case (_?, nil):    return true
                case (nil, nil):   return false
                }
            }
        } catch {
            throw map(error)
        }
    }

    /// Lazily fetch the FULL-resolution image bytes for one photo, on demand
    /// (when the user taps it). Uses a `CKFetchRecordsOperation` scoped to just
    /// the `fullImage` asset field so we download only the bytes we need, not the
    /// thumbnail again. Returns nil if the record / asset is gone. Guards on
    /// availability.
    func fullImage(for photo: SharedPhoto, database: CKDatabase) async throws -> Data? {
        try await requireAvailable()
        let op = CKFetchRecordsOperation(recordIDs: [photo.recordID])
        op.desiredKeys = [SharedAlbum.PhotoField.fullImage]
        op.qualityOfService = .userInitiated

        let guardBox = OneShotResume()
        let record: CKRecord? = try await withCheckedThrowingContinuation { cont in
            var fetched: CKRecord?
            op.perRecordResultBlock = { _, result in
                if case .success(let rec) = result { fetched = rec }
            }
            // The result block fires after all per-record blocks, so resume there.
            op.fetchRecordsResultBlock = { [weak self] result in
                guard guardBox.take() else { return }
                switch result {
                case .success:
                    cont.resume(returning: fetched)
                case .failure(let error):
                    cont.resume(throwing: self?.map(error)
                        ?? SharedAlbumError.cloudKit(String(describing: error)))
                }
            }
            database.add(op)
        }
        guard let asset = record?[SharedAlbum.PhotoField.fullImage] as? CKAsset else {
            return nil
        }
        return Self.assetData(asset)
    }

    /// Read a CKAsset's bytes off its on-disk file URL. Returns nil if the asset
    /// has no file URL (e.g. it was excluded by desiredKeys) or the read fails.
    /// `nonisolated` so callers can decode off the main actor.
    nonisolated static func assetData(_ asset: CKAsset) -> Data? {
        guard let url = asset.fileURL else { return nil }
        return try? Data(contentsOf: url)
    }

    // MARK: - Subscriptions + delta sync (Phase 4)

    /// Register a silent (background) database subscription on `database` if one
    /// is not already present. Used to wake the app on remote changes so
    /// `syncChanges()` can delta-fetch. Idempotent: an "already exists" error is
    /// treated as success. Guards on availability — callers ALSO gate on
    /// `runningTests` so this never runs in the test host.
    func ensureDatabaseSubscription(id: String, on database: CKDatabase) async throws {
        try await requireAvailable()
        let subscription = CKDatabaseSubscription(subscriptionID: id)
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true   // silent push, no alert/badge
        subscription.notificationInfo = info
        do {
            _ = try await database.save(subscription)
        } catch let error as CKError {
            if Self.indicatesAlreadyExists(error) { return }
            throw map(error)
        } catch {
            throw map(error)
        }
    }

    /// Fetch the set of changed record zones in `database` since `token`, then
    /// for each changed zone fetch its record-level changes since that zone's
    /// own token (resolved by `zoneToken`, which the store backs with its
    /// persisted per-zone token cache). Returns the changes plus the NEW tokens
    /// to persist. Pure CloudKit; the store owns token persistence and value
    /// mapping.
    func fetchDatabaseChanges(
        in database: CKDatabase,
        since token: CKServerChangeToken?,
        zoneToken: (CKRecordZone.ID) -> CKServerChangeToken?
    ) async throws -> DatabaseChangeResult {
        try await requireAvailable()

        // 1. Which zones changed (or were deleted)?
        let zoneResult = try await fetchChangedZones(in: database, since: token)

        // 2. For each changed zone, fetch record-level deltas since its own token.
        //    A zone-level `changeTokenExpired` can't be advanced — recover by
        //    clearing it (refetch from scratch with a nil token). The new token
        //    returned replaces the stale one in the store's cache, so this also
        //    un-wedges persisted state.
        var zoneChanges: [ZoneChangeResult] = []
        for zoneID in zoneResult.changedZones {
            do {
                let rc = try await fetchZoneChanges(zoneID, in: database, since: zoneToken(zoneID))
                zoneChanges.append(rc)
            } catch SharedAlbumError.changeTokenExpired {
                let rc = try await fetchZoneChanges(zoneID, in: database, since: nil)
                zoneChanges.append(rc)
            }
        }

        return DatabaseChangeResult(
            newDatabaseToken: zoneResult.newToken,
            deletedZoneIDs: zoneResult.deletedZones,
            zoneChanges: zoneChanges)
    }

    /// Run CKFetchDatabaseChangesOperation, bridged to async. Returns the set of
    /// changed-zone IDs, deleted-zone IDs, and the new database token.
    private func fetchChangedZones(
        in database: CKDatabase,
        since token: CKServerChangeToken?
    ) async throws -> (changedZones: [CKRecordZone.ID],
                       deletedZones: [CKRecordZone.ID],
                       newToken: CKServerChangeToken?) {
        let op = CKFetchDatabaseChangesOperation(previousServerChangeToken: token)
        op.qualityOfService = .userInitiated
        op.fetchAllChanges = true

        var changed: [CKRecordZone.ID] = []
        var deleted: [CKRecordZone.ID] = []
        op.recordZoneWithIDChangedBlock = { changed.append($0) }
        op.recordZoneWithIDWasDeletedBlock = { deleted.append($0) }

        let guardBox = OneShotResume()
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(changedZones: [CKRecordZone.ID], deletedZones: [CKRecordZone.ID], newToken: CKServerChangeToken?), Error>) in
            op.fetchDatabaseChangesResultBlock = { [weak self] result in
                guard guardBox.take() else { return }
                switch result {
                case .success(let (newToken, _)):
                    cont.resume(returning: (changed, deleted, newToken))
                case .failure(let error):
                    cont.resume(throwing: self?.map(error)
                        ?? SharedAlbumError.cloudKit(String(describing: error)))
                }
            }
            database.add(op)
        }
    }

    /// Run CKFetchRecordZoneChangesOperation for one zone, bridged to async.
    /// Returns changed records, deleted record IDs, and the zone's new token.
    private func fetchZoneChanges(
        _ zoneID: CKRecordZone.ID,
        in database: CKDatabase,
        since token: CKServerChangeToken?
    ) async throws -> ZoneChangeResult {
        let config = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
        config.previousServerChangeToken = token
        // Metadata + thumbnail only on sync; full image stays lazy.
        config.desiredKeys = [
            SharedAlbum.PhotoField.thumbnail,
            SharedAlbum.PhotoField.contributorID,
            SharedAlbum.PhotoField.captureDate,
            SharedAlbum.PhotoField.latitude,
            SharedAlbum.PhotoField.longitude,
            SharedAlbum.PhotoField.originalFilename,
            SharedAlbum.PhotoField.contentHash,
        ]
        let op = CKFetchRecordZoneChangesOperation(
            recordZoneIDs: [zoneID],
            configurationsByRecordZoneID: [zoneID: config])
        op.qualityOfService = .userInitiated
        op.fetchAllChanges = true

        var changedRecords: [CKRecord] = []
        var deletedRecordIDs: [CKRecord.ID] = []
        var newToken: CKServerChangeToken?

        op.recordWasChangedBlock = { _, result in
            if case .success(let record) = result { changedRecords.append(record) }
        }
        op.recordWithIDWasDeletedBlock = { id, _ in deletedRecordIDs.append(id) }
        op.recordZoneChangeTokensUpdatedBlock = { _, serverToken, _ in
            if let serverToken { newToken = serverToken }
        }
        op.recordZoneFetchResultBlock = { _, result in
            if case .success(let (serverToken, _, _)) = result { newToken = serverToken }
        }

        let guardBox = OneShotResume()
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ZoneChangeResult, Error>) in
            op.fetchRecordZoneChangesResultBlock = { [weak self] result in
                guard guardBox.take() else { return }
                switch result {
                case .success:
                    cont.resume(returning: ZoneChangeResult(
                        zoneID: zoneID,
                        newToken: newToken,
                        changedRecords: changedRecords,
                        deletedRecordIDs: deletedRecordIDs))
                case .failure(let error):
                    cont.resume(throwing: self?.map(error)
                        ?? SharedAlbumError.cloudKit(String(describing: error)))
                }
            }
            database.add(op)
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
            case .changeTokenExpired:
                // Surfaced as a distinct case so the sync layer can clear the
                // stale token and refetch from scratch instead of wedging.
                return .changeTokenExpired
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

// MARK: - Delta-sync result types

/// Record-level delta for a single zone, plus its new server change token.
struct ZoneChangeResult {
    let zoneID: CKRecordZone.ID
    let newToken: CKServerChangeToken?
    let changedRecords: [CKRecord]
    let deletedRecordIDs: [CKRecord.ID]
}

/// The full delta for one database: which zones were deleted, the per-zone
/// record changes, and the new database-level change token to persist.
struct DatabaseChangeResult {
    let newDatabaseToken: CKServerChangeToken?
    let deletedZoneIDs: [CKRecordZone.ID]
    let zoneChanges: [ZoneChangeResult]
}

extension Array {
    /// Split into chunks of at most `size`. Used to bound CKModifyRecordsOperation
    /// batch sizes. `size` is clamped to ≥ 1 so a zero never loops forever.
    func chunked(into size: Int) -> [[Element]] {
        let step = Swift.max(1, size)
        return stride(from: 0, to: count, by: step).map {
            Array(self[$0 ..< Swift.min($0 + step, count)])
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
