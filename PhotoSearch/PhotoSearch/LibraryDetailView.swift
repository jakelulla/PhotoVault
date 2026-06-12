import Photos
import SwiftUI

/// Full-screen viewer for device photos. Swipe to page, pinch/double-tap to zoom,
/// swipe down to dismiss.
struct LibraryDetailView: View {
    let assets: [PHAsset]
    @State private var selection: String   // current asset localIdentifier
    @State private var isZoomed = false

    init(assets: [PHAsset], startIndex: Int) {
        self.assets = assets
        _selection = State(initialValue: assets[startIndex].localIdentifier)
    }

    var body: some View {
        TabView(selection: $selection) {
            ForEach(assets, id: \.localIdentifier) { asset in
                AssetPage(asset: asset, isZoomed: $isZoomed)
                    .tag(asset.localIdentifier)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .swipeToDismiss(isEnabled: !isZoomed)
        .background(Color.black.ignoresSafeArea())
        .navigationTitle(currentDate)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .onChange(of: selection) { isZoomed = false }
    }

    private var currentDate: String {
        guard let date = assets.first(where: { $0.localIdentifier == selection })?.creationDate
        else { return "Photo" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}

private struct AssetPage: View {
    let asset: PHAsset
    @Binding var isZoomed: Bool
    @EnvironmentObject private var library: PhotoLibraryModel
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                ZoomableImageView(image: image, onZoomChange: { isZoomed = $0 })
            } else {
                ProgressView().tint(.white)
            }
        }
        .onAppear {
            library.requestFullImage(for: asset) { img in
                if let img { image = img }
            }
        }
    }
}
