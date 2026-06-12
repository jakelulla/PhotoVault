import Accelerate
import Foundation

/// Global face re-clustering — a Swift port of the Python backend's pipeline
/// (build_index.py): DBSCAN over ALL face embeddings → per-person prototypes
/// → assign every face to a prototype. This is what made the backend's People
/// quality good: greedy one-photo-at-a-time assignment (the live indexing
/// path) is order-dependent and can split a person whose appearance varies;
/// a global pass sees everything at once.
///
/// Thresholds match the backend's tuned values:
///   - DBSCAN eps 0.40 cosine distance → faces link at similarity ≥ 0.60
///   - min_samples 3
///   - a face joins a person when ≥ 0.42 similar to its prototype
enum FaceReclusterer {
    static let linkSim: Float = 0.60
    static let minSamples = 3
    static let matchThreshold: Float = 0.42

    struct Face {
        let assetID: String
        let rect: [Double]          // normalized [x, y, w, h]
        let embedding: [Float]      // L2-normalized
    }

    /// A person produced by the global pass. Free of app model types so this
    /// file is testable standalone; PhotoStore maps these onto PersonCluster.
    struct ClusterOut {
        var name: String?
        var prototype: [Float]
        var photoAssetIDs: [String]
        var representativeAssetID: String
        var faceNormalizedRect: [Double]
    }

    struct Result {
        var clusters: [ClusterOut]
        /// assetID → cluster indices (into `clusters`), one entry per
        /// assigned face in that photo. Photos in the input with no assigned
        /// faces are present with an empty array.
        var assignments: [String: [Int]]
        /// assetID → per-face cluster index (into `clusters`) in input/log
        /// order, one entry per face INCLUDING unassigned/unusable ones
        /// (nil). PhotoStore rewrites each stored PhotoFace.clusterID
        /// positionally from this after applying the result — the rebuild
        /// renumbers every cluster from 0, so a stale stored ID would
        /// silently resolve to a different person.
        var faceAssignments: [String: [Int?]]
    }

    /// Named prototypes from the previous clustering, used to carry
    /// user-assigned names onto the new clusters.
    struct NamedPrototype {
        let name: String
        let prototype: [Float]
    }

    // MARK: - Entry point

    static func recluster(faces: [Face], previousNames: [NamedPrototype]) -> Result? {
        guard faces.count >= minSamples else { return nil }
        let dim = faces[0].embedding.count
        let usable = faces.filter { $0.embedding.count == dim }
        let n = usable.count
        guard n >= minSamples else { return nil }

        var flat = [Float](); flat.reserveCapacity(n * dim)
        for f in usable { flat.append(contentsOf: f.embedding) }

        let neighbors = neighborLists(flat: flat, n: n, dim: dim, minSim: linkSim)
        let (labels, clusterCount) = dbscan(neighbors: neighbors, n: n)
        guard clusterCount > 0 else { return nil }

        // Prototypes: L2-normalized mean of each cluster's member embeddings.
        var prototypes = [[Float]](repeating: [Float](repeating: 0, count: dim),
                                   count: clusterCount)
        var memberCounts = [Int](repeating: 0, count: clusterCount)
        for i in 0..<n where labels[i] >= 0 {
            let c = labels[i]
            for d in 0..<dim { prototypes[c][d] += flat[i * dim + d] }
            memberCounts[c] += 1
        }
        for c in 0..<clusterCount {
            let norm = sqrt(prototypes[c].reduce(0) { $0 + $1 * $1 }) + 1e-10
            for d in 0..<dim { prototypes[c][d] /= norm }
        }

        // Assignment pass: EVERY face (including DBSCAN noise) joins its most
        // similar prototype if ≥ matchThreshold — same as the backend's
        // labeling step.
        var clusters = (0..<clusterCount).map { c in
            ClusterOut(name: nil, prototype: prototypes[c], photoAssetIDs: [],
                       representativeAssetID: "", faceNormalizedRect: [0, 0, 0, 0])
        }
        var assignments: [String: [Int]] = [:]
        var bestArea = [Double](repeating: -1, count: clusterCount)
        /// Per-usable-face winning cluster (nil = below matchThreshold) —
        /// folded back into per-asset, input-order lists below.
        var usableWinners = [Int?](repeating: nil, count: n)

        for (i, face) in usable.enumerated() {
            if assignments[face.assetID] == nil { assignments[face.assetID] = [] }
            var bestC = -1
            var bestSim = matchThreshold
            for c in 0..<clusterCount {
                var sim: Float = 0
                flat.withUnsafeBufferPointer { fp in
                    prototypes[c].withUnsafeBufferPointer { pp in
                        vDSP_dotpr(fp.baseAddress! + i * dim, 1, pp.baseAddress!, 1,
                                   &sim, vDSP_Length(dim))
                    }
                }
                if sim > bestSim { bestSim = sim; bestC = c }
            }
            guard bestC >= 0 else { continue }
            usableWinners[i] = bestC
            assignments[face.assetID]?.append(bestC)
            if !clusters[bestC].photoAssetIDs.contains(face.assetID) {
                clusters[bestC].photoAssetIDs.append(face.assetID)
            }
            // Representative = biggest face seen (sharpest, best-framed cover)
            let area = face.rect.count == 4 ? face.rect[2] * face.rect[3] : 0
            if area > bestArea[bestC] {
                bestArea[bestC] = area
                clusters[bestC].representativeAssetID = face.assetID
                clusters[bestC].faceNormalizedRect = face.rect
            }
        }

        // Carry user-assigned names: match old named prototypes to the most
        // similar new prototype (best matches first, one name per cluster).
        var nameCandidates: [(sim: Float, name: String, cluster: Int)] = []
        for old in previousNames where old.prototype.count == dim {
            for c in 0..<clusterCount {
                var sim: Float = 0
                vDSP_dotpr(old.prototype, 1, prototypes[c], 1, &sim, vDSP_Length(dim))
                if sim >= matchThreshold {
                    nameCandidates.append((sim, old.name, c))
                }
            }
        }
        for cand in nameCandidates.sorted(by: { $0.sim > $1.sim }) {
            if clusters[cand.cluster].name == nil {
                clusters[cand.cluster].name = cand.name
            }
        }

        // Per-asset face assignments in input order, one entry per face of
        // the ORIGINAL input — unusable faces (wrong dim) keep a nil slot so
        // the lists stay positionally parallel with the face log (and thus
        // with the PhotoFace arrays stored on photos).
        var faceAssignments: [String: [Int?]] = [:]
        var u = 0
        for f in faces {
            if f.embedding.count == dim {
                faceAssignments[f.assetID, default: []].append(usableWinners[u])
                u += 1
            } else {
                faceAssignments[f.assetID, default: []].append(nil)
            }
        }

        // Drop clusters that ended up with no photos (all members stolen by a
        // more similar prototype) and remap assignment indices.
        var remap = [Int](repeating: -1, count: clusterCount)
        var kept: [ClusterOut] = []
        for c in 0..<clusterCount where !clusters[c].photoAssetIDs.isEmpty {
            remap[c] = kept.count
            kept.append(clusters[c])
        }
        for (asset, list) in assignments {
            assignments[asset] = list.compactMap { remap[$0] >= 0 ? remap[$0] : nil }
        }
        for (asset, list) in faceAssignments {
            faceAssignments[asset] = list.map { c -> Int? in
                guard let c, remap[c] >= 0 else { return nil }
                return remap[c]
            }
        }

        return Result(clusters: kept, assignments: assignments,
                      faceAssignments: faceAssignments)
    }

    // MARK: - Neighbor graph (blocked similarity matrix via BLAS)

    /// For each face, indices of all faces with cosine similarity ≥ minSim.
    /// Computed as a blocked X·Xᵀ so memory stays bounded (~48MB per block)
    /// even at tens of thousands of faces.
    private static func neighborLists(flat: [Float], n: Int, dim: Int,
                                      minSim: Float) -> [[Int32]] {
        var neighbors = [[Int32]](repeating: [], count: n)
        let blockRows = max(32, min(2048, (48 << 20) / (4 * max(n, 1))))
        var sims = [Float](repeating: 0, count: blockRows * n)

        var start = 0
        while start < n {
            let rows = min(blockRows, n - start)
            flat.withUnsafeBufferPointer { fp in
                sims.withUnsafeMutableBufferPointer { sp in
                    cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans,
                                Int32(rows), Int32(n), Int32(dim),
                                1.0, fp.baseAddress! + start * dim, Int32(dim),
                                fp.baseAddress!, Int32(dim),
                                0.0, sp.baseAddress!, Int32(n))
                }
            }
            for r in 0..<rows {
                let i = start + r
                let row = r * n
                for j in 0..<n where sims[row + j] >= minSim && j != i {
                    neighbors[i].append(Int32(j))
                }
            }
            start += rows
        }
        return neighbors
    }

    // MARK: - DBSCAN

    /// Classic DBSCAN over precomputed neighbor lists. Returns per-face
    /// labels (-1 = noise) and the number of clusters found.
    private static func dbscan(neighbors: [[Int32]], n: Int) -> ([Int], Int) {
        var labels = [Int](repeating: -1, count: n)
        var visited = [Bool](repeating: false, count: n)
        var clusterCount = 0

        for i in 0..<n where !visited[i] {
            visited[i] = true
            // +1: the point itself counts toward min_samples (sklearn semantics)
            guard neighbors[i].count + 1 >= minSamples else { continue }

            let c = clusterCount
            clusterCount += 1
            labels[i] = c

            var queue = neighbors[i]
            var qi = 0
            while qi < queue.count {
                let j = Int(queue[qi]); qi += 1
                if labels[j] == -1 { labels[j] = c }   // claim border/noise point
                if !visited[j] {
                    visited[j] = true
                    if neighbors[j].count + 1 >= minSamples {
                        queue.append(contentsOf: neighbors[j])  // j is core: expand
                    }
                }
            }
        }
        return (labels, clusterCount)
    }
}
