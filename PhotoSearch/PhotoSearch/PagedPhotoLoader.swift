import SwiftUI

/// Loads LocalPhoto results one page at a time for infinite scroll.
@MainActor
final class PagedPhotoLoader: ObservableObject {
    @Published private(set) var results: [LocalPhoto] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasLoadedOnce = false
    @Published var errorText: String?

    private let pageSize = 100
    private var offset = 0
    private var reachedEnd = false
    private var fetch: ((Int, Int) async throws -> [LocalPhoto])?

    func start(_ fetch: @escaping (Int, Int) async throws -> [LocalPhoto]) async {
        self.fetch = fetch
        offset = 0
        reachedEnd = false
        results = []
        errorText = nil
        hasLoadedOnce = false
        await loadMore()
    }

    func remove(photoID: Int) {
        results.removeAll { $0.photoID == photoID }
    }

    func loadMore() async {
        guard !isLoading, !reachedEnd, let fetch else { return }
        isLoading = true
        do {
            let page = try await fetch(pageSize, offset)
            results.append(contentsOf: page)
            offset += page.count
            if page.count < pageSize { reachedEnd = true }
        } catch {
            errorText = error.localizedDescription
            reachedEnd = true
        }
        isLoading = false
        hasLoadedOnce = true
    }
}
