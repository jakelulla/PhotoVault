import SwiftUI

struct LocationPhotosView: View {
    let location: LocalLocation
    @StateObject private var loader = PagedPhotoLoader()

    var body: some View {
        Group {
            if !loader.hasLoadedOnce && loader.isLoading {
                ProgressView("Loading photos…")
            } else if loader.results.isEmpty {
                ContentUnavailableView("No Photos", systemImage: "photo")
            } else {
                PhotoResultsGrid(
                    results: loader.results,
                    onReachEnd: { Task { await loader.loadMore() } },
                    onDelete: { loader.remove(photoID: $0) }
                )
            }
        }
        .navigationTitle(location.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if !loader.hasLoadedOnce {
                let name = location.name
                await loader.start { limit, offset in
                    let all = PhotoStore.shared.photos(forLocation: name)
                    return Array(all.dropFirst(offset).prefix(limit))
                }
            }
        }
    }
}
