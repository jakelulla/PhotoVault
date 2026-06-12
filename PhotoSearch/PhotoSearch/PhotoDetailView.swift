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
        TabView(selection: $selection) {
            ForEach(results) { result in
                PhotoPage(photo: result, isZoomed: $isZoomed)
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

/// Library ranked by CLIP similarity to one photo.
struct SimilarPhotosView: View {
    let sourceAssetID: String
    @Environment(\.dismiss) private var dismiss
    @State private var results: [LocalPhoto] = []
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Group {
                if !loaded {
                    ProgressView()
                } else if results.isEmpty {
                    ContentUnavailableView(
                        "No similar photos", systemImage: "sparkles.rectangle.stack",
                        description: Text("Nothing else in your library looks like this one."))
                } else {
                    PhotoResultsGrid(results: results)
                }
            }
            .navigationTitle("More Like This")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                results = PhotoStore.shared.similarPhotos(to: sourceAssetID)
                loaded = true
            }
        }
    }
}
