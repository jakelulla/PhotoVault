import AVFoundation
import Photos
import SwiftUI

/// Photo-library authorization + access to the device's photos. The Photos tab
/// shows these immediately; the Indexer ships them to the Mac for embedding.
@MainActor
final class PhotoLibraryModel: NSObject, ObservableObject {
    @Published var status: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @Published var assets: [PHAsset] = []
    /// Bumped whenever the system library gains or loses assets (photo taken,
    /// deletion, iCloud sync) — ContentView watches it to kick a fresh index pass.
    @Published private(set) var libraryChangeToken = 0

    private let imageManager = PHCachingImageManager()
    /// Live fetch result the change observer diffs against.
    private var fetchResult: PHFetchResult<PHAsset>?

    /// Upper bound (seconds) on a single iCloud photo/thumbnail download in the
    /// shared-album upload path. Past this we cancel the PHImageManager request
    /// so a stuck "Optimize iPhone Storage" original resolves to nil (skip that
    /// asset) instead of hanging the whole "Adding photos…" flow. Generous
    /// enough for a real original over cellular; short enough to not wedge.
    private static let iCloudDownloadTimeout: TimeInterval = 30

    /// Shared, observer-free instance used purely for byte extraction by the
    /// shared-albums uploader (fullImageData / thumbnailData). It does NOT
    /// register a library change observer (it skips the designated init), so it
    /// is cheap and never fires UI updates — it's just a wrapper around its own
    /// PHCachingImageManager. Created lazily on first upload; never at launch.
    static let uploadHelper: PhotoLibraryModel = PhotoLibraryModel(observing: false)

    override init() {
        super.init()
        observingLibrary = true
        PHPhotoLibrary.shared().register(self)
    }

    /// Observer-free init for the upload helper: no change observer is
    /// registered, so this instance never publishes UI updates and `deinit`
    /// skips the matching unregister.
    private init(observing: Bool) {
        super.init()
        observingLibrary = observing
        if observing { PHPhotoLibrary.shared().register(self) }
    }

    /// Whether this instance registered a change observer (so deinit knows
    /// whether to unregister). Avoids unregistering an observer we never added.
    private var observingLibrary = false

    deinit {
        if observingLibrary { PHPhotoLibrary.shared().unregisterChangeObserver(self) }
    }

    var isAuthorized: Bool { status == .authorized || status == .limited }

    func refreshStatus() {
        status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if isAuthorized && assets.isEmpty { fetchAssets() }
    }

    func requestAccess() {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] newStatus in
            Task { @MainActor in
                guard let self else { return }
                self.status = newStatus
                if self.isAuthorized { self.fetchAssets() }
            }
        }
    }

    func fetchAssets() {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(format: "mediaType == %d OR mediaType == %d",
                                        PHAssetMediaType.image.rawValue,
                                        PHAssetMediaType.video.rawValue)
        let result = PHAsset.fetchAssets(with: options)
        fetchResult = result
        var fetched: [PHAsset] = []
        fetched.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in fetched.append(asset) }
        assets = fetched
    }

    /// Applies a Photos change notification: swaps in the post-change fetch
    /// result, refreshes `assets`, prunes deleted photos from the index, and
    /// bumps `libraryChangeToken` so new photos get indexed.
    private func applyLibraryChange(_ change: PHChange) {
        guard let fetchResult,
              let details = change.changeDetails(for: fetchResult) else { return }
        let after = details.fetchResultAfterChanges
        self.fetchResult = after

        var fetched: [PHAsset] = []
        fetched.reserveCapacity(after.count)
        after.enumerateObjects { asset, _, _ in fetched.append(asset) }

        let inserted: Bool
        let removedIDs: Set<String>
        if details.hasIncrementalChanges {
            inserted   = !details.insertedObjects.isEmpty
            removedIDs = Set(details.removedObjects.map(\.localIdentifier))
        } else {
            // No per-object diff available (huge change) — compare identifier
            // sets so deletions still get pruned from the index.
            let oldIDs = Set(assets.map(\.localIdentifier))
            let newIDs = Set(fetched.map(\.localIdentifier))
            inserted   = !newIDs.subtracting(oldIDs).isEmpty
            removedIDs = oldIDs.subtracting(newIDs)
        }
        assets = fetched

        // Only prune (which irreversibly strips folder membership) under full
        // access. Under .limited the fetch only sees the user-selected subset,
        // so a removed entry means "left the selection", not "deleted from the
        // library" — pruning it would discard folder membership with no record
        // to restore it. Mirrors LibraryBrowseView.prepareSync and
        // SharpnessBackfill's goneForGood guard.
        let fullAccess = PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized
        if fullAccess && !removedIDs.isEmpty {
            PhotoStore.shared.pruneDeletedAssets(removedIDs)
        }
        // Still bump the token on insertions so newly-selected photos index.
        if inserted || !removedIDs.isEmpty {
            libraryChangeToken += 1
        }
    }

    func requestImage(for asset: PHAsset, targetSize: CGSize, contentMode: PHImageContentMode,
                      completion: @escaping (UIImage?) -> Void) {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        imageManager.requestImage(for: asset, targetSize: targetSize, contentMode: contentMode,
                                  options: options) { image, _ in completion(image) }
    }

    /// Full-resolution image for the full-screen viewer (sharp, zoomable).
    /// `.highQualityFormat` returns the full original once (downloading from
    /// iCloud if needed), rather than a cached thumbnail.
    func requestFullImage(for asset: PHAsset, completion: @escaping (UIImage?) -> Void) {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .none
        imageManager.requestImage(
            for: asset,
            targetSize: PHImageManagerMaximumSize,
            contentMode: .aspectFit,
            options: options
        ) { image, info in
            // Ignore the degraded placeholder; only show the final full image.
            let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            if let image, !degraded { completion(image) }
        }
    }

    /// Evenly spaced frames from a video — about one per 10 seconds of
    /// footage (1…8 frames, sampled at the midpoint of equal segments) —
    /// JPEG-encoded at ≤1280px. The indexer CLIP-embeds each frame so a
    /// video is findable by anything that appears in it, and faces are
    /// picked up from every sampled frame.
    func videoFrameData(for asset: PHAsset, maxPixel: CGFloat = 1280) async -> [Data] {
        let state = PHRequestCancellationState(manager: PHImageManager.default())
        let avAsset: AVAsset? = await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                let opts = PHVideoRequestOptions()
                opts.isNetworkAccessAllowed = true
                opts.deliveryMode = .mediumQualityFormat
                let id = PHImageManager.default().requestAVAsset(forVideo: asset, options: opts) { av, _, _ in
                    // Cancel + completion can race; only the first one resumes.
                    guard state.takeResume() else { return }
                    cont.resume(returning: av)
                }
                state.register(id)
                // Timeout backstop. A stuck iCloud-offline video fetch can
                // otherwise stall this continuation forever and hang the whole
                // foreground index pass. The one-shot flag keeps the
                // continuation single-resume; the losing request is CANCELLED,
                // not abandoned, so its download stops grinding. Mirrors
                // ReelAssetLoader.avAsset in MomentReelView.
                DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
                    if state.takeResume() {
                        cont.resume(returning: nil)
                        state.cancel()
                    }
                }
            }
        } onCancel: {
            state.cancel()
        }
        guard let avAsset else { return [] }
        let gen = AVAssetImageGenerator(asset: avAsset)
        gen.appliesPreferredTrackTransform = true   // bakes in rotation metadata
        gen.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        let duration = asset.duration > 0 ? asset.duration
            : ((try? await avAsset.load(.duration).seconds) ?? 0)
        // ~1 frame per 10s, clamped to 1 (short clips) … 8 (long videos),
        // each taken at the midpoint of an equal segment so coverage stays
        // even at any length (a single frame lands at 50%, as before).
        let count = max(1, min(8, Int((duration / 10).rounded(.up))))
        let fractions = (0..<count).map { (Double($0) + 0.5) / Double(count) }
        var frames: [Data] = []
        for f in fractions {
            // An expiring background task cancels mid-run. Return [] (not
            // partial frames): a partially sampled video would be indexed
            // permanently with reduced coverage, and contains() blocks any
            // re-index. Failing cleanly lets the next window do it fully.
            if Task.isCancelled { return [] }
            let t = CMTime(seconds: max(0, duration * f), preferredTimescale: 600)
            if let cg = try? await gen.image(at: t).image,
               let jpeg = UIImage(cgImage: cg).jpegData(compressionQuality: 0.85) {
                frames.append(jpeg)
            } else {
                // Placeholder keeps the array index-parallel with the sampled
                // fractions: timing reconstruction (MomentHit.time) assumes
                // frame i of n sits at duration×(i+0.5)/n, so a silently
                // dropped frame would shift every later frame's timestamp.
                // MLWorker.processFrames pads an empty embedding for it.
                frames.append(Data())
            }
        }
        // All slots failed → treat as a whole-video failure, same as before.
        return frames.allSatisfy(\.isEmpty) ? [] : frames
    }

    /// Full-resolution JPEG bytes for a single asset, for uploading to a shared
    /// album. Uses `requestImageDataAndOrientation` (the original on-disk
    /// representation) so we ship the real photo, transcoding to JPEG when the
    /// source isn't already JPEG/HEIC-decodable. `.highQualityFormat` yields a
    /// single non-degraded callback; cancellation aborts a stuck iCloud
    /// download. Returns nil if the asset/bytes are unavailable. Mirrors the
    /// one-shot continuation safety used elsewhere in this file.
    func fullImageData(for asset: PHAsset) async -> Data? {
        let state = PHRequestCancellationState(manager: imageManager)
        // Watchdog: if a (possibly iCloud) download stalls — or Photos ever
        // delivers ONLY a degraded callback — cancel the request after a bound
        // so PHImageManager fires its terminal (nil) callback and the
        // continuation resolves nil instead of hanging the upload forever.
        let watchdog = Task { [weak state] in
            try? await Task.sleep(for: .seconds(Self.iCloudDownloadTimeout))
            state?.cancel()
        }
        defer { watchdog.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let options = PHImageRequestOptions()
                options.isNetworkAccessAllowed = true
                options.deliveryMode = .highQualityFormat
                options.resizeMode = .none
                options.isSynchronous = false
                let id = imageManager.requestImageDataAndOrientation(
                    for: asset, options: options
                ) { data, _, _, info in
                    let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                    if degraded { return }   // wait for the final, full-quality result
                    guard state.takeResume() else { return }
                    // Normalize to JPEG: HEIC originals re-encode for broad
                    // compatibility; an already-JPEG original round-trips cheaply.
                    if let data, let image = UIImage(data: data) {
                        continuation.resume(returning: image.jpegData(compressionQuality: 0.92))
                    } else {
                        continuation.resume(returning: data)
                    }
                }
                state.register(id)
            }
        } onCancel: {
            state.cancel()
        }
    }

    /// A downscaled JPEG (longest side ~`maxPixel`) for the one-time metadata
    /// backfill — much cheaper than the full original, and its perceptual hash
    /// still matches the full-res upload so the backend dedups against it.
    /// `.highQualityFormat` yields a single (non-degraded) callback, so the
    /// continuation resumes exactly once. Cancellation aborts the request
    /// (e.g. a stuck iCloud download) so an expiring background task can't
    /// hang past its deadline.
    func thumbnailData(for asset: PHAsset, maxPixel: CGFloat) async -> Data? {
        let state = PHRequestCancellationState(manager: imageManager)
        // Same stall/degraded-only watchdog as fullImageData (see there).
        let watchdog = Task { [weak state] in
            try? await Task.sleep(for: .seconds(Self.iCloudDownloadTimeout))
            state?.cancel()
        }
        defer { watchdog.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let options = PHImageRequestOptions()
                options.isNetworkAccessAllowed = true
                options.deliveryMode = .highQualityFormat
                options.resizeMode = .fast
                let target = CGSize(width: maxPixel, height: maxPixel)
                let id = imageManager.requestImage(for: asset, targetSize: target, contentMode: .aspectFit,
                                                   options: options) { image, info in
                    let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                    if degraded { return }   // wait for the final, full-quality result
                    // Cancel + completion can race; only the first one resumes.
                    guard state.takeResume() else { return }
                    continuation.resume(returning: image?.jpegData(compressionQuality: 0.9))
                }
                state.register(id)
            }
        } onCancel: {
            state.cancel()
        }
    }
}

// MARK: - Library change observation

extension PhotoLibraryModel: PHPhotoLibraryChangeObserver {
    /// Photos delivers changes on an arbitrary queue; hop to the main actor
    /// where the fetch result and published state live.
    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor [weak self] in
            self?.applyLibraryChange(changeInstance)
        }
    }
}

// MARK: - Cancellable PHImageManager requests

/// Lock-guarded bridge between an in-flight PHImageManager request and Swift
/// task cancellation. Cancel and completion fire on different queues, so a
/// single flag behind the lock guarantees the continuation resumes exactly
/// once, and a request ID that arrives after cancellation still gets cancelled.
/// PHImageManager calls the result handler (with nil) even for cancelled
/// requests, so the cancel path never needs to resume the continuation itself.
private final class PHRequestCancellationState: @unchecked Sendable {
    private let manager: PHImageManager
    private let lock = NSLock()
    private var requestID: PHImageRequestID?
    private var cancelled = false
    private var resumed = false

    init(manager: PHImageManager) {
        self.manager = manager
    }

    /// Records the in-flight request, cancelling immediately if the task was
    /// already cancelled before the request call returned its ID.
    func register(_ id: PHImageRequestID) {
        lock.lock()
        requestID = id
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel { manager.cancelImageRequest(id) }
    }

    /// Returns true exactly once — the winner resumes the continuation.
    func takeResume() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if resumed { return false }
        resumed = true
        return true
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let id = requestID
        lock.unlock()
        if let id { manager.cancelImageRequest(id) }
    }
}
