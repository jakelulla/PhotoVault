import Photos
import SwiftUI
import UIKit

// MARK: - Background ML worker

/// Runs CoreML inference on a non-main-actor executor so the UI stays responsive.
/// Receives raw image Data (Sendable) and returns PhotoMLResult.
private actor MLWorker {
    func process(imageData: Data) throws -> PhotoMLResult {
        guard let uiImage = UIImage(data: imageData),
              let cgImage = Self.orientedUpCGImage(uiImage) else {
            throw MLWorkerError.invalidImage
        }
        return try OnDeviceMLEngine.shared.process(cgImage: cgImage)
    }

    /// `UIImage(data:).cgImage` is the raw sensor bitmap — portrait iPhone
    /// photos arrive rotated 90° with an EXIF orientation flag. Feeding that
    /// to SCRFD means sideways faces (worse detection/landmarks) and face
    /// rects stored in rotated coordinates that don't match how
    /// PHImageManager later displays the photo. Bake the orientation in
    /// before inference so pixels and stored rects are both display-oriented.
    private static func orientedUpCGImage(_ img: UIImage) -> CGImage? {
        guard img.imageOrientation != .up else { return img.cgImage }
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1
        let rendered = UIGraphicsImageRenderer(size: img.size, format: fmt).image { _ in
            img.draw(in: CGRect(origin: .zero, size: img.size))
        }
        return rendered.cgImage
    }

    /// Video path: CLIP-embed every sampled frame, keeping each frame's
    /// embedding (per-frame search) plus their L2-renormed mean as the
    /// primary embedding, and collect faces from all frames. A video then
    /// matches a caption search if any part of it does, and everyone in it
    /// lands in People. One bad frame (decode/inference failure) doesn't
    /// sink the video — the result succeeds if any frame embedded.
    func processFrames(_ frameDatas: [Data]) throws -> PhotoMLResult {
        var frameClips: [[Float]] = []
        var faceEmbs: [[Float]] = []
        var rects: [CGRect] = []
        var faceSharp: [Float] = []
        var imageSharp: Float?
        for data in frameDatas {
            guard !data.isEmpty,
                  let ui = UIImage(data: data),
                  let cg = Self.orientedUpCGImage(ui),
                  let r = try? OnDeviceMLEngine.shared.process(cgImage: cg) else {
                // Keep frame slots index-parallel with the sampler's timing:
                // silently dropping a failed frame would shift every later
                // frame and make MomentHit.time (frame i of n at
                // duration×(i+0.5)/n) reconstruct the wrong timestamp — the
                // reel would seek a segment that doesn't contain the match.
                // An empty embedding pads the slot; every consumer
                // (clipScore, videoMoments, duplicate checks, categories)
                // already skips empty frames.
                frameClips.append([])
                continue
            }
            frameClips.append(r.clipEmbedding)
            faceEmbs.append(contentsOf: r.faceEmbeddings)
            rects.append(contentsOf: r.faceRects)
            // Face sharpness must stay index-parallel with faceEmbs across
            // frames — pad with zeros if a frame's counts ever disagree so
            // one bad frame can't shift every later face's score.
            let sharp = r.faceSharpness.count == r.faceEmbeddings.count
                ? r.faceSharpness
                : [Float](repeating: 0, count: r.faceEmbeddings.count)
            faceSharp.append(contentsOf: sharp)
            // Whole-video sharpness: first decodable frame's score. Good
            // enough for ranking — frames of one video share focus quality
            // far more than frames across videos do.
            if imageSharp == nil { imageSharp = r.imageSharpness }
        }
        // Mean over the frames that actually embedded (padded empty slots
        // carry no signal); the result succeeds if any frame embedded.
        let embedded = frameClips.filter { !$0.isEmpty }
        guard var clip = embedded.first else { throw MLWorkerError.invalidImage }
        for emb in embedded.dropFirst() {
            for i in 0..<min(clip.count, emb.count) {
                clip[i] += emb[i]
            }
        }
        let norm = sqrt(clip.reduce(0) { $0 + $1 * $1 }) + 1e-10
        return PhotoMLResult(clipEmbedding: clip.map { $0 / norm },
                             clipFrameEmbeddings: frameClips,
                             faceEmbeddings: faceEmbs,
                             faceRects: rects,
                             faceSharpness: faceSharp,
                             imageSharpness: imageSharp ?? 0)
    }

    enum MLWorkerError: Error { case invalidImage }
}

// MARK: - Indexer

/// Walks the device's photo library and indexes every photo entirely on-device
/// using CoreML (CLIP + SCRFD + ArcFace). Results go straight into PhotoStore —
/// no backend or network upload required.
@MainActor
final class Indexer: ObservableObject {
    @Published private(set) var total      = 0
    @Published private(set) var processed  = 0
    @Published private(set) var enqueueing = false

    private var isRunning    = false
    private var pendingRerun = false
    /// One worker per pipeline slot: fetch/decode of one photo overlaps model
    /// inference of another, keeping both the CPU and the Neural Engine busy.
    /// MLModel.prediction is thread-safe, so concurrent workers share the
    /// engine's loaded models.
    private let workers  = [MLWorker(), MLWorker(), MLWorker()]

    // MARK: - Failure ledger

    /// Assets that keep failing (corrupt originals, undecodable frames,
    /// permanently-stuck iCloud downloads) would otherwise be retried on
    /// every launch forever, and `processed` could never reach `total`.
    /// Track attempts per asset; after `maxFailureAttempts` the asset is
    /// skipped until a manual re-index (resetTracking) clears the ledger.
    private static let maxFailureAttempts = 3
    private static let failuresURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let d = docs.appendingPathComponent("photosearch", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("index_failures.json")
    }()
    /// assetID → failed attempt count, loaded once and persisted at the end
    /// of each index pass.
    private lazy var failureCounts: [String: Int] = {
        guard let data = try? Data(contentsOf: Self.failuresURL),
              let counts = try? JSONDecoder().decode([String: Int].self, from: data)
        else { return [:] }
        return counts
    }()
    private var failuresDirty = false

    private func recordFailure(_ assetID: String) {
        failureCounts[assetID, default: 0] += 1
        failuresDirty = true
    }

    private func clearFailure(_ assetID: String) {
        if failureCounts.removeValue(forKey: assetID) != nil { failuresDirty = true }
    }

    private func saveFailuresIfNeeded() {
        guard failuresDirty else { return }
        failuresDirty = false
        if let data = try? JSONEncoder().encode(failureCounts) {
            try? data.write(to: Self.failuresURL, options: .atomic)
        }
    }

    /// Indexes every not-yet-indexed asset. Safe to call repeatedly (launch,
    /// library-change notifications): overlapping calls coalesce into one
    /// extra pass after the current run, so assets inserted mid-run still get
    /// picked up. A cancelled run (expired background window) does not rerun.
    func indexNewPhotos(from library: PhotoLibraryModel) async {
        if isRunning { pendingRerun = true; return }
        isRunning = true
        defer { isRunning = false }

        repeat {
            pendingRerun = false
            await runIndexPass(from: library)
        } while pendingRerun && !Task.isCancelled

        // Newly indexed photos carry face/sharpness data inline; photos
        // indexed before the feature existed get it backfilled once the
        // pipeline is quiet. Unstructured Task on purpose: awaiting here
        // would hold the indexer "running" through the whole backfill, so a
        // library change during it would set pendingRerun after the loop
        // already exited and never get consumed. The backfill self-guards
        // against overlapping runs and is a no-op when nothing is missing.
        if !Task.isCancelled {
            Task { await SharpnessBackfill.shared.runIfNeeded(library: library) }
        }
    }

    private func runIndexPass(from library: PhotoLibraryModel) async {
        let ml    = OnDeviceMLEngine.shared
        let store = PhotoStore.shared

        if !ml.isAvailable {
            do { try ml.loadModels() } catch { }
        }
        let mlAvailable = ml.isAvailable

        // Capped-failure assets count as "done" so progress can complete.
        let unindexed = library.assets.filter {
            !store.contains(assetID: $0.localIdentifier)
                && failureCounts[$0.localIdentifier, default: 0] < Self.maxFailureAttempts
        }
        total     = library.assets.count
        processed = library.assets.count - unindexed.count

        guard !unindexed.isEmpty else { return }
        enqueueing = true
        defer { enqueueing = false }

        let bgTask = await UIApplication.shared.beginBackgroundTask(withName: "local-index")
        defer { Task { await UIApplication.shared.endBackgroundTask(bgTask) } }

        if mlAvailable {
            // Pipelined indexing: up to `workers.count` photos in flight.
            // Image fetch + JPEG decode (CPU/IO-bound) of the next photos
            // overlaps model inference (ANE-bound) of the current ones.
            // 1280px is plenty for inference (SCRFD's input is 640px, CLIP's
            // 224px, and faces keep 2× headroom for alignment) — decoding the
            // full 12–48MP original was a large fraction of per-photo time.
            // PHImageManager also returns it already orientation-corrected.
            let width = min(workers.count, unindexed.count)
            await withTaskGroup(of: (PHAsset, PhotoMLResult?).self) { group in
                var nextIndex = 0
                func enqueue() {
                    guard nextIndex < unindexed.count else { return }
                    let asset  = unindexed[nextIndex]
                    let worker = workers[nextIndex % workers.count]
                    nextIndex += 1
                    group.addTask {
                        if asset.mediaType == .video {
                            let frames = await library.videoFrameData(for: asset)
                            guard !frames.isEmpty else { return (asset, nil) }
                            return (asset, try? await worker.processFrames(frames))
                        }
                        guard let data = await library.thumbnailData(for: asset, maxPixel: 1280)
                        else { return (asset, nil) }
                        return (asset, try? await worker.process(imageData: data))
                    }
                }
                for _ in 0..<width { enqueue() }

                for await (asset, result) in group {
                    if let result {
                        store.index(
                            assetID:             asset.localIdentifier,
                            createdAt:           asset.creationDate,
                            lat:                 asset.location?.coordinate.latitude,
                            lon:                 asset.location?.coordinate.longitude,
                            clipEmbedding:       result.clipEmbedding,
                            faceEmbeddings:      result.faceEmbeddings,
                            faceRects:           result.faceRects,
                            isVideo:             asset.mediaType == .video,
                            duration:            asset.duration,
                            clipFrameEmbeddings: result.clipFrameEmbeddings,
                            faceSharpness:       result.faceSharpness,
                            imageSharpness:      result.imageSharpness
                        )
                        clearFailure(asset.localIdentifier)
                    } else if !Task.isCancelled {
                        // Cancellation makes in-flight fetches return nil —
                        // don't charge the asset a strike for that.
                        recordFailure(asset.localIdentifier)
                    }
                    processed += 1
                    // Cooperative cancellation: a BGProcessingTask's
                    // expiration handler cancels the surrounding Task; stop
                    // feeding the pipeline, drain what's in flight, and keep
                    // the progress made so far (store persists below).
                    if !Task.isCancelled { enqueue() }
                }
            }
        } else {
            // Simulator: no CoreML models — index metadata only.
            // Small sleep so the progress bar is visible during UI testing.
            for asset in unindexed {
                if Task.isCancelled { break }
                store.index(
                    assetID:        asset.localIdentifier,
                    createdAt:      asset.creationDate,
                    lat:            asset.location?.coordinate.latitude,
                    lon:            asset.location?.coordinate.longitude,
                    clipEmbedding:  [],
                    faceEmbeddings: [],
                    faceRects:      []
                )
                try? await Task.sleep(nanoseconds: 3_000_000) // 3 ms/photo ≈ 4 s total
                processed += 1
            }
        }
        await store.persistAndWait()  // include the off-main embeddings flush
        saveFailuresIfNeeded()

        // Global re-cluster after a substantial batch (mirrors the backend:
        // small increments use the live greedy assignment; big batches get
        // the full DBSCAN pass, which fixes greedy's order-dependent splits).
        // ~1s per 30k faces on M-series; a few seconds on the phone.
        if mlAvailable && !Task.isCancelled && unindexed.count >= 25 {
            await store.reclusterPeople()
        }
    }

    func resetTracking() {
        PhotoStore.shared.resetIndex()
        // A manual re-index is the user asking for another shot at
        // everything — including assets the failure cap had given up on.
        failureCounts = [:]
        failuresDirty = false
        try? FileManager.default.removeItem(at: Self.failuresURL)
        processed = 0; total = 0
    }
}
