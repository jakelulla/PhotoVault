import Foundation
import os
import Photos
import UIKit

/// Backfills per-photo face data (`LocalPhoto.faces`) and sharpness scores
/// for photos indexed BEFORE those fields existed — without re-running the
/// ML pipeline. The expensive part of indexing (detection + embedding) was
/// already done once: every face's ArcFace embedding and rect live in the
/// append-only on-disk log, so cluster membership per face is recovered by
/// matching logged embeddings against current cluster prototypes. Only the
/// cheap CoreGraphics sharpness pass needs the pixels again, fetched at the
/// SAME 1280px the indexer analyzes: the 128×128 Laplacian crops the face
/// region from the source thumbnail first, so a lower-res source would
/// upsample small faces (smoothing away high frequencies) and make backfilled
/// scores systematically lower than inline ones — not comparable.
///
/// Idempotent and safe to re-trigger: the work set is "photos still missing
/// data", so a finished library is a no-op. Cancellation (view teardown,
/// app suspension) stops cleanly mid-stream — progress already written is
/// persisted and the rest is picked up next run. Progress goes to os_log,
/// not UI: this is invisible maintenance, not a user-facing job.
@MainActor
final class SharpnessBackfill {
    static let shared = SharpnessBackfill()
    private init() {}

    private static let logger = Logger(subsystem: "PhotoSearch", category: "SharpnessBackfill")

    /// The same file PhotoStore's private faceLog writes
    /// (documents/photosearch/face_embeddings.bin). Reading through a second
    /// handle is safe: records are append-only and the reader stops at the
    /// first torn record, so a concurrent index append loses us at most the
    /// tail — which belongs to a freshly indexed photo that already carries
    /// its face data inline and is never in our work set.
    private static let faceLogURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("photosearch", isDirectory: true)
            .appendingPathComponent("face_embeddings.bin")
    }()

    /// Overlapping triggers (launch task + every index pass) coalesce into
    /// the run already in flight — its work set covers theirs.
    private var isRunning = false

    func runIfNeeded(library: PhotoLibraryModel) async {
        guard !isRunning, !Task.isCancelled else { return }
        isRunning = true
        defer { isRunning = false }

        let store = PhotoStore.shared
        // faces == nil distinguishes "indexed pre-feature" from "processed,
        // no faces" ([] — index() and this backfill both write [] for
        // face-less photos), so finished photos drop out of the work set.
        let work = store.photos.filter {
            !$0.isDeleted
                && (($0.faces == nil && !$0.personClusterIDs.isEmpty) || $0.sharpness == nil)
        }
        guard !work.isEmpty else { return }
        Self.logger.info("Backfill starting: \(work.count) photos")

        // -- Phase 1: face → cluster matching from the on-disk embedding log.
        // One streaming pass off the main actor. Only the tiny (clusterID,
        // rect) results are kept — the 512-float embeddings (one per face
        // ever indexed, tens of MB at large libraries) are dropped record by
        // record as they're matched.
        let needFaceIDs = Set(work.lazy.filter { $0.faces == nil }.map(\.assetID))
        // Deleted clusters are excluded — matching a face back to a person
        // the user removed would resurrect them in person-centric features.
        // Merged clusters stay in: the raw best id is stored and queries
        // resolve it through resolvedClusterID, same as personClusterIDs.
        //
        // The epoch pins the cluster ID space these prototypes belong to: a
        // recluster or resetIndex mid-run renumbers clusters from 0, so any
        // match still in flight would attach faces to whatever NEW cluster
        // reuses the old ID — a different person. Checked before every write.
        let epoch = store.clusterEpoch
        let prototypes: [(id: Int, prototype: [Float])] = store.clusters
            .filter { !$0.isDeleted && !$0.prototype.isEmpty }
            .map { ($0.id, $0.prototype) }
        let logURL = Self.faceLogURL
        let matchedFaces: [String: [PhotoFace]] = await Task.detached(priority: .utility) {
            guard !needFaceIDs.isEmpty else { return [:] }
            var out: [String: [PhotoFace]] = [:]
            for record in FaceEmbeddingLog(url: logURL).readAll() {
                guard needFaceIDs.contains(record.assetID) else { continue }
                // Last record wins on the (reset-only) chance an asset was
                // logged twice — later records reflect the later index.
                out[record.assetID] = record.faces.map { face in
                    // Best cosine across all prototypes; 0.45 = the live
                    // face-cluster acceptance threshold. Below it the face
                    // stays unassigned (clusterID nil) rather than guessing.
                    var bestID: Int?
                    var best: Float = 0.45
                    for c in prototypes {
                        let sim = PhotoStore.dot(face.embedding, c.prototype)
                        if sim >= best { best = sim; bestID = c.id }
                    }
                    return PhotoFace(clusterID: bestID, rect: face.rect, sharpness: nil)
                }
            }
            return out
        }.value

        if Task.isCancelled { return }

        // -- Phase 2: sharpness needs pixels. ≤2 thumbnail fetches in flight:
        // this runs alongside normal app use (and possibly the indexer), so
        // it must not starve the UI's own PHImageManager requests.
        var assetByID: [String: PHAsset] = [:]
        PHAsset.fetchAssets(withLocalIdentifiers: work.map(\.assetID), options: nil)
            .enumerateObjects { asset, _, _ in assetByID[asset.localIdentifier] = asset }

        var done = 0
        await withTaskGroup(of: (assetID: String, faces: [PhotoFace]?, imageSharpness: Float?).self) { group in
            var next = 0
            func enqueue() {
                guard next < work.count else { return }
                let photo = work[next]
                next += 1
                // nil → faces already present, leave them alone (setFaceData
                // only overwrites non-nil args). Photos with no log entry get
                // [] — "processed, no faces" — so they're marked done.
                let pendingFaces: [PhotoFace]? =
                    photo.faces == nil ? (matchedFaces[photo.assetID] ?? []) : nil
                let asset = assetByID[photo.assetID]
                let needsImage = photo.sharpness == nil
                group.addTask {
                    await Self.processOne(assetID: photo.assetID,
                                          asset: asset,
                                          pendingFaces: pendingFaces,
                                          needsImageSharpness: needsImage,
                                          library: library)
                }
            }
            for _ in 0..<min(2, work.count) { enqueue() }

            for await result in group {
                // Stale-snapshot guards before each write. (1) clusterEpoch:
                // a recluster/reset mid-run renumbered the ID space, so face
                // matches from the prototype snapshot now point at the wrong
                // people — drop them (the photo keeps faces == nil and the
                // next run re-matches against the new prototypes; sharpness
                // is content-derived and stays valid). (2) live faces check:
                // resetIndex + re-index repopulates the SAME assetIDs with
                // fresh inline face data — the work-set snapshot saw
                // faces == nil, but the current photo may not. Never clobber
                // fresh data with pre-reset matches.
                let faceWriteOK = store.clusterEpoch == epoch
                    && store.photo(forAssetID: result.assetID)?.faces == nil
                store.setFaceData(assetID: result.assetID,
                                  faces: faceWriteOK ? result.faces : nil,
                                  imageSharpness: result.imageSharpness)
                done += 1
                // The 3s persist debounce never fires while results stream in
                // every few hundred ms (each setFaceData resets it) — force a
                // flush every 200 photos, exactly like index(), so a mid-run
                // kill loses at most the last batch instead of hours of
                // progress AND any unrelated user edits sharing the debounce.
                if done % 200 == 0 { store.persist() }
                if done % 250 == 0 {
                    Self.logger.info("Backfill progress: \(done)/\(work.count)")
                }
                // Breathe between photos — the UI's main-actor work first.
                await Task.yield()
                if !Task.isCancelled { enqueue() }
                // Cancelled: stop feeding, drain the ≤2 in flight, fall
                // through to the persist below with partial progress intact.
            }
        }

        // setFaceData schedules debounced persists along the way; this final
        // explicit flush covers the tail (and the cancelled-early case).
        await store.persistAndWait()
        Self.logger.info("Backfill \(Task.isCancelled ? "cancelled" : "finished"): \(done)/\(work.count) photos")
    }

    /// One photo's pixel work, off the main actor (task-group child).
    private nonisolated static func processOne(
        assetID: String,
        asset: PHAsset?,
        pendingFaces: [PhotoFace]?,
        needsImageSharpness: Bool,
        library: PhotoLibraryModel
    ) async -> (assetID: String, faces: [PhotoFace]?, imageSharpness: Float?) {
        // Asset missing from the fetch. Only under FULL authorization does
        // that mean "gone for good" (deleted/hidden) — then mark it done
        // (sharpness 0; the photo can't be displayed anyway) instead of
        // re-attempting on every run forever. Under .limited access the
        // fetch only sees the current selection, so a photo outside it is
        // merely unfetchable right now: stamping 0 would permanently drop it
        // from the work set even after access is re-granted. Leave nil so
        // the next run retries. (Same guard LibraryBrowseView uses before
        // treating fetch-absence as deletion.)
        guard let asset else {
            let goneForGood = PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized
            return (assetID, pendingFaces, (needsImageSharpness && goneForGood) ? 0 : nil)
        }
        // 1280px — the indexer's inference resolution. Sharpness scores must
        // be comparable across the two producers (growthTimeline ranks them
        // against each other); a 512px source upsamples small face crops
        // into the 128×128 analysis and deflates their scores.
        guard !Task.isCancelled,
              let data = await library.thumbnailData(for: asset, maxPixel: 1280),
              let ui = UIImage(data: data),
              let cg = orientedUpCGImage(ui)
        else {
            // Transient failure (stuck iCloud download, decode error) or
            // cancellation: keep the cluster faces — they're correct and
            // expensive to recompute — but leave sharpness nil so the next
            // run retries just the pixel pass.
            return (assetID, pendingFaces, nil)
        }
        // sharpness() is pure CoreGraphics — works with no models loaded
        // (simulator included), so the backfill never depends on CoreML.
        let engine = OnDeviceMLEngine.shared
        let imageSharpness: Float? = needsImageSharpness
            ? engine.sharpness(of: cg, normalizedRegion: nil) : nil
        let faces: [PhotoFace]? = pendingFaces.map { faces in
            faces.map { face in
                var f = face
                // A zero rect means rect pairing failed at log time — no
                // region to score, leave sharpness nil.
                if f.rect.count == 4, f.rect[2] > 0, f.rect[3] > 0 {
                    f.sharpness = engine.sharpness(
                        of: cg,
                        normalizedRegion: CGRect(x: f.rect[0], y: f.rect[1],
                                                 width: f.rect[2], height: f.rect[3]))
                }
                return f
            }
        }
        return (assetID, faces, imageSharpness)
    }

    /// Logged face rects are display-oriented (the indexer bakes EXIF
    /// orientation in before detection), so bake it here too or rect →
    /// pixel mapping breaks on rotated photos. Mirrors MLWorker's private
    /// helper in Indexer.swift.
    private nonisolated static func orientedUpCGImage(_ img: UIImage) -> CGImage? {
        guard img.imageOrientation != .up else { return img.cgImage }
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1
        let rendered = UIGraphicsImageRenderer(size: img.size, format: fmt).image { _ in
            img.draw(in: CGRect(origin: .zero, size: img.size))
        }
        return rendered.cgImage
    }
}
