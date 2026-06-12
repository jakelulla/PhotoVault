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

    /// Video path: CLIP-embed every sampled frame and average (L2-renormed),
    /// collect faces from all frames. A video then matches a caption search
    /// if any part of it does, and everyone in it lands in People.
    func processFrames(_ frameDatas: [Data]) throws -> PhotoMLResult {
        var clip: [Float] = []
        var faceEmbs: [[Float]] = []
        var rects: [CGRect] = []
        for data in frameDatas {
            guard let ui = UIImage(data: data),
                  let cg = Self.orientedUpCGImage(ui) else { continue }
            let r = try OnDeviceMLEngine.shared.process(cgImage: cg)
            if clip.isEmpty {
                clip = r.clipEmbedding
            } else {
                for i in 0..<min(clip.count, r.clipEmbedding.count) {
                    clip[i] += r.clipEmbedding[i]
                }
            }
            faceEmbs.append(contentsOf: r.faceEmbeddings)
            rects.append(contentsOf: r.faceRects)
        }
        guard !clip.isEmpty else { throw MLWorkerError.invalidImage }
        let norm = sqrt(clip.reduce(0) { $0 + $1 * $1 }) + 1e-10
        return PhotoMLResult(clipEmbedding: clip.map { $0 / norm },
                             faceEmbeddings: faceEmbs,
                             faceRects: rects)
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
    }

    private func runIndexPass(from library: PhotoLibraryModel) async {
        let ml    = OnDeviceMLEngine.shared
        let store = PhotoStore.shared

        if !ml.isAvailable {
            do { try ml.loadModels() } catch { }
        }
        let mlAvailable = ml.isAvailable

        let unindexed = library.assets.filter { !store.contains(assetID: $0.localIdentifier) }
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
                            assetID:        asset.localIdentifier,
                            createdAt:      asset.creationDate,
                            lat:            asset.location?.coordinate.latitude,
                            lon:            asset.location?.coordinate.longitude,
                            clipEmbedding:  result.clipEmbedding,
                            faceEmbeddings: result.faceEmbeddings,
                            faceRects:      result.faceRects,
                            isVideo:        asset.mediaType == .video,
                            duration:       asset.duration
                        )
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
        store.persist()

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
        processed = 0; total = 0
    }
}
