import CloudKit
import CryptoKit
import Foundation
import Photos
import UIKit

/// Owns the shared-albums state for the view layer. Mirrors PhotoStore's idiom:
/// a `@MainActor` `ObservableObject` singleton, JSON persistence in the app's
/// documents dir, and `@Published` state the views observe.
///
/// CloudKit is the source of truth; the local JSON cache exists only for offline
/// display and graceful degradation (so opening the tab on a plane shows the
/// last-known albums instead of an empty screen). The cache is never trusted
/// over a successful CloudKit fetch.
///
/// Crucially, NOTHING here runs at init or at app launch. A caller
/// (SharedAlbumsView's `.task`, or the share-accept app-delegate hook) drives
/// `refreshAvailability()` / `loadAlbums()`. On the simulator and in the test
/// suite those entry points are never reached at launch, and even if called
/// they short-circuit on `CloudKitService.isAvailable == false` — so this stack
/// is provably inert in the regression gate.
@MainActor
final class SharedAlbumStore: ObservableObject {
    static let shared = SharedAlbumStore()

    /// High-level UI state for SharedAlbumsView.
    enum State: Equatable {
        case idle
        /// iCloud not usable (simulator, signed out). Carries a user-facing reason.
        case unavailable(reason: String)
        case loading
        case ready
        case error(message: String)
    }

    @Published private(set) var albums: [SharedAlbum] = []
    @Published private(set) var state: State = .idle

    /// iCloud user record names we have ever shared an album with — powers a
    /// future "share with the same people again" affordance. Persisted locally.
    @Published private(set) var knownParticipantIDs: Set<String> = []

    /// Photos currently loaded for the OPEN album, keyed by album id. Thumbnails
    /// are stored alongside as in-memory bytes; full images are pulled lazily.
    /// The detail view observes this; only the album it opened is populated.
    @Published private(set) var photosByAlbum: [String: [SharedPhoto]] = [:]

    /// In-memory thumbnail-bytes cache, keyed by SharedPhoto record name. Small
    /// (~256px JPEGs); cleared wholesale on demand. Not persisted.
    @Published private(set) var thumbnailCache: [String: Data] = [:]

    /// Per-album upload progress in [0, 1]; absent when no upload is in flight.
    /// The detail view shows a progress bar while present.
    @Published private(set) var uploadProgress: [String: Double] = [:]

    /// Albums currently performing a network load of their photos.
    @Published private(set) var loadingPhotos: Set<String> = []

    /// True once CKDatabaseSubscriptions have been registered this launch, so we
    /// don't re-register on every view appearance. Reset only on relaunch.
    private var subscriptionsRegistered = false

    private let cloud = CloudKitService.shared

    /// True when running inside the XCTest host. Mirrors ContentView.runningTests
    /// so launch/sync-reachable CloudKit work is skipped in the test suite even
    /// if some entry point is exercised. Belt-and-braces with the isAvailable
    /// guard (which already short-circuits on the simulator).
    private static let runningTests =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    // MARK: - Storage paths (mirror PhotoStore's documents-dir JSON idiom)

    private static let storeDir: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let d = docs.appendingPathComponent("photosearch", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    private static var albumsCacheURL: URL { storeDir.appendingPathComponent("shared_albums.json") }
    private static var participantsURL: URL { storeDir.appendingPathComponent("shared_participants.json") }
    private static var changeTokensURL: URL { storeDir.appendingPathComponent("shared_change_tokens.json") }

    /// In-memory copy of the persisted server-change-token cache. Loaded lazily
    /// (and only when CloudKit is available), so it never touches disk at launch
    /// or in tests. See `ChangeTokenCache` for the encode/decode contract.
    private var tokenCache = ChangeTokenCache()

    /// Loads only the LOCAL cache — no CloudKit. Safe at any time. Not called
    /// from init by default to honor the "do not auto-run" rule; SharedAlbumsView
    /// loads the cache when it appears so offline users see something instantly.
    private init() {}

    // MARK: - Local cache

    /// Hydrate `albums` + `knownParticipantIDs` from disk. Pure local I/O; never
    /// touches CloudKit. Tolerant of missing/corrupt files (treats as empty).
    func loadLocalCache() {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: Self.albumsCacheURL),
           let cached = try? dec.decode([SharedAlbum].self, from: data) {
            albums = cached
        }
        if let data = try? Data(contentsOf: Self.participantsURL),
           let ids = try? JSONDecoder().decode(Set<String>.self, from: data) {
            knownParticipantIDs = ids
        }
    }

    private func persistCache() {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try? enc.encode(albums).write(to: Self.albumsCacheURL, options: .atomic)
        try? JSONEncoder().encode(knownParticipantIDs).write(to: Self.participantsURL, options: .atomic)
    }

    private func rememberParticipants(_ ids: [String]) {
        let before = knownParticipantIDs.count
        knownParticipantIDs.formUnion(ids)
        if knownParticipantIDs.count != before { persistCache() }
    }

    // MARK: - Availability

    /// Check whether iCloud is usable and set `state` accordingly. Safe on the
    /// simulator and in tests: `CloudKitService.accountStatus()` resolves to a
    /// non-available status without hanging, so we land in `.unavailable` and
    /// never make a network call.
    func refreshAvailability() async {
        await cloud.accountStatus()
        if cloud.isAvailable {
            // Available, but don't auto-load here — let the caller decide. Move
            // out of an `.unavailable` state so the UI can offer actions; leave
            // any in-flight `.loading`/`.ready`/`.error` state untouched.
            if case .unavailable = state { state = .idle }
        } else {
            state = .unavailable(reason: "Sign in to iCloud to use Shared Albums")
        }
    }

    // MARK: - Create

    /// Create a new shared album: mint a custom zone, write the album's root
    /// record into it, and create the zone-wide CKShare. Appends to `albums`,
    /// caches locally, and returns the value. Throws `SharedAlbumError` on any
    /// failure (including `.unavailable` on the simulator / signed out).
    @discardableResult
    func createAlbum(named rawName: String) async throws -> SharedAlbum {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw SharedAlbumError.cloudKit("Album name cannot be empty.")
        }
        // Hard guard: even though every CloudKitService op re-checks, fail fast
        // with the friendly message before doing any work.
        await cloud.accountStatus()
        guard cloud.isAvailable else {
            let reason = "Sign in to iCloud to use Shared Albums"
            state = .unavailable(reason: reason)
            throw SharedAlbumError.unavailable(reason: reason)
        }

        do {
            // 1. Mint a stable, unique zone name. Using a UUID avoids collisions
            //    and gives us a durable `id`.
            let zoneName = "album-\(UUID().uuidString)"
            let zone = try await cloud.createAlbumZone(named: zoneName)

            // 2. Resolve our identity for the createdBy stamp (best-effort).
            let ownerDisplay = await currentUserDisplayName()

            // 3. Build + save the album root record into the new zone.
            var album = SharedAlbum(
                id: zone.zoneID.zoneName,
                name: name,
                ownerName: ownerDisplay,
                isOwnedByMe: true,
                recordName: SharedAlbum.RecordType.albumRootRecordName,
                zoneName: zone.zoneID.zoneName,
                zoneOwnerName: zone.zoneID.ownerName,
                shareRecordName: nil,
                photoCount: 0)
            let record = album.toRecord()
            try await cloud.save([record], to: cloud.privateDB)

            // 4. Create the zone-wide share (invite-only).
            let share = try await cloud.fetchOrCreateShare(for: zone.zoneID, title: name)
            album.shareRecordName = share.recordID.recordName

            // 5. Reflect locally.
            albums.append(album)
            persistCache()
            state = .ready
            return album
        } catch {
            let mapped = cloud.map(error)
            // An availability failure is benign UI state, not an error banner.
            if case .unavailable(let reason) = mapped {
                state = .unavailable(reason: reason)
            } else {
                state = .error(message: mapped.localizedDescription)
            }
            throw mapped
        }
    }

    // MARK: - Load

    /// Fetch zones from both databases and map them to `SharedAlbum`s. Tolerant
    /// of partial failures: a failure in one database still surfaces the other's
    /// albums. On total availability failure, falls back to the local cache and
    /// sets `.unavailable`.
    func loadAlbums() async {
        await cloud.accountStatus()
        guard cloud.isAvailable else {
            // Keep whatever the local cache gave us; just mark unavailable.
            state = .unavailable(reason: "Sign in to iCloud to use Shared Albums")
            return
        }

        state = .loading
        var collected: [SharedAlbum] = []
        var sawAnyError = false

        // Albums we own (private DB).
        do {
            let zones = try await cloud.fetchPrivateAlbumZones()
            for zone in zones {
                if let album = await albumFromZone(zone, in: cloud.privateDB, ownedByMe: true) {
                    collected.append(album)
                }
            }
        } catch {
            sawAnyError = true
        }

        // Albums shared with us (shared DB).
        do {
            let zones = try await cloud.fetchSharedAlbumZones()
            for zone in zones {
                if let album = await albumFromZone(zone, in: cloud.sharedDB, ownedByMe: false) {
                    collected.append(album)
                }
            }
        } catch {
            sawAnyError = true
        }

        // If we got nothing AND every fetch errored, keep the cache and report
        // an error; otherwise adopt the fresh (possibly partial) server view.
        if collected.isEmpty && sawAnyError && !albums.isEmpty {
            state = .error(message: "Couldn't refresh Shared Albums. Showing cached.")
            return
        }

        albums = collected.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        persistCache()
        state = sawAnyError
            ? .error(message: "Some Shared Albums couldn't be loaded.")
            : .ready
    }

    /// Map one zone to a SharedAlbum by reading its root album record. Returns
    /// nil (skipping the album) if the root record is missing/malformed, so a
    /// single bad zone never sinks the whole load.
    private func albumFromZone(_ zone: CKRecordZone,
                               in database: CKDatabase,
                               ownedByMe: Bool) async -> SharedAlbum? {
        let rootID = CKRecord.ID(recordName: SharedAlbum.RecordType.albumRootRecordName,
                                 zoneID: zone.zoneID)
        guard let record = try? await cloud.fetchRecord(rootID, from: database) else {
            return nil
        }
        // Best-effort: fetch the zone-wide share so we can show the owner badge
        // and hand a CKShare to the invite sheet later. Tolerate its absence.
        var share: CKShare?
        let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zone.zoneID)
        if let fetched = try? await cloud.fetchRecord(shareID, from: database) as? CKShare {
            share = fetched
        }
        // Photo count is deferred to the upload phase; report the cached value
        // when we already know this album, else 0.
        let count = albums.first { $0.id == zone.zoneID.zoneName }?.photoCount ?? 0
        return SharedAlbum(record: record, share: share, ownedByMe: ownedByMe, photoCount: count)
    }

    // MARK: - Accept share

    /// Accept an incoming share (driven by the app-delegate hook). After accept,
    /// reload so the newly shared-in album appears. Guards on availability.
    func acceptShare(_ metadata: CKShare.Metadata) async {
        await cloud.accountStatus()
        guard cloud.isAvailable else {
            state = .unavailable(reason: "Sign in to iCloud to use Shared Albums")
            return
        }
        do {
            try await cloud.acceptShare(metadata)
            await loadAlbums()
        } catch {
            state = .error(message: cloud.map(error).localizedDescription)
        }
    }

    // MARK: - Contribute photos (Phase 3)

    /// Upload local library assets (by `localIdentifier`) into a shared album.
    /// For each asset we fetch full-res JPEG bytes + a ~256px thumbnail via
    /// PhotoLibraryModel, write them to temp files, then hand the batch to
    /// CloudKitService.uploadPhotos. Progress is published per-album; partial
    /// failures are tolerated (some photos may upload while others fail). The
    /// album's `photoCount` is bumped optimistically by the number that saved.
    ///
    /// Guards on availability up front, so it is inert on the simulator / in
    /// tests. Always clears `uploadProgress` for the album on exit.
    func addPhotos(localAssetIDs: [String], toAlbum album: SharedAlbum) async {
        _ = try? await addPhotosReportingCount(localAssetIDs: localAssetIDs, toAlbum: album)
    }

    /// Like `addPhotos`, but RETURNS the number of photos that actually saved and
    /// THROWS on a hard upload failure. This is the variant share-back uses so it
    /// can gate the invite + "Shared N photos" message + markFulfilled on a
    /// verified non-zero upload — never reporting success for an empty/failed
    /// album (the original `addPhotos` swallowed all errors, so a friend could be
    /// told "Shared 5 photos" while the requester got an EMPTY album and the
    /// request was gone forever).
    ///
    /// Throws `SharedAlbumError` on unavailability, unreadable inputs, or a CK
    /// upload failure. Returns 0 only when there were no inputs (callers should
    /// treat 0 as "nothing shared"). Still updates published progress/cache state.
    @discardableResult
    func addPhotosReportingCount(localAssetIDs: [String], toAlbum album: SharedAlbum) async throws -> Int {
        guard !localAssetIDs.isEmpty else { return 0 }
        await cloud.accountStatus()
        guard cloud.isAvailable else {
            let reason = "Sign in to iCloud to use Shared Albums"
            state = .unavailable(reason: reason)
            throw SharedAlbumError.unavailable(reason: reason)
        }

        uploadProgress[album.id] = 0
        defer { uploadProgress[album.id] = nil }

        // Resolve which database the album lives in.
        let database = album.isOwnedByMe ? cloud.privateDB : cloud.sharedDB
        let albumRootRef = CKRecord.Reference(recordID: album.recordID, action: .deleteSelf)
        let contributor = await currentUserDisplayName()

        // 1. Materialize bytes → temp files for each asset (skip failures).
        var payloads: [SharedPhotoUploadPayload] = []
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: localAssetIDs, options: nil)
        var phAssets: [PHAsset] = []
        assets.enumerateObjects { asset, _, _ in phAssets.append(asset) }

        for asset in phAssets {
            if let payload = await makePayload(for: asset, contributor: contributor) {
                payloads.append(payload)
            }
        }

        guard !payloads.isEmpty else {
            state = .error(message: "Couldn't read the selected photos.")
            throw SharedAlbumError.cloudKit("Couldn't read the selected photos.")
        }

        // 2. Upload. Progress callback updates the published fraction.
        do {
            let saved = try await cloud.uploadPhotos(
                payloads,
                toZone: album.zoneID,
                database: database,
                albumRootRef: albumRootRef,
                progress: { [weak self] done, total in
                    guard let self, total > 0 else { return }
                    self.uploadProgress[album.id] = Double(done) / Double(total)
                })

            // 3. Optimistic count bump + cache.
            if saved > 0, let idx = albums.firstIndex(where: { $0.id == album.id }) {
                albums[idx].photoCount += saved
                persistCache()
            }
            // Pull the fresh list so the just-uploaded photos appear.
            await loadPhotos(forAlbum: album)
            if saved < payloads.count {
                state = .error(message: "Some photos couldn't be uploaded.")
            }
            return saved
        } catch {
            let mapped = cloud.map(error)
            state = .error(message: mapped.localizedDescription)
            throw mapped
        }
    }

    /// Build an upload payload from a PHAsset: full-res JPEG + ~256px thumbnail
    /// written to unique temp files, plus capture metadata + a content hash.
    /// Returns nil if the bytes can't be read. The temp files are owned by the
    /// uploader, which deletes them after the upload completes.
    private func makePayload(for asset: PHAsset,
                            contributor: String?) async -> SharedPhotoUploadPayload? {
        let library = PhotoLibraryModel.uploadHelper
        guard let fullData = await library.fullImageData(for: asset) else { return nil }
        let thumbData = await library.thumbnailData(for: asset, maxPixel: 256)
            ?? fullData   // fall back to full bytes if a separate thumb fails

        let tmp = FileManager.default.temporaryDirectory
        let stem = UUID().uuidString
        let fullURL = tmp.appendingPathComponent("\(stem)-full.jpg")
        let thumbURL = tmp.appendingPathComponent("\(stem)-thumb.jpg")
        do {
            try fullData.write(to: fullURL, options: .atomic)
            try thumbData.write(to: thumbURL, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: fullURL)
            try? FileManager.default.removeItem(at: thumbURL)
            return nil
        }

        let hash = SHA256.hash(data: fullData).map { String(format: "%02x", $0) }.joined()
        let loc = asset.location
        // Original filename via the public PHAssetResource API (no private KVC).
        let filename = PHAssetResource.assetResources(for: asset).first?.originalFilename
        return SharedPhotoUploadPayload(
            fullImageURL: fullURL,
            thumbnailURL: thumbURL,
            contributorID: contributor,
            captureDate: asset.creationDate,
            latitude: loc?.coordinate.latitude,
            longitude: loc?.coordinate.longitude,
            originalFilename: filename,
            contentHash: hash)
    }

    // MARK: - Load + view photos (Phase 4)

    /// Fetch an album's photos (metadata + thumbnail bytes; NOT the full image)
    /// and publish them for the detail view. Tolerant of availability failure
    /// (keeps whatever is cached). Caches thumbnail bytes in memory.
    func loadPhotos(forAlbum album: SharedAlbum) async {
        await cloud.accountStatus()
        guard cloud.isAvailable else {
            state = .unavailable(reason: "Sign in to iCloud to use Shared Albums")
            return
        }
        loadingPhotos.insert(album.id)
        defer { loadingPhotos.remove(album.id) }

        let database = album.isOwnedByMe ? cloud.privateDB : cloud.sharedDB
        do {
            let loaded = try await cloud.loadPhotos(inZone: album.zoneID, database: database)
            // Accumulate thumbnails into a local dict and merge into the
            // @Published cache ONCE, so a big album triggers a single SwiftUI
            // invalidation instead of one per photo. (Asset bytes were already
            // decoded off the main actor inside CloudKitService.loadPhotos.)
            var photos: [SharedPhoto] = []
            var newThumbs: [String: Data] = [:]
            for (photo, thumb) in loaded {
                photos.append(photo)
                if let thumb { newThumbs[photo.id] = thumb }
            }
            if !newThumbs.isEmpty {
                thumbnailCache.merge(newThumbs) { _, new in new }
            }
            photosByAlbum[album.id] = photos
            // Keep the album card's count honest with what we actually fetched.
            if let idx = albums.firstIndex(where: { $0.id == album.id }),
               albums[idx].photoCount != photos.count {
                albums[idx].photoCount = photos.count
                persistCache()
            }
        } catch {
            state = .error(message: cloud.map(error).localizedDescription)
        }
    }

    /// Lazily fetch the full-resolution image bytes for one photo, on tap.
    /// Returns nil (rather than throwing) so the viewer can show a placeholder
    /// without an alert. Guards on availability.
    func fullImage(for photo: SharedPhoto, in album: SharedAlbum) async -> Data? {
        await cloud.accountStatus()
        guard cloud.isAvailable else { return nil }
        let database = album.isOwnedByMe ? cloud.privateDB : cloud.sharedDB
        return try? await cloud.fullImage(for: photo, database: database)
    }

    /// Thumbnail bytes for a photo, from the in-memory cache (populated by
    /// loadPhotos). Nil until the album's photos have been loaded.
    func cachedThumbnail(for photo: SharedPhoto) -> Data? {
        thumbnailCache[photo.id]
    }

    // MARK: - Sync (Phase 4)

    /// Register silent database subscriptions (shared + private DB) so remote
    /// changes wake the app for a delta sync. Idempotent and gated: skips
    /// entirely in tests, when iCloud is unavailable, or once already done this
    /// launch. Called from SharedAlbumsView's `.task`, never at launch.
    func registerSubscriptionsIfNeeded() async {
        guard !Self.runningTests else { return }
        guard !subscriptionsRegistered else { return }
        await cloud.accountStatus()
        guard cloud.isAvailable else { return }
        // Register for remote notifications so CloudKit's silent pushes are
        // actually delivered (the database subscriptions above only matter if
        // the OS routes the push to us). No device token needs forwarding for
        // CloudKit — registering is enough. Gated identically to the
        // subscriptions (isAvailable AND not running tests, via the guards
        // above), so it never runs at cold launch or in the test host, keeping
        // the feature inert on the simulator. Entitlements already declare
        // aps-environment + the remote-notification background mode.
        UIApplication.shared.registerForRemoteNotifications()

        do {
            try await cloud.ensureDatabaseSubscription(
                id: "shared-db-changes", on: cloud.sharedDB)
            try await cloud.ensureDatabaseSubscription(
                id: "private-db-changes", on: cloud.privateDB)
            subscriptionsRegistered = true
        } catch {
            // Subscriptions are an optimization; a failure just means we rely on
            // pull-to-refresh. Don't surface an error banner.
            #if DEBUG
            print("[SharedAlbums] subscription registration failed: \(error)")
            #endif
        }
    }

    /// Delta-sync both databases since their last server change token. Applies
    /// changed/deleted SharedPhoto records to `photosByAlbum`, drops deleted
    /// albums, and persists the new tokens. Driven by the remote-notification
    /// app-delegate hook (and reusable for manual refresh). Gated in tests and
    /// inert when iCloud is unavailable. Returns true if anything changed (so
    /// the app delegate can report `.newData`).
    @discardableResult
    func syncChanges() async -> Bool {
        guard !Self.runningTests else { return false }
        await cloud.accountStatus()
        guard cloud.isAvailable else { return false }

        loadTokenCacheIfNeeded()
        var changed = false
        changed = await syncDatabase(cloud.sharedDB, scope: .shared) || changed
        changed = await syncDatabase(cloud.privateDB, scope: .private) || changed
        if changed { persistTokenCache() }
        return changed
    }

    /// Delta-sync one database. Returns true if any record/zone changed.
    private func syncDatabase(_ database: CKDatabase,
                             scope: CKDatabase.Scope) async -> Bool {
        let result: DatabaseChangeResult
        do {
            result = try await fetchDatabaseChangesRecoveringExpiry(database, scope: scope)
        } catch {
            #if DEBUG
            print("[SharedAlbums] syncDatabase(\(scope)) failed: \(error)")
            #endif
            return false
        }

        var anyChange = false

        // Deleted zones → drop the album + its photos + tokens.
        for zoneID in result.deletedZoneIDs {
            let albumID = zoneID.zoneName
            if albums.contains(where: { $0.id == albumID }) {
                albums.removeAll { $0.id == albumID }
                photosByAlbum[albumID] = nil
                anyChange = true
            }
            tokenCache.removeZone(zoneID)
        }

        // Per-zone record changes.
        for zc in result.zoneChanges {
            let albumID = zc.zoneID.zoneName
            // Decode CKAsset thumbnail bytes OFF the main actor first (a large
            // delta shouldn't jank the UI), then apply the (already-decoded)
            // changes synchronously on the main actor.
            let thumbs = await Self.decodeThumbnails(for: zc.changedRecords)
            if applyZoneChanges(zc, albumID: albumID, decodedThumbnails: thumbs) {
                anyChange = true
            }
            tokenCache.setZoneToken(zc.newToken, for: zc.zoneID)
        }

        tokenCache.setDatabaseToken(result.newDatabaseToken, scope: scope)
        if anyChange { persistCache() }
        return anyChange
    }

    /// Fetch database changes for a scope, recovering from a database-level
    /// `CKError.changeTokenExpired` by CLEARING the stale token and refetching
    /// from scratch (a stale token can't be advanced — leaving it wedges sync
    /// permanently). Zone-level expiry is recovered inside
    /// `CloudKitService.fetchDatabaseChanges`. Retries the full refetch once.
    private func fetchDatabaseChangesRecoveringExpiry(
        _ database: CKDatabase, scope: CKDatabase.Scope
    ) async throws -> DatabaseChangeResult {
        do {
            return try await cloud.fetchDatabaseChanges(
                in: database,
                since: tokenCache.databaseToken(scope: scope),
                zoneToken: { [weak self] zoneID in self?.tokenCache.zoneToken(zoneID) })
        } catch SharedAlbumError.changeTokenExpired {
            // Clear the wedged token and refetch from scratch (nil token).
            tokenCache.removeDatabaseToken(scope: scope)
            persistTokenCache()
            return try await cloud.fetchDatabaseChanges(
                in: database,
                since: nil,
                zoneToken: { [weak self] zoneID in self?.tokenCache.zoneToken(zoneID) })
        }
    }

    /// Decode the thumbnail CKAsset bytes for a batch of changed records OFF the
    /// main actor, keyed by record name. Reading the on-disk asset bytes via
    /// `Data(contentsOf:)` is blocking I/O; doing it here (in a detached task)
    /// keeps it off the @MainActor so a large delta doesn't jank the UI.
    private static func decodeThumbnails(for records: [CKRecord]) async -> [String: Data] {
        await Task.detached(priority: .userInitiated) {
            var thumbs: [String: Data] = [:]
            for record in records where record.recordType == SharedAlbum.RecordType.photo {
                if let data = (record[SharedAlbum.PhotoField.thumbnail] as? CKAsset)
                    .flatMap(CloudKitService.assetData) {
                    thumbs[record.recordID.recordName] = data
                }
            }
            return thumbs
        }.value
    }

    /// Apply one zone's record-level changes to the in-memory photo list for
    /// that album. Ignores changes to the album-root record (album metadata is
    /// refreshed by loadAlbums). Thumbnail bytes are pre-decoded off the main
    /// actor (see `decodeThumbnails`) and passed in as `decodedThumbnails`, keyed
    /// by record name, so this stays a fast pure-mutation pass and the
    /// @Published thumbnailCache is updated in a single merge (one SwiftUI
    /// invalidation) instead of per-record. Returns true if the album's photos
    /// changed.
    private func applyZoneChanges(_ zc: ZoneChangeResult,
                                  albumID: String,
                                  decodedThumbnails: [String: Data]) -> Bool {
        var photos = photosByAlbum[albumID] ?? []
        var changed = false
        var thumbInserts: [String: Data] = [:]
        var thumbRemovals: [String] = []

        // Upserts.
        for record in zc.changedRecords {
            guard record.recordType == SharedAlbum.RecordType.photo,
                  let photo = SharedPhoto(record: record) else { continue }
            if let thumb = decodedThumbnails[photo.id] {
                thumbInserts[photo.id] = thumb
            }
            if let idx = photos.firstIndex(where: { $0.id == photo.id }) {
                photos[idx] = photo
            } else {
                photos.append(photo)
            }
            changed = true
        }

        // Deletions.
        for id in zc.deletedRecordIDs {
            let name = id.recordName
            if let idx = photos.firstIndex(where: { $0.id == name }) {
                photos.remove(at: idx)
                thumbRemovals.append(name)
                changed = true
            }
        }

        // Apply cache mutations in one batch (single @Published invalidation).
        if !thumbInserts.isEmpty {
            thumbnailCache.merge(thumbInserts) { _, new in new }
        }
        for name in thumbRemovals { thumbnailCache[name] = nil }

        if changed {
            photosByAlbum[albumID] = photos
            // Keep the album card count in step with the live photo list.
            if let idx = albums.firstIndex(where: { $0.id == albumID }) {
                albums[idx].photoCount = photos.count
            }
        }
        return changed
    }

    // MARK: - Change-token cache persistence

    /// Load the persisted token cache once, lazily, only when CloudKit is in
    /// use. Never reached at launch or in tests.
    private func loadTokenCacheIfNeeded() {
        guard tokenCache.isEmpty else { return }
        if let data = try? Data(contentsOf: Self.changeTokensURL),
           let decoded = try? JSONDecoder().decode(ChangeTokenCache.self, from: data) {
            tokenCache = decoded
        }
    }

    private func persistTokenCache() {
        if let data = try? JSONEncoder().encode(tokenCache) {
            try? data.write(to: Self.changeTokensURL, options: .atomic)
        }
    }

    // MARK: - Helpers

    /// Resolve an owner stamp for the current user, falling back to nil.
    /// Best-effort and non-throwing — used only for the `createdBy` field.
    ///
    /// We deliberately do NOT fetch the user's discoverable identity here: it's
    /// an extra round-trip gated behind a permission prompt, and the owner badge
    /// for albums we own just reads "Owned by you" regardless. Instead we stamp
    /// the current user's record name (already cheaply fetched via
    /// `currentUserRecordID()`) so the `createdBy` schema field is actually
    /// populated rather than left permanently empty; a participant fetching the
    /// album who can't resolve the share owner's display name still has this as a
    /// fallback. Returns nil when signed out (so createdBy stays unset).
    private func currentUserDisplayName() async -> String? {
        guard let id = try? await cloud.currentUserRecordID() else { return nil }
        return id.recordName
    }

    /// Look up an album by id (used by the view to fetch the CKShare for invites).
    func album(withID id: String) -> SharedAlbum? {
        albums.first { $0.id == id }
    }

    /// Record that an album was shared with these participant user record names,
    /// for the "same people again" affordance. Exposed for the invite flow.
    func noteShared(with participantIDs: [String]) {
        rememberParticipants(participantIDs)
    }
}

// MARK: - Server-change-token cache

/// Codable cache of CloudKit server change tokens — one per database scope and
/// one per record zone — so delta sync only fetches what changed since last
/// time. `CKServerChangeToken` is not Codable, but it IS `NSSecureCoding`, so
/// we archive each token to `Data` (via `NSKeyedArchiver`) and store the bytes.
/// Unarchiving a corrupt/stale blob fails closed (nil token ⇒ a full re-fetch),
/// never a crash. Keys are stringified scopes / zone identifiers.
struct ChangeTokenCache: Codable {
    /// scope ("private"/"shared") -> archived database token bytes.
    private var databaseTokens: [String: Data] = [:]
    /// "zoneName|ownerName" -> archived zone token bytes.
    private var zoneTokens: [String: Data] = [:]

    var isEmpty: Bool { databaseTokens.isEmpty && zoneTokens.isEmpty }

    private static func key(for scope: CKDatabase.Scope) -> String {
        switch scope {
        case .public:  return "public"
        case .private: return "private"
        case .shared:  return "shared"
        @unknown default: return "unknown"
        }
    }

    private static func key(for zoneID: CKRecordZone.ID) -> String {
        "\(zoneID.zoneName)|\(zoneID.ownerName)"
    }

    func databaseToken(scope: CKDatabase.Scope) -> CKServerChangeToken? {
        databaseTokens[Self.key(for: scope)].flatMap(Self.unarchive)
    }

    mutating func setDatabaseToken(_ token: CKServerChangeToken?, scope: CKDatabase.Scope) {
        let k = Self.key(for: scope)
        if let token, let data = Self.archive(token) {
            databaseTokens[k] = data
        } else if token == nil {
            // Leave an existing token in place if we got nil (no progress);
            // a nil result during a normal fetch just means "no newer token",
            // so keep the last good one. To deliberately reset (e.g. after a
            // `changeTokenExpired` error) use `removeDatabaseToken(scope:)`.
        }
    }

    /// Explicitly clear the database token for a scope so the next sync refetches
    /// from scratch. Needed for `CKError.changeTokenExpired` recovery — a stale
    /// token can't be advanced, only discarded, or sync wedges permanently.
    mutating func removeDatabaseToken(scope: CKDatabase.Scope) {
        databaseTokens[Self.key(for: scope)] = nil
    }

    func zoneToken(_ zoneID: CKRecordZone.ID) -> CKServerChangeToken? {
        zoneTokens[Self.key(for: zoneID)].flatMap(Self.unarchive)
    }

    mutating func setZoneToken(_ token: CKServerChangeToken?, for zoneID: CKRecordZone.ID) {
        guard let token, let data = Self.archive(token) else { return }
        zoneTokens[Self.key(for: zoneID)] = data
    }

    /// Explicitly clear a single zone's token so its next fetch refetches from
    /// scratch (zone-level `changeTokenExpired` recovery).
    mutating func removeZoneToken(_ zoneID: CKRecordZone.ID) {
        zoneTokens[Self.key(for: zoneID)] = nil
    }

    mutating func removeZone(_ zoneID: CKRecordZone.ID) {
        zoneTokens[Self.key(for: zoneID)] = nil
    }

    // MARK: token <-> Data

    private static func archive(_ token: CKServerChangeToken) -> Data? {
        try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
    }

    private static func unarchive(_ data: Data) -> CKServerChangeToken? {
        try? NSKeyedUnarchiver.unarchivedObject(
            ofClass: CKServerChangeToken.self, from: data)
    }
}
