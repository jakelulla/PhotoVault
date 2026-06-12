import SwiftUI

struct PersonPhotosView: View {
    let cluster: PersonCluster
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
        .navigationTitle(cluster.name ?? "Person")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if !loader.hasLoadedOnce {
                let id = cluster.id
                await loader.start { limit, offset in
                    let all = PhotoStore.shared.photos(forCluster: id)
                    return Array(all.dropFirst(offset).prefix(limit))
                }
            }
        }
    }
}
