import SwiftUI

struct PersonPhotosView: View {
    let cluster: PersonCluster
    @StateObject private var loader = PagedPhotoLoader()
    @State private var showTogetherPicker = false
    @State private var togetherSelection: TogetherSelection?
    @State private var showGrowth = false
    @State private var slideshow: Slideshow?

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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { showTogetherPicker = true } label: {
                        Label("Together with…", systemImage: "person.2")
                    }
                } label: {
                    Image(systemName: "person.2")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                // Their story as a slideshow: chronological, with music.
                Button { slideshow = SlideshowBuilder.person(cluster) } label: {
                    Image(systemName: "play.circle")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                // Watch Them Grow: one best face per year, scrubbable.
                Button { showGrowth = true } label: {
                    Image(systemName: "sparkles")
                }
            }
        }
        .navigationDestination(isPresented: $showGrowth) {
            GrowthTimelineView(cluster: cluster)
        }
        // Full-screen "their story" slideshow (chronological, with music).
        .fullScreenCover(item: $slideshow) { show in
            SlideshowPlayerView(slideshow: show)
        }
        .navigationDestination(item: $togetherSelection) { selection in
            TogetherView(clusters: selection.clusters)
        }
        .sheet(isPresented: $showTogetherPicker) {
            TogetherPickerSheet(excludeID: cluster.id, singlePick: true) { picked in
                // Let the sheet finish dismissing before pushing — setting the
                // navigation item while the sheet is mid-dismiss can swallow
                // the push entirely.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    togetherSelection = TogetherSelection(clusters: [cluster] + picked)
                }
            }
        }
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
