import CloudKit
import PhotosUI
import SwiftUI
import UIKit

/// The contents of one shared album: a thumbnails-first grid of its photos.
///
/// Loading strategy (Phase 4): the grid fetches records with `desiredKeys` that
/// EXCLUDE the full image (CloudKitService.loadPhotos), so we only download
/// ~256px thumbnails up front. The full-resolution bytes are pulled lazily, on
/// tap, by the full-screen viewer. Pull-to-refresh re-fetches; an "Add Photos"
/// toolbar button presents a PHPicker and contributes the selection.
///
/// Like the rest of the shared-albums stack, every CloudKit touch flows through
/// SharedAlbumStore, which guards on `CloudKitService.isAvailable`. On the
/// simulator / in tests this view's `.task` lands in the unavailable path and
/// does no network work.
struct SharedAlbumDetailView: View {
    let album: SharedAlbum

    @ObservedObject private var store = SharedAlbumStore.shared

    @State private var showPicker = false
    @State private var opened: SharedPhoto?

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 2)]

    private var photos: [SharedPhoto] { store.photosByAlbum[album.id] ?? [] }
    private var isLoading: Bool { store.loadingPhotos.contains(album.id) }
    private var uploadFraction: Double? { store.uploadProgress[album.id] }

    var body: some View {
        Group {
            if photos.isEmpty && isLoading {
                ProgressView("Loading photos…")
            } else if photos.isEmpty {
                ContentUnavailableView {
                    Label("No photos yet", systemImage: "photo.on.rectangle.angled")
                } description: {
                    Text("Tap + to add photos to this album. Everyone you've invited can add their own.")
                } actions: {
                    Button {
                        showPicker = true
                    } label: {
                        Label("Add Photos", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                grid
            }
        }
        .navigationTitle(album.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showPicker = true
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(uploadFraction != nil)
            }
        }
        .safeAreaInset(edge: .top) {
            if let fraction = uploadFraction {
                ProgressView(value: fraction) {
                    Text("Adding photos… \(Int(fraction * 100))%")
                        .font(.caption)
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(.bar)
            }
        }
        // The ONLY CloudKit touch from this view, and only after appear — never
        // at launch. Loads the album's thumbnails-first photo list.
        .task {
            await store.loadPhotos(forAlbum: album)
        }
        .refreshable {
            await store.loadPhotos(forAlbum: album)
        }
        .sheet(isPresented: $showPicker) {
            SharedAlbumPhotoPicker { localIDs in
                guard !localIDs.isEmpty else { return }
                Task { await store.addPhotos(localAssetIDs: localIDs, toAlbum: album) }
            }
        }
        .fullScreenCover(item: $opened) { photo in
            SharedPhotoViewer(photo: photo, album: album)
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(photos) { photo in
                    SharedThumbView(data: store.cachedThumbnail(for: photo))
                        .aspectRatio(1, contentMode: .fill)
                        .frame(minWidth: 0, maxWidth: .infinity)
                        .clipped()
                        .contentShape(Rectangle())
                        .onTapGesture { opened = photo }
                }
            }
            .padding(.horizontal, 2)
        }
    }
}

// MARK: - CKAsset-backed thumbnail

/// Displays a thumbnail from raw JPEG bytes (decoded off the main thread). The
/// bytes come from a CKAsset that SharedAlbumStore already read into memory, so
/// there is no per-cell network or file I/O here — just a decode. Falls back to
/// a placeholder while decoding or when bytes are absent.
struct SharedThumbView: View {
    let data: Data?

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Color(.secondarySystemBackground)
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundStyle(.tertiary)
                    }
            }
        }
        .task(id: data) { await decode() }
    }

    private func decode() async {
        guard let data else { image = nil; return }
        // Decode off the main actor to keep scrolling smooth.
        let decoded = await Task.detached(priority: .userInitiated) {
            UIImage(data: data)
        }.value
        image = decoded
    }
}

// MARK: - Full-screen viewer (lazy full image)

/// Full-screen view of one shared photo. Pulls the FULL-resolution CKAsset bytes
/// lazily on appear (CloudKitService.fullImage), showing the cached thumbnail as
/// an instant placeholder underneath. Tap or swipe-down to dismiss.
private struct SharedPhotoViewer: View {
    let photo: SharedPhoto
    let album: SharedAlbum

    @ObservedObject private var store = SharedAlbumStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var fullImage: UIImage?
    @State private var loading = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let fullImage {
                Image(uiImage: fullImage)
                    .resizable()
                    .scaledToFit()
            } else if let thumb = store.cachedThumbnail(for: photo),
                      let img = UIImage(data: thumb) {
                // Instant low-res placeholder while the full image streams in.
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .blur(radius: 8)
                    .overlay { if loading { ProgressView().tint(.white) } }
            } else if loading {
                ProgressView().tint(.white)
            } else {
                ContentUnavailableView("Couldn't load photo",
                                       systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.white)
            }

            VStack {
                HStack {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title)
                            .foregroundStyle(.white, .black.opacity(0.4))
                            .padding()
                    }
                }
                Spacer()
            }
        }
        .task {
            let data = await store.fullImage(for: photo, in: album)
            if let data, let img = UIImage(data: data) { fullImage = img }
            loading = false
        }
        .onTapGesture { dismiss() }
    }
}

// MARK: - PHPicker wrapper

/// A thin PHPickerViewController wrapper that returns the selected assets'
/// `localIdentifier`s (so the store can re-fetch full-res bytes via PHAsset,
/// reusing the app's existing read access — no new permission this phase). The
/// picker filters to images only. Multi-select is enabled.
struct SharedAlbumPhotoPicker: UIViewControllerRepresentable {
    let onPicked: ([String]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPicked: onPicked) }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .images
        config.selectionLimit = 0   // 0 = unlimited multi-select
        config.preferredAssetRepresentationMode = .current
        let controller = PHPickerViewController(configuration: config)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let onPicked: ([String]) -> Void
        init(onPicked: @escaping ([String]) -> Void) { self.onPicked = onPicked }

        func picker(_ picker: PHPickerViewController,
                    didFinishPicking results: [PHPickerResult]) {
            // `assetIdentifier` is non-nil because the picker was created with an
            // explicit photoLibrary (.shared()), which grants identifier access.
            let ids = results.compactMap(\.assetIdentifier)
            picker.dismiss(animated: true)
            onPicked(ids)
        }
    }
}
