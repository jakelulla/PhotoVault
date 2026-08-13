import CloudKit
import CoreLocation
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

    /// A concrete, user-facing failure for ONE album's most recent contribute
    /// or reload, keyed by album id. The detail view surfaces this as a
    /// persistent alert so a failed "Add Photos" shows the real reason (a mapped
    /// CKError message) instead of silently reverting to an empty grid. Settable
    /// by the view (to dismiss); set by the store on every failure branch and
    /// cleared on a clean contribute.
    struct AlbumAlert: Identifiable {
        let id = UUID()
        var title: String
        var message: String
    }

    @Published private(set) var albums: [SharedAlbum] = []
    @Published private(set) var state: State = .idle

    /// Per-album surfaced error (see `AlbumAlert`). Public-settable so the
    /// detail view's alert binding can clear it on dismiss.
    @Published var albumAlert: [String: AlbumAlert] = [:]

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

    /// Set when a share was just accepted (via link tap or in-app invite) so the
    /// UI can confirm it — carries the album title. The view clears it.
    @Published var acceptedShareToast: String?

    /// Per-album save-to-library progress in [0, 1]; absent when idle.
    @Published private(set) var savingToLibrary: [String: Double] = [:]

    /// Resolved display names for share participants, keyed by userRecordID.
    /// Populated lazily per album (viewer attribution, comments). "You" is
    /// handled by the caller via `myRecordName`.
    @Published private(set) var participantNames: [String: String] = [:]

    /// The current user's CloudKit record name, cached after first resolve —
    /// used to render "you" in attribution and to key reactions.
    @Published private(set) var myRecordName: String?

    /// In-memory album cover thumbnails (JPEG bytes), persisted per album to
    /// disk so the list shows covers across launches without opening albums.
    @Published private(set) var coverCache: [String: Data] = [:]

    /// Reactions/comments on shared photos, keyed by photo record name. Loaded
    /// with the album's photos (same zone) and updated by delta sync.
    @Published private(set) var reactionsByPhoto: [String: [SharedReaction]] = [:]
    @Published private(set) var commentsByPhoto: [String: [SharedComment]] = [:]

    /// True once CKDatabaseSubscriptions have been registered this launch, so we
    /// don't re-register on every view appearance. Reset only on relaunch.
    private var subscriptionsRegistered = false

    /// Share metadata whose accepts failed on a TRANSIENT account status (e.g.
    /// keychain still locked right after cold launch). iOS never redelivers the
    /// metadata, so we queue them (a user can tap several links while iCloud is
    /// waking up) and retry when availability recovers — from BOTH
    /// `refreshAvailability()` (Shared Albums screen) and `onAppActivate()`
    /// (next foregrounding), so the retry doesn't depend on a manual visit.
    private var pendingAcceptMetadatas: [CKShare.Metadata] = []

    /// Album ids whose photos have been FULLY loaded (a whole-zone fetch this
    /// launch). Guards the photo-count bookkeeping: a delta sync into an album
    /// we never fully loaded must not clobber the count with the delta's size.
    private var fullyLoadedAlbums: Set<String> = []

    /// Monotonic generation for loadAlbums. Concurrent loads (accept-triggered,
    /// pull-to-refresh, the delayed post-accept reload) can finish out of order;
    /// only the NEWEST load may overwrite `albums`, or a stale fetch would
    /// visibly erase a just-accepted album. Local mutations (create, delete,
    /// sync-inserted albums) ALSO bump it, so an in-flight load can't publish a
    /// pre-mutation snapshot that resurrects a deleted album or drops a new one.
    private var loadEpoch = 0

    /// Albums with an add-photos call currently in flight. Guards against
    /// concurrent uploads into one album racing the contentHash dedupe.
    private var uploadsInFlight: Set<String> = []

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
    private static var changeTokensURL: URL { storeDir.appendingPathComponent("shared_change_tokens.json") }
    private static var folderLinksURL: URL { storeDir.appendingPathComponent("folder_share_links.json") }

    /// folderID → albumID for folders that were shared as albums. Lets a
    /// re-share (or a retry after a failed upload) REUSE the existing album
    /// instead of minting a duplicate zone every time. Persisted locally;
    /// hydrated lazily (`loadFolderLinksIfNeeded`) so the reuse check works even
    /// when the user goes straight to a folder without visiting Shared Albums.
    private var folderAlbumLinks: [String: String] = [:]
    private var folderLinksLoaded = false

    /// In-memory copy of the persisted server-change-token cache. Loaded lazily
    /// (and only when CloudKit is available), so it never touches disk at launch
    /// or in tests. See `ChangeTokenCache` for the encode/decode contract.
    private var tokenCache = ChangeTokenCache()

    /// Loads only the LOCAL cache — no CloudKit. Safe at any time. Not called
    /// from init by default to honor the "do not auto-run" rule; SharedAlbumsView
    /// loads the cache when it appears so offline users see something instantly.
    private init() {}

    // MARK: - Local cache

    /// Hydrate `albums` + folder links from disk. Pure local I/O; never
    /// touches CloudKit. Tolerant of missing/corrupt files (treats as empty).
    func loadLocalCache() {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: Self.albumsCacheURL),
           let cached = try? dec.decode([SharedAlbum].self, from: data) {
            albums = cached
        }
        if let data = try? Data(contentsOf: Self.folderLinksURL),
           let links = try? JSONDecoder().decode([String: String].self, from: data) {
            folderAlbumLinks = links
        }
        folderLinksLoaded = true
    }

    /// Hydrate just the folder→album links from disk, once. Pure local I/O.
    private func loadFolderLinksIfNeeded() {
        guard !folderLinksLoaded else { return }
        folderLinksLoaded = true
        if let data = try? Data(contentsOf: Self.folderLinksURL),
           let links = try? JSONDecoder().decode([String: String].self, from: data) {
            folderAlbumLinks = links
        }
    }

    private func persistCache() {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try? enc.encode(albums).write(to: Self.albumsCacheURL, options: .atomic)
    }

    private func persistFolderLinks() {
        try? JSONEncoder().encode(folderAlbumLinks).write(to: Self.folderLinksURL, options: .atomic)
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
            // Share accepts that failed on a transient account status are
            // parked (iOS never redelivers the metadata). Availability just
            // recovered — retry them now.
            await retryParkedAccepts()
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

            // 5. Reflect locally. Bump the load epoch so an in-flight
            //    loadAlbums (started before this create) can't publish a
            //    pre-create snapshot that drops the new album.
            loadEpoch += 1
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

    // MARK: - Share an existing folder

    /// Resolve the shared album a folder should upload into: the album this
    /// folder was ALREADY shared as (via the persisted folderID → albumID link),
    /// or a freshly created one. This is the anti-duplication keystone — every
    /// "Share Album" tap, retry, and re-share of the same folder lands on ONE
    /// album instead of minting a new zone each time.
    ///
    /// The caller uploads separately (`addPhotosReportingCount`, which dedupes by
    /// contentHash), so a retried/repeated share adds only NEW photos. Gated
    /// identically to the rest of the stack: fails fast with `.unavailable` on
    /// the simulator / signed out, so it stays inert in the regression gate.
    ///
    /// A stale link (the album was deleted from another device / the Dashboard)
    /// is detected by checking the server's zone list and dropped, falling
    /// through to a fresh create.
    @discardableResult
    func shareFolder(folderID: String?, named rawName: String) async throws -> SharedAlbum {
        await cloud.accountStatus()
        guard cloud.isAvailable else {
            let reason = "Sign in to iCloud to use Shared Albums"
            state = .unavailable(reason: reason)
            throw SharedAlbumError.unavailable(reason: reason)
        }

        // Reuse the album this folder was previously shared as, if it still
        // exists server-side.
        loadFolderLinksIfNeeded()
        if let folderID, let linkedID = folderAlbumLinks[folderID] {
            // PROPAGATE a zone-list fetch failure (flaky network etc.) instead
            // of `try?`-swallowing it: a transient error must surface as a
            // retryable failure, NOT be mistaken for "the album is gone" — that
            // would erase the link and mint a duplicate album on the retry.
            let zones: [CKRecordZone]
            do {
                zones = try await cloud.fetchPrivateAlbumZones()
            } catch {
                throw cloud.map(error)
            }
            if let zone = zones.first(where: { $0.zoneID.zoneName == linkedID }) {
                if let cached = albums.first(where: { $0.id == linkedID && $0.isOwnedByMe }) {
                    return cached
                }
                if let album = await albumFromZone(zone.zoneID, in: cloud.privateDB, ownedByMe: true) {
                    upsertAlbum(album)
                    return album
                }
            }
            // The fetch SUCCEEDED and the linked zone is genuinely absent
            // (deleted from another device / the Dashboard) — drop the stale
            // link and fall through to a fresh create.
            folderAlbumLinks[folderID] = nil
            persistFolderLinks()
        }

        let album = try await createAlbum(named: rawName)
        if let folderID {
            folderAlbumLinks[folderID] = album.id
            persistFolderLinks()
        }
        return album
    }

    /// Insert or replace an album in the published list, keeping the name sort.
    /// Bumps the load epoch: an in-flight loadAlbums started before this upsert
    /// must not publish a snapshot that lacks it.
    private func upsertAlbum(_ album: SharedAlbum) {
        loadEpoch += 1
        if let idx = albums.firstIndex(where: { $0.id == album.id }) {
            albums[idx] = album
        } else {
            albums.append(album)
        }
        albums.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        persistCache()
    }

    /// Filter a list of PHAsset local identifiers down to the ones that still
    /// resolve to a real asset in the photo library, preserving order and dropping
    /// duplicates. Pure Photos lookup (no CloudKit); returns everything unchanged
    /// when nothing resolves is impossible to distinguish from an empty library,
    /// so callers treat an empty result as "nothing to share". `nonisolated static`
    /// so it can run off the main actor and be unit-tested with a trivial input.
    nonisolated static func resolvableAssetIDs(from ids: [String]) -> [String] {
        guard !ids.isEmpty else { return [] }
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var present = Set<String>()
        fetch.enumerateObjects { asset, _, _ in present.insert(asset.localIdentifier) }
        // Preserve the folder's order; keep only resolvable, de-duplicated IDs.
        var seen = Set<String>()
        return ids.filter { present.contains($0) && seen.insert($0).inserted }
    }

    // MARK: - Load

    /// Fetch zones from both databases and map them to `SharedAlbum`s. Tolerant
    /// of partial failures: a failure in one database still surfaces the other's
    /// albums. On total availability failure, falls back to the local cache and
    /// sets `.unavailable`.
    func loadAlbums() async {
        let status = await cloud.accountStatus()
        // .notice so it's visible in Console (not just the Xcode debugger).
        // CKAccountStatus rawValue: 0 couldNotDetermine, 1 available,
        // 2 restricted, 3 noAccount, 4 temporarilyUnavailable.
        SharedAlbumLog.logger.notice(
            "loadAlbums: accountStatus=\(status.rawValue) available=\(self.cloud.isAvailable)")
        guard cloud.isAvailable else {
            // iCloud not usable → we can't load; surface it loudly so this
            // isn't mistaken for "no albums".
            SharedAlbumLog.logger.error(
                "loadAlbums: iCloud UNAVAILABLE (status \(status.rawValue)) — not loading shared albums")
            state = .unavailable(reason: "Sign in to iCloud to use Shared Albums")
            return
        }

        // Re-entrancy guard: several loads can be in flight (accept-triggered,
        // pull-to-refresh, the delayed post-accept reload). Only the NEWEST may
        // publish, or a stale fetch finishing last would erase newer albums.
        loadEpoch += 1
        let myEpoch = loadEpoch

        state = .loading
        var collected: [SharedAlbum] = []
        var sawAnyError = false

        // Albums we own (private DB).
        do {
            let zones = try await cloud.fetchPrivateAlbumZones()
            SharedAlbumLog.logger.notice("loadAlbums: \(zones.count) private zone(s)")
            collected += await albumsFromZones(zones, in: cloud.privateDB, ownedByMe: true)
        } catch {
            sawAnyError = true
            SharedAlbumLog.logger.error("loadAlbums: private-zone fetch FAILED — \(self.cloud.map(error).localizedDescription, privacy: .public)")
        }

        // Albums shared with us (shared DB) — this is the path a just-accepted
        // invite lands on.
        do {
            let zones = try await cloud.fetchSharedAlbumZones()
            SharedAlbumLog.logger.notice("loadAlbums: \(zones.count) shared zone(s)")
            collected += await albumsFromZones(zones, in: cloud.sharedDB, ownedByMe: false)
        } catch {
            sawAnyError = true
            SharedAlbumLog.logger.error("loadAlbums: shared-zone fetch FAILED — \(self.cloud.map(error).localizedDescription, privacy: .public)")
        }
        SharedAlbumLog.logger.notice("loadAlbums: \(collected.count) album(s) total")

        // A newer load started while we were fetching — discard this result.
        guard myEpoch == loadEpoch else { return }

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
        // Keep the widget / share extension's snapshot fresh.
        AppGroupSummaryWriter.refresh()
    }

    /// Map a batch of zones to albums CONCURRENTLY (each album costs up to two
    /// record fetches — share + root — and doing 2N round-trips serially made
    /// every refresh feel slow). Order is restored to the input zone order;
    /// callers re-sort by name anyway.
    private func albumsFromZones(_ zones: [CKRecordZone],
                                 in database: CKDatabase,
                                 ownedByMe: Bool) async -> [SharedAlbum] {
        await withTaskGroup(of: (Int, SharedAlbum?).self) { group in
            for (idx, zone) in zones.enumerated() {
                group.addTask { @MainActor [weak self] in
                    (idx, await self?.albumFromZone(zone.zoneID, in: database, ownedByMe: ownedByMe))
                }
            }
            var indexed: [(Int, SharedAlbum)] = []
            for await (idx, album) in group {
                if let album { indexed.append((idx, album)) }
            }
            return indexed.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    /// Map one zone to a SharedAlbum by reading its root album record. Returns
    /// nil (skipping the album) if the root record is missing/malformed, so a
    /// single bad zone never sinks the whole load.
    private func albumFromZone(_ zoneID: CKRecordZone.ID,
                               in database: CKDatabase,
                               ownedByMe: Bool) async -> SharedAlbum? {
        let rootID = CKRecord.ID(recordName: SharedAlbum.RecordType.albumRootRecordName,
                                 zoneID: zoneID)
        // Best-effort: the zone-wide share carries the album title + owner and is
        // needed for the invite sheet later. Tolerate its absence.
        var share: CKShare?
        let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
        if let fetched = try? await cloud.fetchRecord(shareID, from: database) as? CKShare {
            share = fetched
        }
        let cached = albums.first { $0.id == zoneID.zoneName }
        let count = cached?.photoCount ?? 0

        // Preferred: full metadata from the album-root record.
        if let record = try? await cloud.fetchRecord(rootID, from: database),
           let album = SharedAlbum(record: record, share: share, ownedByMe: ownedByMe, photoCount: count) {
            return album
        }

        // Fallback: the album-root record couldn't be fetched/mapped — common for
        // a JUST-ACCEPTED participant before the shared zone's records propagate,
        // or a transient read failure. The zone genuinely EXISTS in this DB, so
        // do NOT drop the album (the old bug: an accepted share silently never
        // appeared). Synthesize it from the zone + the share's title; it fills in
        // with the real record on the next refresh once the root is reachable.
        SharedAlbumLog.logger.info(
            "loadAlbums: album-root not fetchable for zone \(zoneID.zoneName, privacy: .public) db=\(ownedByMe ? "private" : "shared", privacy: .public) — showing fallback")
        let title = share?[CKShare.SystemFieldKey.title] as? String
        let ownerName = share?.owner.userIdentity.nameComponents
            .map { PersonNameComponentsFormatter().string(from: $0) }
        return SharedAlbum(
            id: zoneID.zoneName,
            name: cached?.name ?? (title?.isEmpty == false ? title! : "Shared Album"),
            ownerName: ownedByMe ? nil : (cached?.ownerName ?? ownerName),
            isOwnedByMe: ownedByMe,
            recordName: SharedAlbum.RecordType.albumRootRecordName,
            zoneName: zoneID.zoneName,
            zoneOwnerName: zoneID.ownerName,
            shareRecordName: share?.recordID.recordName,
            photoCount: count)
    }

    // MARK: - Accept share

    /// Accept an incoming share (driven by the scene-delegate hook or the in-app
    /// invitation inbox). After accept, reload so the newly shared-in album
    /// appears, register the sync subscriptions (the user may never visit the
    /// Shared Albums screen this launch), and set a confirmation toast.
    ///
    /// Cold-launch resilience: right after launch the account status often reads
    /// `.couldNotDetermine`/`.temporarilyUnavailable` for a moment even though
    /// the user IS signed in — and iOS never redelivers share metadata. So we
    /// retry the availability check briefly, and if it still fails we PARK the
    /// metadata; `refreshAvailability()` retries it the moment iCloud recovers.
    func acceptShare(_ metadata: CKShare.Metadata) async {
        var status = await cloud.accountStatus()
        var attempt = 0
        while !cloud.isAvailable, status != .noAccount, status != .restricted, attempt < 4 {
            attempt += 1
            try? await Task.sleep(nanoseconds: UInt64(attempt) * 500_000_000)
            status = await cloud.accountStatus()
        }
        guard cloud.isAvailable else {
            pendingAcceptMetadatas.append(metadata)
            state = .unavailable(reason: "Sign in to iCloud to use Shared Albums")
            SharedAlbumLog.logger.error(
                "acceptShare: iCloud unavailable (status \(status.rawValue)) — parked metadata for retry (\(self.pendingAcceptMetadatas.count) pending)")
            return
        }
        do {
            try await cloud.acceptShare(metadata)
        } catch {
            // Tolerate an ALREADY-ACCEPTED share (the user re-tapped an old
            // link): if the share's zone is reachable in our shared DB, the
            // acceptance is a fact — treat it as success instead of erroring.
            let target = metadata.share.recordID.zoneID
            let zones = (try? await cloud.fetchAllSharedZones()) ?? []
            let alreadyJoined = zones.contains {
                $0.zoneID.zoneName == target.zoneName && $0.zoneID.ownerName == target.ownerName
            }
            guard alreadyJoined else {
                let msg = cloud.map(error).localizedDescription
                SharedAlbumLog.logger.error("acceptShare: FAILED — \(msg, privacy: .public)")
                state = .error(message: msg)
                return
            }
        }
        SharedAlbumLog.logger.notice("acceptShare: accepted, reloading albums")
        acceptedShareToast = (metadata.share[CKShare.SystemFieldKey.title] as? String)
            .flatMap { $0.isEmpty ? nil : $0 } ?? "Shared album"
        await reloadAfterAccept()
        // Make sure sync pushes flow even if the user never opens the
        // Shared Albums screen this launch. Idempotent + internally gated.
        await registerSubscriptionsIfNeeded()
    }

    /// Reload albums, then reload once more after a short delay: a just-accepted
    /// zone can lag before it surfaces in the shared DB's zone list, and this
    /// spares the user a manual pull-to-refresh. Used by BOTH accept paths (link
    /// tap and in-app invitation). The delayed pass runs in an unstructured task
    /// so the caller's UI (e.g. the Accept button spinner) isn't held hostage
    /// for 3 extra seconds; the loadAlbums epoch guard makes it race-safe.
    func reloadAfterAccept() async {
        await loadAlbums()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await loadAlbums()
        }
    }

    // MARK: - Delete / leave

    /// Delete an album we OWN (removes it for everyone — the zone, its photos,
    /// and the share), or LEAVE an album shared with us (deletes the zone from
    /// OUR shared database, which removes only our participation; the owner's
    /// copy is untouched). Cleans every local trace either way. Throws a
    /// `SharedAlbumError` the view surfaces.
    func deleteAlbum(_ album: SharedAlbum) async throws {
        await cloud.accountStatus()
        guard cloud.isAvailable else {
            let reason = "Sign in to iCloud to use Shared Albums"
            state = .unavailable(reason: reason)
            throw SharedAlbumError.unavailable(reason: reason)
        }
        let database = album.isOwnedByMe ? cloud.privateDB : cloud.sharedDB
        do {
            try await cloud.deleteZone(album.zoneID, in: database)
        } catch SharedAlbumError.zoneNotFound {
            // Already gone server-side — proceed to clean up locally.
        }
        // Bump the load epoch so an in-flight loadAlbums (started before the
        // delete) can't publish a stale snapshot that resurrects this album.
        loadEpoch += 1
        albums.removeAll { $0.id == album.id }
        photosByAlbum[album.id] = nil
        fullyLoadedAlbums.remove(album.id)
        tokenCache.removeZone(album.zoneID)
        persistTokenCache()
        let linkedFolders = folderAlbumLinks.filter { $0.value == album.id }.map(\.key)
        if !linkedFolders.isEmpty {
            for key in linkedFolders { folderAlbumLinks[key] = nil }
            persistFolderLinks()
        }
        persistCache()
    }

    // MARK: - Participants (People sheet + sender's acceptance feedback)

    /// The people on an album's share, as displayable value types. Fetches the
    /// LIVE zone-wide CKShare from the album's home database, so the sender can
    /// see who has actually JOINED (CloudKit's acceptance status) — the in-app
    /// invite path's only feedback loop. Returns nil when the share isn't
    /// fetchable (unavailable, or the album was never shared).
    func participants(for album: SharedAlbum) async -> [AlbumParticipant]? {
        await cloud.accountStatus()
        guard cloud.isAvailable else { return nil }
        let database = album.isOwnedByMe ? cloud.privateDB : cloud.sharedDB
        let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: album.zoneID)
        guard let share = try? await cloud.fetchRecord(shareID, from: database) as? CKShare else {
            return nil
        }
        let me = share.currentUserParticipant
        return share.participants.map { p in
            let recordName = p.userIdentity.userRecordID?.recordName
            var name: String
            if let components = p.userIdentity.nameComponents {
                name = PersonNameComponentsFormatter().string(from: components)
            } else {
                name = ""
            }
            if name.isEmpty {
                name = p.userIdentity.lookupInfo?.emailAddress
                    ?? p.userIdentity.lookupInfo?.phoneNumber
                    ?? "Member"
            }
            let status: String
            switch p.acceptanceStatus {
            case .accepted: status = "Joined"
            case .pending:  status = "Invited"
            case .removed:  status = "Removed"
            default:        status = ""
            }
            return AlbumParticipant(
                id: recordName ?? UUID().uuidString,
                displayName: name,
                userRecordID: recordName,
                isOwner: p.role == .owner,
                isMe: p == me,
                status: status,
                canWrite: p.permission == .readWrite)
        }
    }

    // MARK: - App-activation refresh

    /// Called when the app becomes active. If the user actually USES shared
    /// albums (there is local evidence: cached albums or folder links), register
    /// the push subscriptions and run a delta sync — so invitations and new
    /// photos arrive even when the user hasn't visited the Shared Albums screen
    /// this launch. Internally gated (tests, availability), so it stays inert in
    /// the regression gate and on the simulator.
    func onAppActivate() async {
        guard !Self.runningTests else { return }
        // Hydrate from disk only when nothing is loaded yet — never clobber a
        // fresher in-memory server view with the stale cache.
        if albums.isEmpty && folderAlbumLinks.isEmpty { loadLocalCache() }
        // Parked share accepts retry as soon as iCloud recovers — even for a
        // user with no albums yet (a first-ever incoming share lands here).
        if !pendingAcceptMetadatas.isEmpty {
            await cloud.accountStatus()
            if cloud.isAvailable { await retryParkedAccepts() }
        }
        guard !albums.isEmpty || !folderAlbumLinks.isEmpty else { return }
        await cloud.accountStatus()
        guard cloud.isAvailable else { return }
        await registerSubscriptionsIfNeeded()
        await syncChanges()
        // Pick up any upload the last session didn't finish (dedupe-safe),
        // then recompute the local auto-share suggestions.
        await resumePendingUploads()
        refreshSuggestions()
    }

    /// Drain the parked share-accept queue (metadata iOS delivered while
    /// iCloud was transiently unavailable — it is never redelivered).
    private func retryParkedAccepts() async {
        guard !pendingAcceptMetadatas.isEmpty else { return }
        let parked = pendingAcceptMetadatas
        pendingAcceptMetadatas = []
        for metadata in parked {
            await acceptShare(metadata)
        }
    }

    // MARK: - Contribute photos (Phase 3)

    /// What actually happened to one "add photos" request: how many photos newly
    /// saved, how many were skipped because their bytes are ALREADY in the album
    /// (contentHash dedupe — retries and re-shares never duplicate), and how many
    /// couldn't be read off the library (iCloud-optimized originals that failed
    /// to materialize). `saved == 0` with `duplicates > 0` means "everything was
    /// already there" — success, nothing new.
    struct AddPhotosOutcome: Equatable {
        var saved: Int = 0
        var duplicates: Int = 0
        var unreadable: Int = 0
    }

    /// Upload local library assets (by `localIdentifier`) into a shared album.
    /// For each asset we fetch full-res JPEG bytes + a ~256px thumbnail via
    /// PhotoLibraryModel, write them to temp files, then hand the batch to
    /// CloudKitService.uploadPhotos. Progress is published per-album; partial
    /// failures are tolerated (some photos may upload while others fail).
    ///
    /// RETURNS the outcome (saved / duplicate / unreadable
    /// counts) and THROWS on a hard upload failure. This is the variant share-back
    /// uses so it can gate the invite + "Shared N photos" message + markFulfilled
    /// on a verified non-zero upload — never reporting success for an empty/failed
    /// album (the original `addPhotos` swallowed all errors, so a friend could be
    /// told "Shared 5 photos" while the requester got an EMPTY album and the
    /// request was gone forever).
    ///
    /// Dedupe: before uploading we fetch the album's existing contentHashes (a
    /// cheap, asset-free zone enumeration) and skip photos whose bytes are
    /// already there — so a retried upload, a re-shared folder, or the same photo
    /// picked twice never produces duplicates.
    ///
    /// Throws `SharedAlbumError` on unavailability, unreadable inputs, or a CK
    /// upload failure. Still updates published progress/cache state.
    @discardableResult
    func addPhotosReportingCount(localAssetIDs: [String], toAlbum album: SharedAlbum) async throws -> AddPhotosOutcome {
        guard !localAssetIDs.isEmpty else { return AddPhotosOutcome() }
        // Per-album in-flight guard: two concurrent adds into the same album
        // would race the contentHash dedupe (both read the hash set before
        // either finishes writing → duplicates) and fight over one progress
        // slot. Reachable by re-opening ShareFolderView mid-upload or adding
        // from the detail view while a folder share is still uploading.
        guard !uploadsInFlight.contains(album.id) else {
            throw SharedAlbumError.uploadAlreadyInProgress
        }
        uploadsInFlight.insert(album.id)
        defer { uploadsInFlight.remove(album.id) }

        // Background resilience (#7): ask iOS for extra time so leaving the app
        // mid-upload finishes the current work instead of freezing it, and
        // persist the intent so an interrupted upload RESUMES on next activate
        // (contentHash dedupe makes the resume re-add only what's missing).
        let bgTask = UIApplication.shared.beginBackgroundTask(withName: "shared-album-upload")
        defer {
            if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask) }
        }
        notePendingUpload(albumID: album.id, assetIDs: localAssetIDs)
        var uploadCompleted = false
        defer { if uploadCompleted { clearPendingUpload(albumID: album.id) } }
        await cloud.accountStatus()
        guard cloud.isAvailable else {
            let reason = "Sign in to iCloud to use Shared Albums"
            state = .unavailable(reason: reason)
            setAlbumAlert(album.id, title: "Couldn't Add Photos", message: reason)
            throw SharedAlbumError.unavailable(reason: reason)
        }

        let scope = album.isOwnedByMe ? "private" : "shared"
        SharedAlbumLog.logger.info(
            "addPhotos: album=\(album.id, privacy: .public) requested=\(localAssetIDs.count) ownedByMe=\(album.isOwnedByMe) db=\(scope, privacy: .public)")

        uploadProgress[album.id] = 0
        defer { uploadProgress[album.id] = nil }

        // Resolve which database the album lives in.
        let database = album.isOwnedByMe ? cloud.privateDB : cloud.sharedDB
        let contributor = await currentUserDisplayName()

        // 1. Materialize bytes → temp files for each asset (skip failures).
        var payloads: [SharedPhotoUploadPayload] = []
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: localAssetIDs, options: nil)
        var phAssets: [PHAsset] = []
        assets.enumerateObjects { asset, _, _ in phAssets.append(asset) }
        SharedAlbumLog.logger.info(
            "addPhotos: resolved \(phAssets.count)/\(localAssetIDs.count) PHAsset(s)")

        for asset in phAssets {
            if let payload = await makePayload(for: asset, contributor: contributor) {
                payloads.append(payload)
            }
        }
        let unreadable = phAssets.count - payloads.count
        SharedAlbumLog.logger.info(
            "addPhotos: built \(payloads.count)/\(phAssets.count) payload(s)")

        guard !payloads.isEmpty else {
            // Distinguish "assets vanished" from "bytes couldn't be read"
            // (typically iCloud-optimized originals still downloading).
            let msg = phAssets.isEmpty
                ? "The selected photos couldn't be found in your library."
                : "Couldn't read the selected photos. If they're stored in iCloud they may still be downloading — try again in a moment."
            state = .error(message: msg)
            setAlbumAlert(album.id, title: "Couldn't Add Photos", message: msg)
            SharedAlbumLog.logger.error("addPhotos: no payloads (phAssets=\(phAssets.count))")
            // Terminal for auto-resume: the inputs themselves are unreadable —
            // retrying on every activation wouldn't change that.
            uploadCompleted = true
            throw SharedAlbumError.cloudKit(msg)
        }

        // 1a. Dedupe against what's ALREADY in the album (by contentHash), so a
        //     retry / re-share / double-pick never duplicates a photo. Best
        //     effort: if the hash fetch fails we upload everything (the old
        //     behavior) rather than failing the add.
        var duplicates = 0
        let existingHashes = (try? await cloud.existingContentHashes(
            inZone: album.zoneID, database: database)) ?? []
        if !existingHashes.isEmpty {
            var kept: [SharedPhotoUploadPayload] = []
            for payload in payloads {
                if let hash = payload.contentHash, existingHashes.contains(hash) {
                    duplicates += 1
                    // The uploader never sees these payloads, so their temp
                    // files are ours to clean up.
                    try? FileManager.default.removeItem(at: payload.fullImageURL)
                    try? FileManager.default.removeItem(at: payload.thumbnailURL)
                } else {
                    kept.append(payload)
                }
            }
            payloads = kept
            if duplicates > 0 {
                SharedAlbumLog.logger.info("addPhotos: skipped \(duplicates) duplicate(s) by contentHash")
            }
        }

        // Everything requested is already in the album — success, nothing to do.
        guard !payloads.isEmpty else {
            albumAlert[album.id] = nil
            uploadCompleted = true
            return AddPhotosOutcome(saved: 0, duplicates: duplicates, unreadable: unreadable)
        }

        // 2. Verify the album-root parent target exists in the TARGET database
        //    before we reference it (a missing root would make every photo's
        //    parent/album reference a referenceViolation). Repair it for albums
        //    we own by re-saving the root; for a participant we can't write the
        //    root, so we omit the parent reference (makeRecord tolerates nil).
        let rootID = CKRecord.ID(recordName: SharedAlbum.RecordType.albumRootRecordName,
                                 zoneID: album.zoneID)
        var rootExists = await cloud.recordExists(rootID, in: database)
        if !rootExists && album.isOwnedByMe {
            if (try? await cloud.save([album.toRecord()], to: database)) != nil {
                rootExists = true
                SharedAlbumLog.logger.info("addPhotos: repaired missing album-root record")
            }
        }
        SharedAlbumLog.logger.info("addPhotos: albumRoot exists=\(rootExists) db=\(scope, privacy: .public)")
        let albumRootRef: CKRecord.Reference? =
            rootExists ? CKRecord.Reference(recordID: rootID, action: .none) : nil

        // 3. Upload. Progress callback updates the published fraction.
        do {
            let result = try await cloud.uploadPhotos(
                payloads,
                toZone: album.zoneID,
                database: database,
                albumRootRef: albumRootRef,
                progress: { [weak self] done, total in
                    guard let self, total > 0 else { return }
                    self.uploadProgress[album.id] = Double(done) / Double(total)
                })
            SharedAlbumLog.logger.info("addPhotos: saved \(result.savedCount)/\(payloads.count)")

            // 3a. Nothing saved despite readable payloads → surface the concrete
            //     cause (a non-partial op throws above; this is the defensive
            //     backstop for a 0-success op that reported .success).
            guard result.savedCount > 0 else {
                let msg = result.firstError.map { cloud.map($0).localizedDescription }
                    ?? "The photos couldn't be added to iCloud. Please try again."
                state = .error(message: msg)
                setAlbumAlert(album.id, title: "Couldn't Add Photos", message: msg)
                SharedAlbumLog.logger.error("addPhotos: zero saved. cause=\(msg, privacy: .public)")
                throw SharedAlbumError.cloudKit(msg)
            }

            // 3b. Optimistically insert the just-saved photos + cache their
            //     thumbnails so they appear IMMEDIATELY, independent of the
            //     re-fetch (which can lag on a custom zone or fail transiently).
            applyOptimisticSaved(result.savedPhotos,
                                 thumbnails: result.savedThumbnails,
                                 toAlbum: album)

            // 3c. Reconcile with a FULL server fetch, preserving the just-saved
            //     photos if the server hasn't surfaced them yet.
            await loadPhotos(forAlbum: album,
                             preservingRecentlySaved: result.savedPhotos,
                             recentThumbnails: result.savedThumbnails)

            // 3d. Report a partial failure (some saved, some rejected) with the
            //     concrete reason; otherwise clear any stale alert. An unreadable
            //     shortfall (assets whose bytes never materialized) is reported
            //     too — silently missing photos looked like success to BOTH users.
            if result.savedCount < payloads.count {
                let detail = result.firstError.map { cloud.map($0).localizedDescription }
                let msg = detail.map { "Some photos couldn't be added: \($0)" }
                    ?? "Some photos couldn't be added."
                state = .error(message: msg)
                setAlbumAlert(album.id, title: "Some Photos Not Added", message: msg)
            } else if unreadable > 0 {
                let msg = "\(unreadable) photo\(unreadable == 1 ? "" : "s") couldn't be read from your library (possibly still downloading from iCloud) and \(unreadable == 1 ? "wasn't" : "weren't") added. Try adding \(unreadable == 1 ? "it" : "them") again in a moment."
                setAlbumAlert(album.id, title: "Some Photos Skipped", message: msg)
            } else {
                albumAlert[album.id] = nil
            }
            uploadCompleted = true
            return AddPhotosOutcome(saved: result.savedCount,
                                    duplicates: duplicates,
                                    unreadable: unreadable)
        } catch {
            let mapped = cloud.map(error)
            state = .error(message: mapped.localizedDescription)
            setAlbumAlert(album.id, title: "Couldn't Add Photos", message: mapped.localizedDescription)
            SharedAlbumLog.logger.error("addPhotos: upload failed — \(mapped.localizedDescription, privacy: .public)")
            throw mapped
        }
    }

    /// Insert just-saved photos into `photosByAlbum` (deduped by id, newest
    /// first) and cache their thumbnail bytes, so a successful contribute renders
    /// immediately without depending on the re-fetch. Also bumps the album card
    /// count to match. Idempotent: re-inserting an existing id is a no-op.
    private func applyOptimisticSaved(_ saved: [SharedPhoto],
                                      thumbnails: [String: Data],
                                      toAlbum album: SharedAlbum) {
        guard !saved.isEmpty else { return }
        if !thumbnails.isEmpty {
            thumbnailCache.merge(thumbnails) { _, new in new }
        }
        var current = photosByAlbum[album.id] ?? []
        let existing = Set(current.map(\.id))
        for photo in saved where !existing.contains(photo.id) {
            current.append(photo)
        }
        current.sort(by: Self.newestFirst)
        let insertedCount = current.count - (photosByAlbum[album.id]?.count ?? 0)
        photosByAlbum[album.id] = current
        updateCover(albumID: album.id, photos: current)
        if let idx = albums.firstIndex(where: { $0.id == album.id }) {
            // Same rule as the delta-sync path: only trust `current.count` when
            // we hold a FULL view of the album. When we don't (e.g. uploading
            // into a reused folder album that was never opened this launch),
            // BUMP the cached count instead of clobbering it with the partial
            // local view ("52 photos" must not become "3 photos").
            if fullyLoadedAlbums.contains(album.id) {
                albums[idx].photoCount = current.count
            } else {
                albums[idx].photoCount += max(0, insertedCount)
            }
            persistCache()
        }
    }

    /// Newest-first ordering matching CloudKitService.loadPhotos (records with
    /// no captureDate sort last).
    private static func newestFirst(_ a: SharedPhoto, _ b: SharedPhoto) -> Bool {
        switch (a.captureDate, b.captureDate) {
        case let (l?, r?): return l > r
        case (nil, _?):    return false
        case (_?, nil):    return true
        case (nil, nil):   return false
        }
    }

    /// Set the per-album user-facing alert. Centralized so every failure branch
    /// records a concrete, persistent reason for the detail view.
    private func setAlbumAlert(_ albumID: String, title: String, message: String) {
        albumAlert[albumID] = AlbumAlert(title: title, message: message)
    }

    /// Map any thrown error to the user-facing string the view shows. Exposed so
    /// the picker callback can present a thrown error directly.
    func errorText(for error: Error) -> String {
        cloud.map(error).localizedDescription
    }

    /// Build an upload payload from a PHAsset: full-res JPEG + ~256px thumbnail
    /// written to unique temp files, plus capture metadata + a content hash.
    /// Returns nil if the bytes can't be read. The temp files are owned by the
    /// uploader, which deletes them after the upload completes.
    private func makePayload(for asset: PHAsset,
                            contributor: String?) async -> SharedPhotoUploadPayload? {
        // Videos take the file-based path: original movie via PHAssetResource
        // (never loaded whole into memory), streamed hash, poster-frame thumb.
        if asset.mediaType == .video {
            return await makeVideoPayload(for: asset, contributor: contributor)
        }
        let library = PhotoLibraryModel.uploadHelper
        guard let fullData = await library.fullImageData(for: asset) else {
            // Most likely an iCloud-optimized original that couldn't be
            // materialized (or the download stalled and the timeout fired).
            SharedAlbumLog.logger.error(
                "makePayload: no full-image bytes for asset \(asset.localIdentifier, privacy: .public) (iCloud download failed or timed out)")
            return nil
        }
        let thumbData = await library.thumbnailData(for: asset, maxPixel: 256)
            ?? fullData   // fall back to full bytes if a separate thumb fails

        // Gather metadata on the main actor (cheap), then do the heavy work —
        // temp-file writes + SHA-256 over multi-MB bytes — OFF the main actor so
        // a large batch doesn't freeze the UI mid-upload.
        let assetID = asset.localIdentifier
        let captureDate = asset.creationDate
        let latitude = asset.location?.coordinate.latitude
        let longitude = asset.location?.coordinate.longitude
        // Original filename via the public PHAssetResource API (no private KVC).
        let filename = PHAssetResource.assetResources(for: asset).first?.originalFilename

        return await Task.detached(priority: .userInitiated) {
            let tmp = FileManager.default.temporaryDirectory
            let stem = UUID().uuidString
            let fullURL = tmp.appendingPathComponent("\(stem)-full.jpg")
            let thumbURL = tmp.appendingPathComponent("\(stem)-thumb.jpg")
            do {
                try fullData.write(to: fullURL, options: .atomic)
                try thumbData.write(to: thumbURL, options: .atomic)
            } catch {
                SharedAlbumLog.logger.error(
                    "makePayload: temp-file write failed for asset \(assetID, privacy: .public): \(error.localizedDescription, privacy: .public)")
                try? FileManager.default.removeItem(at: fullURL)
                try? FileManager.default.removeItem(at: thumbURL)
                return nil
            }

            let hash = SHA256.hash(data: fullData).map { String(format: "%02x", $0) }.joined()
            return SharedPhotoUploadPayload(
                fullImageURL: fullURL,
                thumbnailURL: thumbURL,
                contributorID: contributor,
                captureDate: captureDate,
                latitude: latitude,
                longitude: longitude,
                originalFilename: filename,
                contentHash: hash)
        }.value
    }

    /// Build an upload payload for a VIDEO asset: the ORIGINAL movie file is
    /// written straight to a temp file via PHAssetResourceManager (no whole-file
    /// memory load), hashed by streaming, with a poster-frame JPEG thumbnail.
    private func makeVideoPayload(for asset: PHAsset,
                                  contributor: String?) async -> SharedPhotoUploadPayload? {
        // Resolve the original video resource (fall back to any video-ish one).
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first(where: { $0.type == .video })
            ?? resources.first(where: { $0.type == .fullSizeVideo }) else {
            SharedAlbumLog.logger.error(
                "makeVideoPayload: no video resource for \(asset.localIdentifier, privacy: .public)")
            return nil
        }

        let tmp = FileManager.default.temporaryDirectory
        let stem = UUID().uuidString
        let ext = (resource.originalFilename as NSString).pathExtension.lowercased()
        let videoURL = tmp.appendingPathComponent("\(stem)-full.\(ext.isEmpty ? "mov" : ext)")
        let thumbURL = tmp.appendingPathComponent("\(stem)-thumb.jpg")

        // 1. Write the original movie to disk (network allowed for iCloud
        //    originals). Completion-handler API bridged to async.
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        let wrote: Bool = await withCheckedContinuation { cont in
            PHAssetResourceManager.default().writeData(
                for: resource, toFile: videoURL, options: options
            ) { error in
                cont.resume(returning: error == nil)
            }
        }
        guard wrote else {
            SharedAlbumLog.logger.error(
                "makeVideoPayload: resource write failed for \(asset.localIdentifier, privacy: .public)")
            try? FileManager.default.removeItem(at: videoURL)
            return nil
        }

        // 2. Poster-frame thumbnail (requestImage works for videos).
        guard let thumbData = await PhotoLibraryModel.uploadHelper
            .thumbnailData(for: asset, maxPixel: 256) else {
            try? FileManager.default.removeItem(at: videoURL)
            return nil
        }

        let contributorID = contributor
        let captureDate = asset.creationDate
        let latitude = asset.location?.coordinate.latitude
        let longitude = asset.location?.coordinate.longitude
        let filename = resource.originalFilename
        let duration = asset.duration

        // 3. Streamed SHA-256 (videos can be huge — never load them whole) +
        //    thumbnail write, off the main actor.
        return await Task.detached(priority: .userInitiated) {
            do {
                try thumbData.write(to: thumbURL, options: .atomic)
            } catch {
                try? FileManager.default.removeItem(at: videoURL)
                return nil
            }
            guard let hash = Self.streamedSHA256(of: videoURL) else {
                try? FileManager.default.removeItem(at: videoURL)
                try? FileManager.default.removeItem(at: thumbURL)
                return nil
            }
            return SharedPhotoUploadPayload(
                fullImageURL: videoURL,
                thumbnailURL: thumbURL,
                contributorID: contributorID,
                captureDate: captureDate,
                latitude: latitude,
                longitude: longitude,
                originalFilename: filename,
                contentHash: hash,
                isVideo: true,
                duration: duration)
        }.value
    }

    /// SHA-256 of a file computed in 1 MB chunks — constant memory regardless
    /// of file size. Returns nil on read failure.
    private nonisolated static func streamedSHA256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk: Data?
            do { chunk = try handle.read(upToCount: 1_048_576) } catch { return nil }
            guard let chunk, !chunk.isEmpty else { break }   // nil/empty = EOF
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Load + view photos (Phase 4)

    /// Fetch an album's photos (metadata + thumbnail bytes; NOT the full image)
    /// and publish them for the detail view. Tolerant of availability failure
    /// (keeps whatever is cached). Caches thumbnail bytes in memory.
    ///
    /// This is always a FULL zone fetch (nil change token) — the incremental
    /// tokens are reserved for the push/`syncChanges` path — so an owner's
    /// just-written record is guaranteed to return.
    ///
    /// `preservingRecentlySaved` guards against custom-zone read-after-write
    /// lag: any just-uploaded photo the server hasn't surfaced yet is re-added
    /// from this list so a successful contribute never renders as an empty grid.
    /// On a fetch error we KEEP whatever is already published (e.g. the
    /// optimistic entries) and surface the error instead of clearing the grid.
    func loadPhotos(forAlbum album: SharedAlbum,
                    preservingRecentlySaved recent: [SharedPhoto] = [],
                    recentThumbnails: [String: Data] = [:]) async {
        await cloud.accountStatus()
        guard cloud.isAvailable else {
            state = .unavailable(reason: "Sign in to iCloud to use Shared Albums")
            return
        }
        loadingPhotos.insert(album.id)
        defer { loadingPhotos.remove(album.id) }

        let scope = album.isOwnedByMe ? "private" : "shared"
        let database = album.isOwnedByMe ? cloud.privateDB : cloud.sharedDB
        do {
            let load = try await cloud.loadPhotos(inZone: album.zoneID, database: database)
            let loaded = load.photos
            SharedAlbumLog.logger.info(
                "loadPhotos: fetched \(loaded.count) photo(s) album=\(album.id, privacy: .public) db=\(scope, privacy: .public) token=full recentToPreserve=\(recent.count)")
            // Accumulate thumbnails into a local dict and merge into the
            // @Published cache ONCE, so a big album triggers a single SwiftUI
            // invalidation instead of one per photo. (Asset bytes were already
            // decoded off the main actor inside CloudKitService.loadPhotos.)
            var photos: [SharedPhoto] = []
            var newThumbs: [String: Data] = [:]
            var serverIDs = Set<String>()
            for (photo, thumb) in loaded {
                photos.append(photo)
                serverIDs.insert(photo.id)
                if let thumb { newThumbs[photo.id] = thumb }
            }
            // Reactions + comments ride the same zone fetch — REPLACE this
            // album's social state wholesale (it's a full enumeration).
            applySocialRecords(load.socialRecords, resetForPhotoIDs: serverIDs)
            // Read-after-write guard: re-add just-saved photos the server hasn't
            // surfaced yet (custom-zone propagation lag), so the optimistic
            // entries aren't clobbered by a short/empty re-fetch.
            for photo in recent where !serverIDs.contains(photo.id) {
                photos.append(photo)
                if newThumbs[photo.id] == nil, let t = recentThumbnails[photo.id] {
                    newThumbs[photo.id] = t
                }
            }
            photos.sort(by: Self.newestFirst)
            if !newThumbs.isEmpty {
                thumbnailCache.merge(newThumbs) { _, new in new }
            }
            photosByAlbum[album.id] = photos
            updateCover(albumID: album.id, photos: photos)
            // This was a WHOLE-zone fetch, so the count bookkeeping (here and in
            // the delta-sync path) may trust `photos.count` as authoritative.
            fullyLoadedAlbums.insert(album.id)
            // Keep the album card's count honest with what we actually have.
            if let idx = albums.firstIndex(where: { $0.id == album.id }),
               albums[idx].photoCount != photos.count {
                albums[idx].photoCount = photos.count
                persistCache()
            }
        } catch {
            let mapped = cloud.map(error)
            SharedAlbumLog.logger.error(
                "loadPhotos: FAILED album=\(album.id, privacy: .public) db=\(scope, privacy: .public) — \(mapped.localizedDescription, privacy: .public)")
            // Do NOT clear photosByAlbum here: keep any optimistic/cached entries
            // so a reload failure doesn't erase a successful contribute. Surface
            // the error so the empty/short grid isn't silent.
            state = .error(message: mapped.localizedDescription)
            // Only pop a modal on the POST-ADD reconcile path (recent non-empty).
            // The passive load paths (.task on appear, pull-to-refresh) pass no
            // `recent`, so a transient/offline fetch failure there degrades
            // silently to the cached grid + state = .error instead of a modal
            // alert on every open.
            if !recent.isEmpty {
                setAlbumAlert(album.id, title: "Couldn't Refresh Album", message: mapped.localizedDescription)
            }
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

    /// What a delta sync brought in — drives both the `.newData` fetch result
    /// and the local "N new photos in X" notification after a background wake.
    struct SyncNews {
        var changed = false
        /// Photos newly INSERTED (not updated) by this sync, per album name.
        var newPhotosByAlbumName: [String: Int] = [:]
        var totalNewPhotos: Int { newPhotosByAlbumName.values.reduce(0, +) }
    }

    /// Delta-sync both databases since their last server change token. Applies
    /// changed/deleted SharedPhoto records to `photosByAlbum`, drops deleted
    /// albums, and persists the new tokens. Driven by the remote-notification
    /// app-delegate hook (and reusable for manual refresh). Gated in tests and
    /// inert when iCloud is unavailable. Returns what changed (so the app
    /// delegate can report `.newData` and post a visible notification).
    @discardableResult
    func syncChanges() async -> SyncNews {
        guard !Self.runningTests else { return SyncNews() }
        await cloud.accountStatus()
        guard cloud.isAvailable else { return SyncNews() }

        loadTokenCacheIfNeeded()
        var news = SyncNews()
        await syncDatabase(cloud.sharedDB, scope: .shared, news: &news)
        await syncDatabase(cloud.privateDB, scope: .private, news: &news)
        if news.changed { persistTokenCache() }
        return news
    }

    /// Delta-sync one database, accumulating into `news`.
    private func syncDatabase(_ database: CKDatabase,
                             scope: CKDatabase.Scope,
                             news: inout SyncNews) async {
        let result: DatabaseChangeResult
        do {
            result = try await fetchDatabaseChangesRecoveringExpiry(database, scope: scope)
        } catch {
            #if DEBUG
            print("[SharedAlbums] syncDatabase(\(scope)) failed: \(error)")
            #endif
            return
        }

        var anyChange = false

        // Deleted zones → drop the album + its photos + tokens + folder links.
        for zoneID in result.deletedZoneIDs {
            let albumID = zoneID.zoneName
            if albums.contains(where: { $0.id == albumID }) {
                albums.removeAll { $0.id == albumID }
                photosByAlbum[albumID] = nil
                fullyLoadedAlbums.remove(albumID)
                anyChange = true
            }
            let linkedFolders = folderAlbumLinks.filter { $0.value == albumID }.map(\.key)
            if !linkedFolders.isEmpty {
                for key in linkedFolders { folderAlbumLinks[key] = nil }
                persistFolderLinks()
            }
            tokenCache.removeZone(zoneID)
        }

        // Per-zone record changes.
        for zc in result.zoneChanges {
            let albumID = zc.zoneID.zoneName
            // This delta was fetched with a nil zone token (brand-new zone) →
            // it is a FULL enumeration, so the photo-count bookkeeping may
            // trust it. Must be read BEFORE the new token is stored below.
            if tokenCache.zoneToken(zc.zoneID) == nil,
               albumID.hasPrefix(CloudKitService.albumZonePrefix) {
                fullyLoadedAlbums.insert(albumID)
            }
            // A change in an ALBUM zone we don't know yet — a brand-new album
            // shared with us (or created on another of our devices). Without
            // this, a pushed-in album never appears until the next manual
            // loadAlbums (the old bug: an accepted invite showed up for the
            // receiver only after force-quitting or pull-to-refresh).
            if albumID.hasPrefix(CloudKitService.albumZonePrefix),
               !albums.contains(where: { $0.id == albumID }) {
                let ownedByMe = scope == .private
                if let album = await albumFromZone(zc.zoneID, in: database, ownedByMe: ownedByMe) {
                    upsertAlbum(album)
                    anyChange = true
                }
            }
            // Decode CKAsset thumbnail bytes OFF the main actor first (a large
            // delta shouldn't jank the UI), then apply the (already-decoded)
            // changes synchronously on the main actor.
            let thumbs = await Self.decodeThumbnails(for: zc.changedRecords)
            let applied = applyZoneChanges(zc, albumID: albumID, decodedThumbnails: thumbs)
            if applied.changed { anyChange = true }
            // Count only photos contributed by OTHERS toward the visible
            // notification — the user's own uploads syncing across their
            // devices shouldn't ping them.
            if applied.insertedByOthers > 0 {
                let name = albums.first(where: { $0.id == albumID })?.name ?? "Shared album"
                news.newPhotosByAlbumName[name, default: 0] += applied.insertedByOthers
            }
            tokenCache.setZoneToken(zc.newToken, for: zc.zoneID)
        }

        // Advance the database token ONLY when every changed zone was fetched.
        // The DB-changes op re-reports a zone only for changes AFTER the token
        // we hand it — persisting the new token past a failed zone would drop
        // that zone's delta forever (stale grid until some future write).
        // Keeping the old token means the next sync re-reports everything since
        // it; already-synced zones no-op via their own advanced zone tokens.
        if result.failedZoneIDs.isEmpty {
            tokenCache.setDatabaseToken(result.newDatabaseToken, scope: scope)
        } else {
            SharedAlbumLog.logger.error(
                "syncDatabase(\(String(describing: scope), privacy: .public)): \(result.failedZoneIDs.count) zone fetch(es) failed — database token NOT advanced")
        }
        if anyChange {
            persistCache()
            news.changed = true
        }
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
                                  decodedThumbnails: [String: Data]) -> (changed: Bool, insertedByOthers: Int) {
        var photos = photosByAlbum[albumID] ?? []
        var changed = false
        var insertedByOthers = 0
        var thumbInserts: [String: Data] = [:]
        var thumbRemovals: [String] = []
        var social: [CKRecord] = []

        // Upserts.
        for record in zc.changedRecords {
            switch record.recordType {
            case SharedAlbum.RecordType.photo:
                guard let photo = SharedPhoto(record: record) else { continue }
                if let thumb = decodedThumbnails[photo.id] {
                    thumbInserts[photo.id] = thumb
                }
                if let idx = photos.firstIndex(where: { $0.id == photo.id }) {
                    photos[idx] = photo
                } else {
                    photos.append(photo)
                    if let contributor = photo.contributorID,
                       contributor != myRecordName {
                        insertedByOthers += 1
                    }
                }
                changed = true
            case SharedSocial.RecordType.reaction, SharedSocial.RecordType.comment:
                social.append(record)
                changed = true
            default:
                break
            }
        }
        applySocialRecords(social, resetForPhotoIDs: nil)

        // Deletions (photos + social, distinguished by record-name prefix).
        for id in zc.deletedRecordIDs {
            let name = id.recordName
            if let idx = photos.firstIndex(where: { $0.id == name }) {
                photos.remove(at: idx)
                thumbRemovals.append(name)
                changed = true
            } else if name.hasPrefix("reaction-") || name.hasPrefix("comment-") {
                removeSocialRecord(named: name)
                changed = true
            }
        }

        // Apply cache mutations in one batch (single @Published invalidation).
        if !thumbInserts.isEmpty {
            thumbnailCache.merge(thumbInserts) { _, new in new }
        }
        for name in thumbRemovals { thumbnailCache[name] = nil }

        if changed {
            photos.sort(by: Self.newestFirst)
            photosByAlbum[albumID] = photos
            updateCover(albumID: albumID, photos: photos)
            // Keep the album card count in step with the live photo list — but
            // ONLY when we hold a full view of the album. A delta into an album
            // never fully loaded this launch would clobber the cached count with
            // the delta's size (e.g. "2 photos" on a 50-photo album).
            if fullyLoadedAlbums.contains(albumID),
               let idx = albums.firstIndex(where: { $0.id == albumID }) {
                albums[idx].photoCount = photos.count
            }
        }
        return (changed, insertedByOthers)
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

    // MARK: - Covers (#6)

    private static func coverURL(for albumID: String) -> URL {
        storeDir.appendingPathComponent("cover-\(albumID).jpg")
    }

    /// The album's cover thumbnail bytes: memory → disk → nil.
    func coverThumbnail(for albumID: String) -> Data? {
        if let data = coverCache[albumID] { return data }
        if let data = try? Data(contentsOf: Self.coverURL(for: albumID)) {
            coverCache[albumID] = data
            return data
        }
        return nil
    }

    /// Record the newest photo's thumbnail as the album cover (memory + disk).
    /// Called wherever the photo list changes; cheap no-op when unchanged.
    private func updateCover(albumID: String, photos: [SharedPhoto]) {
        guard let newest = photos.first,           // photos are newest-first
              let thumb = thumbnailCache[newest.id] else { return }
        if coverCache[albumID] == thumb { return }
        coverCache[albumID] = thumb
        try? thumb.write(to: Self.coverURL(for: albumID), options: .atomic)
    }

    // MARK: - Attribution (#6)

    /// Resolve who contributed a photo, for display: "you", a friend's
    /// @username, a share participant's name, or nil (unknown).
    func contributorDisplayName(for photo: SharedPhoto) -> String? {
        guard let contributor = photo.contributorID else { return nil }
        if contributor == myRecordName { return "you" }
        if let friend = InvitationStore.shared.friends.first(where: { $0.userRecordID == contributor }) {
            return "@\(friend.username)"
        }
        return participantNames[contributor]
    }

    /// Lazily resolve participant display names for an album (one live-share
    /// fetch) so attribution/comments can name non-friend members. Idempotent
    /// per launch once names are known; inert when unavailable.
    func loadParticipantNamesIfNeeded(for album: SharedAlbum) async {
        if myRecordName == nil {
            myRecordName = try? await cloud.currentUserRecordID().recordName
        }
        // If every current photo's contributor already resolves, skip the fetch.
        let unresolved = (photosByAlbum[album.id] ?? []).contains { photo in
            guard let c = photo.contributorID else { return false }
            return c != myRecordName
                && participantNames[c] == nil
                && !InvitationStore.shared.friends.contains(where: { $0.userRecordID == c })
        }
        guard unresolved else { return }
        guard let people = await participants(for: album) else { return }
        for p in people {
            if let record = p.userRecordID, participantNames[record] == nil {
                participantNames[record] = p.displayName
            }
        }
    }

    // MARK: - Resumable uploads (#7)

    /// albumID → asset IDs of an upload that may not have finished. Persisted
    /// so an app kill / hard failure mid-upload resumes on the next activation
    /// (dedupe re-adds only what's missing). Cleared on verified completion.
    private var pendingUploads: [String: [String]] = [:]
    private var pendingUploadsLoaded = false
    private static var pendingUploadsURL: URL {
        storeDir.appendingPathComponent("pending_uploads.json")
    }

    private func loadPendingUploadsIfNeeded() {
        guard !pendingUploadsLoaded else { return }
        pendingUploadsLoaded = true
        if let data = try? Data(contentsOf: Self.pendingUploadsURL),
           let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) {
            pendingUploads = decoded
        }
    }

    private func persistPendingUploads() {
        try? JSONEncoder().encode(pendingUploads).write(to: Self.pendingUploadsURL, options: .atomic)
    }

    private func notePendingUpload(albumID: String, assetIDs: [String]) {
        loadPendingUploadsIfNeeded()
        // Union with anything already pending for this album so an interrupted
        // resume that itself gets interrupted never loses IDs.
        var ids = Set(pendingUploads[albumID] ?? [])
        ids.formUnion(assetIDs)
        pendingUploads[albumID] = Array(ids)
        persistPendingUploads()
    }

    private func clearPendingUpload(albumID: String) {
        loadPendingUploadsIfNeeded()
        guard pendingUploads[albumID] != nil else { return }
        pendingUploads[albumID] = nil
        persistPendingUploads()
    }

    /// Resume uploads interrupted by an app kill / failure. One attempt per
    /// activation; the in-flight guard + dedupe make it safe and cheap.
    func resumePendingUploads() async {
        guard !Self.runningTests else { return }
        loadPendingUploadsIfNeeded()
        guard !pendingUploads.isEmpty else { return }
        await cloud.accountStatus()
        guard cloud.isAvailable else { return }
        for (albumID, assetIDs) in pendingUploads {
            guard let album = album(withID: albumID) else {
                // Album is gone (deleted/left) — drop the orphaned intent.
                clearPendingUpload(albumID: albumID)
                continue
            }
            SharedAlbumLog.logger.notice(
                "resumePendingUploads: resuming \(assetIDs.count) item(s) into \(albumID, privacy: .public)")
            _ = try? await addPhotosReportingCount(localAssetIDs: assetIDs, toAlbum: album)
        }
    }

    // MARK: - Auto-share suggestions (#8)

    /// "N new photos of <person> — add to <album>?" One suggestion per
    /// folder-linked owned album whose folder members are dominated by known
    /// face clusters, when NEWER photos of those people exist outside it.
    struct ShareSuggestion: Identifiable, Equatable {
        let id: String            // album id
        let albumID: String
        let folderID: String
        let albumName: String
        let peopleLabel: String   // "Mom", "Mom & Dad", "3 people"
        let assetIDs: [String]
        let newestDate: Date
    }

    @Published private(set) var suggestions: [ShareSuggestion] = []

    /// albumID → newest candidate date at dismissal; a suggestion re-appears
    /// only when strictly newer candidates exist. Persisted.
    private var dismissedSuggestions: [String: Date] = [:]
    private static var dismissedSuggestionsURL: URL {
        storeDir.appendingPathComponent("dismissed_share_suggestions.json")
    }

    /// Recompute suggestions from purely LOCAL state (PhotoStore's index +
    /// folder links) — no CloudKit. Cheap enough to run on album-screen entry.
    func refreshSuggestions() {
        loadFolderLinksIfNeeded()
        if dismissedSuggestions.isEmpty,
           let data = try? Data(contentsOf: Self.dismissedSuggestionsURL),
           let decoded = try? JSONDecoder().decode([String: Date].self, from: data) {
            dismissedSuggestions = decoded
        }

        let photoStore = PhotoStore.shared
        var fresh: [ShareSuggestion] = []

        for (folderID, albumID) in folderAlbumLinks {
            guard let album = album(withID: albumID), album.isOwnedByMe,
                  let folder = photoStore.folders.first(where: { $0.id == folderID }),
                  !folder.isSmart else { continue }

            let memberIDs = Set(photoStore.activeMemberAssetIDs(in: folder))
            guard memberIDs.count >= 4 else { continue }   // too small to profile

            // Index member photos + find the dominant face clusters.
            var clusterCounts: [Int: Int] = [:]
            var latestMemberDate = Date.distantPast
            for photo in photoStore.photos where memberIDs.contains(photo.assetID) {
                for cluster in Set(photo.personClusterIDs) {
                    clusterCounts[cluster, default: 0] += 1
                }
                if let d = photo.createdAt, d > latestMemberDate { latestMemberDate = d }
            }
            let threshold = max(3, Int(Double(memberIDs.count) * 0.25))
            let dominant = Set(clusterCounts.filter { $0.value >= threshold }.map(\.key))
            guard !dominant.isEmpty else { continue }

            // Newer photos of those people, not already in the folder.
            var candidates: [(id: String, date: Date)] = []
            for photo in photoStore.photos {
                guard !photo.isDeleted,
                      !memberIDs.contains(photo.assetID),
                      let date = photo.createdAt, date > latestMemberDate,
                      !Set(photo.personClusterIDs).isDisjoint(with: dominant) else { continue }
                candidates.append((photo.assetID, date))
            }
            guard !candidates.isEmpty else { continue }
            candidates.sort { $0.date > $1.date }
            let capped = Array(candidates.prefix(24))
            let newest = capped[0].date

            // Respect a dismissal until strictly newer candidates appear.
            if let dismissedAt = dismissedSuggestions[albumID], newest <= dismissedAt { continue }

            // Label from the dominant clusters' names.
            let names = dominant
                .compactMap { id in photoStore.clusters.first(where: { $0.id == id })?.name }
                .filter { !$0.isEmpty }
                .sorted()
            let people: String
            switch names.count {
            case 0:  people = "people in this album"
            case 1:  people = names[0]
            case 2:  people = "\(names[0]) & \(names[1])"
            default: people = "\(names[0]) & \(names.count - 1) others"
            }

            fresh.append(ShareSuggestion(
                id: albumID, albumID: albumID, folderID: folderID,
                albumName: album.name, peopleLabel: people,
                assetIDs: capped.map(\.id), newestDate: newest))
        }

        suggestions = fresh.sorted { $0.newestDate > $1.newestDate }
    }

    /// Accept a suggestion: add the photos to the linked folder (keeps the
    /// folder ⇄ album pairing coherent) and upload them (deduped).
    func acceptSuggestion(_ suggestion: ShareSuggestion) async {
        guard let album = album(withID: suggestion.albumID) else { return }
        PhotoStore.shared.addPhotos(suggestion.assetIDs, toFolder: suggestion.folderID)
        dismissSuggestion(suggestion)   // consume it either way
        _ = try? await addPhotosReportingCount(localAssetIDs: suggestion.assetIDs, toAlbum: album)
    }

    func dismissSuggestion(_ suggestion: ShareSuggestion) {
        dismissedSuggestions[suggestion.albumID] = suggestion.newestDate
        try? JSONEncoder().encode(dismissedSuggestions)
            .write(to: Self.dismissedSuggestionsURL, options: .atomic)
        suggestions.removeAll { $0.id == suggestion.id }
    }

    // MARK: - Search inside shared albums (#9)

    /// CLIP embeddings for shared photos, keyed by contentHash (stable across
    /// devices and re-uploads). Computed on demand from the ~256px thumbnails
    /// — CLIP's input is 224px, so thumbnail quality is exactly right — and
    /// persisted so an album is only ever embedded once.
    private var sharedEmbeddings: [String: [Float]] = [:]
    private var sharedEmbeddingsLoaded = false
    private static var sharedEmbeddingsURL: URL {
        storeDir.appendingPathComponent("shared_clip_embeddings.json")
    }

    /// True when on-device search of shared albums can work here (models load
    /// on device only — the simulator hides the search UI).
    nonisolated var sharedSearchAvailable: Bool { OnDeviceMLEngine.shared.isAvailable }

    private func loadSharedEmbeddingsIfNeeded() {
        guard !sharedEmbeddingsLoaded else { return }
        sharedEmbeddingsLoaded = true
        if let data = try? Data(contentsOf: Self.sharedEmbeddingsURL),
           let decoded = try? JSONDecoder().decode([String: [Float]].self, from: data) {
            sharedEmbeddings = decoded
        }
    }

    private func persistSharedEmbeddings() {
        if let data = try? JSONEncoder().encode(sharedEmbeddings) {
            try? data.write(to: Self.sharedEmbeddingsURL, options: .atomic)
        }
    }

    /// Rank an album's photos against a natural-language query, on device.
    /// Missing embeddings are computed from cached thumbnails first (off the
    /// main actor). Returns nil when the ML engine isn't available (simulator)
    /// or the query is empty; [] when nothing clears the floor.
    func searchShared(album: SharedAlbum, query: String) async -> [SharedPhoto]? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, sharedSearchAvailable else { return nil }
        guard let queryEmb = try? OnDeviceMLEngine.shared.encodeText(trimmed) else { return nil }
        loadSharedEmbeddingsIfNeeded()

        let photos = photosByAlbum[album.id] ?? []
        // 1. Compute any missing embeddings from cached thumbnail bytes.
        var toCompute: [(hash: String, data: Data)] = []
        for photo in photos {
            guard let hash = photo.contentHash, sharedEmbeddings[hash] == nil,
                  let thumb = thumbnailCache[photo.id] else { continue }
            toCompute.append((hash, thumb))
        }
        if !toCompute.isEmpty {
            let computed: [String: [Float]] = await Task.detached(priority: .userInitiated) {
                var out: [String: [Float]] = [:]
                for entry in toCompute {
                    guard let image = UIImage(data: entry.data)?.cgImage else { continue }
                    if let emb = try? OnDeviceMLEngine.shared.encodeImage(image) {
                        out[entry.hash] = emb
                    }
                }
                return out
            }.value
            if !computed.isEmpty {
                sharedEmbeddings.merge(computed) { _, new in new }
                persistSharedEmbeddings()
            }
        }

        // 2. Rank by cosine (embeddings are L2-normalized → dot product).
        let floor: Float = 0.2
        let scored: [(SharedPhoto, Float)] = photos.compactMap { photo in
            guard let hash = photo.contentHash, let emb = sharedEmbeddings[hash] else { return nil }
            var dot: Float = 0
            for i in 0..<min(emb.count, queryEmb.count) { dot += emb[i] * queryEmb[i] }
            return dot >= floor ? (photo, dot) : nil
        }
        return scored.sorted { $0.1 > $1.1 }.map(\.0)
    }

    // MARK: - Reactions + comments (#10)

    /// Replace/merge parsed social records. `resetForPhotoIDs` non-nil means a
    /// FULL zone load: wipe existing entries for those photos first so deleted
    /// reactions don't linger.
    private func applySocialRecords(_ records: [CKRecord], resetForPhotoIDs: Set<String>?) {
        if let ids = resetForPhotoIDs {
            for id in ids {
                reactionsByPhoto[id] = nil
                commentsByPhoto[id] = nil
            }
        }
        guard !records.isEmpty else { return }
        for record in records {
            if let reaction = SharedReaction(record: record) {
                var list = reactionsByPhoto[reaction.photoID] ?? []
                list.removeAll { $0.id == reaction.id }
                list.append(reaction)
                reactionsByPhoto[reaction.photoID] = list
            } else if let comment = SharedComment(record: record) {
                var list = commentsByPhoto[comment.photoID] ?? []
                list.removeAll { $0.id == comment.id }
                list.append(comment)
                list.sort { $0.createdAt < $1.createdAt }
                commentsByPhoto[comment.photoID] = list
            }
        }
    }

    /// Remove a deleted social record from local state (delta sync). The
    /// record type is recoverable from the record-name prefix.
    private func removeSocialRecord(named recordName: String) {
        if recordName.hasPrefix("reaction-") {
            for (photoID, list) in reactionsByPhoto where list.contains(where: { $0.id == recordName }) {
                reactionsByPhoto[photoID] = list.filter { $0.id != recordName }
            }
        } else if recordName.hasPrefix("comment-") {
            for (photoID, list) in commentsByPhoto where list.contains(where: { $0.id == recordName }) {
                commentsByPhoto[photoID] = list.filter { $0.id != recordName }
            }
        }
    }

    /// True when the current user has hearted this photo.
    func myReaction(to photo: SharedPhoto) -> SharedReaction? {
        guard let me = myRecordName else { return nil }
        return reactionsByPhoto[photo.id]?.first { $0.authorID == me }
    }

    /// Toggle the current user's ❤️ on a photo. Optimistic local update; the
    /// server write follows (and delta sync reconciles everyone else).
    func toggleReaction(on photo: SharedPhoto, in album: SharedAlbum) async {
        await cloud.accountStatus()
        guard cloud.isAvailable else { return }
        if myRecordName == nil {
            myRecordName = try? await cloud.currentUserRecordID().recordName
        }
        guard let me = myRecordName else { return }
        let database = album.isOwnedByMe ? cloud.privateDB : cloud.sharedDB

        if let existing = myReaction(to: photo) {
            // Un-heart: optimistic remove, then delete server-side.
            reactionsByPhoto[photo.id] = (reactionsByPhoto[photo.id] ?? [])
                .filter { $0.id != existing.id }
            let recordID = CKRecord.ID(recordName: existing.id, zoneID: album.zoneID)
            do {
                try await cloud.deleteRecord(recordID, from: database)
            } catch {
                // Revert the optimistic remove on failure.
                var list = reactionsByPhoto[photo.id] ?? []
                list.append(existing)
                reactionsByPhoto[photo.id] = list
            }
        } else {
            let reaction = SharedReaction(
                id: SharedSocial.reactionRecordName(photoID: photo.id, authorID: me),
                photoID: photo.id,
                emoji: "\u{2764}\u{FE0F}",
                authorID: me,
                createdAt: Date())
            var list = reactionsByPhoto[photo.id] ?? []
            list.append(reaction)
            reactionsByPhoto[photo.id] = list
            do {
                _ = try await cloud.save([reaction.toRecord(inZone: album.zoneID)], to: database)
            } catch {
                reactionsByPhoto[photo.id] = (reactionsByPhoto[photo.id] ?? [])
                    .filter { $0.id != reaction.id }
            }
        }
    }

    /// Post a comment on a photo. Returns false (and surfaces nothing fatal)
    /// on failure so the sheet can keep the draft text.
    @discardableResult
    func addComment(_ text: String, on photo: SharedPhoto, in album: SharedAlbum) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        await cloud.accountStatus()
        guard cloud.isAvailable else { return false }
        if myRecordName == nil {
            myRecordName = try? await cloud.currentUserRecordID().recordName
        }
        guard let me = myRecordName else { return false }
        let database = album.isOwnedByMe ? cloud.privateDB : cloud.sharedDB
        let comment = SharedComment(
            id: SharedSocial.commentRecordName(),
            photoID: photo.id,
            text: trimmed,
            authorID: me,
            authorName: InvitationStore.shared.myProfile.map { "@\($0.username)" },
            createdAt: Date())
        var list = commentsByPhoto[photo.id] ?? []
        list.append(comment)
        commentsByPhoto[photo.id] = list
        do {
            _ = try await cloud.save([comment.toRecord(inZone: album.zoneID)], to: database)
            return true
        } catch {
            commentsByPhoto[photo.id] = (commentsByPhoto[photo.id] ?? [])
                .filter { $0.id != comment.id }
            return false
        }
    }

    /// Author display for a social item: "you", @username, participant name.
    func authorDisplayName(_ authorID: String, fallback: String? = nil) -> String {
        if authorID == myRecordName { return "you" }
        if let friend = InvitationStore.shared.friends.first(where: { $0.userRecordID == authorID }) {
            return "@\(friend.username)"
        }
        return fallback ?? participantNames[authorID] ?? "Member"
    }

    // MARK: - Save to Library (#4)

    /// Copy shared photos into the user's own photo library. Fetches each
    /// full-resolution asset lazily, then creates a library asset; the app's
    /// existing library observer picks the new assets up and indexes them
    /// (CLIP + faces) automatically — so saved photos become searchable like
    /// any other. Returns (saved, failed). Progress publishes per album.
    @discardableResult
    func saveToLibrary(_ photos: [SharedPhoto], from album: SharedAlbum) async -> (saved: Int, failed: Int) {
        guard !photos.isEmpty else { return (0, 0) }
        await cloud.accountStatus()
        guard cloud.isAvailable else { return (0, photos.count) }

        savingToLibrary[album.id] = 0
        defer { savingToLibrary[album.id] = nil }

        var saved = 0, failed = 0
        for (idx, photo) in photos.enumerated() {
            let ok: Bool
            if photo.isVideo {
                ok = await saveVideoToLibrary(photo, album: album)
            } else {
                ok = await savePhotoToLibrary(photo, album: album)
            }
            if ok { saved += 1 } else { failed += 1 }
            savingToLibrary[album.id] = Double(idx + 1) / Double(photos.count)
        }
        if failed > 0 {
            setAlbumAlert(album.id, title: "Some Items Not Saved",
                          message: "\(failed) of \(photos.count) couldn't be saved. Check your connection and try again.")
        }
        return (saved, failed)
    }

    private func savePhotoToLibrary(_ photo: SharedPhoto, album: SharedAlbum) async -> Bool {
        guard let data = await fullImage(for: photo, in: album) else { return false }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: data, options: nil)
                if let date = photo.captureDate { request.creationDate = date }
                if let lat = photo.latitude, let lon = photo.longitude {
                    request.location = CLLocation(latitude: lat, longitude: lon)
                }
            }
            return true
        } catch {
            SharedAlbumLog.logger.error("saveToLibrary(photo): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func saveVideoToLibrary(_ photo: SharedPhoto, album: SharedAlbum) async -> Bool {
        let database = album.isOwnedByMe ? cloud.privateDB : cloud.sharedDB
        guard let url = try? await cloud.fullAssetFileURL(for: photo, database: database) else {
            return false
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = true   // temp copy — hand it over
                request.addResource(with: .video, fileURL: url, options: options)
                if let date = photo.captureDate { request.creationDate = date }
                if let lat = photo.latitude, let lon = photo.longitude {
                    request.location = CLLocation(latitude: lat, longitude: lon)
                }
            }
            return true
        } catch {
            try? FileManager.default.removeItem(at: url)
            SharedAlbumLog.logger.error("saveToLibrary(video): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// The album id a folder was previously shared as, if a link is on record.
    /// (ShareFolderView uses this to decide whether an empty folder may still
    /// open its existing shared album.) Hydrates the links from disk if needed.
    func linkedAlbumID(forFolder folderID: String) -> String? {
        loadFolderLinksIfNeeded()
        return folderAlbumLinks[folderID]
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

    /// Drop a zone's token (album deleted/left, or zone-level
    /// `changeTokenExpired` recovery) so any next fetch starts from scratch.
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
