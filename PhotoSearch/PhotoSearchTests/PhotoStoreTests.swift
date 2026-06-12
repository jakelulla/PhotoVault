import CoreGraphics
import XCTest
@testable import PhotoSearch

/// Persistence + membership lifecycle tests. These run inside the host app's
/// simulator container, so PhotoStore.shared's on-disk state is the test
/// app's own documents directory — wiped via resetIndex() per test.
@MainActor
final class PhotoStoreTests: XCTestCase {

    var store: PhotoStore { PhotoStore.shared }

    override func setUp() async throws {
        store.resetIndex()
    }

    override func tearDown() async throws {
        store.resetIndex()
    }

    private func indexPhoto(_ id: String, emb: [Float]? = nil, createdAt: Date = Date(),
                            faceEmbeddings: [[Float]] = [], faceRects: [CGRect] = [],
                            faceSharpness: [Float]? = nil, imageSharpness: Float? = nil) {
        store.index(
            assetID: id, createdAt: createdAt, lat: nil, lon: nil,
            clipEmbedding: emb ?? [Float](repeating: 0, count: 512),
            faceEmbeddings: faceEmbeddings, faceRects: faceRects,
            isVideo: false, duration: 0,
            faceSharpness: faceSharpness, imageSharpness: imageSharpness
        )
    }

    /// Distinct unit vector along the given axis — guaranteed orthogonal to
    /// other axes (cosine 0), so photos don't accidentally duplicate-group.
    private func unitEmb(axis: Int) -> [Float] {
        var v = [Float](repeating: 0, count: 512)
        v[axis] = 1
        return v
    }

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: y, month: m, day: d))!
    }

    /// Cluster ID a photo's single face was assigned to at index time.
    private func clusterID(of assetID: String, faceIndex: Int = 0) -> Int {
        store.photos.first { $0.assetID == assetID }!.personClusterIDs[faceIndex]
    }

    // MARK: - Delete / restore lifecycle

    func testDeleteIsAppOnlySoftDelete() {
        indexPhoto("a", emb: unitEmb(axis: 0))
        store.deletePhoto(assetID: "a")
        // Record stays (soft), flagged deleted, hidden from active queries.
        XCTAssertTrue(store.contains(assetID: "a"))
        XCTAssertTrue(store.photos.first { $0.assetID == "a" }!.isDeleted)
        XCTAssertFalse(store.allPhotos().contains { $0.assetID == "a" })
    }

    func testRestoreBringsPhotoBack() {
        indexPhoto("a", emb: unitEmb(axis: 0))
        store.deletePhoto(assetID: "a")
        let restored = store.restorePhotos(["a"])
        XCTAssertEqual(restored, 1)
        XCTAssertTrue(store.allPhotos().contains { $0.assetID == "a" })
        // Restoring an active photo is a no-op.
        XCTAssertEqual(store.restorePhotos(["a"]), 0)
    }

    func testFolderMembershipSurvivesDeleteAndRestore() {
        indexPhoto("a", emb: unitEmb(axis: 0))
        store.createFolder(name: "Trip", query: nil)
        let folder = store.folders.first!
        store.addPhotos(["a"], toFolder: folder.id)

        store.deletePhoto(assetID: "a")
        // Membership preserved while hidden; active count reflects deletion.
        XCTAssertTrue(store.folders.first!.photoAssetIDs.contains("a"))
        XCTAssertEqual(store.activeCount(in: store.folders.first!), 0)

        store.restorePhotos(["a"])
        XCTAssertEqual(store.activeCount(in: store.folders.first!), 1)
    }

    func testPruneStripsFolderMembership() {
        indexPhoto("a", emb: unitEmb(axis: 0))
        store.createFolder(name: "Trip", query: nil)
        store.addPhotos(["a"], toFolder: store.folders.first!.id)

        store.pruneDeletedAssets(["a"])  // asset gone from camera roll
        XCTAssertFalse(store.folders.first!.photoAssetIDs.contains("a"))
        XCTAssertTrue(store.photos.first { $0.assetID == "a" }!.isDeleted)
    }

    func testRestoreDoesNotSelfDuplicate() {
        // Regression: the dup re-check on restore must not match the photo
        // against itself (dot(e, e) ≈ 1 > 0.97 → phantom singleton group).
        indexPhoto("solo", emb: unitEmb(axis: 3))
        store.deletePhoto(assetID: "solo")
        store.restorePhotos(["solo"])
        XCTAssertNil(store.photos.first { $0.assetID == "solo" }!.dupGroupID)
    }

    func testDuplicateDetectionGroupsIdenticalEmbeddings() {
        indexPhoto("a", emb: unitEmb(axis: 0))
        indexPhoto("b", emb: unitEmb(axis: 0))  // identical → dup
        indexPhoto("c", emb: unitEmb(axis: 1))  // orthogonal → not
        let a = store.photos.first { $0.assetID == "a" }!
        let b = store.photos.first { $0.assetID == "b" }!
        let c = store.photos.first { $0.assetID == "c" }!
        XCTAssertNotNil(b.dupGroupID)
        XCTAssertEqual(a.dupGroupID ?? a.assetID, b.dupGroupID)
        XCTAssertNil(c.dupGroupID)
    }

    // MARK: - Persistence round-trip

    func testPersistAndReload() async {
        indexPhoto("a", emb: unitEmb(axis: 0))
        indexPhoto("b", emb: unitEmb(axis: 1))
        store.deletePhoto(assetID: "b")
        await store.persistAndWait()

        // Reload from disk into the same singleton (load() re-reads files).
        store.load()
        XCTAssertEqual(store.photos.count, 2)
        XCTAssertFalse(store.photos.first { $0.assetID == "a" }!.isDeleted)
        XCTAssertTrue(store.photos.first { $0.assetID == "b" }!.isDeleted)
        XCTAssertEqual(store.clipEmbeddings["a"]?.count, 512)
    }

    func testResetIndexClearsEverything() async {
        indexPhoto("a", emb: unitEmb(axis: 0))
        store.createFolder(name: "Trip", query: nil)
        await store.persistAndWait()

        store.resetIndex()
        XCTAssertTrue(store.photos.isEmpty)
        XCTAssertTrue(store.folders.isEmpty)
        store.load()  // a reload must not resurrect anything
        XCTAssertTrue(store.photos.isEmpty)
        XCTAssertTrue(store.folders.isEmpty)
    }

    // MARK: - Per-photo face data (index pairing + backfill)

    func testIndexPopulatesFacesPairing() {
        indexPhoto("f1", emb: unitEmb(axis: 0),
                   faceEmbeddings: [unitEmb(axis: 10), unitEmb(axis: 11)],
                   faceRects: [CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
                               CGRect(x: 0.5, y: 0.5, width: 0.2, height: 0.2)],
                   faceSharpness: [12.5, 3.25], imageSharpness: 88)
        let p = store.photos.first { $0.assetID == "f1" }!
        XCTAssertEqual(p.sharpness, 88)
        let faces = p.faces ?? []
        XCTAssertEqual(faces.count, 2)
        XCTAssertEqual(faces[0].rect, [0.1, 0.2, 0.3, 0.4])
        XCTAssertEqual(faces[1].rect, [0.5, 0.5, 0.2, 0.2])
        XCTAssertEqual(faces[0].sharpness, 12.5)
        XCTAssertEqual(faces[1].sharpness, 3.25)
        // Face order follows faceEmbeddings order, same as personClusterIDs —
        // each stored face carries the cluster its embedding was assigned to.
        XCTAssertEqual(faces.map(\.clusterID), p.personClusterIDs.map { Optional($0) })
        XCTAssertNotEqual(faces[0].clusterID, faces[1].clusterID)  // orthogonal faces → distinct people
    }

    func testIndexFaceSharpnessCountMismatchDropsSharpness() {
        indexPhoto("f2", emb: unitEmb(axis: 1),
                   faceEmbeddings: [unitEmb(axis: 10), unitEmb(axis: 11)],
                   faceRects: [CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2),
                               CGRect(x: 0.6, y: 0.6, width: 0.2, height: 0.2)],
                   faceSharpness: [7])  // one value for two faces → pairing untrustworthy
        let faces = store.photos.first { $0.assetID == "f2" }!.faces ?? []
        XCTAssertEqual(faces.count, 2)
        XCTAssertTrue(faces.allSatisfy { $0.sharpness == nil })
    }

    func testSetFaceDataOverwritesOnlyNonNilArgs() {
        indexPhoto("a", emb: unitEmb(axis: 0), imageSharpness: 5)
        store.setFaceData(assetID: "a",
                          faces: [PhotoFace(clusterID: nil, rect: [0, 0, 1, 1], sharpness: 9)],
                          imageSharpness: nil)
        var p = store.photos.first { $0.assetID == "a" }!
        XCTAssertEqual(p.faces?.count, 1)
        XCTAssertEqual(p.sharpness, 5)      // nil arg left it alone
        store.setFaceData(assetID: "a", faces: nil, imageSharpness: 7)
        p = store.photos.first { $0.assetID == "a" }!
        XCTAssertEqual(p.faces?.count, 1)   // nil arg left faces alone
        XCTAssertEqual(p.sharpness, 7)
    }

    // MARK: - photos(forClusters:) — "together" queries

    func testPhotosForClustersRequiresAllPeople() {
        let fa = unitEmb(axis: 10), fb = unitEmb(axis: 11)
        let r = CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)
        indexPhoto("ab-old", emb: unitEmb(axis: 0), createdAt: date(2020, 1, 1),
                   faceEmbeddings: [fa, fb], faceRects: [r, r])
        indexPhoto("a-only", emb: unitEmb(axis: 1), createdAt: date(2021, 1, 1),
                   faceEmbeddings: [fa], faceRects: [r])
        indexPhoto("ab-new", emb: unitEmb(axis: 2), createdAt: date(2022, 1, 1),
                   faceEmbeddings: [fa, fb], faceRects: [r, r])
        let a = clusterID(of: "a-only")
        let b = clusterID(of: "ab-old", faceIndex: 1)

        // AND semantics, oldest first ("first photo together" = .first).
        XCTAssertEqual(store.photos(forClusters: [a, b]).map(\.assetID), ["ab-old", "ab-new"])
        XCTAssertEqual(store.photos(forClusters: [a]).count, 3)
        XCTAssertTrue(store.photos(forClusters: []).isEmpty)

        // Deleted photos drop out.
        store.deletePhoto(assetID: "ab-old")
        XCTAssertEqual(store.photos(forClusters: [a, b]).map(\.assetID), ["ab-new"])
    }

    func testPhotosForClustersResolvesMergedIDs() {
        let fa = unitEmb(axis: 10), fb = unitEmb(axis: 11), fa2 = unitEmb(axis: 12)
        let r = CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)
        indexPhoto("ab", emb: unitEmb(axis: 0), createdAt: date(2020, 1, 1),
                   faceEmbeddings: [fa, fb], faceRects: [r, r])
        indexPhoto("xb", emb: unitEmb(axis: 1), createdAt: date(2021, 1, 1),
                   faceEmbeddings: [fa2, fb], faceRects: [r, r])
        let a  = clusterID(of: "ab")
        let b  = clusterID(of: "ab", faceIndex: 1)
        let a2 = clusterID(of: "xb")
        XCTAssertEqual(store.photos(forClusters: [a, b]).map(\.assetID), ["ab"])

        // fa2 was really the same person: merge its cluster into a. Both the
        // canonical ID and the merged-away ID must now find both photos.
        store.mergeClusters(source: a2, into: a)
        XCTAssertEqual(store.photos(forClusters: [a, b]).map(\.assetID), ["ab", "xb"])
        XCTAssertEqual(store.photos(forClusters: [a2, b]).map(\.assetID), ["ab", "xb"])
    }

    // MARK: - Growth timeline

    func testGrowthTimelinePicksBestFacePerYearAndFallsBack() {
        let face = unitEmb(axis: 9)
        let r = CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)
        // 2019: equal-size faces — sharpness decides.
        indexPhoto("s-blur", createdAt: date(2019, 3, 1), faceEmbeddings: [face],
                   faceRects: [r], faceSharpness: [10])
        indexPhoto("s-sharp", createdAt: date(2019, 6, 1), faceEmbeddings: [face],
                   faceRects: [r], faceSharpness: [50])
        // 2020: equal sharpness — the bigger face decides.
        indexPhoto("a-small", createdAt: date(2020, 3, 1), faceEmbeddings: [face],
                   faceRects: [CGRect(x: 0.1, y: 0.1, width: 0.1, height: 0.1)],
                   faceSharpness: [10])
        indexPhoto("a-big", createdAt: date(2020, 6, 1), faceEmbeddings: [face],
                   faceRects: [CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)],
                   faceSharpness: [10])
        // 2021: cluster members whose photos carry no usable face data
        // (simulates pre-backfill stores) → whole-photo fallback.
        indexPhoto("old-1", createdAt: date(2021, 2, 1), faceEmbeddings: [face], faceRects: [r])
        indexPhoto("old-2", createdAt: date(2021, 9, 1), faceEmbeddings: [face], faceRects: [r])
        store.setFaceData(assetID: "old-1", faces: [], imageSharpness: nil)
        store.setFaceData(assetID: "old-2", faces: [], imageSharpness: nil)

        let timeline = store.growthTimeline(forCluster: clusterID(of: "s-blur"))
        XCTAssertEqual(timeline.map(\.year), [2019, 2020, 2021])  // ascending
        XCTAssertEqual(timeline[0].assetID, "s-sharp")
        XCTAssertEqual(timeline[1].assetID, "a-big")
        XCTAssertNotNil(timeline[0].rect)
        XCTAssertNotNil(timeline[1].rect)
        // Fallback year: latest photo, shown whole.
        XCTAssertEqual(timeline[2].assetID, "old-2")
        XCTAssertNil(timeline[2].rect)
        XCTAssertEqual(timeline[2].score, 0)
    }

    func testGrowthTimelineSurvivesMerge() {
        let r = CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3)
        indexPhoto("p1", createdAt: date(2020, 1, 1),
                   faceEmbeddings: [unitEmb(axis: 9)], faceRects: [r], faceSharpness: [5])
        indexPhoto("p2", createdAt: date(2021, 1, 1),
                   faceEmbeddings: [unitEmb(axis: 13)], faceRects: [r], faceSharpness: [5])
        let c1 = clusterID(of: "p1")
        let c2 = clusterID(of: "p2")
        store.mergeClusters(source: c2, into: c1)

        // p2's stored face still carries the pre-merge cluster ID; the
        // timeline resolves it at query time, so 2021 keeps its face entry
        // instead of degrading to the whole-photo fallback.
        let timeline = store.growthTimeline(forCluster: c1)
        XCTAssertEqual(timeline.map(\.year), [2020, 2021])
        XCTAssertEqual(timeline[1].assetID, "p2")
        XCTAssertNotNil(timeline[1].rect)
    }

    // MARK: - Embedding search

    func testSearchByEmbeddingRanksAndUsesBestVideoFrame() {
        indexPhoto("match", emb: unitEmb(axis: 0))
        indexPhoto("other", emb: unitEmb(axis: 1))
        // Video whose mean embedding is zero but one sampled frame matches —
        // must score via max-over-frames (clipScore), not the mean.
        store.index(assetID: "vid", createdAt: Date(), lat: nil, lon: nil,
                    clipEmbedding: [Float](repeating: 0, count: 512),
                    faceEmbeddings: [], faceRects: [],
                    isVideo: true, duration: 30,
                    clipFrameEmbeddings: [unitEmb(axis: 1), unitEmb(axis: 0)])

        let hits = store.searchByEmbedding(unitEmb(axis: 0), floor: 0.5)
        XCTAssertEqual(Set(hits.map(\.photo.assetID)), ["match", "vid"])
        XCTAssertEqual(hits.first?.score ?? 0, 1.0, accuracy: 1e-4)
        XCTAssertEqual(store.searchByEmbedding(unitEmb(axis: 0), floor: 0.5, limit: 1).count, 1)
        XCTAssertTrue(store.searchByEmbedding([], floor: 0).isEmpty)
    }

    func testCompositeQueryEmbeddingNilWithoutComponents() {
        // Deterministic regardless of engine state: no non-empty component
        // (after trimming, and after dropping anchors with no stored
        // embedding) must yield nil.
        XCTAssertNil(store.compositeQueryEmbedding())
        XCTAssertNil(store.compositeQueryEmbedding(baseText: "   ", plus: [""], minus: [" "]))
        XCTAssertNil(store.compositeQueryEmbedding(anchorAssetID: "never-indexed"))
    }

    func testCompositeQueryEmbeddingAnchorOnly() {
        indexPhoto("a", emb: unitEmb(axis: 0))
        guard let v = store.compositeQueryEmbedding(anchorAssetID: "a") else {
            // Engine unavailable (truly headless run) — nil is the contract.
            XCTAssertFalse(OnDeviceMLEngine.shared.isAvailable)
            return
        }
        // Anchor-only needs no text encode: the composite is the anchor's
        // own (already unit-norm) embedding.
        XCTAssertEqual(v.count, 512)
        XCTAssertEqual(v[0], 1.0, accuracy: 1e-4)
    }

    func testAnchoredSmartFolderMembership() {
        indexPhoto("a", emb: unitEmb(axis: 0))
        indexPhoto("far", emb: unitEmb(axis: 1))
        let f = store.createFolder(name: "Like A", query: nil)
        store.updateSmartFolder(id: f.id, query: nil, anchorAssetID: "a",
                                minusQuery: nil, minScore: nil)
        let folder = store.folders.first { $0.id == f.id }!
        XCTAssertTrue(folder.isSmart)  // anchor alone makes it smart

        let members = store.photosForFolder(folder)
        if OnDeviceMLEngine.shared.isAvailable {
            // Anchor-only composite is pure CLIP similarity at the 0.55
            // image-anchored floor: the anchor itself (1.0) is in, the
            // orthogonal photo (0.0) is out.
            XCTAssertEqual(members.map(\.assetID), ["a"])
        } else {
            // Contract: no engine → nil composite → empty membership.
            XCTAssertTrue(members.isEmpty)
        }
    }

    // MARK: - Video moments

    func testMomentHitTimeMatchesSamplerTiming() {
        // Sampler places frame i of n at duration × (i + 0.5) / n:
        // frame 2 of 4 in a 40s video → 40 × 2.5 / 4 = 25s.
        let hit = MomentHit(assetID: "v", frameIndex: 2, frameCount: 4,
                            score: 0.5, duration: 40, createdAt: nil)
        XCTAssertEqual(hit.time, 25.0, accuracy: 1e-9)
    }

    func testVideoMomentsDegradesGracefully() {
        store.index(assetID: "v", createdAt: Date(), lat: nil, lon: nil,
                    clipEmbedding: unitEmb(axis: 4), faceEmbeddings: [], faceRects: [],
                    isVideo: true, duration: 40,
                    clipFrameEmbeddings: [unitEmb(axis: 4), unitEmb(axis: 5)])
        // Engine-independent: a blank query is never sent to the encoder.
        XCTAssertTrue(store.videoMoments(matching: "   ").isEmpty)

        let hits = store.videoMoments(matching: "dog")
        if OnDeviceMLEngine.shared.isAvailable {
            // The host app may have loaded the models; real text embeddings
            // make hit *content* nondeterministic here, so only check shape:
            // at most one hit per video, argmax frame index in range.
            XCTAssertLessThanOrEqual(hits.count, 1)
            for h in hits {
                XCTAssertEqual(h.assetID, "v")
                XCTAssertEqual(h.frameCount, 2)
                XCTAssertTrue((0..<2).contains(h.frameIndex))
                XCTAssertGreaterThanOrEqual(h.score, 0.25)
            }
        } else {
            // Contract: no engine → empty, never a throw or crash.
            XCTAssertTrue(hits.isEmpty)
        }
    }

    // MARK: - Smart folder editing + Codable back-compat

    func testUpdateSmartFolderNormalizesEmptyStrings() {
        let f = store.createFolder(name: "S", query: "dogs")
        store.updateSmartFolder(id: f.id, query: "", anchorAssetID: "anchor-1",
                                minusQuery: "", minScore: 0.4)
        let u = store.folders.first { $0.id == f.id }!
        XCTAssertNil(u.query)
        XCTAssertNil(u.minusQuery)
        XCTAssertEqual(u.anchorAssetID, "anchor-1")
        XCTAssertEqual(u.minScore, 0.4)
        XCTAssertTrue(u.isSmart)

        store.updateSmartFolder(id: f.id, query: "cats", anchorAssetID: nil,
                                minusQuery: nil, minScore: nil)
        let v = store.folders.first { $0.id == f.id }!
        XCTAssertEqual(v.query, "cats")
        XCTAssertNil(v.anchorAssetID)
        XCTAssertNil(v.minScore)
    }

    func testLocalFolderDecodesLegacyJSONWithoutNewFields() throws {
        // folders.json written before anchorAssetID/minusQuery/minScore
        // existed must keep decoding — fields are optional, absent ⇒ nil.
        let json = #"{"id":"F1","name":"Trip","photoAssetIDs":["a"],"query":"beach"}"#
        let f = try JSONDecoder().decode(LocalFolder.self, from: Data(json.utf8))
        XCTAssertEqual(f.name, "Trip")
        XCTAssertNil(f.anchorAssetID)
        XCTAssertNil(f.minusQuery)
        XCTAssertNil(f.minScore)
        XCTAssertTrue(f.isSmart)  // query-based smartness unchanged
    }

    func testLocalPhotoDecodesLegacyJSONWithoutFaceFields() throws {
        let json = #"{"assetID":"a","photoID":1,"personClusterIDs":[],"isDeleted":false}"#
        let p = try JSONDecoder().decode(LocalPhoto.self, from: Data(json.utf8))
        XCTAssertNil(p.faces)
        XCTAssertNil(p.sharpness)
    }
}

// MARK: - Binary codec

final class EmbeddingCodecTests: XCTestCase {
    func testBinaryEmbeddingCodecRoundTrip() {
        let dict: [String: [Float]] = [
            "asset-1": (0..<512).map { Float($0) / 512 },
            "asset-2": [Float](repeating: -0.25, count: 512),
        ]
        let data = BinaryEmbeddingCodec.encode(dict)
        let back = BinaryEmbeddingCodec.decode(data)
        XCTAssertEqual(back?.count, 2)
        XCTAssertEqual(back?["asset-1"], dict["asset-1"])
        XCTAssertEqual(back?["asset-2"], dict["asset-2"])
    }

    func testBinaryEmbeddingCodecRejectsTruncation() {
        let data = BinaryEmbeddingCodec.encode(["a": [1, 2, 3]])
        XCTAssertNil(BinaryEmbeddingCodec.decode(data.prefix(data.count - 2)))
    }
}
