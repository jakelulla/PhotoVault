import AVKit
import Photos
import SwiftUI

/// Full-screen photo viewer with swipe-to-page through the result set.
struct PhotoDetailView: View {
    let results: [LocalPhoto]
    var onDelete: ((Int) -> Void)? = nil
    @State private var selection: Int    // current photoID
    @State private var isZoomed = false
    @State private var confirmingDelete = false
    @State private var showSimilar = false
    @Environment(\.dismiss) private var dismiss

    init(results: [LocalPhoto], startID: Int, onDelete: ((Int) -> Void)? = nil) {
        self.results = results
        self.onDelete = onDelete
        _selection = State(initialValue: startID)
    }

    var body: some View {
        // Paged TabView builds every page eagerly — one tap would materialize
        // the whole result set. Keep every page in the ForEach (stable tags so
        // swiping works) but render real content only for selection±1; the
        // rest are black placeholders that fill in as the selection moves.
        let currentIndex = results.firstIndex { $0.photoID == selection } ?? 0
        TabView(selection: $selection) {
            ForEach(Array(results.enumerated()), id: \.element.id) { idx, result in
                Group {
                    if abs(idx - currentIndex) <= 1 {
                        PhotoPage(photo: result, isZoomed: $isZoomed)
                    } else {
                        Color.black
                    }
                }
                .tag(result.photoID)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .swipeToDismiss(isEnabled: !isZoomed)
        .background(Color.black.ignoresSafeArea())
        .navigationTitle(current?.displayDate ?? "Photo")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showSimilar = true } label: {
                    Image(systemName: "sparkles.rectangle.stack")
                }
            }
            if onDelete != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) { confirmingDelete = true } label: {
                        Image(systemName: "trash")
                    }
                }
            }
        }
        .sheet(isPresented: $showSimilar) {
            if let photo = current {
                SimilarPhotosView(sourceAssetID: photo.assetID)
            }
        }
        .confirmationDialog("Delete this photo?", isPresented: $confirmingDelete,
                            titleVisibility: .visible) {
            Button("Delete Photo", role: .destructive) { deleteCurrent() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It will be removed from Search, People, and Places. Your camera roll isn't affected.")
        }
        .onChange(of: selection) { isZoomed = false }
    }

    private func deleteCurrent() {
        let id = selection
        PhotoStore.shared.deletePhoto(photoID: id)
        onDelete?(id)
        dismiss()
    }

    private var current: LocalPhoto? { results.first { $0.photoID == selection } }
}

private struct PhotoPage: View {
    let photo: LocalPhoto
    @Binding var isZoomed: Bool

    private var personNames: [String] {
        PhotoStore.shared.clusters
            .filter { photo.personClusterIDs.contains($0.id) }
            .compactMap { $0.name }
    }

    var body: some View {
        ZStack {
            if photo.video {
                VideoPage(assetID: photo.assetID)
            } else {
                PHFullImageView(assetID: photo.assetID, isZoomed: $isZoomed)
            }
        }
        .overlay(alignment: .bottom) {
            let names = personNames
            let loc = photo.locationName
            if !names.isEmpty || loc != nil {
                VStack(spacing: 2) {
                    if !names.isEmpty {
                        Text(names.joined(separator: ", "))
                            .font(.subheadline).foregroundStyle(.white)
                    }
                    if let loc {
                        Label(loc, systemImage: "mappin.and.ellipse")
                            .font(.caption).foregroundStyle(.white.opacity(0.8))
                    }
                }
                .padding(8)
                .background(.black.opacity(0.35), in: Capsule())
                .padding(.bottom, 24)
                .allowsHitTesting(false)
            }
        }
    }
}

// MARK: - Video playback

/// Full-screen AVPlayer page for one video asset. Shared by the detail
/// viewer, the pre-index browse viewer, and the duplicate reviewer.
struct VideoPage: View {
    let assetID: String
    @State private var player: AVPlayer?

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
            } else {
                ProgressView().tint(.white)
            }
        }
        .task {
            guard player == nil,
                  let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID],
                                                  options: nil).firstObject else { return }
            let opts = PHVideoRequestOptions()
            opts.isNetworkAccessAllowed = true
            let item: AVPlayerItem? = await withCheckedContinuation { cont in
                PHImageManager.default().requestPlayerItem(forVideo: asset, options: opts) { item, _ in
                    cont.resume(returning: item)
                }
            }
            if let item { player = AVPlayer(playerItem: item) }
        }
        .onDisappear { player?.pause() }
    }
}

// MARK: - More Like This

/// Library ranked by CLIP similarity to one photo — and the image-anchor
/// entry point for search math: +/− text chips re-rank with a composite
/// embedding ("this photo, but at night"), and the current expression can
/// be saved as a live smart folder.
struct SimilarPhotosView: View {
    let sourceAssetID: String
    @ObservedObject private var store = PhotoStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var results: [LocalPhoto] = []
    @State private var loaded = false
    @State private var plusTerms: [String] = []
    @State private var minusTerms: [String] = []
    @State private var mathUnavailable = false
    @State private var showSaveFolder = false

    private var mathActive: Bool { !plusTerms.isEmpty || !minusTerms.isEmpty }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                MathChipsEditor(plusTerms: $plusTerms,
                                minusTerms: $minusTerms,
                                onChange: refresh)
                    .disabled(mathUnavailable)
                    // Tinted while a composite vector (∑) drives the ranking.
                    .background(mathActive ? Color.accentColor.opacity(0.06) : Color.clear)
                if mathUnavailable {
                    Text("Chips need the on-device models, which aren't available here — showing plain similarity instead.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 6)
                }
                Divider()
                content
            }
            .navigationTitle("More Like This")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showSaveFolder = true
                    } label: {
                        Label("Save as Folder", systemImage: "folder.badge.plus")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showSaveFolder) {
                // Seed the editor with this photo as anchor plus the chips;
                // the saved folder re-evaluates the same composite live.
                // With chips active, seed the SAME 0.45 floor this view
                // ranked with — the editor's anchored default (0.55) would
                // save a folder that drops photos visible in this grid.
                SmartFolderEditor(folderID: nil,
                                  initialQuery: plusTerms.joined(separator: " "),
                                  initialAnchor: sourceAssetID,
                                  initialMinus: minusTerms.joined(separator: ", "),
                                  initialMinScore: mathActive ? 0.45 : nil)
            }
            .task { refresh() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !loaded {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if results.isEmpty {
            ContentUnavailableView(
                "No similar photos", systemImage: "sparkles.rectangle.stack",
                description: Text(mathActive
                    ? "Nothing matches this photo combined with those terms."
                    : "Nothing else in your library looks like this one."))
        } else {
            PhotoResultsGrid(results: results)
        }
    }

    private func refresh() {
        if mathActive {
            // The engine loads its models lazily; nudge it like the store's
            // own embedding paths do before declaring it unavailable.
            let engine = OnDeviceMLEngine.shared
            if !engine.isAvailable { try? engine.loadModels() }
            if let emb = store.compositeQueryEmbedding(anchorAssetID: sourceAssetID,
                                                       plus: plusTerms,
                                                       minus: minusTerms) {
                mathUnavailable = false
                // 0.45 floor: looser than pure image–image similarity (0.55)
                // because the text terms deliberately pull the vector away
                // from the anchor. The anchor itself always scores ~top, so
                // drop it from its own results.
                results = store.searchByEmbedding(emb, floor: 0.45)
                    .map(\.photo)
                    .filter { $0.assetID != sourceAssetID }
                loaded = true
                return
            }
            mathUnavailable = true
        }
        results = store.similarPhotos(to: sourceAssetID)
        loaded = true
    }
}
