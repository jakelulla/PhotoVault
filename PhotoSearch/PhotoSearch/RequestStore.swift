import CloudKit
import Foundation
import UIKit

/// Owns the PHOTO-REQUEST state for the view layer (compose + inbox + build),
/// plus the user's PROFILE PHOTOS:
///   - a PUBLIC avatar (decorative; shown in friends/requests UI, NEVER matched),
///   - a PRIVATE face photo (stored LOCALLY only; used solely to compute the
///     requester's ArcFace embedding on demand, which is then delivered to a
///     friend EPHEMERALLY via the private-share machinery — never the public DB).
///
/// Mirrors InvitationStore / SharedAlbumStore exactly: a `@MainActor`
/// `ObservableObject` singleton, JSON + file caches in the app's
/// documents/photosearch dir, `@Published` state the views observe, a handled-set
/// for inbox dedup, and — crucially — NOTHING runs at init or at app launch.
///
/// Every CloudKit entry point first refreshes account status and short-circuits
/// on `CloudKitService.isAvailable == false`; the launch/push-reachable paths
/// additionally gate on `runningTests`. So this stack is provably inert on the
/// simulator and in the test suite, mirroring ContentView.runningTests.
@MainActor
final class RequestStore: ObservableObject {
    static let shared = RequestStore()

    /// Pending photo requests addressed to me (the friend asked to build), already
    /// filtered against the handled-set, newest first. Drives the inbox + banner.
    @Published private(set) var pendingRequests: [PhotoRequest] = []

    /// True while a public-DB op (send, fetch inbox) is in flight — for spinners.
    @Published private(set) var isWorking = false

    /// True once a PRIVATE face photo has been set (so the compose UI knows
    /// whether a face filter is usable). Derived from the on-disk file presence.
    @Published private(set) var hasPrivateFacePhoto = false

    private let directory = DirectoryService.shared
    private let cloud = CloudKitService.shared

    /// Requests the friend already built/dismissed, so they don't re-show.
    private var handled = HandledRequests()

    /// Ephemeral face zones we created but haven't confirmed deleted. Persisted to
    /// disk so a startup sweep can tear them down even if the app was suspended
    /// before the fast-path timer fired (the "ephemeral" privacy guarantee).
    private var pendingFaceZones = PendingFaceZones()

    /// True once the pending-zone sweep has run this launch (so we don't repeat it
    /// on every view appearance).
    private var faceZonesSwept = false

    /// True once the request subscription has been registered this launch.
    private var subscriptionRegistered = false

    /// Mirrors ContentView.runningTests — skip launch/push-reachable CloudKit/ML
    /// work in the XCTest host even if some entry point is exercised.
    private static let runningTests =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    private init() {}

    // MARK: - Storage paths (same documents/photosearch dir as the other stores)

    private static let storeDir: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let d = docs.appendingPathComponent("photosearch", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    private static var handledURL: URL { storeDir.appendingPathComponent("handled_requests.json") }
    /// Persisted set of ephemeral face zones pending teardown (durable cleanup).
    private static var pendingFaceZonesURL: URL { storeDir.appendingPathComponent("pending_face_zones.json") }
    /// The PRIVATE face photo lives ONLY here on disk — never uploaded as-is.
    /// Only its derived ArcFace embedding is ever sent, and only ephemerally.
    private static var privateFaceURL: URL { storeDir.appendingPathComponent("private_face.jpg") }

    // MARK: - Local cache (pure I/O — safe at any time, never CloudKit)

    /// Hydrate the handled-set + private-face presence from disk. Tolerant of
    /// missing/corrupt files. Called from the views' `.task`; never at launch.
    func loadLocalCache() {
        if let data = try? Data(contentsOf: Self.handledURL),
           let cached = try? JSONDecoder().decode(HandledRequests.self, from: data) {
            handled = cached
        }
        if let data = try? Data(contentsOf: Self.pendingFaceZonesURL),
           let cached = try? JSONDecoder().decode(PendingFaceZones.self, from: data) {
            pendingFaceZones = cached
        }
        hasPrivateFacePhoto = FileManager.default.fileExists(atPath: Self.privateFaceURL.path)
    }

    private func persistHandled() {
        try? JSONEncoder().encode(handled).write(to: Self.handledURL, options: .atomic)
    }

    private func persistPendingFaceZones() {
        try? JSONEncoder().encode(pendingFaceZones).write(to: Self.pendingFaceZonesURL, options: .atomic)
    }

    // MARK: - Durable ephemeral face-zone cleanup

    /// Record an ephemeral face zone as pending teardown and persist it, so the
    /// next-launch sweep deletes it even if the app is suspended before the
    /// fast-path timer fires. Called from `sendRequest` after a face share is
    /// created. Pure local I/O (no CloudKit), safe at any time. Exposed for tests.
    func rememberPendingEphemeralFaceZone(_ zoneID: CKRecordZone.ID) {
        pendingFaceZones.add(PendingFaceZones.ZoneRef(
            zoneName: zoneID.zoneName, ownerName: zoneID.ownerName))
        persistPendingFaceZones()
    }

    /// Drop one zone from the pending set (after we've deleted it, or learned it's
    /// already gone) and persist. Pure local I/O. Exposed for tests.
    func forgetPendingEphemeralFaceZone(_ zoneID: CKRecordZone.ID) {
        pendingFaceZones.remove(PendingFaceZones.ZoneRef(
            zoneName: zoneID.zoneName, ownerName: zoneID.ownerName))
        persistPendingFaceZones()
    }

    /// The current pending ephemeral face zones (for tests / diagnostics).
    var pendingEphemeralFaceZoneRefs: [PendingFaceZones.ZoneRef] { pendingFaceZones.zones }

    /// Durable sweep: delete every persisted pending ephemeral face zone and clear
    /// the set. This is the real "ephemeral" guarantee — it runs at app startup
    /// (driven by a view `.task`, never auto-run at launch) and tears down zones
    /// the fast-path 600s timer missed because the app was suspended. Gated like
    /// every other launch-reachable CloudKit path: skips in tests and when iCloud
    /// is unavailable, so it stays inert on the simulator / in the test host.
    /// Tolerant of already-gone zones (deleteEphemeralFaceZone never throws), and
    /// idempotent per launch via `faceZonesSwept`.
    func sweepPendingEphemeralFaceZones() async {
        guard !Self.runningTests else { return }
        guard !faceZonesSwept else { return }
        // Nothing to do if the set is empty (hydrate from disk first).
        if pendingFaceZones.isEmpty {
            if let data = try? Data(contentsOf: Self.pendingFaceZonesURL),
               let cached = try? JSONDecoder().decode(PendingFaceZones.self, from: data) {
                pendingFaceZones = cached
            }
        }
        guard !pendingFaceZones.isEmpty else { faceZonesSwept = true; return }
        await cloud.accountStatus()
        guard cloud.isAvailable else { return }   // retry next launch
        faceZonesSwept = true

        let refs = pendingFaceZones.zones
        for ref in refs {
            let zoneID = CKRecordZone.ID(zoneName: ref.zoneName, ownerName: ref.ownerName)
            // Best-effort, tolerant of already-gone zones (never throws).
            await directory.deleteEphemeralFaceZone(zoneID)
            pendingFaceZones.remove(ref)
            persistPendingFaceZones()
        }
    }

    // MARK: - Profile photos

    /// Read the private face photo bytes from disk (nil if none set). Used to
    /// compute the requester's embedding; never uploaded directly.
    func privateFacePhotoData() -> Data? {
        try? Data(contentsOf: Self.privateFaceURL)
    }

    /// Set (or replace) the PRIVATE face photo from JPEG/HEIC bytes. Downscaled
    /// to a sane size and re-encoded JPEG for compact local storage. Stays
    /// entirely on-device. Returns true on success.
    @discardableResult
    func setPrivateFacePhoto(_ data: Data) -> Bool {
        guard let normalized = Self.downscaledJPEG(data, maxPixel: 1024) else { return false }
        do {
            try normalized.write(to: Self.privateFaceURL, options: .atomic)
            hasPrivateFacePhoto = true
            return true
        } catch {
            return false
        }
    }

    /// Forget the private face photo (local delete). Disables face-filtered
    /// requests until a new one is set.
    func clearPrivateFacePhoto() {
        try? FileManager.default.removeItem(at: Self.privateFaceURL)
        hasPrivateFacePhoto = false
    }

    /// Set the PUBLIC avatar on my UserProfile (decorative; never matched). Routes
    /// through InvitationStore so the cached profile + the public record both
    /// update. Throws on CloudKit failure / no profile yet. Downscales the bytes
    /// first so the avatar asset stays small.
    func setPublicAvatar(_ data: Data) async throws {
        let small = Self.downscaledJPEG(data, maxPixel: 256) ?? data
        try await InvitationStore.shared.setMyAvatar(small)
    }

    /// Compute MY ArcFace embedding from the PRIVATE face photo, on demand. Runs
    /// the on-device pipeline (face detect + ArcFace) off the main actor. Returns
    /// nil when: no private photo is set, the ML engine is unavailable (simulator
    /// / tests), the image can't be decoded, or no face is found. The caller uses
    /// this ONLY to build the ephemeral face share — the embedding never lands in
    /// the public DB.
    func computeMyFaceEmbedding() async -> [Float]? {
        guard !Self.runningTests else { return nil }
        guard let data = privateFacePhotoData() else { return nil }
        let engine = OnDeviceMLEngine.shared
        // Lazily load models (the indexer may not have run yet). On the simulator
        // the .mlmodelc bundles load but inference isn't ANE-validated; isAvailable
        // gating + runningTests keep this from running there in practice.
        if !engine.isAvailable { try? engine.loadModels() }
        guard engine.isAvailable else { return nil }
        return await Task.detached(priority: .userInitiated) {
            guard let ui = UIImage(data: data),
                  let cg = Self.orientedUpCGImage(ui),
                  let result = try? engine.process(cgImage: cg),
                  !result.faceEmbeddings.isEmpty else { return nil }
            // Pick the LARGEST face (the subject), not the first: SCRFD orders
            // faceEmbeddings by detection CONFIDENCE, not size, so `.first` can be
            // a small bystander. Zip each embedding with its parallel faceRect and
            // choose the one whose bounding box has the greatest area (normalized
            // 0…1 space). Fall back to the first if the rects array is somehow
            // shorter than the embeddings (defensive — they're parallel by
            // contract).
            let embs = result.faceEmbeddings
            let rects = result.faceRects
            guard rects.count == embs.count else { return embs.first }
            let largestIndex = rects.indices.max { a, b in
                (rects[a].width * rects[a].height) < (rects[b].width * rects[b].height)
            }
            return largestIndex.map { embs[$0] } ?? embs.first
        }.value
    }

    // MARK: - Compose (requester side)

    /// Send a photo request to a friend. When `faceFilter` needs a face we compute
    /// MY embedding from the private photo here and hand it to the directory, which
    /// stands up the ephemeral face share and puts only its URL on the public
    /// record. Returns the directory's outcome (the ephemeral zone ID, if any, so
    /// the caller can schedule a durable cleanup once the friend has built the
    /// album, plus a flag disclosing whether the face filter was downgraded to
    /// `.any`).
    @discardableResult
    func sendRequest(to friend: Friend,
                     description: String,
                     from startDate: Date,
                     to endDate: Date,
                     faceFilter: FaceFilter) async throws -> DirectoryService.SendRequestOutcome {
        isWorking = true
        defer { isWorking = false }
        await cloud.accountStatus()
        guard cloud.isAvailable else {
            throw SharedAlbumError.unavailable(reason: "Sign in to iCloud to send a request")
        }
        guard let me = InvitationStore.shared.myProfile else {
            throw SharedAlbumError.cloudKit("Claim a username before sending requests.")
        }

        var embedding: [Float]?
        if faceFilter.needsFace {
            embedding = await computeMyFaceEmbedding()
            guard embedding != nil else {
                throw SharedAlbumError.cloudKit(
                    "Set a clear photo of your face first (Friends → your profile) to use a face filter.")
            }
        }

        let outcome = try await directory.sendPhotoRequest(
            toUserRecordID: friend.userRecordID,
            fromUsername: me.username,
            description: description,
            from: startDate,
            to: endDate,
            faceFilter: faceFilter,
            faceEmbedding: embedding)

        // Durable cleanup (#4): record the ephemeral face zone so a startup sweep
        // deletes it even if the app is suspended before the fast-path timer fires.
        if let zoneID = outcome.ephemeralZoneID {
            rememberPendingEphemeralFaceZone(zoneID)
        }
        return outcome
    }

    /// Best-effort cleanup of the ephemeral face zone after a request round-trips.
    /// The requester owns this; we never rely on the friend to delete it. This is
    /// the FAST PATH (a 600s post-send timer); the durable guarantee is
    /// `sweepPendingEphemeralFaceZones` at next launch. On success we also drop the
    /// zone from the persisted pending set so the sweep doesn't re-attempt it.
    func cleanupEphemeralFaceZone(_ zoneID: CKRecordZone.ID) async {
        await directory.deleteEphemeralFaceZone(zoneID)
        forgetPendingEphemeralFaceZone(zoneID)
    }

    // MARK: - Inbox (friend side)

    /// Fetch pending requests addressed to me, filter out already-handled ones,
    /// and publish them newest-first. Tolerant of availability failure (keeps
    /// cached/empty). Gated in tests. Called from the view `.task` + the push
    /// hook — never at launch.
    func refreshPendingRequests() async {
        guard !Self.runningTests else { return }
        await cloud.accountStatus()
        guard cloud.isAvailable else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let fetched = try await directory.fetchPendingRequests()
            // Same blocklist filter as the invitation inbox: a blocked person
            // cannot ask you for photos.
            pendingRequests = SafetyStore.shared.filterBlocked(
                handled.unhandled(fetched), senderID: \.fromUserRecordID)
        } catch {
            #if DEBUG
            print("[Requests] fetch failed: \(error)")
            #endif
        }
    }

    /// Dismiss a request: mark it handled locally so it stops re-showing. No
    /// CloudKit work (the friend generally can't delete the requester's public
    /// record). Best-effort nudges the requester to clean up their record.
    func dismiss(_ request: PhotoRequest) {
        markHandled(request)
        Task { await directory.deleteSentRequest(id: request.id) }
    }

    private func markHandled(_ request: PhotoRequest) {
        handled.mark(request.id)
        persistHandled()
        pendingRequests.removeAll { $0.id == request.id }
    }

    // MARK: - Fulfill (build the candidate set)

    /// The result of building a candidate set for review: the asset IDs to show in
    /// the review grid, plus the source request and the FACE-FILTER OUTCOME.
    /// Identifiable/Hashable so it can drive a SwiftUI `navigationDestination`.
    ///
    /// `faceFilterStatus` is load-bearing for privacy: it distinguishes a filter
    /// that was actually APPLIED from one that was REQUESTED but could not be
    /// applied (no embedding — unavailable / accept failure / simulator). The
    /// review view MUST NOT pre-select an over-broad grid when the requested
    /// filter failed (an `.onlyMe` request would otherwise default to sharing
    /// everything). See `FaceFilterStatus`.
    struct FulfillResult: Identifiable, Hashable {
        let request: PhotoRequest
        let candidateAssetIDs: [String]
        let faceFilterStatus: FaceFilterStatus
        var id: String { request.id }
    }

    /// Outcome of the (optional) face-filter step during `fulfill`.
    enum FaceFilterStatus: Hashable {
        /// The request didn't ask for a face filter (`.any`) — nothing to apply.
        case notRequested
        /// A face filter was requested AND successfully applied (the candidate set
        /// is genuinely filtered). Safe to pre-select the whole grid for review.
        case applied
        /// A face filter was requested but COULD NOT be applied (no reachable
        /// embedding: unavailable / accept failure / simulator). The candidate set
        /// is the UNFILTERED description+date matches, so the review view MUST
        /// start with NOTHING pre-selected and offer a retry.
        case unavailable
    }

    /// Run the friend's BUILD step for a request: search THEIR library for the
    /// description within the date window, then apply the face filter (accepting
    /// the ephemeral face share + matching it against the friend's own people
    /// clusters when needed). Returns candidate asset IDs for the REVIEW grid —
    /// the friend always reviews + deselects before anything is shared.
    ///
    /// Inert in tests / on the simulator: the CloudKit accept short-circuits on
    /// availability and `runningTests`. CRUCIALLY, when a `.onlyMe`/`.withoutMe`
    /// filter is requested but its embedding can't be obtained, we do NOT silently
    /// degrade to the UNFILTERED set as the review candidates — that would let an
    /// `.onlyMe` request default to pre-selecting EVERYTHING. Instead we return
    /// `.unavailable` so the review view starts with nothing selected and offers a
    /// retry. The PhotoStore search itself is pure on-device logic.
    func fulfill(request: PhotoRequest) async -> FulfillResult {
        let store = PhotoStore.shared
        let matches = store.photosMatching(
            description: request.requestDescription,
            from: request.startDate,
            to: request.endDate)

        // No face filter requested → matches as-is, status `.notRequested`.
        guard request.faceFilter.needsFace, let url = request.faceShareURL else {
            return FulfillResult(request: request,
                                 candidateAssetIDs: matches.map(\.assetID),
                                 faceFilterStatus: .notRequested)
        }

        // Accept the ephemeral face share and read the requester's embedding.
        // Gated: never reach CloudKit at launch / in tests.
        var embedding: [Float] = []
        if !Self.runningTests {
            await cloud.accountStatus()
            if cloud.isAvailable {
                embedding = (try? await directory.acceptFaceShare(url: url)) ?? []
            }
        }

        // Couldn't obtain the embedding → the requested face filter is
        // UNAVAILABLE. Return the unfiltered matches as the *candidate pool* (so a
        // retry can refine, or the friend can pick manually) but flag the status
        // so the review view starts with NOTHING pre-selected and shows a clear
        // "couldn't apply the face filter — tap to retry" message. We never
        // pre-select an over-broad set for a filter that didn't actually apply.
        guard !embedding.isEmpty else {
            return FulfillResult(request: request,
                                 candidateAssetIDs: matches.map(\.assetID),
                                 faceFilterStatus: .unavailable)
        }

        let filtered = store.applyFaceFilter(
            request.faceFilter, to: matches, requesterEmbedding: embedding)
        return FulfillResult(request: request,
                             candidateAssetIDs: filtered.map(\.assetID),
                             faceFilterStatus: .applied)
    }

    /// Mark a request handled after the friend has shared the built album back (or
    /// after they explicitly finish). Keeps it out of the inbox going forward.
    func markFulfilled(_ request: PhotoRequest) {
        markHandled(request)
    }

    // MARK: - Subscription registration (silent push for the inbox)

    /// Register the request-inbox query subscription if not already done this
    /// launch. Idempotent and gated: skips in tests, when iCloud is unavailable,
    /// or once already done. Registers for remote notifications so the silent push
    /// is delivered (mirrors InvitationStore). Called from the view `.task`, never
    /// at launch.
    func registerRequestSubscriptionIfNeeded() async {
        guard !Self.runningTests else { return }
        guard !subscriptionRegistered else { return }
        guard InvitationStore.shared.myProfile != nil else { return }   // no inbox without a profile
        await cloud.accountStatus()
        guard cloud.isAvailable else { return }
        UIApplication.shared.registerForRemoteNotifications()
        do {
            try await directory.registerRequestSubscription()
            subscriptionRegistered = true
        } catch {
            #if DEBUG
            print("[Requests] subscription registration failed: \(error)")
            #endif
        }
    }

    // MARK: - Image helpers (pure, on-device)

    /// Downscale + JPEG-re-encode image bytes so the longest side is ≤ maxPixel.
    /// Returns nil if the bytes can't be decoded. Used for the compact local
    /// private face photo and the small public avatar.
    nonisolated static func downscaledJPEG(_ data: Data, maxPixel: CGFloat) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let longest = max(image.size.width, image.size.height)
        guard longest > 0 else { return nil }
        let scale = min(1, maxPixel / longest)
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1
        let rendered = UIGraphicsImageRenderer(size: target, format: fmt).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return rendered.jpegData(compressionQuality: 0.9)
    }

    /// Bake EXIF orientation into the pixels before ML inference, identical to
    /// the Indexer's path — portrait photos otherwise arrive rotated 90°, which
    /// degrades face detection and was the source of the historical flip bug.
    nonisolated static func orientedUpCGImage(_ img: UIImage) -> CGImage? {
        guard img.imageOrientation != .up else { return img.cgImage }
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1
        let rendered = UIGraphicsImageRenderer(size: img.size, format: fmt).image { _ in
            img.draw(in: CGRect(origin: .zero, size: img.size))
        }
        return rendered.cgImage
    }
}
