import SwiftUI

struct SearchView: View {
    /// Incremented by MainTabs when the Search tab is tapped while already
    /// selected; each change clears the view back to the pre-search screen.
    var resetToken: Int = 0

    @ObservedObject private var store = PhotoStore.shared
    @State private var query = ""
    /// The query as last submitted — chip re-ranks and the moments reel key
    /// off this, not the live text field (typing without submitting must not
    /// silently change what the chips refine).
    @State private var submittedQuery = ""
    @State private var results: [LocalPhoto] = []
    @State private var hasSearched = false
    @State private var selectedFolderID: String?

    // Search math: +/− text chips composed onto the typed query's embedding.
    // Chips refine the current search; a fresh submit clears them.
    @State private var showRefine = false
    @State private var plusTerms: [String] = []
    @State private var minusTerms: [String] = []
    @State private var mathUnavailable = false

    // Best-matching moment inside each video for the current query.
    @State private var momentHits: [MomentHit] = []
    @State private var showMoments = false

    private var mathActive: Bool { !plusTerms.isEmpty || !minusTerms.isEmpty }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchBar
                // Recents (or, for a new user, worked examples) sit above the
                // divider so the pre-search screen teaches the query grammar
                // instead of showing an empty field.
                if !hasSearched && query.isEmpty { suggestionsBar }
                if hasSearched { refineBar }
                Divider()
                if hasSearched && !submittedQuery.isEmpty && !momentHits.isEmpty {
                    momentsButton
                }
                resultsArea
            }
            .navigationTitle("Search")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    FolderFilterButton(selectedFolderID: $selectedFolderID)
                }
            }
            .fullScreenCover(isPresented: $showMoments) {
                MomentReelView(hits: momentHits, title: submittedQuery)
            }
        }
        .onChange(of: selectedFolderID) { _, _ in
            if hasSearched {
                // Both the grid AND the moments must re-scope to the folder.
                momentHits = scopedMoments(for: submittedQuery)
                rerank()
            }
        }
        .onChange(of: resetToken) { _, _ in resetToRoot() }
    }

    /// Back to the pre-search screen: empty field, no results, no refine chips,
    /// no moments. The folder filter deliberately SURVIVES — it's a scope the
    /// user set explicitly from the toolbar, and silently dropping it on a tab
    /// tap would be the surprising behaviour.
    private func resetToRoot() {
        query = ""
        submittedQuery = ""
        results = []
        hasSearched = false
        plusTerms = []
        minusTerms = []
        mathUnavailable = false
        showRefine = false
        momentHits = []
        showMoments = false
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

    // MARK: - Recents / suggestions

    /// Worked examples for a library with no search history yet. Chosen to
    /// demonstrate the three things that compose but aren't discoverable:
    /// a person name, a relative date, and a place — each combined with a
    /// free-form description.
    private static let exampleQueries = [
        "beach last summer",
        "birthday cake",
        "hiking 2 years ago",
        "snow yesterday",
    ]

    private var suggestionsBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(store.recentSearches.isEmpty ? "Try" : "Recent")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                if !store.recentSearches.isEmpty {
                    Button("Clear") { store.clearRecentSearches() }
                        .font(.caption)
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                }
            }
            .padding(.horizontal)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    let recents = store.recentSearches
                    let items = recents.isEmpty ? Self.exampleQueries : recents
                    ForEach(items, id: \.self) { item in
                        Button {
                            query = item
                            runSearch()
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: recents.isEmpty ? "sparkles" : "clock.arrow.circlepath")
                                    .font(.caption2)
                                Text(item).font(.subheadline)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color(.secondarySystemBackground))
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.primary)
                        // Long-press to forget one entry without nuking the list.
                        .contextMenu {
                            if !recents.isEmpty {
                                Button(role: .destructive) {
                                    store.removeRecentSearch(item)
                                } label: { Label("Remove", systemImage: "trash") }
                            }
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
        .padding(.bottom, 10)
    }

    // MARK: - Search math (refine chips)

    private var refineBar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showRefine.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        // ∑ marks math mode: results are ranked by a composite
                        // vector, not the plain structured/caption search.
                        Image(systemName: mathActive ? "sum" : "plus.forwardslash.minus")
                        Text("Refine")
                        Image(systemName: showRefine ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                    }
                    .font(.caption.bold())
                }
                Spacer()
                if mathActive {
                    Button("Clear") {
                        plusTerms = []
                        minusTerms = []
                        rerank()
                    }
                    .font(.caption)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 6)

            if showRefine {
                MathChipsEditor(plusTerms: $plusTerms,
                                minusTerms: $minusTerms,
                                onChange: rerank)
                    .disabled(mathUnavailable)
                if mathUnavailable {
                    Text("Refining needs the on-device models, which aren't available here (e.g. in the Simulator).")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 6)
                }
            }
        }
        // Tint the whole bar while math mode is driving the ranking.
        .background(mathActive ? Color.accentColor.opacity(0.06) : Color.clear)
    }

    // MARK: - Video moments

    private var momentsButton: some View {
        Button { showMoments = true } label: {
            Label("Play Moments (\(momentHits.count))",
                  systemImage: "play.rectangle.on.rectangle.fill")
                .font(.subheadline.bold())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        }
        .buttonStyle(.borderedProminent)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
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
        submittedQuery = q
        store.recordSearch(q)
        // Chips refine one search; a fresh submit starts clean.
        plusTerms = []
        minusTerms = []
        mathUnavailable = false
        // Moments key off the submitted query only — chip edits re-rank
        // photos but don't change which video moments match.
        momentHits = scopedMoments(for: q)
        rerank()
    }

    /// videoMoments has no folder parameter (it scans the whole library), so
    /// scope its hits to the active folder filter caller-side — the grid
    /// below is folder-scoped, and the button's count and the reel must
    /// agree with it.
    private func scopedMoments(for q: String) -> [MomentHit] {
        let hits = store.videoMoments(matching: q)
        guard let fid = selectedFolderID,
              let folder = store.folders.first(where: { $0.id == fid }) else { return hits }
        let ids = folder.isSmart
            ? Set(store.photosForFolder(folder).map(\.assetID))
            : Set(folder.photoAssetIDs)
        return hits.filter { ids.contains($0.assetID) }
    }

    /// Re-rank the submitted query, routing through the composite-embedding
    /// path while math chips are active. The structured filters ("Mom 2021"
    /// = person + year are HARD constraints) survive chip mode: only the
    /// residual caption joins the composite vector, and the ranking is
    /// intersected with the structured candidate set — encoding the whole
    /// query as caption text silently dropped the filters. compositeQuery-
    /// Embedding returning nil (no text encoder — simulator) falls back to
    /// the plain structured search and flags the chip UI as unavailable.
    private func rerank() {
        let q = submittedQuery
        guard !q.isEmpty else { return }
        if mathActive {
            // The engine loads its models lazily; nudge it like the store's
            // own embedding paths do before declaring it unavailable.
            let engine = OnDeviceMLEngine.shared
            if !engine.isAvailable { try? engine.loadModels() }
            let (candidates, caption) =
                store.structuredSearchStage(query: q, folderID: selectedFolderID)
            if let emb = store.compositeQueryEmbedding(
                baseText: caption.isEmpty ? nil : caption,
                plus: plusTerms,
                minus: minusTerms) {
                mathUnavailable = false
                // 0.25 = the text-query calibration searchPhotos uses (the
                // 0.2 searchByEmbedding default is deliberately permissive
                // and admits a tail of unrelated photos). The candidate set
                // already carries the folder filter.
                let ids = Set(candidates.map(\.assetID))
                results = store.searchByEmbedding(emb, floor: 0.25)
                    .map(\.photo)
                    .filter { ids.contains($0.assetID) }
                return
            }
            mathUnavailable = true
        }
        results = store.searchPhotos(query: q, folderID: selectedFolderID)
    }
}
