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

    /// Prefix that distinguishes ALBUM zones from every other custom zone we
    /// create (notably the ephemeral "facereq-" zones that carry a photo-request
    /// face payload). Load-bearing: the album loaders filter on this so a face
    /// zone never surfaces as a ghost "Shared Album" in the UI, on either the
    /// requester's device (private DB) or the friend's (shared DB).
    static let albumZonePrefix = "album-"

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

    /// Fetch the user's ALBUM zones in the PRIVATE database (the albums we own).
    /// Filters to the "album-" prefix so the default zone AND the ephemeral
    /// "facereq-" face-payload zones never surface as albums.
    func fetchPrivateAlbumZones() async throws -> [CKRecordZone] {
        try await requireAvailable()
        do {
            let zonesByID = try await privateDB.allRecordZones()
            return zonesByID.filter { $0.zoneID.zoneName.hasPrefix(Self.albumZonePrefix) }
        } catch {
            throw map(error)
        }
    }

    /// Fetch the ALBUM zones in the SHARED database (albums others shared with
    /// us). Same "album-" prefix filter as the private side: an accepted
    /// photo-request face share also lands a zone here, and it must never render
    /// as a ghost album.
    func fetchSharedAlbumZones() async throws -> [CKRecordZone] {
        try await requireAvailable()
        do {
            let zones = try await sharedDB.allRecordZones()
            return zones.filter { $0.zoneID.zoneName.hasPrefix(Self.albumZonePrefix) }
        } catch {
            throw map(error)
        }
    }

    /// Fetch EVERY zone in the SHARED database, unfiltered. The photo-request
    /// face path needs this (its ephemeral zones are "facereq-", which the album
    /// loaders deliberately exclude).
    func fetchAllSharedZones() async throws -> [CKRecordZone] {
        try await requireAvailable()
        do {
            return try await sharedDB.allRecordZones()
        } catch {
            throw map(error)
        }
    }

    /// Delete a record zone (and with it every record + the zone-wide share).
    /// Owners call this on the private DB to delete an album for everyone;
    /// participants call it on the shared DB to LEAVE an album (removing only
    /// their own participation — the owner's copy is untouched).
    func deleteZone(_ zoneID: CKRecordZone.ID, in database: CKDatabase) async throws {
        try await requireAvailable()
        do {
            _ = try await database.deleteRecordZone(withID: zoneID)
        } catch {
            throw map(error)
        }
    }

    /// LEAVE a share we participate in but do not own.
    ///
    /// The operation is deleting the zone-wide CKShare record from OUR shared
    /// database, which removes only this user's participation — the owner's
    /// zone, photos and other participants are untouched. Zone deletion is the
    /// OWNER's operation; CloudKit rejects it against the shared database,
    /// which surfaced as "error deleting record zone" when Leave used it.
    ///
    /// Falls back to a zone delete if the share record is missing (an older
    /// album that never recorded one, or a share already torn down), so a
    /// half-migrated album can still be left.
    func leaveShare(zoneID: CKRecordZone.ID) async throws {
        try await requireAvailable()
        let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
        do {
            _ = try await sharedDB.deleteRecord(withID: shareID)
            return
        } catch {
            let mapped = map(error)
            // Already gone — nothing left to leave.
            if case .zoneNotFound = mapped { return }
            if let ck = error as? CKError, ck.code == .unknownItem { return }
            // Anything else: try the zone path before giving up, so we don't
            // strand the user if this share predates zone-wide sharing.
            do {
                _ = try await sharedDB.deleteRecordZone(withID: zoneID)
            } catch {
                throw map(error)
            }
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

    /// True if a record with `id` currently exists in `database`. Used to verify
    /// the album-root parent target exists BEFORE contributing photos: a missing
    /// root would make the photo's `parent`/`album` reference a
    /// `CKError.referenceViolation` and sink the whole save. Never throws — any
    /// failure (including "unknown item") resolves to false so the caller can
    /// decide to repair (re-save the root) or omit the parent reference.
    func recordExists(_ id: CKRecord.ID, in database: CKDatabase) async -> Bool {
        (try? await database.record(for: id)) != nil
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
    ///
    /// We wire BOTH result blocks: the op-level result can be `.success` (or an
    /// opaque `.partialFailure`) even when the individual share failed — the
    /// REAL cause (e.g. `.participantMayNeedVerification` when the device is
    /// signed into a different Apple ID than the invited identity) arrives in
    /// the per-share block. Surfacing it is the difference between "nothing
    /// happened" and an actionable message.
    func acceptShare(_ metadata: CKShare.Metadata) async throws {
        try await requireAvailable()
        let op = CKAcceptSharesOperation(shareMetadatas: [metadata])
        let guardBox = OneShotResume()
        let perShareBox = ErrorBox()

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            op.perShareResultBlock = { _, result in
                if case .failure(let error) = result { perShareBox.store(error) }
            }
            op.acceptSharesResultBlock = { [weak self] result in
                guard guardBox.take() else { return }
                // Prefer the concrete per-share error over the op-level wrapper.
                if let perShare = perShareBox.value {
                    cont.resume(throwing: self?.map(perShare)
                        ?? SharedAlbumError.cloudKit(String(describing: perShare)))
                    return
                }
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
    /// - Returns: a `PhotoUploadResult` — the SharedPhoto value types that saved
    ///   (so the caller can render them optimistically without waiting for a
    ///   re-fetch), their thumbnail bytes (read back from the payload temp files
    ///   before cleanup), and every per-record CKError (so a partial or total
    ///   reject surfaces a concrete cause instead of a silent empty grid).
    ///   Partial success is tolerated — a per-record failure does not sink the
    ///   whole batch — but if a chunk saves NOTHING the operation throws the
    ///   concrete per-record error rather than silently returning zero.
    /// - Note: guards on availability, so it is inert on the simulator / in
    ///   tests, throwing `.unavailable` before any network work.
    /// - Parameter albumRootRef: the album-root parent reference, or nil to omit
    ///   the parent/cascade references (see `SharedPhoto.makeRecord`). The
    ///   caller verifies the root exists in `database` first.
    @discardableResult
    func uploadPhotos(_ payloads: [SharedPhotoUploadPayload],
                      toZone zoneID: CKRecordZone.ID,
                      database: CKDatabase,
                      albumRootRef: CKRecord.Reference?,
                      progress: (@MainActor (Int, Int) -> Void)? = nil) async throws -> PhotoUploadResult {
        try await requireAvailable()
        guard !payloads.isEmpty else { return PhotoUploadResult() }

        let total = payloads.count
        var savedPhotos: [SharedPhoto] = []
        var savedThumbnails: [String: Data] = [:]
        var perRecordErrors: [(id: CKRecord.ID, error: Error)] = []
        // Track every temp file so we can clean up even if we throw mid-batch.
        let allTempURLs = payloads.flatMap { [$0.fullImageURL, $0.thumbnailURL] }
        defer { Self.removeTempFiles(allTempURLs) }

        SharedAlbumLog.logger.info(
            "uploadPhotos: \(total) payload(s) → zone \(zoneID.zoneName, privacy: .public), parent=\(albumRootRef != nil)")

        for chunk in payloads.chunked(into: Self.uploadChunkSize) {
            // Remember each record's thumbnail temp URL so we can read the bytes
            // back for the optimistic cache after the save (the returned server
            // record's CKAsset isn't guaranteed locally materialized yet).
            var thumbURLByRecordID: [CKRecord.ID: URL] = [:]
            let records = chunk.map { payload -> CKRecord in
                let r = SharedPhoto.makeRecord(from: payload, inZone: zoneID, albumRootRef: albumRootRef)
                thumbURLByRecordID[r.recordID] = payload.thumbnailURL
                return r
            }
            SharedAlbumLog.logger.info("uploadPhotos: saving chunk of \(records.count) record(s)")
            let outcome = try await modifyLongLived(saving: records, in: database)
            for rec in outcome.savedRecords {
                guard let photo = SharedPhoto(record: rec) else { continue }
                savedPhotos.append(photo)
                if let url = thumbURLByRecordID[rec.recordID],
                   let data = try? Data(contentsOf: url) {
                    savedThumbnails[photo.id] = data
                }
            }
            for entry in outcome.perRecordErrors {
                perRecordErrors.append(entry)
                let code = (entry.error as? CKError)?.code.rawValue ?? -1
                SharedAlbumLog.logger.error(
                    "uploadPhotos: per-record save FAILED id=\(entry.id.recordName, privacy: .public) code=\(code) \(entry.error.localizedDescription, privacy: .public)")
            }
            let done = savedPhotos.count
            if let progress { await MainActor.run { progress(done, total) } }
        }

        SharedAlbumLog.logger.info(
            "uploadPhotos: saved \(savedPhotos.count)/\(total), \(perRecordErrors.count) per-record failure(s)")
        return PhotoUploadResult(savedPhotos: savedPhotos,
                                 savedThumbnails: savedThumbnails,
                                 perRecordErrors: perRecordErrors)
    }

    /// Save records via a `CKModifyRecordsOperation` (bridged to async, bounded
    /// by the foreground upload task — NOT long-lived), with the same
    /// transient-error retry policy as `save(_:to:)`. Returns the saved records
    /// plus any per-record failures; per-record failures are tolerated unless
    /// the whole op fails (or nothing saved), in which case it throws.
    private func modifyLongLived(saving records: [CKRecord],
                                 in database: CKDatabase,
                                 maxAttempts: Int = 4) async throws -> ModifyOutcome {
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

    /// One pass of a modify operation, bridged to async. Captures per-record
    /// results: successes are returned as records, failures are collected with
    /// their CKError so the caller can surface a concrete cause. Tolerates
    /// partial failure (SOME saved); if NOTHING saved it rethrows the FIRST
    /// per-record CKError (mapped) — not the generic partial-failure wrapper —
    /// so a device run reveals the real reason (e.g. `.permissionFailure`).
    private func runModifyOperation(saving records: [CKRecord],
                                    in database: CKDatabase) async throws -> ModifyOutcome {
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
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ModifyOutcome, Error>) in
            var saved: [CKRecord] = []
            var perRecordErrors: [(id: CKRecord.ID, error: Error)] = []
            op.perRecordSaveBlock = { id, result in
                switch result {
                case .success(let rec):
                    saved.append(rec)
                case .failure(let err):
                    perRecordErrors.append((id, err))
                }
            }
            op.modifyRecordsResultBlock = { [weak self] result in
                guard guardBox.take() else { return }
                switch result {
                case .success:
                    cont.resume(returning: ModifyOutcome(savedRecords: saved,
                                                         perRecordErrors: perRecordErrors))
                case .failure(let error):
                    // A partial failure where SOME records saved is not fatal:
                    // return what saved (plus the failures) so the caller keeps
                    // the progress AND can report which records failed.
                    if let ck = error as? CKError, ck.code == .partialFailure, !saved.isEmpty {
                        cont.resume(returning: ModifyOutcome(savedRecords: saved,
                                                             perRecordErrors: perRecordErrors))
                    } else if let first = perRecordErrors.first {
                        // Nothing saved: surface the concrete per-record CKError
                        // (e.g. permissionFailure / referenceViolation) instead
                        // of the opaque partialFailure wrapper. These are
                        // non-retryable hard rejects, so mapping here is correct.
                        cont.resume(throwing: self?.map(first.error)
                            ?? SharedAlbumError.cloudKit(String(describing: first.error)))
                    } else {
                        // Op-level failure with no per-record breakdown (e.g.
                        // .zoneBusy / .requestRateLimited / .serviceUnavailable
                        // when two accounts hammer one zone). Rethrow the RAW
                        // error UNMAPPED so modifyLongLived's `catch let error as
                        // CKError` can classify it and honor the transient-error
                        // retry policy (retryDelay + retryAfterSeconds). Mapping
                        // it here would yield a SharedAlbumError that that catch
                        // can never match, making the retry loop dead code.
                        cont.resume(throwing: error)
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
    /// The result of a full zone load: photo metadata + thumbnails, plus every
    /// NON-photo record in the zone (reactions/comments) for the store to parse.
    struct ZoneLoad {
        var photos: [(photo: SharedPhoto, thumbnail: Data?)] = []
        var socialRecords: [CKRecord] = []
    }

    func loadPhotos(inZone zoneID: CKRecordZone.ID,
                    database: CKDatabase) async throws -> ZoneLoad {
        try await requireAvailable()

        do {
            // Full enumeration: nil previous token ⇒ all records in the zone.
            // (Same desiredKeys — thumbnail + metadata, no fullImage — as sync.)
            // NOTE: this is deliberately a FULL fetch (nil token), NOT the
            // incremental delta the push path uses, so an owner's just-written
            // record is guaranteed to return on the post-upload reload.
            let zc = try await fetchZoneChanges(zoneID, in: database, since: nil)
            SharedAlbumLog.logger.info(
                "loadPhotos(cloud): zone \(zoneID.zoneName, privacy: .public) returned \(zc.changedRecords.count) record(s) [full token]")

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

            let social = records.filter {
                $0.recordType == SharedSocial.RecordType.reaction
                    || $0.recordType == SharedSocial.RecordType.comment
            }

            let sorted = mapped.sorted { lhs, rhs in
                switch (lhs.photo.captureDate, rhs.photo.captureDate) {
                case let (l?, r?): return l > r          // newest first
                case (nil, _?):    return false           // nils sort last
                case (_?, nil):    return true
                case (nil, nil):   return false
                }
            }
            return ZoneLoad(photos: sorted, socialRecords: social)
        } catch {
            throw map(error)
        }
    }

    /// Delete a single record (used to remove one's own reaction). Maps errors.
    func deleteRecord(_ id: CKRecord.ID, from database: CKDatabase) async throws {
        try await requireAvailable()
        do {
            _ = try await database.deleteRecord(withID: id)
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
        // Read the (potentially multi-MB) asset bytes OFF the main actor — a
        // synchronous Data(contentsOf:) here would jank the viewer on every tap.
        return await Task.detached(priority: .userInitiated) {
            Self.assetData(asset)
        }.value
    }

    /// Read a CKAsset's bytes off its on-disk file URL. Returns nil if the asset
    /// has no file URL (e.g. it was excluded by desiredKeys) or the read fails.
    /// `nonisolated` so callers can decode off the main actor.
    nonisolated static func assetData(_ asset: CKAsset) -> Data? {
        guard let url = asset.fileURL else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Fetch a photo's FULL asset as a temp FILE URL (not Data) — the right
    /// shape for videos, which can be hundreds of MB and are handed straight to
    /// AVPlayer / PHAssetCreationRequest. The CKAsset's staging file is copied
    /// to our own temp path (CloudKit may reclaim its staging area); the CALLER
    /// owns the returned file. Returns nil when the record/asset is gone.
    func fullAssetFileURL(for photo: SharedPhoto, database: CKDatabase) async throws -> URL? {
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
        guard let asset = record?[SharedAlbum.PhotoField.fullImage] as? CKAsset,
              let source = asset.fileURL else { return nil }
        let ext = photo.isVideo ? "mov" : "jpg"
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("shared-\(UUID().uuidString).\(ext)")
        // Copy OFF the main actor — the file can be large.
        return await Task.detached(priority: .userInitiated) {
            do {
                try FileManager.default.copyItem(at: source, to: dest)
                return dest
            } catch {
                return nil
            }
        }.value
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
            // A duplicate subscription (same subscriptionID) is rejected with
            // .serverRejectedRequest — but so is a GENUINELY rejected one
            // (container misconfig, unsupported database). Disambiguate by
            // fetching the subscription: if it exists, this was the benign
            // duplicate; if not, the push channel is really broken — surface it
            // instead of silently never syncing.
            if error.code == .serverRejectedRequest || Self.indicatesAlreadyExists(error) {
                if (try? await database.subscription(for: id)) != nil { return }
                SharedAlbumLog.logger.error(
                    "ensureDatabaseSubscription: \(id, privacy: .public) REJECTED and absent — pushes will not arrive")
                throw map(error)
            }
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
        //
        //    Per-zone errors are ISOLATED: one bad zone must not abort the whole
        //    sync (which would discard every other zone's delta AND stall the
        //    database token forever). `.zoneNotFound`/`.userDeletedZone` means the
        //    zone vanished between the DB pass and the zone fetch — e.g. the owner
        //    revoked our access — so report it as deleted; anything else is
        //    skipped (its token doesn't advance, so nothing is lost) and logged.
        var zoneChanges: [ZoneChangeResult] = []
        var deletedZones = zoneResult.deletedZones
        var failedZones: [CKRecordZone.ID] = []
        for zoneID in zoneResult.changedZones {
            do {
                let rc = try await fetchZoneChanges(zoneID, in: database, since: zoneToken(zoneID))
                zoneChanges.append(rc)
            } catch SharedAlbumError.changeTokenExpired {
                do {
                    let rc = try await fetchZoneChanges(zoneID, in: database, since: nil)
                    zoneChanges.append(rc)
                } catch {
                    failedZones.append(zoneID)
                    SharedAlbumLog.logger.error(
                        "fetchDatabaseChanges: zone \(zoneID.zoneName, privacy: .public) refetch failed — \(error.localizedDescription, privacy: .public)")
                }
            } catch SharedAlbumError.zoneNotFound {
                // Zone vanished between the DB pass and the zone fetch (owner
                // deleted it / revoked us) — report as deleted.
                deletedZones.append(zoneID)
            } catch {
                failedZones.append(zoneID)
                SharedAlbumLog.logger.error(
                    "fetchDatabaseChanges: zone \(zoneID.zoneName, privacy: .public) fetch failed — \(error.localizedDescription, privacy: .public)")
            }
        }

        return DatabaseChangeResult(
            newDatabaseToken: zoneResult.newToken,
            deletedZoneIDs: deletedZones,
            zoneChanges: zoneChanges,
            failedZoneIDs: failedZones)
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

    /// The default per-record keys for zone sync/loads: metadata + thumbnail
    /// only — the full image stays lazy (fetched on tap via `fullImage`).
    /// Includes the social record types' fields (reactions/comments live in the
    /// same zone and ride the same fetches; keys absent on a record type are
    /// simply omitted).
    private static let syncDesiredKeys: [CKRecord.FieldKey] = [
        SharedAlbum.PhotoField.thumbnail,
        SharedAlbum.PhotoField.contributorID,
        SharedAlbum.PhotoField.captureDate,
        SharedAlbum.PhotoField.latitude,
        SharedAlbum.PhotoField.longitude,
        SharedAlbum.PhotoField.originalFilename,
        SharedAlbum.PhotoField.contentHash,
        SharedAlbum.PhotoField.mediaType,
        SharedAlbum.PhotoField.duration,
        SharedSocial.Field.photoRef,
        SharedSocial.Field.emoji,
        SharedSocial.Field.commentText,
        SharedSocial.Field.authorID,
        SharedSocial.Field.authorName,
        SharedSocial.Field.createdAt,
    ]

    /// The contentHash of every photo currently in a zone. A cheap, asset-free
    /// enumeration (desiredKeys = contentHash only) used to dedupe uploads: a
    /// retried or repeated "add photos" skips photos whose bytes are already in
    /// the album instead of duplicating them.
    func existingContentHashes(inZone zoneID: CKRecordZone.ID,
                               database: CKDatabase) async throws -> Set<String> {
        try await requireAvailable()
        do {
            let zc = try await fetchZoneChanges(
                zoneID, in: database, since: nil,
                desiredKeys: [SharedAlbum.PhotoField.contentHash])
            var hashes = Set<String>()
            for record in zc.changedRecords where record.recordType == SharedAlbum.RecordType.photo {
                if let hash = record[SharedAlbum.PhotoField.contentHash] as? String {
                    hashes.insert(hash)
                }
            }
            return hashes
        } catch {
            throw map(error)
        }
    }

    /// Run CKFetchRecordZoneChangesOperation for one zone, bridged to async.
    /// Returns changed records, deleted record IDs, and the zone's new token.
    /// Fetch EVERY record in a zone with ALL fields (no desiredKeys filter).
    /// Used by the settings-sync layer, whose records aren't photo-shaped.
    func allRecords(inZone zoneID: CKRecordZone.ID,
                    database: CKDatabase) async throws -> [CKRecord] {
        try await requireAvailable()
        do {
            let zc = try await fetchZoneChanges(zoneID, in: database, since: nil, allFields: true)
            return zc.changedRecords
        } catch {
            throw map(error)
        }
    }

    private func fetchZoneChanges(
        _ zoneID: CKRecordZone.ID,
        in database: CKDatabase,
        since token: CKServerChangeToken?,
        desiredKeys: [CKRecord.FieldKey]? = nil,
        allFields: Bool = false
    ) async throws -> ZoneChangeResult {
        let config = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
        config.previousServerChangeToken = token
        // Metadata + thumbnail only on sync; full image stays lazy.
        config.desiredKeys = allFields ? nil : (desiredKeys ?? Self.syncDesiredKeys)
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
            // A partialFailure is an opaque wrapper ("Failed to modify some
            // records") — the REAL cause lives in partialErrorsByItemID. Unwrap
            // to the first underlying CKError so the user sees something
            // actionable (e.g. a permission or verification failure).
            if ck.code == .partialFailure,
               let first = ck.partialErrorsByItemID?.values
                   .compactMap({ $0 as? CKError }).first {
                return map(first)
            }
            switch ck.code {
            case .notAuthenticated, .accountTemporarilyUnavailable:
                return .unavailable(reason: "Sign in to iCloud to use Shared Albums")
            case .networkUnavailable, .networkFailure:
                return .cloudKit("iCloud is unreachable. Check your connection.")
            case .permissionFailure:
                // The classic participant-with-read-only-access failure. Keep the
                // reason NEUTRAL (this mapper also serves read/refresh/accept/sync
                // paths); the operation context comes from the call site's alert
                // title (e.g. "Couldn't Add Photos" / "Couldn't Refresh Album").
                return .cloudKit("You have view-only access to this album.")
            case .quotaExceeded:
                return .cloudKit("Your iCloud storage is full.")
            case .changeTokenExpired:
                // Surfaced as a distinct case so the sync layer can clear the
                // stale token and refetch from scratch instead of wedging.
                return .changeTokenExpired
            case .zoneNotFound, .userDeletedZone:
                // Distinct case: the zone (album) is gone or our access was
                // revoked — the sync layer treats this as a deletion, not a
                // failure.
                return .zoneNotFound
            default:
                // Unhandled CKError codes previously surfaced only Apple's
                // generic sentence ("error deleting record zone"), which names
                // the operation but not the cause and is undebuggable from a
                // user report. Append the numeric code so a screenshot is
                // actionable.
                return .cloudKit("\(ck.localizedDescription) (CloudKit error \(ck.errorCode))")
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

// MARK: - Upload result types

/// The outcome of one `CKModifyRecordsOperation` pass: the server records that
/// saved, plus every per-record failure (id + CKError). Lets the upload layer
/// report partial success AND surface the concrete cause when nothing saved.
struct ModifyOutcome {
    var savedRecords: [CKRecord]
    var perRecordErrors: [(id: CKRecord.ID, error: Error)]
}

/// The outcome of an `uploadPhotos` call. Carries the saved photos as value
/// types (for optimistic rendering), their thumbnail bytes (read back from the
/// payload temp files before cleanup, keyed by SharedPhoto id), and any
/// per-record CKErrors so the store can surface a precise reason.
struct PhotoUploadResult {
    var savedPhotos: [SharedPhoto] = []
    var savedThumbnails: [String: Data] = [:]
    var perRecordErrors: [(id: CKRecord.ID, error: Error)] = []

    var savedCount: Int { savedPhotos.count }
    /// The first per-record error, if any — the store maps it to a user-facing
    /// message via `CloudKitService.map`.
    var firstError: Error? { perRecordErrors.first?.error }
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
///
/// `failedZoneIDs`: zones the DB pass reported as changed but whose record
/// fetch failed. LOAD-BEARING for the store: CKFetchDatabaseChangesOperation
/// only re-reports a zone for changes AFTER the supplied database token — so if
/// the store persisted `newDatabaseToken` despite a failed zone, that zone's
/// delta would never be re-delivered (until some future unrelated write). The
/// store must NOT advance the database token when this is non-empty.
struct DatabaseChangeResult {
    let newDatabaseToken: CKServerChangeToken?
    let deletedZoneIDs: [CKRecordZone.ID]
    let zoneChanges: [ZoneChangeResult]
    var failedZoneIDs: [CKRecordZone.ID] = []
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

/// Lock-guarded first-error capture for CKOperations whose per-item blocks fire
/// on arbitrary queues before the op-level result block. Stores the FIRST error
/// only (the concrete cause); later errors are ignored.
private final class ErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Error?
    func store(_ error: Error) {
        lock.lock(); defer { lock.unlock() }
        if stored == nil { stored = error }
    }
    var value: Error? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
}
