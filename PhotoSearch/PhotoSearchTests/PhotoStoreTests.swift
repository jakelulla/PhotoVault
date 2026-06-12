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

    private func indexPhoto(_ id: String, emb: [Float]? = nil) {
        store.index(
            assetID: id, createdAt: Date(), lat: nil, lon: nil,
            clipEmbedding: emb ?? [Float](repeating: 0, count: 512),
            faceEmbeddings: [], faceRects: [],
            isVideo: false, duration: 0
        )
    }

    /// Distinct unit vector along the given axis — guaranteed orthogonal to
    /// other axes (cosine 0), so photos don't accidentally duplicate-group.
    private func unitEmb(axis: Int) -> [Float] {
        var v = [Float](repeating: 0, count: 512)
        v[axis] = 1
        return v
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
