import Accelerate
import CoreLocation
import Photos
import SwiftUI

// MARK: - Data models

/// One detected face on a photo, stored with the photo so person-centric
/// features (growth timelines, best-face picks) can rank faces without
/// re-reading the on-disk face log. `clusterID` is the raw cluster assigned
/// at index/backfill time — resolve through resolvedClusterID at query time
/// so merged people keep working.
struct PhotoFace: Codable, Hashable {
    var clusterID: Int?
    var rect: [Double]           // [x, y, w, h] normalized 0…1
    var sharpness: Float?        // Laplacian variance of the 128×128 grayscale face crop; nil = not yet computed
}

struct LocalPhoto: Identifiable, Codable {
    let assetID: String
    let photoID: Int            // stable Int assigned at index time (for Set-based selection in views)
    var createdAt: Date?
    var lat: Double?
    var lon: Double?
    var locationName: String?
    var personClusterIDs: [Int]
    var dupGroupID: String?     // nil = unique; shared key = duplicate group
    var isDeleted: Bool
    var isVideo: Bool?          // optional for back-compat with pre-video stores
    var duration: Double?       // seconds, videos only
    var faces: [PhotoFace]?     // nil = indexed before per-photo face data existed (backfill fills it)
    var sharpness: Float?       // whole-image sharpness: Laplacian variance of the 128×128 grayscale downsample

    var id: String { assetID }
    var video: Bool { isVideo ?? false }
    var durationText: String {
        let s = Int(duration ?? 0)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    var displayDate: String {
        guard let d = createdAt else { return "" }
        return d.formatted(date: .abbreviated, time: .omitted)
    }
}

struct PersonCluster: Identifiable, Codable, Hashable {
    let id: Int
    var name: String?
    var prototype: [Float]          // 512-dim L2-normalized centroid
    var photoAssetIDs: [String]
    var representativeAssetID: String
    var faceNormalizedRect: [Double] // [x, y, w, h] in 0…1 image-relative coords
    var mergedInto: Int?             // non-nil → this cluster is merged into another
    var isDeleted: Bool

    var displayName: String { name ?? "" }
    var photoCount: Int { photoAssetIDs.count }
    var faceRect: CGRect {
        guard faceNormalizedRect.count == 4 else { return .zero }
        return CGRect(x: faceNormalizedRect[0], y: faceNormalizedRect[1],
                      width: faceNormalizedRect[2], height: faceNormalizedRect[3])
    }
}

struct LocalLocation: Identifiable, Codable, Hashable {
    let name: String
    var alias: String?
    var photoAssetIDs: [String]
    var coverAssetID: String

    var id: String { name }
    var displayName: String { (alias.map { $0.isEmpty ? nil : $0 } ?? nil) ?? name }
    var count: Int { photoAssetIDs.count }
}

struct LocalFolder: Identifiable, Codable {
    let id: String
    var name: String
    var photoAssetIDs: [String]
    /// Non-empty → smart folder: membership is this saved search, re-run on
    /// open, instead of the static photoAssetIDs list.
    var query: String?
    /// Non-nil → embedding-anchored smart folder: membership is a live CLIP
    /// ranking against this photo's embedding, composed with query/minusQuery
    /// (see photosForFolder). All three fields are optional for Codable
    /// back-compat with folders.json written before they existed.
    var anchorAssetID: String?
    /// Comma-separated terms the composite query is steered *away* from.
    var minusQuery: String?
    /// Pinned score floor for the embedding ranking; nil → the calibrated
    /// default (0.55 image-anchored, 0.25 text — see photosForFolder).
    var minScore: Float?

    var isSmart: Bool { !(query ?? "").isEmpty || anchorAssetID != nil }
}

/// One representative face of a person per calendar year — the result row
/// of growthTimeline(forCluster:).
struct YearFace: Identifiable {
    let year: Int
    let assetID: String
    let rect: CGRect?            // normalized face rect; nil → show the whole photo
    let score: Float             // (sharpness ?? 1) × √(face area); 0 for whole-photo fallbacks
    var id: Int { year }
}

/// The best-matching moment inside one video for a text query — the result
/// row of videoMoments(matching:). `time` reconstructs the sampled frame's
/// timestamp with the same formula the sampler uses (PhotoLibraryModel:
/// frame i of n sits at duration × (i + 0.5) / n), so seeking there lands on
/// the content that actually matched.
struct MomentHit: Identifiable {
    let assetID: String
    let frameIndex: Int
    let frameCount: Int
    let score: Float
    let duration: Double
    let createdAt: Date?
    var time: Double { duration * (Double(frameIndex) + 0.5) / Double(frameCount) }
    var id: String { assetID }
}

// MARK: - PhotoStore

@MainActor
final class PhotoStore: ObservableObject {
    static let shared = PhotoStore()
    private init() { load() }

    @Published private(set) var photos:    [LocalPhoto]     = []
    @Published private(set) var clusters:  [PersonCluster]  = []
    @Published private(set) var locations: [LocalLocation]  = []
    @Published private(set) var folders:   [LocalFolder]    = []

    // CLIP embeddings stored separately (not in LocalPhoto) for efficiency
    private(set) var clipEmbeddings: [String: [Float]] = [:]

    // Per-frame CLIP embeddings for videos (assetID → ≤8 sampled-frame
    // vectors, ~2KB each). clipEmbeddings keeps the L2-renormalized mean for
    // back-compat (photos and pre-existing videos have only that); when
    // frames exist, search/relevance takes the max over them — a video
    // matches if ANY part matches, instead of being diluted by the mean —
    // and video-video duplicate checks compare best frame pairs.
    private(set) var videoFrameEmbeddings: [String: [[Float]]] = [:]

    private var nextPhotoID   = 0
    private var nextClusterID = 0
    private var photoIndex: [String: Int] = [:]  // assetID → index in photos

    // MARK: - Storage paths

    private static let storeDir: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let d = docs.appendingPathComponent("photosearch", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    private static var photosURL:     URL { storeDir.appendingPathComponent("photos.json") }
    private static var clustersURL:   URL { storeDir.appendingPathComponent("clusters.json") }
    private static var locationsURL:  URL { storeDir.appendingPathComponent("locations.json") }
    private static var foldersURL:    URL { storeDir.appendingPathComponent("folders.json") }
    private static var embeddingsURL: URL { storeDir.appendingPathComponent("embeddings.json") }      // legacy JSON
    private static var clipBinURL:    URL { storeDir.appendingPathComponent("clip_embeddings.bin") }
    private static var videoFramesURL: URL { storeDir.appendingPathComponent("videoframes.bin") }
    private static var facesLogURL:   URL { storeDir.appendingPathComponent("face_embeddings.bin") }

    /// Per-photo face embeddings, disk-only (read in one pass when
    /// re-clustering — never held resident).
    private let faceLog = FaceEmbeddingLog(url: PhotoStore.facesLogURL)

    // MARK: - Load / Persist

    /// A store file exists on disk but failed to decode (truncated by a kill
    /// mid-write, disk corruption, schema skew). Without this, load() proceeds
    /// as if the store were empty, and the very next persist() overwrites the
    /// original bytes with an empty store — turning a recoverable read error
    /// into permanent data loss. Renaming the bad file to "<name>.corrupt"
    /// frees the path for a fresh empty store while preserving the original
    /// bytes for manual recovery. Returns whether a rename happened.
    @discardableResult
    private func backupCorruptStore(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let backup = url.appendingPathExtension("corrupt")
        try? FileManager.default.removeItem(at: backup)   // keep only the latest
        try? FileManager.default.moveItem(at: url, to: backup)
        return true
    }

    /// Read a store's bytes, distinguishing a READ failure from a DECODE
    /// failure. Returns nil in both cases, but only renames the file to
    /// .corrupt when the bytes were read successfully yet failed to decode
    /// (genuine corruption / schema skew). A transient read failure — e.g. an
    /// iOS Data-Protection denial during a locked-device BGProcessingTask
    /// launch — must NOT rename a healthy file: doing so frees the path for the
    /// next persist() to overwrite with an empty store, turning a recoverable
    /// I/O error into data loss. On a read failure we leave the file untouched
    /// so it self-heals on the next successful launch.
    private func loadStore<T>(_ url: URL, _ decode: (Data) -> T?) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let value = decode(data) { return value }
        backupCorruptStore(url)
        return nil
    }

    func load() {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        if let arr = loadStore(Self.photosURL, { try? dec.decode([LocalPhoto].self, from: $0) }) {
            photos = arr
            photoIndex = Dictionary(uniqueKeysWithValues: arr.enumerated().map { ($1.assetID, $0) })
            nextPhotoID = (arr.map(\.photoID).max() ?? -1) + 1
        }
        if let arr = loadStore(Self.clustersURL, { try? dec.decode([PersonCluster].self, from: $0) }) {
            clusters = arr
            nextClusterID = (arr.map(\.id).max() ?? -1) + 1
        }
        if let arr = loadStore(Self.locationsURL, { try? dec.decode([LocalLocation].self, from: $0) }) {
            locations = arr
        }
        if let arr = loadStore(Self.foldersURL, { try? dec.decode([LocalFolder].self, from: $0) }) {
            folders = arr
        }
        // CLIP embeddings: binary store, with one-time migration from the
        // legacy JSON file (JSON cost 100MB+ encodes and slow launches at
        // tens of thousands of photos). Use loadStore so a transient read
        // failure leaves the binary untouched (only a successful-read-but-bad-
        // decode backs it up); a re-index can rewrite from the .corrupt copy.
        if let dict = loadStore(Self.clipBinURL, { BinaryEmbeddingCodec.decode($0) }) {
            clipEmbeddings = dict
        } else if let data = try? Data(contentsOf: Self.embeddingsURL),
                  let dict = try? JSONDecoder().decode([String: [Float]].self, from: data) {
            clipEmbeddings = dict
            try? BinaryEmbeddingCodec.encode(dict).write(to: Self.clipBinURL, options: .atomic)
            try? FileManager.default.removeItem(at: Self.embeddingsURL)
        }
        // Embeddings empty but photos exist → the binary went missing/corrupt
        // (the contains() re-index gate keys off photos, not embeddings, so
        // these would otherwise stay unsearchable). The .corrupt rename above
        // preserves recovery; surface it for diagnostics.
        if clipEmbeddings.isEmpty && !photos.isEmpty {
            print("[PhotoStore] \(photos.count) photos loaded but clipEmbeddings empty — embeddings missing/corrupt")
        }
        // Per-frame video embeddings (new store — no legacy format to
        // migrate; videos indexed before it exists simply have no entry).
        if let data = try? Data(contentsOf: Self.videoFramesURL),
           let dict = BinaryFrameEmbeddingCodec.decode(data) {
            videoFrameEmbeddings = dict
        }
        if let data = try? Data(contentsOf: Self.geocodeCacheURL),
           let dict = try? JSONDecoder().decode([String: String].self, from: data) {
            geocodeCache = dict
        }
        if let data = try? Data(contentsOf: Self.geocodePendingURL),
           let dict = try? JSONDecoder().decode([String: PendingGeocode].self, from: data) {
            geocodePending = dict
        }
        // Resume any geocoding left over from the previous session, and
        // re-queue photos that have GPS but never got a place name (e.g.
        // indexed while the old geocoder was being rate-limited). Dedup by
        // ~1km cell keeps this cheap no matter how many photos re-enter.
        for p in photos where !p.isDeleted && p.locationName == nil {
            if let lat = p.lat, let lon = p.lon {
                enqueueGeocode(assetID: p.assetID, lat: lat, lon: lon)
            }
        }
        startGeocodeDrain()
        // Backfill isVideo/duration for photos whose stores predate the video
        // fields (contains() blocks a re-index, so they'd stay nil forever).
        // Runs after load() returns so launch isn't blocked on a PHAsset fetch.
        let missingVideoInfo = photos.filter { $0.isVideo == nil }.map(\.assetID)
        if !missingVideoInfo.isEmpty {
            Task { await backfillVideoInfo(assetIDs: missingVideoInfo) }
        }
    }

    /// Resolve isVideo/duration from PHAsset metadata for photos indexed
    /// before those fields existed. Assets missing from the fetch (deleted
    /// from the camera roll) keep nil and are retried next launch — the
    /// library-sync prune handles them.
    private func backfillVideoInfo(assetIDs: [String]) async {
        guard !assetIDs.isEmpty else { return }
        let fetched = await Task.detached(priority: .utility) {
            () -> [String: (isVideo: Bool, duration: Double)] in
            var out: [String: (isVideo: Bool, duration: Double)] = [:]
            let result = PHAsset.fetchAssets(withLocalIdentifiers: assetIDs, options: nil)
            result.enumerateObjects { asset, _, _ in
                out[asset.localIdentifier] = (asset.mediaType == .video, asset.duration)
            }
            return out
        }.value
        var changed = false
        for (assetID, info) in fetched {
            guard let idx = photoIndex[assetID], photos[idx].isVideo == nil else { continue }
            photos[idx].isVideo = info.isVideo
            photos[idx].duration = info.isVideo ? info.duration : nil
            changed = true
        }
        if changed { schedulePersist(.photos) }
    }

    /// Which on-disk stores have un-persisted changes. Every mutation site
    /// marks exactly what it touched; persist() then writes only those files
    /// instead of rewriting all of them — the embeddings binary alone is
    /// ~100MB, and a folder rename must not pay for it.
    struct DirtyStores: OptionSet {
        let rawValue: Int
        static let photos     = DirtyStores(rawValue: 1 << 0)  // photos.json
        static let clusters   = DirtyStores(rawValue: 1 << 1)  // clusters.json
        static let locations  = DirtyStores(rawValue: 1 << 2)  // locations.json
        static let folders    = DirtyStores(rawValue: 1 << 3)  // folders.json
        static let embeddings = DirtyStores(rawValue: 1 << 4)  // clip_embeddings.bin + videoframes.bin (always change together — both written at index time)
        static let geocode    = DirtyStores(rawValue: 1 << 5)  // geocode_cache.json + geocode_pending.json
        static let all: DirtyStores = [.photos, .clusters, .locations, .folders, .embeddings, .geocode]
    }

    private var dirty: DirtyStores = []

    /// Write every dirty store to disk, then clear the flags.
    ///
    /// The JSON stores are written synchronously on the main actor (small and
    /// fast). The embeddings binary is NOT: encoding ~100MB on the main actor
    /// froze the UI, so it's snapshotted and written from a detached task —
    /// see flushEmbeddingsAsync(). persist() therefore returns with the JSON
    /// stores durable but the embeddings write merely *started*. Callers that
    /// must have the embeddings on disk before the process can be suspended
    /// (e.g. a BGProcessingTask about to call setTaskCompleted) should await
    /// persistAndWait(); callers tearing state down synchronously (resetIndex)
    /// use persistAll().
    func persist() {
        // A debounced persistTask may still be pending (schedulePersist set it,
        // and a direct persist()/persistAndWait() call beat the 3s timer). This
        // synchronous write already flushes everything currently dirty, so the
        // pending task is redundant — and worse, if left live it fires later
        // (potentially after a resetIndex on a shared singleton) and writes
        // whatever is dirty *then*, leaking one context's state across a
        // boundary. Cancel it so persist() is the single source of truth.
        persistTask?.cancel()
        persistTask = nil
        indexesSincePersist = 0
        let toWrite = dirty
        dirty = []
        guard !toWrite.isEmpty else { return }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        if toWrite.contains(.photos) {
            try? enc.encode(photos).write(to: Self.photosURL, options: .atomic)
        }
        if toWrite.contains(.clusters) {
            try? enc.encode(clusters).write(to: Self.clustersURL, options: .atomic)
        }
        if toWrite.contains(.locations) {
            try? enc.encode(locations).write(to: Self.locationsURL, options: .atomic)
        }
        if toWrite.contains(.folders) {
            try? enc.encode(folders).write(to: Self.foldersURL, options: .atomic)
        }
        if toWrite.contains(.geocode) {
            try? JSONEncoder().encode(geocodeCache).write(to: Self.geocodeCacheURL, options: .atomic)
            try? JSONEncoder().encode(geocodePending).write(to: Self.geocodePendingURL, options: .atomic)
        }
        if toWrite.contains(.embeddings) { flushEmbeddingsAsync() }
    }

    /// Synchronous full write of every store, embeddings included — the
    /// escape hatch for callers that need completion guarantees on return
    /// (resetIndex, or anything running right before process teardown).
    /// Bumps the embeddings write generation so an in-flight async flush of
    /// an older snapshot can't land on top of what's written here.
    func persistAll() {
        persistTask?.cancel()
        indexesSincePersist = 0
        dirty = []
        embeddingFlushDirtyAgain = false
        embeddingWriteGeneration += 1
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try? enc.encode(photos).write(to: Self.photosURL, options: .atomic)
        try? enc.encode(clusters).write(to: Self.clustersURL, options: .atomic)
        try? enc.encode(locations).write(to: Self.locationsURL, options: .atomic)
        try? enc.encode(folders).write(to: Self.foldersURL, options: .atomic)
        try? BinaryEmbeddingCodec.encode(clipEmbeddings).write(to: Self.clipBinURL, options: .atomic)
        try? BinaryFrameEmbeddingCodec.encode(videoFrameEmbeddings).write(to: Self.videoFramesURL, options: .atomic)
        try? JSONEncoder().encode(geocodeCache).write(to: Self.geocodeCacheURL, options: .atomic)
        try? JSONEncoder().encode(geocodePending).write(to: Self.geocodePendingURL, options: .atomic)
    }

    /// persist(), then suspend until any in-flight embeddings flush — and any
    /// re-flush queued behind it — has landed on disk. Background-indexing
    /// callers should prefer this over bare persist() before signalling task
    /// completion, so the big binary write can't be cut off by suspension.
    func persistAndWait() async {
        persist()
        while let task = embeddingFlushTask {
            await task.value  // finishEmbeddingFlush may chain another pass; loop
        }
    }

    // Embeddings flush: at most one detached write at a time. If the dict is
    // dirtied again while a write is in flight, we re-flush once it finishes
    // rather than interleaving two ~100MB writes to the same file.
    private var embeddingFlushTask: Task<Void, Never>?
    private var embeddingFlushInFlight = false
    private var embeddingFlushDirtyAgain = false
    /// Bumped by persistAll()/resetIndex() when they touch the embeddings
    /// file directly on the main actor; a detached flush re-checks its
    /// generation just before writing and drops itself if stale.
    private var embeddingWriteGeneration = 0

    private func flushEmbeddingsAsync() {
        if embeddingFlushInFlight { embeddingFlushDirtyAgain = true; return }
        embeddingFlushInFlight = true
        let snapshot = clipEmbeddings
        let frameSnapshot = videoFrameEmbeddings
        let url = Self.clipBinURL
        let framesURL = Self.videoFramesURL
        let gen = embeddingWriteGeneration
        embeddingFlushTask = Task.detached(priority: .utility) {
            let data = BinaryEmbeddingCodec.encode(snapshot)
            let frameData = BinaryFrameEmbeddingCodec.encode(frameSnapshot)
            if await self.embeddingGenerationIsCurrent(gen) {
                try? data.write(to: url, options: .atomic)
                try? frameData.write(to: framesURL, options: .atomic)
                // The writes take seconds at scale — persistAll/resetIndex
                // may have rewritten the files mid-write. If the generation
                // moved, our (stale) rename landed last: re-flush current
                // state so disk converges.
                if await !self.embeddingGenerationIsCurrent(gen) {
                    await self.markEmbeddingsDirtyAgain()
                }
            }
            await self.finishEmbeddingFlush()
        }
    }

    private func embeddingGenerationIsCurrent(_ gen: Int) -> Bool {
        embeddingWriteGeneration == gen
    }

    private func markEmbeddingsDirtyAgain() {
        embeddingFlushDirtyAgain = true
    }

    private func finishEmbeddingFlush() {
        embeddingFlushInFlight = false
        embeddingFlushTask = nil
        if embeddingFlushDirtyAgain {
            embeddingFlushDirtyAgain = false
            flushEmbeddingsAsync()
        }
    }

    private var persistTask: Task<Void, Never>?
    /// index() calls since the last persist — drives the forced flush in
    /// index() (the debounce alone never fires during continuous indexing).
    private var indexesSincePersist = 0

    /// Mark `stores` dirty and debounce a persist 3s out.
    func schedulePersist(_ stores: DirtyStores) {
        dirty.formUnion(stores)
        persistTask?.cancel()
        persistTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            persist()
        }
    }

    // MARK: - Indexing

    func contains(assetID: String) -> Bool { photoIndex[assetID] != nil }

    /// O(1) photo lookup, for callers that stream per-asset updates and need
    /// to re-check live state (e.g. SharpnessBackfill verifying that a
    /// photo's faces are still unset before writing a snapshot-derived match).
    func photo(forAssetID id: String) -> LocalPhoto? {
        photoIndex[id].map { photos[$0] }
    }

    /// `clipFrameEmbeddings`: per-sampled-frame CLIP vectors for videos.
    /// `clipEmbedding` stays the L2-renormalized frame mean (photos and old
    /// callers pass only that), so existing stores remain valid; frames are
    /// extra signal layered on top.
    /// `faceSharpness`/`imageSharpness`: Laplacian-variance sharpness from
    /// the engine (per detected face / whole frame), stored on the photo for
    /// best-face ranking. Optional with nil defaults so pre-sharpness
    /// callers keep compiling.
    func index(
        assetID: String,
        createdAt: Date?,
        lat: Double?, lon: Double?,
        clipEmbedding: [Float],
        faceEmbeddings: [[Float]],
        faceRects: [CGRect],
        isVideo: Bool = false,
        duration: Double? = nil,
        clipFrameEmbeddings: [[Float]]? = nil,
        faceSharpness: [Float]? = nil,
        imageSharpness: Float? = nil
    ) {
        guard !contains(assetID: assetID) else { return }

        clipEmbeddings[assetID] = clipEmbedding
        // Stored before markDuplicateIfNeeded below, so the duplicate check
        // sees the new video's frames.
        if let frames = clipFrameEmbeddings, !frames.isEmpty {
            videoFrameEmbeddings[assetID] = frames
        }

        // Keep raw face embeddings on disk so the global re-cluster pass
        // (reclusterPeople) can see every face, not just cluster prototypes.
        faceLog.append(assetID: assetID, embeddings: faceEmbeddings, rects: faceRects)

        let clusterIDs = assignFaces(embeddings: faceEmbeddings, rects: faceRects, toAssetID: assetID)

        // Pair each assigned face with its rect and sharpness, index-wise —
        // clusterIDs follows faceEmbeddings order (assignFaces zips them).
        // A count mismatch means the pairing can't be trusted: rects fall
        // back to .zero exactly like assignFaces, sharpness to nil rather
        // than mislabeling a face. An empty array (vs nil) records that this
        // photo was indexed with face-data support — backfill can skip it.
        let pairedRects = faceRects.count == clusterIDs.count
            ? faceRects : Array(repeating: CGRect.zero, count: clusterIDs.count)
        let pairedSharpness: [Float]? =
            faceSharpness?.count == clusterIDs.count ? faceSharpness : nil
        let faces = clusterIDs.indices.map { i in
            PhotoFace(clusterID: clusterIDs[i],
                      rect: [pairedRects[i].minX, pairedRects[i].minY,
                             pairedRects[i].width, pairedRects[i].height],
                      sharpness: pairedSharpness?[i])
        }

        var photo = LocalPhoto(
            assetID: assetID,
            photoID: nextPhotoID,
            createdAt: createdAt,
            lat: lat, lon: lon,
            locationName: nil,
            personClusterIDs: clusterIDs,
            dupGroupID: nil,
            isDeleted: false,
            isVideo: isVideo,
            duration: isVideo ? duration : nil,
            faces: faces,
            sharpness: imageSharpness
        )
        nextPhotoID += 1

        markDuplicateIfNeeded(&photo, embedding: clipEmbedding)

        photoIndex[assetID] = photos.count
        photos.append(photo)

        if let lat, let lon {
            enqueueGeocode(assetID: assetID, lat: lat, lon: lon)
        }

        // The 3s debounce never fires during continuous indexing (every
        // photo resets it), so force a flush every 200 photos — a mid-run
        // kill then loses at most the last batch, not the whole session.
        indexesSincePersist += 1
        if indexesSincePersist >= 200 {
            persistTask?.cancel()
            dirty.formUnion([.photos, .clusters, .embeddings])
            persist()
        } else {
            schedulePersist([.photos, .clusters, .embeddings])
        }
    }

    /// Backfill setter for per-photo face data on photos indexed before it
    /// existed. nil args leave the current value alone (only non-nil
    /// overwrites), so the face pass and the whole-image sharpness pass can
    /// land independently without clobbering each other.
    func setFaceData(assetID: String, faces: [PhotoFace]?, imageSharpness: Float?) {
        guard let idx = photoIndex[assetID] else { return }
        if let faces { photos[idx].faces = faces }
        if let imageSharpness { photos[idx].sharpness = imageSharpness }
        schedulePersist([.photos])
    }

    // MARK: - Duplicate detection

    private func markDuplicateIfNeeded(_ photo: inout LocalPhoto, embedding: [Float]) {
        let newFrames = videoFrameEmbeddings[photo.assetID] ?? []
        for other in photos where !other.isDeleted && other.video == photo.video
            && other.assetID != photo.assetID {   // self-match guard: restore path re-checks in-place
            guard let otherEmb = clipEmbeddings[other.assetID] else { continue }
            // Video pairs with per-frame data: best frame-pair similarity at
            // the same 0.97 bar. Comparing frame means inflated similarity
            // (averaging washes out the parts that differ), flagging distinct
            // videos of the same scene; the best single-frame pair restores
            // the still-image calibration the threshold was tuned on. Videos
            // without frames (indexed pre-frames) keep the mean-vs-mean check.
            let sim: Float
            if photo.video, !newFrames.isEmpty,
               let otherFrames = videoFrameEmbeddings[other.assetID], !otherFrames.isEmpty {
                sim = bestPairSimilarity(newFrames, otherFrames)
            } else {
                sim = dot(embedding, otherEmb)
            }
            if sim > 0.97 {
                let gid = other.dupGroupID ?? other.assetID
                photo.dupGroupID = gid
                if let idx = photoIndex[other.assetID], photos[idx].dupGroupID == nil {
                    photos[idx].dupGroupID = gid
                }
                return
            }
        }
    }

    /// Max cosine similarity over all cross pairs of two frame sets
    /// (≤8×8 = 64 vDSP dots — negligible).
    private func bestPairSimilarity(_ a: [[Float]], _ b: [[Float]]) -> Float {
        var best: Float = -1
        for fa in a where !fa.isEmpty {
            for fb in b where !fb.isEmpty {
                best = max(best, dot(fa, fb))   // dot() returns 0 on dim mismatch
            }
        }
        return best
    }

    // MARK: - Face clustering

    private func assignFaces(embeddings: [[Float]], rects: [CGRect], toAssetID: String) -> [Int] {
        zip(embeddings, rects.isEmpty
            ? Array(repeating: CGRect.zero, count: embeddings.count)
            : Array(rects)
        ).map { assignSingleFace(embedding: $0, rect: $1, toAssetID: toAssetID) }
    }

    private func assignSingleFace(embedding: [Float], rect: CGRect, toAssetID: String) -> Int {
        var bestID  = -1
        // Same-person match threshold. Measured on LFW through this exact
        // pipeline: same-person sims are 0.64 ± 0.14, different-person max
        // ~0.23 — so 0.45 accepts ~90% of true matches while staying far
        // above random-pair similarity. (Backend uses 0.42 vs DBSCAN
        // prototypes; we sit slightly stricter because greedy prototypes
        // start from a single face. The old 0.70 rejected most true matches
        // and shattered each person into many clusters.)
        var bestSim: Float = 0.45

        for cluster in clusters where cluster.mergedInto == nil && !cluster.isDeleted {
            let sim = dot(embedding, cluster.prototype)
            if sim > bestSim { bestSim = sim; bestID = cluster.id }
        }

        if bestID >= 0, let ci = clusterIndex(bestID) {
            // Update running centroid
            let n = Float(clusters[ci].photoAssetIDs.count)
            var proto = zip(clusters[ci].prototype, embedding).map { $0.0 * n + $0.1 }
            proto = l2Normalize(proto)
            clusters[ci].prototype = proto
            if !clusters[ci].photoAssetIDs.contains(toAssetID) {
                clusters[ci].photoAssetIDs.append(toAssetID)
            }
            // Upgrade the cover face when a clearly larger one arrives —
            // bigger face in frame = sharper, better-framed thumbnail.
            // 1.3× hysteresis avoids churning on near-equal faces.
            let newArea = rect.width * rect.height
            let cur = clusters[ci].faceRect
            if newArea > cur.width * cur.height * 1.3 {
                clusters[ci].representativeAssetID = toAssetID
                clusters[ci].faceNormalizedRect = [rect.minX, rect.minY, rect.width, rect.height]
            }
            return bestID
        } else {
            let newID = nextClusterID; nextClusterID += 1
            clusters.append(PersonCluster(
                id: newID,
                name: nil,
                prototype: l2Normalize(embedding),
                photoAssetIDs: [toAssetID],
                representativeAssetID: toAssetID,
                faceNormalizedRect: [rect.minX, rect.minY, rect.width, rect.height],
                mergedInto: nil,
                isDeleted: false
            ))
            return newID
        }
    }

    private func clusterIndex(_ id: Int) -> Int? { clusters.firstIndex { $0.id == id } }

    // MARK: - Global re-clustering

    @Published private(set) var isReclustering = false
    /// Bumped whenever photo↔person/group membership changes — soft deletes
    /// (delete/restore/prune), duplicate-group edits, AND merges/unmerges/
    /// reclusters. photos.count is unchanged by all of those, so caches and
    /// views keyed on count alone would go stale — key on this too.
    @Published private(set) var membershipVersion = 0
    /// Bumped whenever the cluster ID space itself is rebuilt or wiped
    /// (reclusterPass renumbers every cluster from 0; resetIndex clears
    /// everything). Long-running consumers that matched faces against a
    /// snapshot of cluster prototypes (SharpnessBackfill) re-check this
    /// before writing: a stale match would attach a face to whatever NEW
    /// cluster happens to reuse the old ID — a different person.
    private(set) var clusterEpoch = 0
    private var reclusterPending = false

    /// Rebuild People from scratch with a global DBSCAN over every stored
    /// face embedding — the same algorithm (and thresholds) the Python
    /// backend used for full re-indexes. The live greedy assignment is
    /// order-dependent and can split a person across clusters; this pass
    /// sees all faces at once. User-assigned names are carried onto the
    /// best-matching new clusters by prototype similarity.
    func reclusterPeople() async {
        // Coalesce instead of drop: a request arriving mid-recluster runs one
        // more pass when the current one finishes (its snapshot may predate
        // e.g. a just-restored photo — silently returning would leave that
        // photo out of People until the next big indexing batch).
        guard !isReclustering else { reclusterPending = true; return }
        isReclustering = true
        defer { isReclustering = false }
        repeat {
            reclusterPending = false
            await reclusterPass()
        } while reclusterPending
    }

    private func reclusterPass() async {
        // Snapshots for the off-main compute. Exclude soft-deleted photos —
        // their faces are still in the log, and including them would
        // resurrect in-app-deleted photos into People clusters.
        let validAssets = Set(photos.lazy.filter { !$0.isDeleted }.map(\.assetID))
        let log = faceLog
        let previousNames = clusters
            .filter { $0.mergedInto == nil && !$0.isDeleted }
            .compactMap { c -> FaceReclusterer.NamedPrototype? in
                guard let name = c.name, !name.isEmpty else { return nil }
                return FaceReclusterer.NamedPrototype(name: name, prototype: c.prototype)
            }

        let result = await Task.detached(priority: .userInitiated) { () -> FaceReclusterer.Result? in
            let records = log.readAll().filter { validAssets.contains($0.assetID) }
            let faces = records.flatMap { record in
                record.faces.map {
                    FaceReclusterer.Face(assetID: record.assetID,
                                         rect: $0.rect,
                                         embedding: $0.embedding)
                }
            }
            return FaceReclusterer.recluster(faces: faces, previousNames: previousNames)
        }.value

        guard let result else { return }

        // Apply: replace all clusters and rebuild every photo's assignments.
        var newClusters: [PersonCluster] = []
        for (i, c) in result.clusters.enumerated() {
            newClusters.append(PersonCluster(
                id: i,
                name: c.name,
                prototype: c.prototype,
                photoAssetIDs: c.photoAssetIDs,
                representativeAssetID: c.representativeAssetID,
                faceNormalizedRect: c.faceNormalizedRect,
                mergedInto: nil,
                isDeleted: false
            ))
        }
        clusters = newClusters
        nextClusterID = newClusters.count
        // A reentrant index() during the off-main DBSCAN (await above) may have
        // indexed NEW photos and given them a greedy assignment in the OLD ID
        // space. The rebuild renumbers every cluster from 0, so those live IDs
        // now point at a DIFFERENT person (or out of range) — a misattribution
        // resolvedClusterID can't detect (it only follows merge chains). We
        // must NOT preserve them. Instead clear them: a temporarily person-less
        // photo is recoverable, a wrong-person one is not. Track whether any
        // such photo appeared so we can schedule a follow-up pass that actually
        // sees them — index() doesn't set reclusterPending itself.
        var sawUnsnapshottedAsset = false
        for i in photos.indices {
            let assetID = photos[i].assetID
            // Only assets this pass saw get a result-derived assignment; assets
            // absent from the snapshot (freshly indexed, or soft-deleted) carry
            // stale OLD-space IDs and must be cleared, never preserved.
            if let assigned = result.assignments[assetID] {
                photos[i].personClusterIDs = assigned
            } else {
                if !validAssets.contains(assetID) && !photos[i].isDeleted {
                    sawUnsnapshottedAsset = true
                }
                photos[i].personClusterIDs = []
            }
            // Stored per-photo faces carry raw cluster IDs from the OLD
            // numbering; the rebuild reuses IDs from 0, so a stale ID would
            // silently resolve to a different person (resolvedClusterID only
            // follows merge chains, which this pass wipes). Rewrite them from
            // the same pass, positionally — stored PhotoFace arrays and the
            // face log share face order and count. Same rule: clear (don't
            // preserve) any face the result didn't name, so no stale old-space
            // ID survives the renumbering.
            guard var faces = photos[i].faces, !faces.isEmpty else { continue }
            if let assigned = result.faceAssignments[assetID],
               assigned.count == faces.count {
                for j in faces.indices { faces[j].clusterID = assigned[j] }
            } else {
                // Unmatched (freshly indexed during the await, soft-deleted, or
                // torn log record): nil beats the wrong person's face. The
                // follow-up pass scheduled below re-assigns the fresh ones.
                for j in faces.indices { faces[j].clusterID = nil }
            }
            photos[i].faces = faces
        }
        // A photo was indexed during the off-main compute and cleared above —
        // it's now person-less. Run one more pass (reclusterPeople's repeat
        // loop honors this flag) so it gets a real, current-ID-space
        // assignment from the next DBSCAN instead of staying unattributed.
        if sawUnsnapshottedAsset { reclusterPending = true }
        // New ID space: invalidate any in-flight prototype-snapshot matching
        // (SharpnessBackfill), and refresh views keyed on membership.
        clusterEpoch += 1
        membershipVersion += 1
        dirty.formUnion([.photos, .clusters])
        persist()
    }

    // MARK: - Reverse geocoding (queued + throttled)
    //
    // Apple rate-limits CLGeocoder hard (sustained ~1 req/s at best; bursts
    // get error-throttled). The old per-photo fire-and-forget Tasks meant a
    // full index spawned thousands of concurrent requests — the first burst
    // succeeded and everything after failed silently, leaving Places sparse.
    // Now: requests are deduped by ~1km cell, queued, drained serially with
    // spacing and backoff, and both cache and queue persist across launches
    // so a big library finishes geocoding over a few sessions.

    struct PendingGeocode: Codable {
        var lat: Double
        var lon: Double
        var assetIDs: [String]
    }

    private var geocodeCache:   [String: String] = [:]           // cell key → place name ("" = no result)
    private var geocodePending: [String: PendingGeocode] = [:]   // cell key → coords + waiting photos
    private var geocodeDrainTask: Task<Void, Never>?
    /// Guards the drain handle against a stale task's cleanup clobbering a
    /// newer drain after resetIndex cancels and restarts the queue.
    private var geocodeDrainGeneration = 0
    private let geocoder = CLGeocoder()

    private static var geocodeCacheURL:   URL { storeDir.appendingPathComponent("geocode_cache.json") }
    private static var geocodePendingURL: URL { storeDir.appendingPathComponent("geocode_pending.json") }

    private func geocodeKey(lat: Double, lon: Double) -> String {
        "\(Int(lat * 100))_\(Int(lon * 100))"
    }

    func enqueueGeocode(assetID: String, lat: Double, lon: Double) {
        let key = geocodeKey(lat: lat, lon: lon)
        if let cached = geocodeCache[key] {
            if !cached.isEmpty { applyLocation(assetID: assetID, name: cached) }
            return
        }
        if var job = geocodePending[key] {
            job.assetIDs.append(assetID)
            geocodePending[key] = job
        } else {
            geocodePending[key] = PendingGeocode(lat: lat, lon: lon, assetIDs: [assetID])
        }
        schedulePersist(.geocode)   // queue changed — debounce a write
        startGeocodeDrain()
    }

    func startGeocodeDrain() {
        guard geocodeDrainTask == nil, !geocodePending.isEmpty else { return }
        geocodeDrainGeneration += 1
        let gen = geocodeDrainGeneration
        geocodeDrainTask = Task { [weak self] in
            await self?.drainGeocodeQueue()
            // Clear only our own handle — resetIndex may have cancelled this
            // drain and a newer one may already be running.
            if let self, self.geocodeDrainGeneration == gen { self.geocodeDrainTask = nil }
        }
    }

    private func drainGeocodeQueue() async {
        var failureStreak = 0
        while !Task.isCancelled, let (key, job) = geocodePending.first {
            do {
                let loc = CLLocation(latitude: job.lat, longitude: job.lon)
                let placemarks = try await geocoder.reverseGeocodeLocation(loc)
                // resetIndex cancels the drain; a lookup resolving after the
                // wipe must not repopulate Places from stale state.
                if Task.isCancelled { break }
                failureStreak = 0
                var parts: [String] = []
                if let p = placemarks.first {
                    if let city = p.locality { parts.append(city) }
                    if let state = p.administrativeArea { parts.append(state) }
                    if parts.isEmpty, let country = p.country { parts.append(country) }
                }
                let name = parts.joined(separator: ", ")
                geocodeCache[key] = name   // cache "" too, so dead cells aren't retried forever
                for id in job.assetIDs where !name.isEmpty {
                    applyLocation(assetID: id, name: name)
                }
                geocodePending.removeValue(forKey: key)
                schedulePersist(.geocode)
                try? await Task.sleep(for: .seconds(1.5))   // stay under Apple's rate limit
            } catch let error as CLError where error.code == .geocodeFoundNoResult {
                geocodeCache[key] = ""
                geocodePending.removeValue(forKey: key)
                schedulePersist(.geocode)
            } catch {
                // Throttled or offline — back off; give up after a few tries
                // (queue is persisted, the next launch or enqueue resumes it).
                failureStreak += 1
                if failureStreak >= 5 { break }
                try? await Task.sleep(for: .seconds(min(60 * Double(failureStreak), 300)))
            }
        }
    }

    private func applyLocation(assetID: String, name: String) {
        guard !name.isEmpty else { return }
        // A deferred reverse-geocode can land after the photo was soft-deleted.
        // Skip the whole body for deleted (or torn-out) photos so we don't
        // resurrect a phantom into a Places bucket. restorePhotos re-attaches
        // buckets from locationName, or re-enqueues the geocode from lat/lon
        // (cheap, per-cell cached) if it never resolved — so skipping here is
        // safe.
        guard let idx = photoIndex[assetID], !photos[idx].isDeleted else { return }
        photos[idx].locationName = name
        if let li = locations.firstIndex(where: { $0.name == name }) {
            if !locations[li].photoAssetIDs.contains(assetID) {
                locations[li].photoAssetIDs.append(assetID)
            }
        } else {
            locations.append(LocalLocation(name: name, alias: nil,
                                           photoAssetIDs: [assetID], coverAssetID: assetID))
        }
        schedulePersist([.photos, .locations])
    }

    // MARK: - Delete

    func deletePhoto(assetID: String) {
        guard let idx = photoIndex[assetID], !photos[idx].isDeleted else { return }
        photos[idx].isDeleted = true
        for ci in 0..<clusters.count  { clusters[ci].photoAssetIDs.removeAll { $0 == assetID } }
        for li in 0..<locations.count { locations[li].photoAssetIDs.removeAll { $0 == assetID } }
        // Drop the assetID from any pending geocode cell: a deferred lookup
        // draining after delete would otherwise re-resurrect it into a Places
        // bucket (and the dangling ID persists in geocode_pending.json and is
        // re-drained next launch). restorePhotos re-enqueues from lat/lon, so
        // removal here doesn't lose the eventual place name.
        for (k, var job) in geocodePending {
            if let i = job.assetIDs.firstIndex(of: assetID) {
                job.assetIDs.remove(at: i)
                if job.assetIDs.isEmpty { geocodePending.removeValue(forKey: k) }
                else { geocodePending[k] = job }
            }
        }
        // Folder membership intentionally survives a soft delete — folder
        // reads filter !isDeleted instead (allPhotos/searchPhotos/activeCount),
        // so restorePhotos can bring a photo back into its folders. Stripping
        // here was irreversible: nothing recorded which folders held it.
        membershipVersion += 1
        schedulePersist([.photos, .clusters, .locations, .geocode])
    }

    func deletePhoto(photoID: Int) {
        if let p = photos.first(where: { $0.photoID == photoID }) { deletePhoto(assetID: p.assetID) }
    }

    /// Un-hide photos previously deleted in-app (their assets still exist in
    /// the camera roll). Everything heavy survives soft-deletion — CLIP
    /// embedding, face-log entries, metadata — so restoring is instant.
    /// Location buckets re-attach here; People membership returns on the
    /// next reclusterPeople() (deletePhoto stripped it, and the reclusterer
    /// keys off non-deleted photos). Folder membership survives delete and
    /// restore: deletePhoto no longer strips it — folder reads filter out
    /// deleted photos instead — so restored photos reappear in their folders.
    @discardableResult
    func restorePhotos(_ assetIDs: Set<String>) -> Int {
        var restored = 0
        for assetID in assetIDs {
            guard let idx = photoIndex[assetID], photos[idx].isDeleted else { continue }
            photos[idx].isDeleted = false
            restored += 1
            if let name = photos[idx].locationName {
                if let li = locations.firstIndex(where: { $0.name == name }),
                   !locations[li].photoAssetIDs.contains(assetID) {
                    locations[li].photoAssetIDs.append(assetID)
                }
            } else if let lat = photos[idx].lat, let lon = photos[idx].lon {
                // Deleted before its geocode resolved — re-enqueue, otherwise
                // it would wait for the next app launch to get a place.
                enqueueGeocode(assetID: assetID, lat: lat, lon: lon)
            }
            // Re-pair duplicates: if its twin was "kept" while this one was
            // deleted, the twin's dupGroupID was cleared — re-check so the
            // pair is visible to the sweep again. (Copy out/in to avoid
            // overlapping access: the check walks the photos array.)
            // A photo deleted via keep-newest retains a now-dangling
            // dupGroupID (its kept twin's was cleared) — treat a group with
            // <2 active members as "needs re-pairing" too.
            let gidStale: Bool = {
                guard let gid = photos[idx].dupGroupID else { return true }
                let active = photos.lazy.filter { !$0.isDeleted && $0.dupGroupID == gid }.count
                return active < 2
            }()
            if gidStale, let emb = clipEmbeddings[assetID], !emb.isEmpty {
                var p = photos[idx]
                p.dupGroupID = nil
                markDuplicateIfNeeded(&p, embedding: emb)
                photos[idx] = p
            }
        }
        if restored > 0 {
            membershipVersion += 1
            schedulePersist([.photos, .locations])
        }
        return restored
    }

    /// Mark assets that were deleted from the system photo library as gone
    /// in the index too. Like deletePhoto, minus the library deletion (these
    /// assets no longer exist there) — and unlike deletePhoto it also strips
    /// folder membership, because a pruned asset can never be restored.
    func pruneDeletedAssets(_ assetIDs: Set<String>) {
        var pruned = false
        for assetID in assetIDs {
            guard let idx = photoIndex[assetID], !photos[idx].isDeleted else { continue }
            photos[idx].isDeleted = true
            pruned = true
        }
        guard pruned else { return }
        for ci in 0..<clusters.count  { clusters[ci].photoAssetIDs.removeAll { assetIDs.contains($0) } }
        for li in 0..<locations.count { locations[li].photoAssetIDs.removeAll { assetIDs.contains($0) } }
        // Unlike deletePhoto, folder membership IS stripped here: these
        // assets are gone from the camera roll and can never be restored.
        for fi in 0..<folders.count   { folders[fi].photoAssetIDs.removeAll { assetIDs.contains($0) } }
        // Drain pruned IDs from the pending geocode queue (as deletePhoto does):
        // a pruned asset can never be restored, so leaving its ID in
        // geocode_pending.json is pure residue that re-drains every launch.
        for (k, var job) in geocodePending {
            job.assetIDs.removeAll { assetIDs.contains($0) }
            if job.assetIDs.isEmpty { geocodePending.removeValue(forKey: k) }
            else { geocodePending[k] = job }
        }
        membershipVersion += 1
        schedulePersist([.photos, .clusters, .locations, .folders, .geocode])
    }

    // MARK: - People

    var activeClusters: [PersonCluster] {
        clusters
            .filter { $0.mergedInto == nil && !$0.isDeleted && $0.photoAssetIDs.count >= 3 }
            .sorted { $0.photoAssetIDs.count > $1.photoAssetIDs.count }
    }

    func photos(forCluster id: Int) -> [LocalPhoto] {
        // Collect all cluster IDs that resolve to this one (itself + merged-in clusters)
        let root = resolvedClusterID(id)
        let ids = Set(clusters.filter { resolvedClusterID($0.id) == root && !$0.isDeleted }
                              .flatMap(\.photoAssetIDs))
        return photos.filter { ids.contains($0.assetID) && !$0.isDeleted }
                     .sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
    }

    /// Photos containing ALL of the given people — AND semantics, with both
    /// the query IDs and each photo's assignments resolved through merges.
    /// Oldest first, so "first photo together" is simply .first.
    func photos(forClusters ids: [Int]) -> [LocalPhoto] {
        let want = Set(ids.map { resolvedClusterID($0) })
        guard !want.isEmpty else { return [] }
        return photos
            .filter { p in
                guard !p.isDeleted else { return false }
                return want.isSubset(of: Set(p.personClusterIDs.map { resolvedClusterID($0) }))
            }
            .sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
    }

    /// One representative face of a person per calendar year, ascending —
    /// the growth-timeline strip. Best face = (sharpness ?? 1) × √(face
    /// area): bigger faces crop better and sharpness separates the keeper
    /// from its motion-blurred near-duplicate; √area keeps the two factors
    /// on comparable scales. Cluster IDs resolve through merges on both
    /// sides — a face tagged with a pre-merge cluster ID still counts, so
    /// merged people keep their timeline. Years whose photos predate
    /// per-photo face data fall back to the year's latest photo shown whole
    /// (rect nil, score 0).
    func growthTimeline(forCluster id: Int) -> [YearFace] {
        let root = resolvedClusterID(id)
        let cal = Calendar.current
        var byYear: [Int: [LocalPhoto]] = [:]
        for p in photos(forCluster: root) {
            guard let d = p.createdAt else { continue }
            byYear[cal.component(.year, from: d), default: []].append(p)
        }
        var result: [YearFace] = []
        for (year, ps) in byYear {
            var best: YearFace?
            for p in ps {
                for face in p.faces ?? [] {
                    guard let cid = face.clusterID, resolvedClusterID(cid) == root,
                          face.rect.count == 4 else { continue }
                    let area = Float(face.rect[2] * face.rect[3])
                    let score = (face.sharpness ?? 1) * area.squareRoot()
                    if score > (best?.score ?? -.greatestFiniteMagnitude) {
                        best = YearFace(year: year, assetID: p.assetID,
                                        rect: CGRect(x: face.rect[0], y: face.rect[1],
                                                     width: face.rect[2], height: face.rect[3]),
                                        score: score)
                    }
                }
            }
            if best == nil,
               let latest = ps.max(by: { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }) {
                best = YearFace(year: year, assetID: latest.assetID, rect: nil, score: 0)
            }
            if let best { result.append(best) }
        }
        return result.sorted { $0.year < $1.year }
    }

    func resolvedClusterID(_ id: Int) -> Int {
        guard let c = clusters.first(where: { $0.id == id }), let m = c.mergedInto else { return id }
        return resolvedClusterID(m)
    }

    func mergeMembers(ofCluster id: Int) -> [PersonCluster] {
        let self_ = clusters.filter { $0.id == id }
        let merged = clusters.filter { $0.mergedInto == id && !$0.isDeleted }
        return self_ + merged
    }

    func mergeClusters(source: Int, into target: Int) {
        guard source != target,
              let si = clusterIndex(source), let ti = clusterIndex(target) else { return }
        clusters[si].mergedInto = target
        let n = Float(clusters[ti].photoAssetIDs.count)
        let m = Float(clusters[si].photoAssetIDs.count)
        if n + m > 0 {
            let blended = zip(clusters[ti].prototype.map { $0 * n },
                              clusters[si].prototype.map { $0 * m })
                .map { ($0.0 + $0.1) / (n + m) }
            clusters[ti].prototype = l2Normalize(blended)
        }
        for assetID in clusters[si].photoAssetIDs
            where !clusters[ti].photoAssetIDs.contains(assetID) {
            clusters[ti].photoAssetIDs.append(assetID)
        }
        // Remap photos
        for i in 0..<photos.count {
            photos[i].personClusterIDs = photos[i].personClusterIDs.map { $0 == source ? target : $0 }
        }
        membershipVersion += 1   // Together/growth views key on this
        schedulePersist([.clusters, .photos])
    }

    func unmergeCluster(_ memberID: Int) {
        guard let si = clusterIndex(memberID), let targetID = clusters[si].mergedInto,
              let ti = clusterIndex(targetID) else { return }
        clusters[si].mergedInto = nil
        let toRemove = Set(clusters[si].photoAssetIDs)
        clusters[ti].photoAssetIDs.removeAll { toRemove.contains($0) }
        // Remap photos back
        for i in 0..<photos.count {
            if let assetID = (photoIndex.first { $0.value == i }?.key),
               toRemove.contains(assetID) {
                photos[i].personClusterIDs = photos[i].personClusterIDs
                    .map { $0 == targetID ? memberID : $0 }
            }
        }
        membershipVersion += 1   // Together/growth views key on this
        schedulePersist([.clusters, .photos])
    }

    func setClusterName(id: Int, name: String) {
        guard let ci = clusterIndex(id) else { return }
        clusters[ci].name = name.trimmingCharacters(in: .whitespaces).isEmpty ? nil : name
        schedulePersist(.clusters)
    }

    func deleteCluster(id: Int) {
        guard let ci = clusterIndex(id) else { return }
        clusters[ci].isDeleted = true
        schedulePersist(.clusters)
    }

    // MARK: - Locations

    func photos(forLocation name: String) -> [LocalPhoto] {
        photos.filter { $0.locationName == name && !$0.isDeleted }
              .sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
    }

    func setLocationAlias(name: String, alias: String) {
        guard let li = locations.firstIndex(where: { $0.name == name }) else { return }
        locations[li].alias = alias.trimmingCharacters(in: .whitespaces).isEmpty ? nil : alias
        schedulePersist(.locations)
    }

    // MARK: - Folders

    @discardableResult
    func createFolder(name: String, query: String? = nil) -> LocalFolder {
        let f = LocalFolder(id: UUID().uuidString, name: name, photoAssetIDs: [],
                            query: (query?.isEmpty == true) ? nil : query)
        folders.append(f)
        schedulePersist(.folders)
        return f
    }

    /// Full overwrite of a smart folder's definition (the editor saves all
    /// four fields at once). Empty-string query/minusQuery normalize to nil
    /// so isSmart and the photosForFolder branches stay unambiguous.
    func updateSmartFolder(id: String, query: String?, anchorAssetID: String?,
                           minusQuery: String?, minScore: Float?) {
        guard let fi = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[fi].query = (query?.isEmpty == true) ? nil : query
        folders[fi].anchorAssetID = anchorAssetID
        folders[fi].minusQuery = (minusQuery?.isEmpty == true) ? nil : minusQuery
        folders[fi].minScore = minScore
        schedulePersist(.folders)
    }

    /// Evaluate a smart folder's saved search (static folders return their
    /// list). Soft-deleted photos stay in photoAssetIDs (see deletePhoto) but
    /// are filtered out here — all paths go through
    /// searchByEmbedding/searchPhotos/allPhotos, which drop isDeleted.
    func photosForFolder(_ folder: LocalFolder) -> [LocalPhoto] {
        // Embedding-anchored smart folder: membership is a live ranking
        // against the composite query vector. When the folder doesn't pin
        // its own floor, defaults follow the existing calibrations: 0.55
        // image-anchored (similarPhotos), 0.25 text-only (caption floor).
        // No engine (simulator) → empty, matching searchPhotos' degradation.
        if folder.anchorAssetID != nil || folder.minScore != nil {
            let minus = folder.minusQuery?
                .split(separator: ",")
                .map { String($0).trimmingCharacters(in: .whitespaces) } ?? []
            guard let emb = compositeQueryEmbedding(anchorAssetID: folder.anchorAssetID,
                                                    baseText: folder.query,
                                                    minus: minus) else { return [] }
            return searchByEmbedding(
                emb,
                floor: folder.minScore ?? (folder.anchorAssetID != nil ? 0.55 : 0.25)
            ).map(\.photo)
        }
        if let q = folder.query, !q.isEmpty {
            return searchPhotos(query: q)
        }
        return allPhotos(folderID: folder.id)
    }

    /// Non-deleted member count, for folder badges. Soft-deleted photos
    /// remain in photoAssetIDs so they can be restored — don't count them.
    /// Smart folders have no static membership (evaluating their query per
    /// row would be O(folders × search)), so they report 0 and the UI shows
    /// the query instead of a count.
    func activeCount(in folder: LocalFolder) -> Int {
        guard !folder.isSmart else { return 0 }
        return folder.photoAssetIDs.reduce(0) { count, assetID in
            guard let idx = photoIndex[assetID], !photos[idx].isDeleted else { return count }
            return count + 1
        }
    }

    /// Most recent non-deleted member, for folder cover thumbnails (folder
    /// membership now survives soft-deletes, so .last alone may point at a
    /// hidden photo).
    func activeCoverAssetID(in folder: LocalFolder) -> String? {
        folder.photoAssetIDs.last { id in
            guard let idx = photoIndex[id] else { return false }
            return !photos[idx].isDeleted
        }
    }

    func renameFolder(id: String, name: String) {
        guard let fi = folders.firstIndex(where: { $0.id == id }), !name.isEmpty else { return }
        folders[fi].name = name
        schedulePersist(.folders)
    }

    func deleteFolder(id: String, deletePhotos: Bool) {
        if deletePhotos, let fi = folders.firstIndex(where: { $0.id == id }) {
            folders[fi].photoAssetIDs.forEach { deletePhoto(assetID: $0) }
        }
        folders.removeAll { $0.id == id }
        schedulePersist(.folders)
    }

    func addPhotos(_ assetIDs: [String], toFolder id: String) {
        guard let fi = folders.firstIndex(where: { $0.id == id }) else { return }
        for assetID in assetIDs where !folders[fi].photoAssetIDs.contains(assetID) {
            folders[fi].photoAssetIDs.append(assetID)
        }
        schedulePersist(.folders)
    }

    func removePhotos(_ assetIDs: [String], fromFolder id: String) {
        guard let fi = folders.firstIndex(where: { $0.id == id }) else { return }
        let s = Set(assetIDs); folders[fi].photoAssetIDs.removeAll { s.contains($0) }
        schedulePersist(.folders)
    }

    // MARK: - Duplicates

    /// All duplicate groups with ≥2 surviving photos, newest group first —
    /// powers the global duplicates sweep.
    var duplicateGroups: [[LocalPhoto]] {
        var byGID: [String: [LocalPhoto]] = [:]
        for p in photos where !p.isDeleted {
            if let gid = p.dupGroupID { byGID[gid, default: []].append(p) }
        }
        return byGID.values
            .filter { $0.count >= 2 }
            .map { $0.sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) } }
            .sorted { ($0.first?.createdAt ?? .distantPast) > ($1.first?.createdAt ?? .distantPast) }
    }

    // MARK: - Auto-categories (zero-shot CLIP)

    private var categoryCache: (photoCount: Int, version: Int, result: [String: [LocalPhoto]])?
    /// Per-category prompt embeddings, encoded once per process — the
    /// prompts are compile-time constants, so re-encoding them on every
    /// call was pure waste. Filled on the first autoCategories() call.
    private static var promptEmbeddingCache: [String: [[Float]]]?

    /// Score every photo against each category's text prompts. Prompt
    /// embeddings are encoded once per process; the scoring loop (vDSP over
    /// every stored embedding) runs detached so big libraries don't stall
    /// the main thread. Result cached until membership changes.
    func autoCategories() async -> [(category: AutoCategory, photos: [LocalPhoto])] {
        if let cached = categoryCache, cached.photoCount == photos.count,
           cached.version == membershipVersion {
            return Self.assembleCategories(from: cached.result)
        }

        if Self.promptEmbeddingCache == nil {
            let engine = OnDeviceMLEngine.shared
            if !engine.isAvailable { try? engine.loadModels() }
            guard engine.isAvailable else { return [] }
            // MLModel.prediction is thread-safe, so the text encodes can run
            // off the main actor.
            let encoded = await Task.detached(priority: .userInitiated) {
                () -> [String: [[Float]]] in
                var out: [String: [[Float]]] = [:]
                for cat in AutoCategorizer.categories {
                    let embs = cat.prompts.compactMap { try? engine.encodeText($0) }
                    if !embs.isEmpty { out[cat.id] = embs }
                }
                return out
            }.value
            // Don't cache a total failure — leave nil so the next call retries.
            Self.promptEmbeddingCache = encoded.isEmpty ? nil : encoded
        }
        guard let promptEmbs = Self.promptEmbeddingCache else { return [] }

        // Snapshot store state on the main actor (post-await — the encode
        // suspension above may have let indexing land new photos), then
        // score detached. The cache is keyed on the snapshot, so state that
        // changes mid-scoring just means a recompute on the next call.
        let snapshotPhotos = photos.filter { !$0.isDeleted }
        let snapshotCount = photos.count
        let snapshotVersion = membershipVersion
        let clipSnapshot = clipEmbeddings
        let frameSnapshot = videoFrameEmbeddings

        let result = await Task.detached(priority: .userInitiated) {
            () -> [String: [LocalPhoto]] in
            var out: [String: [LocalPhoto]] = [:]
            for cat in AutoCategorizer.categories {
                guard let prompts = promptEmbs[cat.id] else { continue }
                var matches: [(LocalPhoto, Float)] = []
                for p in snapshotPhotos {
                    var best: Float = -1
                    if let emb = clipSnapshot[p.assetID], !emb.isEmpty {
                        for t in prompts { best = max(best, Self.dot(emb, t)) }
                    }
                    // Videos: any sampled frame can claim the category.
                    if let frames = frameSnapshot[p.assetID] {
                        for f in frames where !f.isEmpty {
                            for t in prompts { best = max(best, Self.dot(f, t)) }
                        }
                    }
                    if best >= cat.threshold { matches.append((p, best)) }
                }
                out[cat.id] = matches
                    .sorted { ($0.0.createdAt ?? .distantPast) > ($1.0.createdAt ?? .distantPast) }
                    .map(\.0)
            }
            return out
        }.value

        categoryCache = (snapshotCount, snapshotVersion, result)
        return Self.assembleCategories(from: result)
    }

    private static func assembleCategories(from result: [String: [LocalPhoto]])
        -> [(category: AutoCategory, photos: [LocalPhoto])] {
        AutoCategorizer.categories.compactMap { cat in
            guard let ps = result[cat.id], !ps.isEmpty else { return nil }
            return (cat, ps)
        }
    }

    // MARK: - Memories: Trips & On This Day

    struct Trip: Identifiable {
        let id: String
        let name: String          // most common place name, or "Trip"
        let start: Date
        let end: Date
        let photos: [LocalPhoto]  // chronological
        var coverAssetID: String { photos.first?.assetID ?? "" }
        var dateRangeText: String {
            let f = Date.FormatStyle.dateTime.month(.abbreviated).day()
            if Calendar.current.isDate(start, equalTo: end, toGranularity: .year) {
                return "\(start.formatted(f)) – \(end.formatted(f.year()))"
            }
            return "\(start.formatted(f.year())) – \(end.formatted(f.year()))"
        }
    }

    /// Heuristic trip detection: photos segmented by >36h gaps; a segment is
    /// a trip when it has enough photos, spans more than a day, and the
    /// majority of its GPS fixes are away from "home" (the most common
    /// ~10km cell across the whole library).
    var trips: [Trip] {
        let dated = photos
            .filter { !$0.isDeleted && $0.createdAt != nil }
            .sorted { $0.createdAt! < $1.createdAt! }
        guard dated.count >= 8 else { return [] }

        func cell(_ p: LocalPhoto) -> String? {
            guard let la = p.lat, let lo = p.lon else { return nil }
            return "\(Int(la * 10))_\(Int(lo * 10))"
        }
        var cellCounts: [String: Int] = [:]
        for p in dated { if let c = cell(p) { cellCounts[c, default: 0] += 1 } }
        let homeCell = cellCounts.max { $0.value < $1.value }?.key

        var segments: [[LocalPhoto]] = []
        var current: [LocalPhoto] = []
        for p in dated {
            if let last = current.last,
               p.createdAt!.timeIntervalSince(last.createdAt!) > 36 * 3600 {
                segments.append(current)
                current = []
            }
            current.append(p)
        }
        segments.append(current)

        var result: [Trip] = []
        for seg in segments {
            guard seg.count >= 8,
                  let s = seg.first?.createdAt, let e = seg.last?.createdAt,
                  (Calendar.current.dateComponents([.day], from: s, to: e).day ?? 0) >= 1
            else { continue }
            let cells = seg.compactMap(cell)
            guard !cells.isEmpty else { continue }
            let away = cells.filter { $0 != homeCell }.count
            guard away * 2 > cells.count else { continue }   // majority away from home
            var names: [String: Int] = [:]
            for p in seg { if let n = p.locationName { names[n, default: 0] += 1 } }
            let name = names.max { $0.value < $1.value }?.key ?? "Trip"
            result.append(Trip(id: "trip-\(Int(s.timeIntervalSince1970))",
                               name: name, start: s, end: e, photos: seg))
        }
        return result.reversed()   // newest first
    }

    struct OnThisDayGroup: Identifiable {
        let year: Int
        let photos: [LocalPhoto]
        var id: Int { year }
        var yearsAgo: Int { Calendar.current.component(.year, from: Date()) - year }
    }

    /// Photos taken on today's month/day in previous years, newest year first.
    func onThisDay(reference: Date = Date()) -> [OnThisDayGroup] {
        let cal = Calendar.current
        let m = cal.component(.month, from: reference)
        let d = cal.component(.day, from: reference)
        let thisYear = cal.component(.year, from: reference)
        var byYear: [Int: [LocalPhoto]] = [:]
        for p in photos where !p.isDeleted {
            guard let dt = p.createdAt else { continue }
            guard cal.component(.month, from: dt) == m,
                  cal.component(.day, from: dt) == d else { continue }
            let y = cal.component(.year, from: dt)
            if y != thisYear { byYear[y, default: []].append(p) }
        }
        return byYear.sorted { $0.key > $1.key }
            .map { OnThisDayGroup(year: $0.key, photos: $0.value) }
    }

    /// Average coordinate of a place's photos — for map annotations.
    func coordinate(for location: LocalLocation) -> CLLocationCoordinate2D? {
        var lat = 0.0, lon = 0.0, n = 0.0
        for assetID in location.photoAssetIDs {
            guard let idx = photoIndex[assetID],
                  let la = photos[idx].lat, let lo = photos[idx].lon else { continue }
            lat += la; lon += lo; n += 1
        }
        guard n > 0 else { return nil }
        return CLLocationCoordinate2D(latitude: lat / n, longitude: lon / n)
    }

    // MARK: - Similar photos ("More Like This")

    /// Rank the library by CLIP similarity to one photo. Pure vDSP dot
    /// products over stored embeddings — runs in milliseconds.
    /// Floor 0.55: near-identical scenes score 0.85+, same-subject/related
    /// scenes 0.6–0.8, loosely related ~0.5, unrelated below.
    func similarPhotos(to assetID: String, limit: Int = 60, floor: Float = 0.55) -> [LocalPhoto] {
        // Target = mean embedding plus any per-frame vectors (videos), so
        // "more like this" on a video can match any part of it; candidates
        // likewise score by their best representation via clipScore.
        var targets: [[Float]] = []
        if let t = clipEmbeddings[assetID], !t.isEmpty { targets.append(t) }
        for f in videoFrameEmbeddings[assetID] ?? [] where !f.isEmpty { targets.append(f) }
        guard !targets.isEmpty else { return [] }
        var scored: [(LocalPhoto, Float)] = []
        for p in photos where !p.isDeleted && p.assetID != assetID {
            var s: Float = -.greatestFiniteMagnitude
            for t in targets { s = max(s, clipScore(assetID: p.assetID, query: t) ?? s) }
            if s >= floor { scored.append((p, s)) }
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(limit).map { $0.0 }
    }

    func duplicateGroup(for assetID: String) -> [LocalPhoto] {
        guard let idx = photoIndex[assetID] else { return [] }
        let photo = photos[idx]
        guard let gid = photo.dupGroupID else { return [photo] }
        return photos.filter { $0.dupGroupID == gid && !$0.isDeleted }
                     .sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
    }

    func duplicateGroup(forPhotoID photoID: Int) -> [LocalPhoto] {
        guard let photo = photos.first(where: { $0.photoID == photoID }) else { return [] }
        return duplicateGroup(for: photo.assetID)
    }

    /// Non-deleted member counts per duplicate group, built lazily in one
    /// pass. Keyed on (photos.count, membershipVersion) like categoryCache;
    /// the dupGroupID mutators that change neither (merge/ungroup/keep) nil
    /// it explicitly.
    private var dupCountCache: (photoCount: Int, version: Int, counts: [String: Int])?

    /// O(1) duplicate-group size for thumbnail badges — duplicateGroup() is
    /// an O(N) scan, and grids were paying it per visible cell.
    func duplicateCount(forGroupID groupID: String) -> Int {
        if let cached = dupCountCache, cached.photoCount == photos.count,
           cached.version == membershipVersion {
            return cached.counts[groupID] ?? 0
        }
        var counts: [String: Int] = [:]
        for p in photos where !p.isDeleted {
            if let gid = p.dupGroupID { counts[gid, default: 0] += 1 }
        }
        dupCountCache = (photos.count, membershipVersion, counts)
        return counts[groupID] ?? 0
    }

    func mergeDuplicates(a: Int, b: Int) {
        guard let pa = photos.first(where: { $0.photoID == a }),
              let pb = photos.first(where: { $0.photoID == b }) else { return }
        let gid = pa.dupGroupID ?? pa.assetID
        if let ia = photoIndex[pa.assetID] { photos[ia].dupGroupID = gid }
        if let ib = photoIndex[pb.assetID] { photos[ib].dupGroupID = gid }
        dupCountCache = nil
        membershipVersion += 1   // sweep list + grids key on this
        schedulePersist(.photos)
    }

    func ungroupDuplicates(forPhotoID photoID: Int) {
        guard let photo = photos.first(where: { $0.photoID == photoID }),
              let gid = photo.dupGroupID else { return }
        for i in 0..<photos.count where photos[i].dupGroupID == gid {
            photos[i].dupGroupID = nil
        }
        dupCountCache = nil
        membershipVersion += 1   // sweep list + grids key on this
        schedulePersist(.photos)
    }

    func keepDuplicates(groupOf photoID: Int, keepIDs: [Int]) -> [Int] {
        let group = duplicateGroup(forPhotoID: photoID)
        let keepSet = Set(keepIDs)
        var deleted: [Int] = []
        for p in group where !keepSet.contains(p.photoID) {
            deletePhoto(assetID: p.assetID)
            deleted.append(p.photoID)
        }
        if keepIDs.count <= 1 {
            for p in group where keepSet.contains(p.photoID) {
                if let idx = photoIndex[p.assetID] { photos[idx].dupGroupID = nil }
            }
        }
        dupCountCache = nil   // may clear dupGroupID without a count/version bump
        schedulePersist(.photos)
        return deleted
    }

    // MARK: - Search

    /// Best CLIP relevance of one photo against a query embedding: the
    /// stored (mean) embedding, plus — for videos with per-frame data — the
    /// max over sampled frames, so a video matches when ANY part of it does.
    /// nil when the photo has no embeddings at all.
    private func clipScore(assetID: String, query tEmb: [Float]) -> Float? {
        var best: Float = -.greatestFiniteMagnitude
        if let emb = clipEmbeddings[assetID], !emb.isEmpty { best = dot(emb, tEmb) }
        if let frames = videoFrameEmbeddings[assetID] {
            for f in frames where !f.isEmpty { best = max(best, dot(f, tEmb)) }
        }
        return best > -.greatestFiniteMagnitude ? best : nil
    }

    func searchPhotos(query: String, folderID: String? = nil) -> [LocalPhoto] {
        let (results, caption) = structuredSearchStage(query: query, folderID: folderID)
        guard !results.isEmpty || !caption.isEmpty else { return [] }

        // Caption (CLIP) ranking: words not consumed by the structured filters
        // are treated as content ("beach", "birthday cake", …) and used to
        // rank the remaining candidates by text↔image cosine similarity.
        // Mirrors the backend: CAPTION_FLOOR drops unrelated photos
        // (ViT-B/32 calibration: >0.30 strongly related, <0.22 unrelated).
        if !caption.isEmpty, let tEmb = try? OnDeviceMLEngine.shared.encodeText(caption) {
            let floor: Float = 0.25
            let scored: [(LocalPhoto, Float)] = results.compactMap { p in
                guard let s = clipScore(assetID: p.assetID, query: tEmb) else { return nil }
                return s >= floor ? (p, s) : nil
            }
            return scored.sorted { $0.1 > $1.1 }.map { $0.0 }
        }

        return results.sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
    }

    /// The structured half of searchPhotos: folder, year, month+year,
    /// location, and person-name HARD filters, plus the residual caption left
    /// over for CLIP ranking. Factored out so the refine-chip path
    /// (SearchView.rerank) can keep "Mom 2021"'s person/year constraints
    /// while re-ranking the candidates with a composite embedding — routing
    /// the whole query string through the text encoder silently dropped them.
    func structuredSearchStage(query: String, folderID: String? = nil)
        -> (candidates: [LocalPhoto], caption: String) {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return ([], "") }

        var results = photos.filter { !$0.isDeleted }

        // Folder filter. Smart folders keep photoAssetIDs empty — membership
        // is their saved query, so resolve it the way photosForFolder does
        // (which calls back in with a nil folderID, so no recursion).
        if let fid = folderID, !fid.isEmpty,
           let folder = folders.first(where: { $0.id == fid }) {
            let ids = folder.isSmart
                ? Set(photosForFolder(folder).map(\.assetID))
                : Set(folder.photoAssetIDs)
            results = results.filter { ids.contains($0.assetID) }
        }

        // Year filter e.g. "2023"
        if let range = q.range(of: #"\b(19|20)\d{2}\b"#, options: .regularExpression) {
            if let year = Int(q[range]) {
                results = results.filter { p in
                    guard let d = p.createdAt else { return false }
                    return Calendar.current.component(.year, from: d) == year
                }
            }
        }

        // Month+year filter e.g. "june 2023" or "2023-06". Bare month words
        // with no year apply no filter (and stay in the caption below).
        let monthYear = parseMonthYear(q)
        if let (year, month) = monthYear {
            results = results.filter { p in
                guard let d = p.createdAt else { return false }
                let cal = Calendar.current
                return cal.component(.year, from: d) == year
                    && cal.component(.month, from: d) == month
            }
        }

        // Location filter. Stored names are geocoded "City, State"/"City,
        // Country" — match on the city part so "san francisco" finds
        // "San Francisco, California" (a query containing the full stored
        // name necessarily contains the city part too).
        let matchingLocs = locations.filter { loc in
            let city = cityPart(of: loc.name)
            if matchesWord(city, in: q) { return true }
            return loc.alias.map { matchesWord($0.lowercased(), in: q) } ?? false
        }
        if !matchingLocs.isEmpty {
            let nameSet = Set(matchingLocs.map(\.name))
            results = results.filter { ($0.locationName).map { nameSet.contains($0) } ?? false }
        }

        // Person name filter
        let matchingClusters = clusters.filter { c in
            guard let name = c.name, !name.isEmpty else { return false }
            return matchesWord(name.lowercased(), in: q)
        }
        if !matchingClusters.isEmpty {
            let resolvedIDs = Set(matchingClusters.map { resolvedClusterID($0.id) })
            results = results.filter { p in
                !Set(p.personClusterIDs.map { resolvedClusterID($0) }).isDisjoint(with: resolvedIDs)
            }
        }

        // Whatever the structured filters didn't consume is the CLIP caption.
        let caption = residualCaption(
            from: q, matchedLocations: matchingLocs, matchedClusters: matchingClusters,
            monthYearMatched: monthYear != nil)
        return (results, caption)
    }

    /// Rank non-deleted photos against an arbitrary query embedding (text,
    /// image, or a composite of both). Scoring goes through clipScore, so
    /// videos take the max over their sampled frames exactly like text
    /// search. Folder intersection mirrors searchPhotos — smart folders
    /// resolve via photosForFolder, which calls back in with no folderID, so
    /// there's no recursion. The 0.2 default floor is deliberately
    /// permissive; callers pass their calibrated one (0.25 text-style,
    /// 0.55 image-anchored).
    func searchByEmbedding(_ emb: [Float], folderID: String? = nil, floor: Float = 0.2,
                           limit: Int? = nil) -> [(photo: LocalPhoto, score: Float)] {
        guard !emb.isEmpty else { return [] }
        var candidates = photos.filter { !$0.isDeleted }
        if let fid = folderID, !fid.isEmpty,
           let folder = folders.first(where: { $0.id == fid }) {
            let ids = folder.isSmart
                ? Set(photosForFolder(folder).map(\.assetID))
                : Set(folder.photoAssetIDs)
            candidates = candidates.filter { ids.contains($0.assetID) }
        }
        let scored = candidates
            .compactMap { p -> (photo: LocalPhoto, score: Float)? in
                guard let s = clipScore(assetID: p.assetID, query: emb), s >= floor
                else { return nil }
                return (p, s)
            }
            .sorted { $0.score > $1.score }
        if let limit { return Array(scored.prefix(limit)) }
        return scored
    }

    /// Compose one query vector from any mix of an anchor photo's stored
    /// CLIP embedding, base text, and plus/minus text terms — CLIP's shared
    /// image/text space makes the arithmetic meaningful ("this photo, but at
    /// night"). Anchor/base/plus add at full weight; minus terms subtract at
    /// 0.8, because a full-strength subtraction overshoots and starts
    /// matching the concept's visual opposite instead of merely avoiding it.
    /// Returns nil when the text encoder is unavailable (simulator!), an
    /// encode throws, or no component is non-empty — callers must handle nil.
    func compositeQueryEmbedding(anchorAssetID: String? = nil,
                                 baseText: String? = nil,
                                 plus: [String] = [],
                                 minus: [String] = []) -> [Float]? {
        let engine = OnDeviceMLEngine.shared
        guard engine.isAvailable else { return nil }

        var v: [Float] = []
        var hasComponent = false
        func accumulate(_ emb: [Float], _ weight: Float) {
            guard !emb.isEmpty else { return }
            if v.isEmpty { v = [Float](repeating: 0, count: emb.count) }
            guard emb.count == v.count else { return }
            for i in emb.indices { v[i] += emb[i] * weight }
            hasComponent = true
        }

        if let anchor = anchorAssetID, let emb = clipEmbeddings[anchor] {
            accumulate(emb, 1.0)
        }
        var terms: [(text: String, weight: Float)] = []
        if let base = baseText?.trimmingCharacters(in: .whitespaces), !base.isEmpty {
            terms.append((base, 1.0))
        }
        for t in plus {
            let s = t.trimmingCharacters(in: .whitespaces)
            if !s.isEmpty { terms.append((s, 1.0)) }
        }
        for t in minus {
            let s = t.trimmingCharacters(in: .whitespaces)
            if !s.isEmpty { terms.append((s, -0.8)) }
        }
        for (text, weight) in terms {
            guard let emb = try? engine.encodeText(text) else { return nil }
            accumulate(emb, weight)
        }
        guard hasComponent else { return nil }
        return l2Normalize(v)
    }

    /// The best-matching moment inside each video for a text query: the
    /// argmax sampled frame and its score, one hit per video. Chronological
    /// (createdAt ascending) like a reel; floor matches the caption-search
    /// calibration. No engine (simulator) → empty.
    func videoMoments(matching query: String, floor: Float = 0.25, limit: Int = 60) -> [MomentHit] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let engine = OnDeviceMLEngine.shared
        guard !q.isEmpty, engine.isAvailable,
              let tEmb = try? engine.encodeText(q) else { return [] }

        var hits: [MomentHit] = []
        for p in photos where !p.isDeleted && p.video {
            guard let frames = videoFrameEmbeddings[p.assetID], !frames.isEmpty else { continue }
            var bestIdx = -1
            var bestScore: Float = -.greatestFiniteMagnitude
            for (i, f) in frames.enumerated() where !f.isEmpty {
                let s = dot(f, tEmb)
                if s > bestScore { bestScore = s; bestIdx = i }
            }
            guard bestIdx >= 0, bestScore >= floor else { continue }
            hits.append(MomentHit(assetID: p.assetID, frameIndex: bestIdx,
                                  frameCount: frames.count, score: bestScore,
                                  duration: p.duration ?? 0, createdAt: p.createdAt))
        }
        return Array(hits.sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
                         .prefix(limit))
    }

    /// "San Francisco, California" → "san francisco". Geocoded names are
    /// "City, State" / "City, Country"; users search by the city alone, so
    /// both location matching and caption-stripping key off the part before
    /// the first comma.
    private func cityPart(of name: String) -> String {
        let head = name.split(separator: ",", maxSplits: 1,
                              omittingEmptySubsequences: false).first ?? Substring(name)
        return head.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// Whole-word/phrase match of `term` inside `q`. A raw `q.contains(term)`
    /// over-matches: a person named "Mar" matches "marble", "dec" matches
    /// "decorations". Wrap the (regex-escaped) term in `\b…\b` so it only fires
    /// on word boundaries, while a multi-word term ("san francisco", "mary
    /// jane") still matches as a contiguous phrase. Mirrors the year filter's
    /// existing `\b(19|20)\d{2}\b` idiom. `term` is expected lowercased.
    private func matchesWord(_ term: String, in q: String) -> Bool {
        guard !term.isEmpty else { return false }
        let pattern = #"\b"# + NSRegularExpression.escapedPattern(for: term) + #"\b"#
        return q.range(of: pattern, options: .regularExpression) != nil
    }

    /// Words of the query left over after removing everything the structured
    /// filters consumed (years, matched location/person names, and — only
    /// when a month+year filter actually applied — month names) plus filler
    /// stopwords. What remains is the CLIP caption. Month words are kept when
    /// no month+year filter matched, so "may day parade" keeps "may" and a
    /// bare "june" stays a caption instead of matching everything.
    private func residualCaption(from q: String,
                                 matchedLocations: [LocalLocation],
                                 matchedClusters: [PersonCluster],
                                 monthYearMatched: Bool) -> String {
        var consumed = Set<String>()
        for loc in matchedLocations {
            // The filter matched on the city part / alias, so strip those
            // same tokens (the full stored name was never in the query).
            cityPart(of: loc.name).split(separator: " ").forEach { consumed.insert(String($0)) }
            if let alias = loc.alias {
                alias.lowercased().split(separator: " ").forEach { consumed.insert(String($0)) }
            }
        }
        for c in matchedClusters {
            c.name?.lowercased().split(separator: " ").forEach { consumed.insert(String($0)) }
        }
        let stop: Set<String> = [
            "a", "an", "the", "of", "in", "on", "at", "with", "and", "to", "from",
            "me", "my", "show", "find", "search", "for", "taken", "photo", "photos",
            "pic", "pics", "picture", "pictures", "image", "images", "all",
        ]
        let months: Set<String> = [
            "january", "february", "march", "april", "may", "june", "july",
            "august", "september", "october", "november", "december",
            "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec",
        ]
        let words = q.split(separator: " ").map(String.init).filter { w in
            if consumed.contains(w) || stop.contains(w) { return false }
            if monthYearMatched && months.contains(w) { return false }
            if w.range(of: #"^(19|20)\d{2}$"#, options: .regularExpression) != nil { return false }
            return true
        }
        return words.joined(separator: " ")
    }

    // MARK: - All photos (sorted, optionally filtered)

    func allPhotos(folderID: String? = nil) -> [LocalPhoto] {
        // The !isDeleted filter runs before the folder intersect: folder
        // photoAssetIDs keep soft-deleted members (so restore works), and
        // this is where they're hidden.
        var result = photos.filter { !$0.isDeleted }
        if let fid = folderID, !fid.isEmpty,
           let folder = folders.first(where: { $0.id == fid }) {
            let ids = Set(folder.photoAssetIDs)
            result = result.filter { ids.contains($0.assetID) }
        }
        return result.sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
    }

    func photos(forPeriod filter: String) -> [LocalPhoto] {
        // filter = "2024" (year), "2024-06" (year-month), or "2024-06-13" (day)
        let cal = Calendar.current
        return photos.filter { p in
            guard !p.isDeleted, let d = p.createdAt else { return false }
            if filter.count == 4, let y = Int(filter) {
                return cal.component(.year, from: d) == y
            }
            let parts = filter.split(separator: "-")
            if filter.count == 7, parts.count == 2,
               let y = Int(parts[0]), let m = Int(parts[1]) {
                return cal.component(.year, from: d) == y && cal.component(.month, from: d) == m
            }
            if filter.count == 10, parts.count == 3,
               let y = Int(parts[0]), let m = Int(parts[1]), let dd = Int(parts[2]) {
                return cal.component(.year, from: d) == y
                    && cal.component(.month, from: d) == m
                    && cal.component(.day, from: d) == dd
            }
            return false
        }.sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
    }

    // MARK: - Timeline

    struct PeriodInfo: Identifiable {
        let year: Int
        let month: Int?
        let count: Int
        let coverAssetID: String
        var id: String { month.map { "\(year)-\($0)" } ?? "\(year)" }
        var label: String {
            guard let m = month else { return "\(year)" }
            if let d = Calendar.current.date(from: DateComponents(year: year, month: m)) {
                return d.formatted(.dateTime.month(.wide).year())
            }
            return "\(year)-\(m)"
        }
        var timestampFilter: String {
            guard let m = month else { return "\(year)" }
            return "\(year)-\(String(format: "%02d", m))"
        }
    }

    var yearsIndex: [PeriodInfo] {
        var byYear: [Int: [LocalPhoto]] = [:]
        for p in photos where !p.isDeleted {
            guard let d = p.createdAt else { continue }
            let y = Calendar.current.component(.year, from: d)
            byYear[y, default: []].append(p)
        }
        return byYear.sorted { $0.key > $1.key }.map { y, ps in
            let sorted = ps.sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
            return PeriodInfo(year: y, month: nil, count: ps.count,
                              coverAssetID: sorted.first?.assetID ?? "")
        }
    }

    var monthsIndex: [PeriodInfo] {
        var byYM: [Int: [Int: [LocalPhoto]]] = [:]
        let cal = Calendar.current
        for p in photos where !p.isDeleted {
            guard let d = p.createdAt else { continue }
            let y = cal.component(.year, from: d)
            let m = cal.component(.month, from: d)
            byYM[y, default: [:]][m, default: []].append(p)
        }
        var result: [PeriodInfo] = []
        for (y, months) in byYM {
            for (m, ps) in months {
                let sorted = ps.sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
                result.append(PeriodInfo(year: y, month: m, count: ps.count,
                                         coverAssetID: sorted.first?.assetID ?? ""))
            }
        }
        return result.sorted {
            $0.year != $1.year ? $0.year > $1.year : ($0.month ?? 0) > ($1.month ?? 0)
        }
    }

    // MARK: - Reset

    func resetIndex() {
        // Stop the geocode drain first — an in-flight lookup resolving after
        // the wipe would repopulate Places from stale state. Bump the drain
        // generation so the cancelled task's cleanup can't clobber the handle
        // of a drain started by post-reset indexing.
        geocodeDrainTask?.cancel()
        geocodeDrainTask = nil
        geocodeDrainGeneration += 1
        geocodePending = [:]

        photos = []; clusters = []; locations = []; folders = []
        clipEmbeddings = [:]; videoFrameEmbeddings = [:]
        photoIndex = [:]; nextPhotoID = 0; nextClusterID = 0
        // The cluster ID space is gone; a SharpnessBackfill mid-run matched
        // faces against the pre-reset prototypes and must not keep writing
        // those IDs onto freshly re-indexed photos (same assetIDs reappear
        // as the indexer re-walks the library).
        clusterEpoch += 1
        try? FileManager.default.removeItem(at: Self.photosURL)
        try? FileManager.default.removeItem(at: Self.clustersURL)
        try? FileManager.default.removeItem(at: Self.locationsURL)
        try? FileManager.default.removeItem(at: Self.foldersURL)
        try? FileManager.default.removeItem(at: Self.embeddingsURL)
        try? FileManager.default.removeItem(at: Self.clipBinURL)
        try? FileManager.default.removeItem(at: Self.videoFramesURL)
        faceLog.reset()
        try? FileManager.default.removeItem(at: Self.geocodePendingURL)

        // Synchronous full write of the cleared state. Without it, a pending
        // debounced persist (or nothing at all) raced relaunch and the old
        // stores resurrected; persistAll also cancels that debounce and bumps
        // the embeddings generation so an in-flight async flush can't bring
        // the old binary back.
        persistAll()
    }

    // MARK: - Math

    /// nonisolated static so the detached autoCategories scoring loop can
    /// use it; the instance method below keeps existing call sites working.
    nonisolated static func dot(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        // vDSP: ~10× the scalar loop. This runs against every stored photo
        // for duplicate checks and caption-search ranking, so it adds up.
        var result: Float = 0
        vDSP_dotpr(a, 1, b, 1, &result, vDSP_Length(a.count))
        return result
    }

    func dot(_ a: [Float], _ b: [Float]) -> Float { Self.dot(a, b) }

    func l2Normalize(_ v: [Float]) -> [Float] {
        let norm = v.map { $0 * $0 }.reduce(0, +).squareRoot() + 1e-10
        return v.map { $0 / norm }
    }

    // MARK: - Helpers

    private func parseMonthYear(_ q: String) -> (year: Int, month: Int)? {
        let months = ["january":1,"february":2,"march":3,"april":4,"may":5,"june":6,
                      "july":7,"august":8,"september":9,"october":10,"november":11,"december":12,
                      "jan":1,"feb":2,"mar":3,"apr":4,"jun":6,"jul":7,"aug":8,
                      "sep":9,"oct":10,"nov":11,"dec":12]
        for (name, m) in months {
            // Word-bounded: a bare q.contains would let "dec" match
            // "decorations", "mar" match "marble". (Same class of bug as the
            // person/location filters above.)
            if matchesWord(name, in: q) {
                if let range = q.range(of: #"\b(19|20)\d{2}\b"#, options: .regularExpression),
                   let y = Int(q[range]) {
                    return (y, m)
                }
            }
        }
        return nil
    }
}

// MARK: - Per-frame video embedding codec

/// Flat binary serialization for `[String: [[Float]]]` — per-video sampled-
/// frame CLIP embeddings (videoframes.bin). A variant of
/// BinaryEmbeddingCodec, whose format only fits one vector per key: this one
/// count-prefixes a frame list per key instead. Distinct magic so neither
/// file can be mis-decoded as the other.
///
/// Format (little-endian):
///   [UInt32 magic][UInt32 entryCount]
///   per entry: [UInt16 keyLen][key UTF-8][UInt16 frameCount]
///              per frame: [UInt32 floatCount][floats]
enum BinaryFrameEmbeddingCodec {
    private static let magic: UInt32 = 0x5053_4632  // "PSF2"

    static func encode(_ dict: [String: [[Float]]]) -> Data {
        var data = Data()
        data.reserveCapacity(16 + dict.count * (64 + 8 * 512 * 4))
        data.appendLE(magic)
        data.appendLE(UInt32(dict.count))
        for (key, frames) in dict {
            let kb = Data(key.utf8)
            data.appendLE(UInt16(kb.count))
            data.append(kb)
            data.appendLE(UInt16(frames.count))
            for frame in frames {
                data.appendLE(UInt32(frame.count))
                frame.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
            }
        }
        return data
    }

    static func decode(_ data: Data) -> [String: [[Float]]]? {
        var cur = FrameDataCursor(data)
        guard cur.readLE(UInt32.self) == magic,
              let count = cur.readLE(UInt32.self) else { return nil }
        var dict = [String: [[Float]]](minimumCapacity: Int(count))
        for _ in 0..<count {
            guard let keyLen = cur.readLE(UInt16.self),
                  let keyData = cur.readBytes(Int(keyLen)),
                  let key = String(data: keyData, encoding: .utf8),
                  let frameCount = cur.readLE(UInt16.self) else { return nil }
            var frames: [[Float]] = []
            frames.reserveCapacity(Int(frameCount))
            for _ in 0..<frameCount {
                guard let floatCount = cur.readLE(UInt32.self),
                      let values = cur.readFloats(Int(floatCount)) else { return nil }
                frames.append(values)
            }
            dict[key] = frames
        }
        return dict
    }
}

/// Sequential little-endian reader, nil past the end (truncated file ⇒
/// decode fails, store starts empty). Same shape as EmbeddingStore's
/// DataCursor, which is private to that file.
private struct FrameDataCursor {
    let data: Data
    var offset: Int

    init(_ data: Data) { self.data = data; offset = data.startIndex }

    mutating func readLE<T: FixedWidthInteger>(_ type: T.Type) -> T? {
        let size = MemoryLayout<T>.size
        guard offset + size <= data.endIndex else { return nil }
        var v: T = 0
        _ = withUnsafeMutableBytes(of: &v) { data.copyBytes(to: $0, from: offset..<offset + size) }
        offset += size
        return T(littleEndian: v)
    }

    mutating func readBytes(_ count: Int) -> Data? {
        guard count >= 0, offset + count <= data.endIndex else { return nil }
        defer { offset += count }
        return data.subdata(in: offset..<offset + count)
    }

    mutating func readFloats(_ count: Int) -> [Float]? {
        guard let raw = readBytes(count * 4) else { return nil }
        return raw.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}
