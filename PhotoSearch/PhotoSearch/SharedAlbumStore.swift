import CloudKit
import Foundation

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

    private let cloud = CloudKitService.shared

    // MARK: - Storage paths (mirror PhotoStore's documents-dir JSON idiom)

    private static let storeDir: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let d = docs.appendingPathComponent("photosearch", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    private static var albumsCacheURL: URL { storeDir.appendingPathComponent("shared_albums.json") }
    private static var participantsURL: URL { storeDir.appendingPathComponent("shared_participants.json") }

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
