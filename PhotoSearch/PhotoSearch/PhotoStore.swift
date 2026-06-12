import Accelerate
import CoreLocation
import Photos
import SwiftUI

// MARK: - Data models

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

    var isSmart: Bool { !(query ?? "").isEmpty }
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
    private static var facesLogURL:   URL { storeDir.appendingPathComponent("face_embeddings.bin") }

    /// Per-photo face embeddings, disk-only (read in one pass when
    /// re-clustering — never held resident).
    private let faceLog = FaceEmbeddingLog(url: PhotoStore.facesLogURL)

    // MARK: - Load / Persist

    func load() {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: Self.photosURL),
           let arr  = try? dec.decode([LocalPhoto].self, from: data) {
            photos = arr
            photoIndex = Dictionary(uniqueKeysWithValues: arr.enumerated().map { ($1.assetID, $0) })
            nextPhotoID = (arr.map(\.photoID).max() ?? -1) + 1
        }
        if let data = try? Data(contentsOf: Self.clustersURL),
           let arr  = try? dec.decode([PersonCluster].self, from: data) {
            clusters = arr
            nextClusterID = (arr.map(\.id).max() ?? -1) + 1
        }
        if let data = try? Data(contentsOf: Self.locationsURL),
           let arr  = try? dec.decode([LocalLocation].self, from: data) {
            locations = arr
        }
        if let data = try? Data(contentsOf: Self.foldersURL),
           let arr  = try? dec.decode([LocalFolder].self, from: data) {
            folders = arr
        }
        // CLIP embeddings: binary store, with one-time migration from the
        // legacy JSON file (JSON cost 100MB+ encodes and slow launches at
        // tens of thousands of photos).
        if let data = try? Data(contentsOf: Self.clipBinURL),
           let dict = BinaryEmbeddingCodec.decode(data) {
            clipEmbeddings = dict
        } else if let data = try? Data(contentsOf: Self.embeddingsURL),
                  let dict = try? JSONDecoder().decode([String: [Float]].self, from: data) {
            clipEmbeddings = dict
            try? BinaryEmbeddingCodec.encode(dict).write(to: Self.clipBinURL, options: .atomic)
            try? FileManager.default.removeItem(at: Self.embeddingsURL)
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
    }

    func persist() {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try? enc.encode(photos).write(to: Self.photosURL, options: .atomic)
        try? enc.encode(clusters).write(to: Self.clustersURL, options: .atomic)
        try? enc.encode(locations).write(to: Self.locationsURL, options: .atomic)
        try? enc.encode(folders).write(to: Self.foldersURL, options: .atomic)
        try? BinaryEmbeddingCodec.encode(clipEmbeddings).write(to: Self.clipBinURL, options: .atomic)
        try? JSONEncoder().encode(geocodeCache).write(to: Self.geocodeCacheURL, options: .atomic)
        try? JSONEncoder().encode(geocodePending).write(to: Self.geocodePendingURL, options: .atomic)
    }

    private var persistTask: Task<Void, Never>?
    func schedulePersist() {
        persistTask?.cancel()
        persistTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            persist()
        }
    }

    // MARK: - Indexing

    func contains(assetID: String) -> Bool { photoIndex[assetID] != nil }

    func index(
        assetID: String,
        createdAt: Date?,
        lat: Double?, lon: Double?,
        clipEmbedding: [Float],
        faceEmbeddings: [[Float]],
        faceRects: [CGRect],
        isVideo: Bool = false,
        duration: Double? = nil
    ) {
        guard !contains(assetID: assetID) else { return }

        clipEmbeddings[assetID] = clipEmbedding

        // Keep raw face embeddings on disk so the global re-cluster pass
        // (reclusterPeople) can see every face, not just cluster prototypes.
        faceLog.append(assetID: assetID, embeddings: faceEmbeddings, rects: faceRects)

        let clusterIDs = assignFaces(embeddings: faceEmbeddings, rects: faceRects, toAssetID: assetID)

        var photo = LocalPhoto(
            assetID: assetID,
            photoID: nextPhotoID,
            createdAt: createdAt,
            lat: lat, lon: lon,
            locationName: nil,
            personClusterIDs: clusterIDs,
            dupGroupID: nil,
            isDeleted: false,
            isVideo: isVideo ? true : nil,
            duration: isVideo ? duration : nil
        )
        nextPhotoID += 1

        markDuplicateIfNeeded(&photo, embedding: clipEmbedding)

        photoIndex[assetID] = photos.count
        photos.append(photo)

        if let lat, let lon {
            enqueueGeocode(assetID: assetID, lat: lat, lon: lon)
        }

        schedulePersist()
    }

    // MARK: - Duplicate detection

    private func markDuplicateIfNeeded(_ photo: inout LocalPhoto, embedding: [Float]) {
        for other in photos where !other.isDeleted && other.video == photo.video {
            guard let otherEmb = clipEmbeddings[other.assetID] else { continue }
            if dot(embedding, otherEmb) > 0.97 {
                let gid = other.dupGroupID ?? other.assetID
                photo.dupGroupID = gid
                if let idx = photoIndex[other.assetID], photos[idx].dupGroupID == nil {
                    photos[idx].dupGroupID = gid
                }
                return
            }
        }
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

    /// Rebuild People from scratch with a global DBSCAN over every stored
    /// face embedding — the same algorithm (and thresholds) the Python
    /// backend used for full re-indexes. The live greedy assignment is
    /// order-dependent and can split a person across clusters; this pass
    /// sees all faces at once. User-assigned names are carried onto the
    /// best-matching new clusters by prototype similarity.
    func reclusterPeople() async {
        guard !isReclustering else { return }
        isReclustering = true
        defer { isReclustering = false }

        // Snapshots for the off-main compute.
        let validAssets = Set(photoIndex.keys)
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
        for i in photos.indices {
            photos[i].personClusterIDs = result.assignments[photos[i].assetID] ?? []
        }
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
        startGeocodeDrain()
    }

    func startGeocodeDrain() {
        guard geocodeDrainTask == nil, !geocodePending.isEmpty else { return }
        geocodeDrainTask = Task { [weak self] in
            await self?.drainGeocodeQueue()
            self?.geocodeDrainTask = nil
        }
    }

    private func drainGeocodeQueue() async {
        var failureStreak = 0
        while !Task.isCancelled, let (key, job) = geocodePending.first {
            do {
                let loc = CLLocation(latitude: job.lat, longitude: job.lon)
                let placemarks = try await geocoder.reverseGeocodeLocation(loc)
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
                schedulePersist()
                try? await Task.sleep(for: .seconds(1.5))   // stay under Apple's rate limit
            } catch let error as CLError where error.code == .geocodeFoundNoResult {
                geocodeCache[key] = ""
                geocodePending.removeValue(forKey: key)
                schedulePersist()
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
        if let idx = photoIndex[assetID] { photos[idx].locationName = name }
        if let li = locations.firstIndex(where: { $0.name == name }) {
            if !locations[li].photoAssetIDs.contains(assetID) {
                locations[li].photoAssetIDs.append(assetID)
            }
        } else {
            locations.append(LocalLocation(name: name, alias: nil,
                                           photoAssetIDs: [assetID], coverAssetID: assetID))
        }
        schedulePersist()
    }

    // MARK: - Delete

    func deletePhoto(assetID: String) {
        guard let idx = photoIndex[assetID] else { return }
        photos[idx].isDeleted = true
        for ci in 0..<clusters.count  { clusters[ci].photoAssetIDs.removeAll { $0 == assetID } }
        for li in 0..<locations.count { locations[li].photoAssetIDs.removeAll { $0 == assetID } }
        for fi in 0..<folders.count   { folders[fi].photoAssetIDs.removeAll { $0 == assetID } }
        schedulePersist()
    }

    func deletePhoto(photoID: Int) {
        if let p = photos.first(where: { $0.photoID == photoID }) { deletePhoto(assetID: p.assetID) }
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
        schedulePersist()
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
        schedulePersist()
    }

    func setClusterName(id: Int, name: String) {
        guard let ci = clusterIndex(id) else { return }
        clusters[ci].name = name.trimmingCharacters(in: .whitespaces).isEmpty ? nil : name
        schedulePersist()
    }

    func deleteCluster(id: Int) {
        guard let ci = clusterIndex(id) else { return }
        clusters[ci].isDeleted = true
        schedulePersist()
    }

    // MARK: - Locations

    func photos(forLocation name: String) -> [LocalPhoto] {
        photos.filter { $0.locationName == name && !$0.isDeleted }
              .sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
    }

    func setLocationAlias(name: String, alias: String) {
        guard let li = locations.firstIndex(where: { $0.name == name }) else { return }
        locations[li].alias = alias.trimmingCharacters(in: .whitespaces).isEmpty ? nil : alias
        schedulePersist()
    }

    // MARK: - Folders

    @discardableResult
    func createFolder(name: String, query: String? = nil) -> LocalFolder {
        let f = LocalFolder(id: UUID().uuidString, name: name, photoAssetIDs: [],
                            query: (query?.isEmpty == true) ? nil : query)
        folders.append(f)
        schedulePersist()
        return f
    }

    func setFolderQuery(id: String, query: String) {
        guard let fi = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[fi].query = query.isEmpty ? nil : query
        schedulePersist()
    }

    /// Evaluate a smart folder's saved search (static folders return their list).
    func photosForFolder(_ folder: LocalFolder) -> [LocalPhoto] {
        if let q = folder.query, !q.isEmpty {
            return searchPhotos(query: q)
        }
        return allPhotos(folderID: folder.id)
    }

    func renameFolder(id: String, name: String) {
        guard let fi = folders.firstIndex(where: { $0.id == id }), !name.isEmpty else { return }
        folders[fi].name = name
        schedulePersist()
    }

    func deleteFolder(id: String, deletePhotos: Bool) {
        if deletePhotos, let fi = folders.firstIndex(where: { $0.id == id }) {
            folders[fi].photoAssetIDs.forEach { deletePhoto(assetID: $0) }
        }
        folders.removeAll { $0.id == id }
        schedulePersist()
    }

    func addPhotos(_ assetIDs: [String], toFolder id: String) {
        guard let fi = folders.firstIndex(where: { $0.id == id }) else { return }
        for assetID in assetIDs where !folders[fi].photoAssetIDs.contains(assetID) {
            folders[fi].photoAssetIDs.append(assetID)
        }
        schedulePersist()
    }

    func removePhotos(_ assetIDs: [String], fromFolder id: String) {
        guard let fi = folders.firstIndex(where: { $0.id == id }) else { return }
        let s = Set(assetIDs); folders[fi].photoAssetIDs.removeAll { s.contains($0) }
        schedulePersist()
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

    private var categoryCache: (photoCount: Int, result: [String: [LocalPhoto]])?

    /// Score every photo against each category's text prompts. Prompt
    /// embeddings are computed once per call (a few CLIPText inferences);
    /// the scoring is vDSP over stored embeddings. Cached until the photo
    /// count changes.
    func autoCategories() -> [(category: AutoCategory, photos: [LocalPhoto])] {
        if let cached = categoryCache, cached.photoCount == photos.count {
            return AutoCategorizer.categories.compactMap { cat in
                guard let ps = cached.result[cat.id], !ps.isEmpty else { return nil }
                return (cat, ps)
            }
        }
        let engine = OnDeviceMLEngine.shared
        if !engine.isAvailable { try? engine.loadModels() }
        guard engine.isAvailable else { return [] }

        var result: [String: [LocalPhoto]] = [:]
        for cat in AutoCategorizer.categories {
            let promptEmbs = cat.prompts.compactMap { try? engine.encodeText($0) }
            guard !promptEmbs.isEmpty else { continue }
            var matches: [(LocalPhoto, Float)] = []
            for p in photos where !p.isDeleted {
                guard let emb = clipEmbeddings[p.assetID], !emb.isEmpty else { continue }
                var best: Float = -1
                for t in promptEmbs { best = max(best, dot(emb, t)) }
                if best >= cat.threshold { matches.append((p, best)) }
            }
            result[cat.id] = matches
                .sorted { ($0.0.createdAt ?? .distantPast) > ($1.0.createdAt ?? .distantPast) }
                .map(\.0)
        }
        categoryCache = (photos.count, result)
        return AutoCategorizer.categories.compactMap { cat in
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
        guard let target = clipEmbeddings[assetID], !target.isEmpty else { return [] }
        var scored: [(LocalPhoto, Float)] = []
        for p in photos where !p.isDeleted && p.assetID != assetID {
            guard let emb = clipEmbeddings[p.assetID], !emb.isEmpty else { continue }
            let s = dot(emb, target)
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

    func mergeDuplicates(a: Int, b: Int) {
        guard let pa = photos.first(where: { $0.photoID == a }),
              let pb = photos.first(where: { $0.photoID == b }) else { return }
        let gid = pa.dupGroupID ?? pa.assetID
        if let ia = photoIndex[pa.assetID] { photos[ia].dupGroupID = gid }
        if let ib = photoIndex[pb.assetID] { photos[ib].dupGroupID = gid }
        schedulePersist()
    }

    func ungroupDuplicates(forPhotoID photoID: Int) {
        guard let photo = photos.first(where: { $0.photoID == photoID }),
              let gid = photo.dupGroupID else { return }
        for i in 0..<photos.count where photos[i].dupGroupID == gid {
            photos[i].dupGroupID = nil
        }
        schedulePersist()
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
        schedulePersist()
        return deleted
    }

    // MARK: - Search

    func searchPhotos(query: String, folderID: String? = nil) -> [LocalPhoto] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }

        var results = photos.filter { !$0.isDeleted }

        // Folder filter
        if let fid = folderID, !fid.isEmpty,
           let folder = folders.first(where: { $0.id == fid }) {
            let ids = Set(folder.photoAssetIDs)
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

        // Month+year filter e.g. "june 2023" or "2023-06"
        if let (year, month) = parseMonthYear(q) {
            results = results.filter { p in
                guard let d = p.createdAt else { return false }
                let cal = Calendar.current
                return cal.component(.year, from: d) == year
                    && cal.component(.month, from: d) == month
            }
        }

        // Location filter
        let matchingLocs = locations.filter { loc in
            q.contains(loc.name.lowercased()) ||
            (loc.alias.map { q.contains($0.lowercased()) } ?? false)
        }
        if !matchingLocs.isEmpty {
            let nameSet = Set(matchingLocs.map(\.name))
            results = results.filter { ($0.locationName).map { nameSet.contains($0) } ?? false }
        }

        // Person name filter
        let matchingClusters = clusters.filter { c in
            guard let name = c.name, !name.isEmpty else { return false }
            return q.contains(name.lowercased())
        }
        if !matchingClusters.isEmpty {
            let resolvedIDs = Set(matchingClusters.map { resolvedClusterID($0.id) })
            results = results.filter { p in
                !Set(p.personClusterIDs.map { resolvedClusterID($0) }).isDisjoint(with: resolvedIDs)
            }
        }

        // Caption (CLIP) ranking: words not consumed by the structured filters
        // above are treated as content ("beach", "birthday cake", …) and used
        // to rank the remaining candidates by text↔image cosine similarity.
        // Mirrors the backend: CAPTION_FLOOR drops unrelated photos
        // (ViT-B/32 calibration: >0.30 strongly related, <0.22 unrelated).
        let caption = residualCaption(
            from: q, matchedLocations: matchingLocs, matchedClusters: matchingClusters)
        if !caption.isEmpty, let tEmb = try? OnDeviceMLEngine.shared.encodeText(caption) {
            let floor: Float = 0.25
            let scored: [(LocalPhoto, Float)] = results.compactMap { p in
                guard let emb = clipEmbeddings[p.assetID], !emb.isEmpty else { return nil }
                let s = dot(emb, tEmb)
                return s >= floor ? (p, s) : nil
            }
            return scored.sorted { $0.1 > $1.1 }.map { $0.0 }
        }

        return results.sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
    }

    /// Words of the query left over after removing everything the structured
    /// filters consumed (years, month names, matched location/person names)
    /// plus filler stopwords. What remains is the CLIP caption.
    private func residualCaption(from q: String,
                                 matchedLocations: [LocalLocation],
                                 matchedClusters: [PersonCluster]) -> String {
        var consumed = Set<String>()
        for loc in matchedLocations {
            loc.name.lowercased().split(separator: " ").forEach { consumed.insert(String($0)) }
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
            if consumed.contains(w) || stop.contains(w) || months.contains(w) { return false }
            if w.range(of: #"^(19|20)\d{2}$"#, options: .regularExpression) != nil { return false }
            return true
        }
        return words.joined(separator: " ")
    }

    // MARK: - All photos (sorted, optionally filtered)

    func allPhotos(folderID: String? = nil) -> [LocalPhoto] {
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
        photos = []; clusters = []; locations = []; folders = []
        clipEmbeddings = [:]; photoIndex = [:]; nextPhotoID = 0; nextClusterID = 0
        try? FileManager.default.removeItem(at: Self.photosURL)
        try? FileManager.default.removeItem(at: Self.clustersURL)
        try? FileManager.default.removeItem(at: Self.locationsURL)
        try? FileManager.default.removeItem(at: Self.embeddingsURL)
        try? FileManager.default.removeItem(at: Self.clipBinURL)
        faceLog.reset()
        geocodePending = [:]
        try? FileManager.default.removeItem(at: Self.geocodePendingURL)
    }

    // MARK: - Math

    func dot(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        // vDSP: ~10× the scalar loop. This runs against every stored photo
        // for duplicate checks and caption-search ranking, so it adds up.
        var result: Float = 0
        vDSP_dotpr(a, 1, b, 1, &result, vDSP_Length(a.count))
        return result
    }

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
            if q.contains(name) {
                if let range = q.range(of: #"\b(19|20)\d{2}\b"#, options: .regularExpression),
                   let y = Int(q[range]) {
                    return (y, m)
                }
            }
        }
        return nil
    }
}
