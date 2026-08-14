import CloudKit
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

    // MARK: - Structured search: word-boundary name matching

    func testPersonNameFilterMatchesOnWordBoundary() {
        // A face-bearing photo whose cluster we name "Mar". The structured
        // person filter must NOT fire on a query that merely *contains* "mar"
        // as a substring ("marble"), only on the whole word "mar".
        let r = CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)
        indexPhoto("p", emb: unitEmb(axis: 0), faceEmbeddings: [unitEmb(axis: 10)],
                   faceRects: [r])
        let cid = clusterID(of: "p")
        store.setClusterName(id: cid, name: "Mar")

        // Substring "marble" must not pull the named cluster in: with no person
        // match the caption keeps the whole query for CLIP ranking.
        let substr = store.structuredSearchStage(query: "marble countertop")
        XCTAssertTrue(substr.caption.contains("marble"))
        XCTAssertEqual(substr.candidates.count, 1)  // unfiltered by person name

        // Whole word "mar" matches: photos hard-filter to the cluster's
        // members and "mar" is consumed out of the caption.
        let whole = store.structuredSearchStage(query: "mar")
        XCTAssertEqual(whole.candidates.map(\.assetID), ["p"])
        XCTAssertFalse(whole.caption.contains("mar"))
    }

    func testMonthFilterMatchesOnWordBoundary() {
        indexPhoto("dec-photo", emb: unitEmb(axis: 0), createdAt: date(2021, 12, 1))
        indexPhoto("jun-photo", emb: unitEmb(axis: 1), createdAt: date(2021, 6, 1))

        // "decorations 2021" must not be read as December 2021 — "dec" is a
        // substring, not a whole word, so the year-only filter applies and
        // both 2021 photos survive.
        let decor = store.structuredSearchStage(query: "decorations 2021")
        XCTAssertEqual(Set(decor.candidates.map(\.assetID)), ["dec-photo", "jun-photo"])

        // "december 2021" is a whole word → month+year filter narrows to Dec.
        let december = store.structuredSearchStage(query: "december 2021")
        XCTAssertEqual(december.candidates.map(\.assetID), ["dec-photo"])
    }

    // MARK: - Photo request helpers (photosMatching / clusterMatching / face filter)

    func testPhotosMatchingFiltersToDateWindow() {
        // Date-only request (blank description) returns every photo in the
        // inclusive [from, to] window; photos outside it (and undated) drop.
        indexPhoto("in1", emb: unitEmb(axis: 0), createdAt: date(2023, 6, 10))
        indexPhoto("in2", emb: unitEmb(axis: 1), createdAt: date(2023, 6, 20))
        indexPhoto("before", emb: unitEmb(axis: 2), createdAt: date(2023, 5, 1))
        indexPhoto("after", emb: unitEmb(axis: 3), createdAt: date(2023, 7, 1))
        store.index(assetID: "undated", createdAt: nil,
                    lat: nil, lon: nil, clipEmbedding: unitEmb(axis: 4),
                    faceEmbeddings: [], faceRects: [], isVideo: false, duration: 0)

        let hits = store.photosMatching(description: "",
                                        from: date(2023, 6, 1), to: date(2023, 6, 30))
        XCTAssertEqual(Set(hits.map(\.assetID)), ["in1", "in2"])

        // Swapped bounds are normalized (min/max), so the same window works.
        let swapped = store.photosMatching(description: "",
                                           from: date(2023, 6, 30), to: date(2023, 6, 1))
        XCTAssertEqual(Set(swapped.map(\.assetID)), ["in1", "in2"])
    }

    func testClusterMatchingPicksBestAboveThreshold() {
        // Three orthogonal "people" with ≥3 photos each so they're activeClusters.
        let r = CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)
        for i in 0..<3 { indexPhoto("p\(i)", emb: unitEmb(axis: i), faceEmbeddings: [unitEmb(axis: 20)], faceRects: [r]) }
        for i in 0..<3 { indexPhoto("q\(i)", emb: unitEmb(axis: 5 + i), faceEmbeddings: [unitEmb(axis: 21)], faceRects: [r]) }
        let pCluster = store.clusterID(forAsset: "p0")

        // An embedding identical to person-P's prototype matches P (cosine 1.0).
        let matchP = store.clusterMatching(unitEmb(axis: 20))
        XCTAssertEqual(matchP?.id, pCluster)

        // An embedding orthogonal to every prototype (cosine 0) is below the
        // 0.45 threshold → nil (the requester isn't recognized here).
        XCTAssertNil(store.clusterMatching(unitEmb(axis: 100)))
        // Empty embedding → nil.
        XCTAssertNil(store.clusterMatching([]))
    }

    func testApplyFaceFilterOnlyMeAndWithoutMe() {
        let r = CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)
        // Person "me" (axis 20) appears in m0/m1/m2; person "other" in o0/o1/o2.
        for i in 0..<3 { indexPhoto("m\(i)", emb: unitEmb(axis: i), createdAt: date(2023, 1, i + 1),
                                    faceEmbeddings: [unitEmb(axis: 20)], faceRects: [r]) }
        for i in 0..<3 { indexPhoto("o\(i)", emb: unitEmb(axis: 5 + i), createdAt: date(2023, 1, i + 4),
                                    faceEmbeddings: [unitEmb(axis: 21)], faceRects: [r]) }
        let all = store.allPhotos()
        let meEmb = unitEmb(axis: 20)

        // any → unchanged (embedding ignored).
        XCTAssertEqual(store.applyFaceFilter(.any, to: all, requesterEmbedding: []).count, all.count)

        // onlyMe → just the photos "me" is in.
        let onlyMe = store.applyFaceFilter(.onlyMe, to: all, requesterEmbedding: meEmb)
        XCTAssertEqual(Set(onlyMe.map(\.assetID)), ["m0", "m1", "m2"])

        // withoutMe → everything except those.
        let withoutMe = store.applyFaceFilter(.withoutMe, to: all, requesterEmbedding: meEmb)
        XCTAssertEqual(Set(withoutMe.map(\.assetID)), ["o0", "o1", "o2"])
    }

    func testApplyFaceFilterUnrecognizedRequester() {
        // The requester isn't in this library (no cluster clears the threshold):
        //   onlyMe   → empty (can't prove they're in any photo),
        //   withoutMe → all (they're in none, as far as we can tell).
        let r = CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)
        for i in 0..<3 { indexPhoto("x\(i)", emb: unitEmb(axis: i),
                                    faceEmbeddings: [unitEmb(axis: 30)], faceRects: [r]) }
        let all = store.allPhotos()
        let stranger = unitEmb(axis: 100)   // orthogonal to every prototype
        XCTAssertTrue(store.applyFaceFilter(.onlyMe, to: all, requesterEmbedding: stranger).isEmpty)
        XCTAssertEqual(store.applyFaceFilter(.withoutMe, to: all, requesterEmbedding: stranger).count, all.count)
    }

    func testBuildFolderStagesAssetsInOrder() {
        indexPhoto("a", emb: unitEmb(axis: 0))
        indexPhoto("b", emb: unitEmb(axis: 1))
        let folder = store.buildFolder(named: "For Jake", assetIDs: ["b", "a"])
        let saved = store.folders.first { $0.id == folder.id }!
        XCTAssertEqual(saved.name, "For Jake")
        XCTAssertEqual(saved.photoAssetIDs, ["b", "a"])   // order preserved
        XCTAssertFalse(saved.isSmart)                      // static folder
    }

    // MARK: - Share-a-folder membership (feeds "Share Album")

    func testActiveMemberAssetIDsExcludesDeletedAndPreservesOrder() {
        indexPhoto("a", emb: unitEmb(axis: 0))
        indexPhoto("b", emb: unitEmb(axis: 1))
        indexPhoto("c", emb: unitEmb(axis: 2))
        let folder = store.buildFolder(named: "Trip", assetIDs: ["c", "a", "b"])

        // All present → returned in membership order (what gets uploaded).
        XCTAssertEqual(store.activeMemberAssetIDs(in: store.folders.first { $0.id == folder.id }!),
                       ["c", "a", "b"])

        // Soft-deleting a member keeps it in photoAssetIDs (restore-safe) but it
        // must NOT be offered for upload — a hidden photo shouldn't be shared.
        store.deletePhoto(assetID: "a")
        XCTAssertTrue(store.folders.first { $0.id == folder.id }!.photoAssetIDs.contains("a"))
        XCTAssertEqual(store.activeMemberAssetIDs(in: store.folders.first { $0.id == folder.id }!),
                       ["c", "b"])
    }

    func testActiveMemberAssetIDsEmptyForSmartFolder() {
        // Smart folders have no static membership to upload.
        let f = store.createFolder(name: "Smart", query: "beach")
        XCTAssertTrue(store.folders.first { $0.id == f.id }!.isSmart)
        XCTAssertTrue(store.activeMemberAssetIDs(in: store.folders.first { $0.id == f.id }!).isEmpty)
    }

    // MARK: - Smart-folder manual add/remove (query ∪ include) − exclude

    private func folder(_ id: String) -> LocalFolder { store.folders.first { $0.id == id }! }

    func testSmartFolderAddRoutesToIncludeSetNotStaticList() {
        indexPhoto("x", emb: unitEmb(axis: 0))
        let f = store.createFolder(name: "Dogs", query: "dogs")
        XCTAssertTrue(folder(f.id).isSmart)
        let versionBefore = store.membershipVersion

        store.addPhotos(["x"], toFolder: f.id)

        // Routed to the manual-include overlay, NOT the static photoAssetIDs
        // (which smart folders never read), and membershipVersion advanced so
        // the folder view re-evaluates.
        XCTAssertEqual(folder(f.id).manualIncludeAssetIDs, ["x"])
        XCTAssertTrue((folder(f.id).manualExcludeAssetIDs ?? []).isEmpty)
        XCTAssertTrue(folder(f.id).photoAssetIDs.isEmpty)
        XCTAssertGreaterThan(store.membershipVersion, versionBefore)
    }

    func testSmartFolderRemoveRoutesToExcludeSet() {
        let f = store.createFolder(name: "Dogs", query: "dogs")
        store.removePhotos(["y"], fromFolder: f.id)
        XCTAssertEqual(folder(f.id).manualExcludeAssetIDs, ["y"])
        XCTAssertTrue((folder(f.id).manualIncludeAssetIDs ?? []).isEmpty)
    }

    func testSmartFolderIncludeAndExcludeStayMutuallyExclusive() {
        let f = store.createFolder(name: "Dogs", query: "dogs")

        store.addPhotos(["x"], toFolder: f.id)          // include=[x]
        XCTAssertEqual(folder(f.id).manualIncludeAssetIDs, ["x"])

        store.removePhotos(["x"], fromFolder: f.id)     // remove cancels the add
        XCTAssertTrue((folder(f.id).manualIncludeAssetIDs ?? []).isEmpty)
        XCTAssertEqual(folder(f.id).manualExcludeAssetIDs, ["x"])

        store.addPhotos(["x"], toFolder: f.id)          // re-add un-excludes
        XCTAssertEqual(folder(f.id).manualIncludeAssetIDs, ["x"])
        XCTAssertTrue((folder(f.id).manualExcludeAssetIDs ?? []).isEmpty)
    }

    func testSmartFolderManualIncludeSurfacesInMembership() {
        indexPhoto("x", emb: unitEmb(axis: 0))
        let f = store.createFolder(name: "Dogs", query: "dogs")
        store.addPhotos(["x"], toFolder: f.id)
        // Regardless of whether the on-device engine is available (which decides
        // the query portion), a manually-added, non-deleted photo is appended.
        let members = store.photosForFolder(folder(f.id))
        XCTAssertTrue(members.contains { $0.assetID == "x" })
    }

    func testSmartFolderManualExcludeWinsOverQuery() {
        indexPhoto("x", emb: unitEmb(axis: 0))
        let f = store.createFolder(name: "Dogs", query: "dogs")
        // Add then remove: exclude=[x], include empty. The photo must be absent
        // from membership whether or not the query would otherwise match it
        // (exclude filters query hits; with no engine it isn't matched anyway).
        store.addPhotos(["x"], toFolder: f.id)
        store.removePhotos(["x"], fromFolder: f.id)
        let members = store.photosForFolder(folder(f.id))
        XCTAssertFalse(members.contains { $0.assetID == "x" })
    }

    func testSmartFolderManualIncludeSkipsDeletedPhotos() {
        indexPhoto("x", emb: unitEmb(axis: 0))
        let f = store.createFolder(name: "Dogs", query: "dogs")
        store.addPhotos(["x"], toFolder: f.id)
        store.deletePhoto(assetID: "x")   // soft-delete → excluded from membership
        let members = store.photosForFolder(folder(f.id))
        XCTAssertFalse(members.contains { $0.assetID == "x" })
    }

    func testStaticFolderAddRemoveUnaffectedByManualSets() {
        // The static path must be byte-for-byte today's behavior: appends/removes
        // on photoAssetIDs, never touching the manual sets.
        indexPhoto("a", emb: unitEmb(axis: 0))
        let f = store.createFolder(name: "Trip", query: nil)   // static
        XCTAssertFalse(folder(f.id).isSmart)
        store.addPhotos(["a"], toFolder: f.id)
        XCTAssertEqual(folder(f.id).photoAssetIDs, ["a"])
        XCTAssertNil(folder(f.id).manualIncludeAssetIDs)
        XCTAssertNil(folder(f.id).manualExcludeAssetIDs)
        store.removePhotos(["a"], fromFolder: f.id)
        XCTAssertTrue(folder(f.id).photoAssetIDs.isEmpty)
    }

    func testLocalFolderManualSetsCodableRoundTripAndLegacyDecode() throws {
        // Legacy folders.json (no manual keys) decodes with both nil.
        let legacy = #"{"id":"F1","name":"Dogs","photoAssetIDs":[],"query":"dogs"}"#
        let old = try JSONDecoder().decode(LocalFolder.self, from: Data(legacy.utf8))
        XCTAssertNil(old.manualIncludeAssetIDs)
        XCTAssertNil(old.manualExcludeAssetIDs)

        // Round-trip preserves populated manual sets.
        var f = old
        f.manualIncludeAssetIDs = ["a", "b"]
        f.manualExcludeAssetIDs = ["c"]
        let data = try JSONEncoder().encode(f)
        let back = try JSONDecoder().decode(LocalFolder.self, from: data)
        XCTAssertEqual(back.manualIncludeAssetIDs, ["a", "b"])
        XCTAssertEqual(back.manualExcludeAssetIDs, ["c"])
    }

    // MARK: - Saved slideshows

    func testSaveSlideshowDefaultsNameToCapitalizedQuery() {
        let show = store.saveSlideshow(query: "  beach  ")
        XCTAssertEqual(show?.query, "beach")          // trimmed
        XCTAssertEqual(show?.name, "Beach")           // capitalized for display
        XCTAssertEqual(store.savedSlideshows.count, 1)
    }

    func testEmptyQueryIsNotSaved() {
        XCTAssertNil(store.saveSlideshow(query: "   "))
        XCTAssertTrue(store.savedSlideshows.isEmpty)
    }

    /// Re-saving the same search must update in place, not stack duplicates —
    /// the hub's bookmark button is easy to tap twice.
    func testResavingSameQueryUpdatesInPlace() {
        store.saveSlideshow(query: "beach")
        store.saveSlideshow(query: "  BEACH ", name: "Summer", mood: .bright)
        XCTAssertEqual(store.savedSlideshows.count, 1)
        XCTAssertEqual(store.savedSlideshows[0].name, "Summer")
        XCTAssertEqual(store.savedSlideshows[0].mood, .bright)
        // The original query text is kept; only presentation changed.
        XCTAssertEqual(store.savedSlideshows[0].query, "beach")
    }

    func testIsSlideshowSavedIgnoresCaseAndWhitespace() {
        store.saveSlideshow(query: "beach")
        XCTAssertTrue(store.isSlideshowSaved(query: " Beach "))
        XCTAssertFalse(store.isSlideshowSaved(query: "mountains"))
        XCTAssertFalse(store.isSlideshowSaved(query: "  "))
    }

    func testDistinctQueriesEachSaveNewestFirst() {
        store.saveSlideshow(query: "beach")
        store.saveSlideshow(query: "mountains")
        XCTAssertEqual(store.savedSlideshows.map(\.query), ["mountains", "beach"])
    }

    func testRenameChangesNameNotQuery() {
        let show = store.saveSlideshow(query: "beach")!
        store.renameSlideshow(id: show.id, name: "  Summer at the lake  ")
        XCTAssertEqual(store.savedSlideshows[0].name, "Summer at the lake")
        XCTAssertEqual(store.savedSlideshows[0].query, "beach")
        // An all-whitespace rename is rejected rather than blanking the row.
        store.renameSlideshow(id: show.id, name: "   ")
        XCTAssertEqual(store.savedSlideshows[0].name, "Summer at the lake")
    }

    func testDeleteSlideshow() {
        let show = store.saveSlideshow(query: "beach")!
        store.saveSlideshow(query: "mountains")
        store.deleteSlideshow(id: show.id)
        XCTAssertEqual(store.savedSlideshows.map(\.query), ["mountains"])
        store.deleteSlideshow(id: "no-such-id")   // no-op
        XCTAssertEqual(store.savedSlideshows.count, 1)
    }

    func testSavedSlideshowsSurviveReload() {
        store.saveSlideshow(query: "beach", name: "Summer", mood: .warm)
        store.persist()
        store.load()
        XCTAssertEqual(store.savedSlideshows.count, 1)
        let show = store.savedSlideshows[0]
        XCTAssertEqual(show.query, "beach")
        XCTAssertEqual(show.name, "Summer")
        XCTAssertEqual(show.mood, .warm)
    }

    // MARK: - Relative dates

    private var cal: Calendar { Calendar.current }

    /// Bare season/month words must NOT become date filters — they are common
    /// caption terms and common people names (Summer, May, June).
    func testBareSeasonIsNotADateFilter() {
        XCTAssertNil(store.parseRelativeDate("summer", now: date(2026, 3, 15)))
        XCTAssertNil(store.parseRelativeDate("summer beach", now: date(2026, 3, 15)))
        XCTAssertNil(store.parseRelativeDate("beach", now: date(2026, 3, 15)))
    }

    /// "last summer" means the most recently COMPLETED summer, which flips
    /// depending on where in the year you ask.
    func testLastSummerDependsOnWhetherItHasEnded() {
        // March 2026: summer 2026 hasn't happened yet → last summer is 2025.
        let march = store.parseRelativeDate("last summer", now: date(2026, 3, 15))!
        XCTAssertEqual(cal.component(.year, from: march.start), 2025)
        XCTAssertEqual(cal.component(.month, from: march.start), 6)
        // December 2026: summer 2026 is over → that's last summer.
        let dec = store.parseRelativeDate("last summer", now: date(2026, 12, 15))!
        XCTAssertEqual(cal.component(.year, from: dec.start), 2026)
    }

    func testNYearsAgoCoversTheWholeYear() {
        let r = store.parseRelativeDate("3 years ago", now: date(2026, 8, 14))!
        XCTAssertEqual(cal.component(.year, from: r.start), 2023)
        XCTAssertEqual(cal.component(.month, from: r.start), 1)
        XCTAssertEqual(cal.component(.year, from: r.end), 2023)
        XCTAssertEqual(cal.component(.month, from: r.end), 12)
        XCTAssertTrue(r.contains(date(2023, 6, 1)))
        XCTAssertFalse(r.contains(date(2024, 1, 1)))
    }

    func testYesterdayIsASingleDay() {
        let r = store.parseRelativeDate("yesterday", now: date(2026, 8, 14))!
        XCTAssertTrue(r.contains(date(2026, 8, 13)))
        XCTAssertFalse(r.contains(date(2026, 8, 14)))
        XCTAssertFalse(r.contains(date(2026, 8, 12)))
    }

    func testLastMonthWindow() {
        let r = store.parseRelativeDate("last month", now: date(2026, 1, 10))!
        // Crosses the year boundary correctly.
        XCTAssertEqual(cal.component(.year, from: r.start), 2025)
        XCTAssertEqual(cal.component(.month, from: r.start), 12)
        XCTAssertTrue(r.contains(date(2025, 12, 31)))
        XCTAssertFalse(r.contains(date(2026, 1, 1)))
    }

    /// "last weekend" must not be swallowed by the "last week" branch.
    func testLastWeekendIsTwoDaysNotSeven() {
        let r = store.parseRelativeDate("last weekend", now: date(2026, 8, 14))!
        let span = r.end.timeIntervalSince(r.start)
        XCTAssertEqual(span, 2 * 86400 - 1, accuracy: 3600)
    }

    /// The phrase's words are reported so they can be stripped from the CLIP
    /// caption — otherwise "beach last summer" would rank on "last summer" too.
    func testRelativeTokensAreReported() {
        XCTAssertEqual(store.parseRelativeDate("beach last summer", now: date(2026, 12, 1))!.tokens,
                       ["last", "summer"])
        XCTAssertEqual(store.parseRelativeDate("yesterday", now: date(2026, 8, 14))!.tokens,
                       ["yesterday"])
    }

    /// End to end: the window actually filters search candidates.
    func testRelativeDateFiltersSearchCandidates() {
        let now = Date()
        let yesterday = cal.date(byAdding: .day, value: -1, to: now)!
        let longAgo = cal.date(byAdding: .year, value: -3, to: now)!
        indexPhoto("recent", emb: unitEmb(axis: 0), createdAt: yesterday)
        indexPhoto("old", emb: unitEmb(axis: 1), createdAt: longAgo)
        let (candidates, caption) = store.structuredSearchStage(query: "yesterday")
        XCTAssertEqual(candidates.map(\.assetID), ["recent"])
        // The date phrase is consumed, leaving nothing to rank on.
        XCTAssertTrue(caption.isEmpty, "caption was \(caption)")
    }

    // MARK: - Recent searches

    func testRecordSearchNewestFirstAndDedupes() {
        store.recordSearch("beach")
        store.recordSearch("mountains")
        XCTAssertEqual(store.recentSearches, ["mountains", "beach"])
        // Re-running an old query moves it to the front, not a second copy.
        store.recordSearch("  BEACH ")
        XCTAssertEqual(store.recentSearches, ["BEACH", "mountains"])
    }

    func testRecordSearchIgnoresBlank() {
        store.recordSearch("   ")
        XCTAssertTrue(store.recentSearches.isEmpty)
    }

    func testRecentSearchesAreCapped() {
        for i in 0..<(PhotoStore.maxRecentSearches + 5) { store.recordSearch("q\(i)") }
        XCTAssertEqual(store.recentSearches.count, PhotoStore.maxRecentSearches)
        // The oldest fell off the end; the newest is at the front.
        XCTAssertEqual(store.recentSearches.first, "q\(PhotoStore.maxRecentSearches + 4)")
        XCTAssertFalse(store.recentSearches.contains("q0"))
    }

    func testRemoveAndClearRecentSearches() {
        store.recordSearch("beach")
        store.recordSearch("mountains")
        store.removeRecentSearch("BEACH")          // case-insensitive
        XCTAssertEqual(store.recentSearches, ["mountains"])
        store.clearRecentSearches()
        XCTAssertTrue(store.recentSearches.isEmpty)
    }

    func testRecentSearchesSurviveReload() {
        store.recordSearch("beach")
        store.recordSearch("mountains")
        store.persist()
        store.load()
        XCTAssertEqual(store.recentSearches, ["mountains", "beach"])
    }

    // MARK: - Memory notification copy

    /// The notification body names the day's protagonists, so the ranking must
    /// be by frequency and must skip clusters nobody has named.
    func testTopNamedPeopleRanksByFrequencyAndSkipsUnnamed() {
        let fa = unitEmb(axis: 10), fb = unitEmb(axis: 11)
        let r = CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)
        indexPhoto("p1", emb: unitEmb(axis: 0), faceEmbeddings: [fa, fb], faceRects: [r, r])
        indexPhoto("p2", emb: unitEmb(axis: 1), faceEmbeddings: [fa], faceRects: [r])
        indexPhoto("p3", emb: unitEmb(axis: 2), faceEmbeddings: [fa], faceRects: [r])

        let a = clusterID(of: "p2")
        let b = clusterID(of: "p1", faceIndex: 1)
        store.setClusterName(id: a, name: "Emma")     // in 3 photos
        store.setClusterName(id: b, name: "Jack")     // in 1

        let photos = store.allPhotos()
        XCTAssertEqual(store.topNamedPeople(in: photos), ["Emma", "Jack"])
        XCTAssertEqual(store.topNamedPeople(in: photos, limit: 1), ["Emma"])

        // Unnamed clusters contribute nothing — there's no way to say them.
        store.setClusterName(id: b, name: "")
        XCTAssertEqual(store.topNamedPeople(in: photos), ["Emma"])
    }

    func testTopNamedPeopleEmptyWhenNobodyNamed() {
        indexPhoto("p1", emb: unitEmb(axis: 0),
                   faceEmbeddings: [unitEmb(axis: 10)],
                   faceRects: [CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)])
        XCTAssertTrue(store.topNamedPeople(in: store.allPhotos()).isEmpty)
    }
}

// Test-only convenience: the cluster id a single-face photo was assigned to.
private extension PhotoStore {
    func clusterID(forAsset assetID: String) -> Int {
        photos.first { $0.assetID == assetID }!.personClusterIDs[0]
    }
}

// MARK: - Shared albums: pure-logic round-trips (no CloudKit network)

/// These exercise only the value<->CKRecord mapping and the change-token cache
/// encode/decode — both pure logic. They construct CKRecords in memory and never
/// reach a CloudKit container, so they run fine in the simulator test host where
/// CloudKit itself is unavailable.
final class SharedAlbumMappingTests: XCTestCase {

    private func zoneID() -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: "album-zone-1", ownerName: CKCurrentUserDefaultName)
    }

    func testSharedPhotoRecordMetadataRoundTrips() {
        let zone = zoneID()
        let payload = SharedPhotoUploadPayload(
            fullImageURL: URL(fileURLWithPath: "/tmp/full.jpg"),
            thumbnailURL: URL(fileURLWithPath: "/tmp/thumb.jpg"),
            contributorID: "user-abc",
            captureDate: Date(timeIntervalSince1970: 1_700_000_000),
            latitude: 37.33,
            longitude: -122.03,
            originalFilename: "IMG_0001.HEIC",
            contentHash: "deadbeef")
        let rootRef = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: SharedAlbum.RecordType.albumRootRecordName,
                                  zoneID: zone),
            action: .none)

        let record = SharedPhoto.makeRecord(from: payload, inZone: zone, albumRootRef: rootRef)

        // The record lands in the album's zone, with both assets + the cascade
        // reference set. Crucially `parent` is NOT set: these albums use
        // zone-wide sharing, where parent chaining is illegal (CloudKit:
        // "Chaining supported for hierarchical sharing only"). Sharing is carried
        // by the zone; the cascade uses the ordinary `album` field reference.
        XCTAssertEqual(record.recordType, SharedAlbum.RecordType.photo)
        XCTAssertEqual(record.recordID.zoneID, zone)
        XCTAssertNotNil(record[SharedAlbum.PhotoField.fullImage] as? CKAsset)
        XCTAssertNotNil(record[SharedAlbum.PhotoField.thumbnail] as? CKAsset)
        XCTAssertNil(record.parent)
        let albumRef = record[SharedAlbum.PhotoField.album] as? CKRecord.Reference
        XCTAssertEqual(albumRef?.action, .deleteSelf)
        XCTAssertEqual(albumRef?.recordID.recordName,
                       SharedAlbum.RecordType.albumRootRecordName)

        // Mapping the record back recovers the metadata (assets are not read by
        // the value-type init, by design).
        let photo = SharedPhoto(record: record)
        XCTAssertNotNil(photo)
        XCTAssertEqual(photo?.contributorID, "user-abc")
        XCTAssertEqual(photo?.captureDate, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(photo?.latitude, 37.33)
        XCTAssertEqual(photo?.longitude, -122.03)
        XCTAssertEqual(photo?.originalFilename, "IMG_0001.HEIC")
        XCTAssertEqual(photo?.contentHash, "deadbeef")
        XCTAssertEqual(photo?.albumZoneName, zone.zoneName)
        XCTAssertEqual(photo?.id, record.recordID.recordName)
        // recordID rehydrates to the same identity it came from.
        XCTAssertEqual(photo?.recordID, record.recordID)
    }

    func testSharedPhotoRecordOmitsParentWhenRootMissing() {
        // When the album-root target can't be resolved in the zone/DB (older
        // album, or a participant's shared-zone view), makeRecord must OMIT the
        // parent + album references — referencing a non-existent record would
        // fail the whole save with a referenceViolation. Assets + metadata still
        // land, and the value-type mapping still recovers.
        let zone = zoneID()
        let payload = SharedPhotoUploadPayload(
            fullImageURL: URL(fileURLWithPath: "/tmp/f.jpg"),
            thumbnailURL: URL(fileURLWithPath: "/tmp/t.jpg"),
            contributorID: "user-abc", captureDate: nil, latitude: nil,
            longitude: nil, originalFilename: nil, contentHash: "abc123")

        let record = SharedPhoto.makeRecord(from: payload, inZone: zone, albumRootRef: nil)

        XCTAssertNil(record.parent)
        XCTAssertNil(record[SharedAlbum.PhotoField.album] as? CKRecord.Reference)
        XCTAssertNotNil(record[SharedAlbum.PhotoField.fullImage] as? CKAsset)
        XCTAssertNotNil(record[SharedAlbum.PhotoField.thumbnail] as? CKAsset)
        let photo = SharedPhoto(record: record)
        XCTAssertEqual(photo?.contributorID, "user-abc")
        XCTAssertEqual(photo?.contentHash, "abc123")
    }

    func testSharedPhotoInitRejectsWrongRecordType() {
        let wrong = CKRecord(recordType: SharedAlbum.RecordType.album,
                             recordID: CKRecord.ID(recordName: "x", zoneID: zoneID()))
        XCTAssertNil(SharedPhoto(record: wrong))
    }

    func testSharedPhotoOptionalMetadataDefaultsToNil() {
        // A record with only the required asset fields still maps; optional
        // metadata comes back nil rather than crashing.
        let payload = SharedPhotoUploadPayload(
            fullImageURL: URL(fileURLWithPath: "/tmp/f.jpg"),
            thumbnailURL: URL(fileURLWithPath: "/tmp/t.jpg"),
            contributorID: nil, captureDate: nil, latitude: nil,
            longitude: nil, originalFilename: nil, contentHash: nil)
        let rootRef = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: SharedAlbum.RecordType.albumRootRecordName,
                                  zoneID: zoneID()),
            action: .none)
        let record = SharedPhoto.makeRecord(from: payload, inZone: zoneID(), albumRootRef: rootRef)
        let photo = SharedPhoto(record: record)
        XCTAssertNotNil(photo)
        XCTAssertNil(photo?.captureDate)
        XCTAssertNil(photo?.latitude)
        XCTAssertNil(photo?.contentHash)
    }

    func testArrayChunkedSplitsEvenlyAndClampsZeroSize() {
        XCTAssertEqual([1, 2, 3, 4, 5].chunked(into: 2), [[1, 2], [3, 4], [5]])
        XCTAssertEqual([Int]().chunked(into: 3), [])
        // A zero/negative size must not loop forever: clamp to 1.
        XCTAssertEqual([1, 2].chunked(into: 0), [[1], [2]])
    }

    /// `resolvableAssetIDs` filters a folder's stored PHAsset identifiers down to
    /// the ones still present in the library before "Share Album" uploads them.
    /// Empty input is a deterministic []; arbitrary (non-real) identifiers resolve
    /// to nothing in the test host's photo library, so they're all filtered out —
    /// proving the "skip missing" behavior without needing real assets.
    func testResolvableAssetIDsFiltersEmptyAndMissing() {
        XCTAssertEqual(SharedAlbumStore.resolvableAssetIDs(from: []), [])
        // These identifiers don't correspond to any real library asset, so none
        // resolve → all skipped (the caller then treats [] as "nothing to share").
        XCTAssertEqual(
            SharedAlbumStore.resolvableAssetIDs(from: ["not-a-real-id/L0/001",
                                                       "also-fake/L0/001"]),
            [])
    }
}

// MARK: - Shared albums: server-change-token cache encode/decode

final class ChangeTokenCacheTests: XCTestCase {

    /// A real CKServerChangeToken can only be minted by the server, so we build
    /// the cache from an archived token by feeding it through an archive of a
    /// known-archivable secure-coding object isn't possible directly. Instead we
    /// verify the cache's Codable round-trip preserves whatever bytes it holds:
    /// an empty cache encodes/decodes to an empty cache, and zone removal works.
    func testEmptyCacheRoundTripsAndReportsEmpty() throws {
        let cache = ChangeTokenCache()
        XCTAssertTrue(cache.isEmpty)
        let data = try JSONEncoder().encode(cache)
        let back = try JSONDecoder().decode(ChangeTokenCache.self, from: data)
        XCTAssertTrue(back.isEmpty)
        XCTAssertNil(back.databaseToken(scope: .shared))
        XCTAssertNil(back.zoneToken(CKRecordZone.ID(zoneName: "z", ownerName: "o")))
    }

    func testNilTokenWritesAreNoOps() {
        var cache = ChangeTokenCache()
        // Setting a nil database token leaves the cache empty (keep-last-good
        // semantics); setting a nil zone token is a no-op.
        cache.setDatabaseToken(nil, scope: .shared)
        cache.setZoneToken(nil, for: CKRecordZone.ID(zoneName: "z", ownerName: "o"))
        XCTAssertTrue(cache.isEmpty)
    }

    func testRemoveZoneOnEmptyCacheIsSafe() {
        var cache = ChangeTokenCache()
        cache.removeZone(CKRecordZone.ID(zoneName: "gone", ownerName: "o"))
        XCTAssertTrue(cache.isEmpty)
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

// MARK: - Friends / directory / invitation: pure-logic round-trips (no CloudKit)

/// These exercise only the value<->CKRecord mapping, username normalization, the
/// handled-invitations cache, and the friends-cache encode/decode — all pure
/// logic. They build CKRecords in memory and never reach a CloudKit container, so
/// they run in the simulator test host where CloudKit itself is unavailable.
final class DirectoryMappingTests: XCTestCase {

    // MARK: UserProfile record-name normalization

    func testUsernameRecordNameIsCaseInsensitiveAndTrimmed() {
        // Case + surrounding whitespace collapse to the same record name, so
        // "Alice" and "  alice " collide (case-insensitive uniqueness).
        XCTAssertEqual(UserProfile.recordName(for: "Alice"), "profile_alice")
        XCTAssertEqual(UserProfile.recordName(for: "  ALICE  "), "profile_alice")
        XCTAssertEqual(UserProfile.recordName(for: "alice"),
                       UserProfile.recordName(for: "ALICE"))
        XCTAssertEqual(UserProfile.normalizedUsername("  BoB "), "bob")
    }

    func testUsernameValidationBounds() {
        XCTAssertTrue(UserProfile.isValidUsername("jake"))
        XCTAssertTrue(UserProfile.isValidUsername("a_b.c-1"))
        XCTAssertFalse(UserProfile.isValidUsername("a"))            // too short
        XCTAssertFalse(UserProfile.isValidUsername(""))            // empty
        XCTAssertFalse(UserProfile.isValidUsername("has space"))   // disallowed char
        XCTAssertFalse(UserProfile.isValidUsername("emoji😀"))      // disallowed char
        XCTAssertFalse(UserProfile.isValidUsername(String(repeating: "x", count: 31)))
    }

    // MARK: UserProfile <-> CKRecord

    func testUserProfileRecordRoundTrips() {
        let profile = UserProfile(
            username: "Jake",
            displayName: "Jake L",
            userRecordID: "_abc123",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let record = profile.toRecord()

        // The record lands at the deterministic, normalized record name.
        XCTAssertEqual(record.recordType, UserProfile.RecordType.profile)
        XCTAssertEqual(record.recordID.recordName, "profile_jake")
        XCTAssertEqual(record[UserProfile.Field.username] as? String, "Jake")
        XCTAssertEqual(record[UserProfile.Field.userRecordID] as? String, "_abc123")

        // Mapping back recovers the value (original-case username preserved).
        let back = UserProfile(record: record)
        XCTAssertEqual(back?.username, "Jake")
        XCTAssertEqual(back?.displayName, "Jake L")
        XCTAssertEqual(back?.userRecordID, "_abc123")
        XCTAssertEqual(back?.createdAt, Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testUserProfileInitRejectsWrongTypeAndMissingFields() {
        // Wrong record type → nil.
        let wrong = CKRecord(recordType: Invitation.RecordType.invitation,
                             recordID: CKRecord.ID(recordName: "x"))
        XCTAssertNil(UserProfile(record: wrong))

        // Right type but missing the required username/userRecordID → nil.
        let incomplete = CKRecord(recordType: UserProfile.RecordType.profile,
                                  recordID: CKRecord.ID(recordName: "profile_x"))
        XCTAssertNil(UserProfile(record: incomplete))
    }

    func testUserProfileDisplayNameDefaultsToUsername() {
        let rec = CKRecord(recordType: UserProfile.RecordType.profile,
                           recordID: CKRecord.ID(recordName: "profile_x"))
        rec[UserProfile.Field.username] = "Xavier" as CKRecordValue
        rec[UserProfile.Field.userRecordID] = "_x" as CKRecordValue
        // No displayName field set → falls back to username.
        XCTAssertEqual(UserProfile(record: rec)?.displayName, "Xavier")
    }

    // MARK: Invitation <-> CKRecord

    func testInvitationRecordRoundTrips() {
        let url = URL(string: "https://www.icloud.com/share/ABC123")!
        let invitation = Invitation.make(
            toUserRecordID: "_recipient",
            fromUserRecordID: "_sender",
            fromUsername: "jake",
            albumName: "Trip 2026",
            shareURL: url)
        let record = invitation.toRecord()

        XCTAssertEqual(record.recordType, Invitation.RecordType.invitation)
        XCTAssertEqual(record.recordID.recordName, invitation.id)   // UUID
        XCTAssertEqual(record[Invitation.Field.toUserRecordID] as? String, "_recipient")
        XCTAssertEqual(record[Invitation.Field.shareURL] as? String, url.absoluteString)

        let back = Invitation(record: record)
        XCTAssertEqual(back?.id, invitation.id)
        XCTAssertEqual(back?.toUserRecordID, "_recipient")
        XCTAssertEqual(back?.fromUserRecordID, "_sender")
        XCTAssertEqual(back?.fromUsername, "jake")
        XCTAssertEqual(back?.albumName, "Trip 2026")
        XCTAssertEqual(back?.shareURL, url)
    }

    func testInvitationInitRejectsWrongTypeAndMissingFields() {
        let wrong = CKRecord(recordType: UserProfile.RecordType.profile,
                             recordID: CKRecord.ID(recordName: "profile_y"))
        XCTAssertNil(Invitation(record: wrong))

        // Missing the required share URL → nil (won't show a useless inbox row).
        let incomplete = CKRecord(recordType: Invitation.RecordType.invitation,
                                  recordID: CKRecord.ID(recordName: "inv-1"))
        incomplete[Invitation.Field.toUserRecordID] = "_r" as CKRecordValue
        incomplete[Invitation.Field.fromUserRecordID] = "_s" as CKRecordValue
        XCTAssertNil(Invitation(record: incomplete))
    }

    // MARK: HandledInvitations cache

    func testHandledInvitationsFilterAndRoundTrip() throws {
        var handled = HandledInvitations()
        let a = Invitation.make(toUserRecordID: "_r", fromUserRecordID: "_s",
                                fromUsername: "x", albumName: "A",
                                shareURL: URL(string: "https://x/a")!)
        let b = Invitation.make(toUserRecordID: "_r", fromUserRecordID: "_s",
                                fromUsername: "x", albumName: "B",
                                shareURL: URL(string: "https://x/b")!)
        XCTAssertEqual(handled.unhandled([a, b]).count, 2)

        handled.mark(a.id)
        XCTAssertTrue(handled.contains(a.id))
        let remaining = handled.unhandled([a, b])
        XCTAssertEqual(remaining.map(\.id), [b.id])

        // Codable round-trip preserves the handled set.
        let data = try JSONEncoder().encode(handled)
        let back = try JSONDecoder().decode(HandledInvitations.self, from: data)
        XCTAssertTrue(back.contains(a.id))
        XCTAssertFalse(back.contains(b.id))
    }

    // MARK: Friend cache encode/decode

    func testFriendCacheEncodeDecode() throws {
        let friends = [
            Friend(username: "alice", displayName: "Alice", userRecordID: "_a"),
            Friend(username: "bob", displayName: "Bob", userRecordID: "_b"),
        ]
        let data = try JSONEncoder().encode(friends)
        let back = try JSONDecoder().decode([Friend].self, from: data)
        XCTAssertEqual(back, friends)
        // Identity is the userRecordID (unique per person).
        XCTAssertEqual(back.first?.id, "_a")
    }

    func testFriendFromProfileCopiesIdentity() {
        let profile = UserProfile(username: "Cara", displayName: "Cara K",
                                  userRecordID: "_c", createdAt: Date())
        let friend = Friend(profile: profile)
        XCTAssertEqual(friend.username, "Cara")
        XCTAssertEqual(friend.displayName, "Cara K")
        XCTAssertEqual(friend.userRecordID, "_c")
        XCTAssertEqual(friend.id, "_c")
    }

    // MARK: UserProfile public avatar (decorative; never matched)

    func testUserProfileAvatarRoundTripsThroughRecord() {
        let profile = UserProfile(username: "Pat", displayName: "Pat",
                                  userRecordID: "_p", createdAt: Date())
        let record = profile.toRecord()
        // toRecord stays pure (no avatar). attachAvatar adds the CKAsset.
        XCTAssertNil(record[UserProfile.Field.avatar])
        let bytes = Data([0xFF, 0xD8, 0xFF, 0x01, 0x02])   // arbitrary "jpeg-ish" bytes
        let tempURL = UserProfile.attachAvatar(bytes, to: record)
        defer { tempURL.map { try? FileManager.default.removeItem(at: $0) } }
        XCTAssertNotNil(record[UserProfile.Field.avatar] as? CKAsset)

        // Mapping the record back recovers the avatar bytes from the CKAsset file.
        let back = UserProfile(record: record)
        XCTAssertEqual(back?.avatarData, bytes)

        // Clearing the avatar removes the field and yields nil bytes on map-back.
        UserProfile.attachAvatar(nil, to: record)
        XCTAssertNil(record[UserProfile.Field.avatar])
        XCTAssertNil(UserProfile(record: record)?.avatarData)
    }
}

// MARK: - Photo requests: pure-logic round-trips (no CloudKit network)

/// These exercise only the value<->CKRecord mapping for PhotoRequest /
/// FacePayload, the FaceFilter raw values, the embedding byte codec, and the
/// handled-requests cache — all pure logic. They build CKRecords in memory and
/// never reach a CloudKit container, so they run in the simulator test host.
/// CRITICALLY they also assert the biometric embedding is NEVER on the public
/// PhotoRequest record.
final class PhotoRequestMappingTests: XCTestCase {

    func testFaceFilterRawValuesAndNeedsFace() {
        // Raw values are part of the on-the-wire schema; pin them.
        XCTAssertEqual(FaceFilter.any.rawValue, "any")
        XCTAssertEqual(FaceFilter.onlyMe.rawValue, "onlyMe")
        XCTAssertEqual(FaceFilter.withoutMe.rawValue, "withoutMe")
        XCTAssertEqual(FaceFilter(rawValue: "onlyMe"), .onlyMe)
        XCTAssertNil(FaceFilter(rawValue: "bogus"))
        XCTAssertFalse(FaceFilter.any.needsFace)
        XCTAssertTrue(FaceFilter.onlyMe.needsFace)
        XCTAssertTrue(FaceFilter.withoutMe.needsFace)
    }

    func testPhotoRequestRecordRoundTripsWithFaceShare() {
        let url = URL(string: "https://www.icloud.com/share/FACE123")!
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = Date(timeIntervalSince1970: 1_700_600_000)
        let request = PhotoRequest.make(
            toUserRecordID: "_friend",
            fromUserRecordID: "_me",
            fromUsername: "jake",
            description: "concert",
            startDate: start, endDate: end,
            faceFilter: .onlyMe,
            faceShareURL: url)
        let record = request.toRecord()

        XCTAssertEqual(record.recordType, PhotoRequest.RecordType.request)
        XCTAssertEqual(record.recordID.recordName, request.id)
        XCTAssertEqual(record[PhotoRequest.Field.toUserRecordID] as? String, "_friend")
        XCTAssertEqual(record[PhotoRequest.Field.faceFilter] as? String, "onlyMe")
        XCTAssertEqual(record[PhotoRequest.Field.faceShareURL] as? String, url.absoluteString)

        // PRIVACY: the public record carries NO embedding and NO photo — only the
        // criteria + the (access-controlled) face-share URL.
        XCTAssertNil(record["embedding"])
        XCTAssertNil(record[FacePayload.Field.embedding])
        XCTAssertFalse(record.allKeys().contains { $0.lowercased().contains("embedding") })

        let back = PhotoRequest(record: record)
        XCTAssertEqual(back?.toUserRecordID, "_friend")
        XCTAssertEqual(back?.fromUsername, "jake")
        XCTAssertEqual(back?.requestDescription, "concert")
        XCTAssertEqual(back?.startDate, start)
        XCTAssertEqual(back?.endDate, end)
        XCTAssertEqual(back?.faceFilter, .onlyMe)
        XCTAssertEqual(back?.faceShareURL, url)
    }

    func testPhotoRequestAnyFilterOmitsFaceShareURL() {
        let request = PhotoRequest.make(
            toUserRecordID: "_f", fromUserRecordID: "_m", fromUsername: "x",
            description: "beach",
            startDate: Date(timeIntervalSince1970: 0), endDate: Date(timeIntervalSince1970: 1),
            faceFilter: .any, faceShareURL: nil)
        let record = request.toRecord()
        XCTAssertNil(record[PhotoRequest.Field.faceShareURL])
        XCTAssertEqual(PhotoRequest(record: record)?.faceFilter, .any)
        XCTAssertNil(PhotoRequest(record: record)?.faceShareURL)
    }

    func testPhotoRequestInitRejectsWrongTypeAndDegradesUnknownFilter() {
        // Wrong record type → nil.
        let wrong = CKRecord(recordType: UserProfile.RecordType.profile,
                             recordID: CKRecord.ID(recordName: "profile_z"))
        XCTAssertNil(PhotoRequest(record: wrong))

        // Missing required fields → nil.
        let incomplete = CKRecord(recordType: PhotoRequest.RecordType.request,
                                  recordID: CKRecord.ID(recordName: "req-1"))
        incomplete[PhotoRequest.Field.toUserRecordID] = "_f" as CKRecordValue
        XCTAssertNil(PhotoRequest(record: incomplete))

        // Complete but with an UNKNOWN faceFilter string → degrades to .any (the
        // safe, no-biometric mode) rather than dropping the whole request.
        let rec = CKRecord(recordType: PhotoRequest.RecordType.request,
                           recordID: CKRecord.ID(recordName: "req-2"))
        rec[PhotoRequest.Field.toUserRecordID] = "_f" as CKRecordValue
        rec[PhotoRequest.Field.fromUserRecordID] = "_m" as CKRecordValue
        rec[PhotoRequest.Field.description] = "x" as CKRecordValue
        rec[PhotoRequest.Field.startDate] = Date(timeIntervalSince1970: 0) as CKRecordValue
        rec[PhotoRequest.Field.endDate] = Date(timeIntervalSince1970: 1) as CKRecordValue
        rec[PhotoRequest.Field.faceFilter] = "garbage" as CKRecordValue
        XCTAssertEqual(PhotoRequest(record: rec)?.faceFilter, .any)
    }

    // MARK: FacePayload (the biometric — lives ONLY in the ephemeral private zone)

    func testFacePayloadEmbeddingByteCodecRoundTrips() {
        let vector: [Float] = (0..<512).map { Float($0) / 512 - 0.5 }
        let data = FacePayload.encode(vector)
        XCTAssertEqual(data.count, 512 * MemoryLayout<Float32>.size)
        let back = FacePayload.decode(data)
        XCTAssertEqual(back, vector)
    }

    func testFacePayloadDecodeRejectsTruncatedBytes() {
        let data = FacePayload.encode([1, 2, 3])
        XCTAssertNil(FacePayload.decode(data.prefix(data.count - 1)))   // not a whole Float32
    }

    func testFacePayloadRecordRoundTripsInEphemeralZone() {
        let zone = CKRecordZone.ID(zoneName: "facereq-1", ownerName: CKCurrentUserDefaultName)
        let payload = FacePayload(embedding: [0.1, -0.2, 0.3])
        let record = payload.toRecord(inZone: zone)

        XCTAssertEqual(record.recordType, FacePayload.RecordType.payload)
        XCTAssertEqual(record.recordID.recordName, FacePayload.recordName)
        XCTAssertEqual(record.recordID.zoneID, zone)   // never the default/public zone
        XCTAssertNotNil(record[FacePayload.Field.embedding] as? Data)

        let back = FacePayload(record: record)
        XCTAssertEqual(back?.embedding, [0.1, -0.2, 0.3])

        // Wrong record type → nil.
        let wrong = CKRecord(recordType: PhotoRequest.RecordType.request,
                             recordID: CKRecord.ID(recordName: "x"))
        XCTAssertNil(FacePayload(record: wrong))
    }

    // MARK: HandledRequests cache

    func testHandledRequestsFilterAndRoundTrip() throws {
        var handled = HandledRequests()
        let a = PhotoRequest.make(toUserRecordID: "_r", fromUserRecordID: "_s",
                                  fromUsername: "x", description: "A",
                                  startDate: Date(timeIntervalSince1970: 0),
                                  endDate: Date(timeIntervalSince1970: 1),
                                  faceFilter: .any, faceShareURL: nil)
        let b = PhotoRequest.make(toUserRecordID: "_r", fromUserRecordID: "_s",
                                  fromUsername: "x", description: "B",
                                  startDate: Date(timeIntervalSince1970: 0),
                                  endDate: Date(timeIntervalSince1970: 1),
                                  faceFilter: .any, faceShareURL: nil)
        XCTAssertEqual(handled.unhandled([a, b]).count, 2)
        handled.mark(a.id)
        XCTAssertTrue(handled.contains(a.id))
        XCTAssertEqual(handled.unhandled([a, b]).map(\.id), [b.id])

        let data = try JSONEncoder().encode(handled)
        let back = try JSONDecoder().decode(HandledRequests.self, from: data)
        XCTAssertTrue(back.contains(a.id))
        XCTAssertFalse(back.contains(b.id))
    }

    // MARK: PendingFaceZones cache (durable ephemeral-face-zone cleanup, #4)

    func testPendingFaceZonesAddIsIdempotentRemoveAndRoundTrip() throws {
        var pending = PendingFaceZones()
        XCTAssertTrue(pending.isEmpty)

        let a = PendingFaceZones.ZoneRef(zoneName: "facereq-A", ownerName: "_owner")
        let b = PendingFaceZones.ZoneRef(zoneName: "facereq-B", ownerName: "_owner")

        pending.add(a)
        pending.add(a)                 // duplicate → no-op
        pending.add(b)
        XCTAssertEqual(pending.zones.count, 2)
        XCTAssertFalse(pending.isEmpty)

        pending.remove(a)
        XCTAssertEqual(pending.zones, [b])

        // Codable round-trip (the on-disk persistence contract for the sweep).
        let data = try JSONEncoder().encode(pending)
        let back = try JSONDecoder().decode(PendingFaceZones.self, from: data)
        XCTAssertEqual(back.zones, [b])

        // Removing an absent ref is a harmless no-op (tolerant of already-gone).
        var p2 = back
        p2.remove(a)
        XCTAssertEqual(p2.zones, [b])
    }
}

// MARK: - RequestStore fulfill: face-filter status (privacy, #2)

/// Exercises RequestStore.fulfill's FACE-FILTER STATUS in the XCTest host, where
/// `runningTests` is true so the CloudKit accept never runs and a face-filtered
/// request deterministically reports `.unavailable` (never silently degrading to
/// a pre-selected unfiltered set). Pure on-device PhotoStore search underneath.
@MainActor
final class RequestStoreFulfillTests: XCTestCase {

    private var store: PhotoStore { PhotoStore.shared }
    private var requests: RequestStore { RequestStore.shared }

    override func setUp() async throws { store.resetIndex() }
    override func tearDown() async throws { store.resetIndex() }

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private func indexPhoto(_ id: String, createdAt: Date) {
        store.index(assetID: id, createdAt: createdAt, lat: nil, lon: nil,
                    clipEmbedding: [Float](repeating: 0, count: 512),
                    faceEmbeddings: [], faceRects: [], isVideo: false, duration: 0,
                    faceSharpness: nil, imageSharpness: nil)
    }

    /// A `.any` request needs no face → status `.notRequested`, candidates = the
    /// date-window matches, and the review view will pre-select them.
    func testFulfillAnyFilterIsNotRequestedAndReturnsWindowMatches() async {
        indexPhoto("p1", createdAt: date(2023, 5, 10))
        indexPhoto("p2", createdAt: date(2023, 5, 11))
        indexPhoto("out", createdAt: date(2022, 1, 1))   // outside the window

        let req = PhotoRequest.make(
            toUserRecordID: "_me", fromUserRecordID: "_them", fromUsername: "ann",
            description: "", startDate: date(2023, 5, 1), endDate: date(2023, 5, 31),
            faceFilter: .any, faceShareURL: nil)

        let result = await requests.fulfill(request: req)
        XCTAssertEqual(result.faceFilterStatus, .notRequested)
        XCTAssertEqual(Set(result.candidateAssetIDs), ["p1", "p2"])
    }

    /// A face-filtered request with a face-share URL CANNOT obtain the embedding in
    /// the test host (gated). It MUST report `.unavailable` (NOT `.applied`), so the
    /// review view starts with nothing pre-selected — never defaulting an `.onlyMe`
    /// request to sharing the whole unfiltered set.
    func testFulfillFaceFilterUnavailableInTestHostDoesNotClaimApplied() async {
        indexPhoto("p1", createdAt: date(2023, 5, 10))
        indexPhoto("p2", createdAt: date(2023, 5, 11))

        let url = URL(string: "https://www.icloud.com/share/FACEXYZ")!
        let req = PhotoRequest.make(
            toUserRecordID: "_me", fromUserRecordID: "_them", fromUsername: "ann",
            description: "", startDate: date(2023, 5, 1), endDate: date(2023, 5, 31),
            faceFilter: .onlyMe, faceShareURL: url)

        let result = await requests.fulfill(request: req)
        // Critically NOT `.applied` — the filter could not be enforced.
        XCTAssertEqual(result.faceFilterStatus, .unavailable)
        // The candidate POOL is the unfiltered window matches (so a retry/manual
        // pick is possible), but the status flags that nothing should be
        // pre-selected.
        XCTAssertEqual(Set(result.candidateAssetIDs), ["p1", "p2"])
    }
}
