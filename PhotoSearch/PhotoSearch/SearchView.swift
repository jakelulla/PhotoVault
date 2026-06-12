import SwiftUI

struct SearchView: View {
    @State private var query = ""
    @State private var results: [LocalPhoto] = []
    @State private var hasSearched = false
    @State private var selectedFolderID: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchBar
                Divider()
                resultsArea
            }
            .navigationTitle("Search")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    FolderFilterButton(selectedFolderID: $selectedFolderID)
                }
            }
        }
        .onChange(of: selectedFolderID) { _, _ in
            if hasSearched { runSearch() }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Try \"Mom 2021\" or \"San Francisco\"", text: $query)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit { runSearch() }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .foregroundStyle(.secondary)
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding()
    }

    @ViewBuilder
    private var resultsArea: some View {
        if hasSearched && results.isEmpty {
            ContentUnavailableView("No matches", systemImage: "photo.badge.exclamationmark")
        } else if results.isEmpty {
            // Pre-search home: On This Day + Trips (falls back to the search
            // hint when there are no memories to show).
            MemoriesHome()
        } else {
            PhotoResultsGrid(
                results: results,
                onDelete: { id in results.removeAll { $0.photoID == id } }
            )
        }
    }

    private func runSearch() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        hasSearched = true
        results = PhotoStore.shared.searchPhotos(query: q, folderID: selectedFolderID)
    }
}
