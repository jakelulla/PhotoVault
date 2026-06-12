import Photos
import PhotosUI
import SwiftUI

private enum LibraryMode: String, CaseIterable {
    case years = "Years", months = "Months", all = "All", folders = "Folders"
}

/// Result of comparing the index against the camera roll, driving the
/// sync confirmation dialog.
private struct SyncPlan {
    var newCount: Int            // in camera roll, never indexed
    var goneIDs: Set<String>     // indexed + active, no longer in camera roll
    var excludedIDs: Set<String> // deleted in-app, still in camera roll
}

struct LibraryBrowseView: View {
    @EnvironmentObject private var indexer: Indexer
    @EnvironmentObject private var folderStore: FolderStore
    @EnvironmentObject private var library: PhotoLibraryModel
    @ObservedObject private var store = PhotoStore.shared
    @State private var mode: LibraryMode = .all

    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var syncPlan: SyncPlan? = nil
    @State private var showSyncDialog = false
    @State private var resultMessage: String? = nil

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $mode) {
                    ForEach(LibraryMode.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16).padding(.vertical, 8)
                Divider()

                content.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle("Photos")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    // Add photos from the camera roll: new ones index, ones
                    // deleted in-app are restored, already-present are no-ops.
                    PhotosPicker(selection: $pickerItems,
                                 matching: .any(of: [.images, .videos]),
                                 photoLibrary: .shared()) {
                        Image(systemName: "plus")
                    }
                    // Sync: make the app match the camera roll, with a choice
                    // about photos previously deleted in-app.
                    Button { Task { await prepareSync() } } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    NavigationLink {
                        DuplicatesSweepView()
                    } label: {
                        Image(systemName: "square.on.square")
                    }
                }
            }
            .onChange(of: pickerItems) { _, items in
                guard !items.isEmpty else { return }
                handlePicked(items)
            }
            .confirmationDialog(
                "Sync with Camera Roll",
                isPresented: $showSyncDialog,
                titleVisibility: .visible,
                presenting: syncPlan
            ) { plan in
                Button("Add Back \(plan.excludedIDs.count) Removed") {
                    executeSync(plan, restoreExcluded: true)
                }
                Button("Keep \(plan.excludedIDs.count) Removed Out") {
                    executeSync(plan, restoreExcluded: false)
                }
                Button("Cancel", role: .cancel) {}
            } message: { plan in
                Text(syncDialogMessage(plan))
            }
            .alert("Library", isPresented: Binding(
                get: { resultMessage != nil },
                set: { if !$0 { resultMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(resultMessage ?? "")
            }
        }
        .task { await folderStore.load() }
    }

    // MARK: - Add from camera roll

    private func handlePicked(_ items: [PhotosPickerItem]) {
        let pickedIDs = items.compactMap(\.itemIdentifier)
        pickerItems = []
        guard !pickedIDs.isEmpty else { return }

        var deletedByID: Set<String> = []
        var activeByID: Set<String> = []
        for p in store.photos {
            if p.isDeleted { deletedByID.insert(p.assetID) } else { activeByID.insert(p.assetID) }
        }

        let toRestore = Set(pickedIDs.filter { deletedByID.contains($0) })
        let newIDs    = pickedIDs.filter { !deletedByID.contains($0) && !activeByID.contains($0) }
        let already   = pickedIDs.count - toRestore.count - newIDs.count

        let restored = store.restorePhotos(toRestore)

        var parts: [String] = []
        if !newIDs.isEmpty { parts.append("\(newIDs.count) new photo\(newIDs.count == 1 ? "" : "s") queued for indexing") }
        if restored > 0 { parts.append("\(restored) restored") }
        if already > 0 { parts.append("\(already) already in the app") }
        resultMessage = parts.isEmpty ? "Nothing to add." : parts.joined(separator: ", ") + "."

        Task {
            // Recluster FIRST so a restored photo rejoins People immediately
            // instead of waiting behind a potentially long indexing pass.
            if restored > 0 {
                await store.reclusterPeople()
            }
            if !newIDs.isEmpty {
                // New picks arrive in library.assets via the change observer
                // (or are already there); the indexer skips everything else.
                await indexer.indexNewPhotos(from: library)
            }
        }
    }

    // MARK: - Sync with camera roll

    private func prepareSync() async {
        // Snapshot camera-roll IDs off the main thread — enumerating tens of
        // thousands of PHAssets on tap would visibly hang the UI.
        let rollIDs = await Task.detached(priority: .userInitiated) { () -> Set<String> in
            var ids = Set<String>()
            PHAsset.fetchAssets(with: PHFetchOptions()).enumerateObjects { asset, _, _ in
                ids.insert(asset.localIdentifier)
            }
            return ids
        }.value

        // Under limited photo access the fetch only sees the user-selected
        // subset — treating everything else as "gone" would mass-remove the
        // index (and irreversibly strip folder membership). Only prune with
        // full access.
        let fullAccess = library.status == .authorized

        var gone: Set<String> = []
        var excluded: Set<String> = []
        var known: Set<String> = []
        for p in store.photos {
            known.insert(p.assetID)
            if p.isDeleted {
                if rollIDs.contains(p.assetID) { excluded.insert(p.assetID) }
            } else if fullAccess && !rollIDs.contains(p.assetID) {
                gone.insert(p.assetID)
            }
        }
        let newCount = rollIDs.subtracting(known).count

        let plan = SyncPlan(newCount: newCount, goneIDs: gone, excludedIDs: excluded)
        if plan.excludedIDs.isEmpty {
            // Nothing to ask — just reconcile.
            executeSync(plan, restoreExcluded: false)
        } else {
            syncPlan = plan
            showSyncDialog = true
        }
    }

    private func syncDialogMessage(_ plan: SyncPlan) -> String {
        var lines: [String] = []
        if plan.newCount > 0 { lines.append("\(plan.newCount) new photo\(plan.newCount == 1 ? "" : "s") will be added.") }
        if !plan.goneIDs.isEmpty { lines.append("\(plan.goneIDs.count) no longer in your camera roll will be removed.") }
        lines.append("You removed \(plan.excludedIDs.count) photo\(plan.excludedIDs.count == 1 ? "" : "s") in the app — add them back or keep them out?")
        return lines.joined(separator: " ")
    }

    private func executeSync(_ plan: SyncPlan, restoreExcluded: Bool) {
        let restored = restoreExcluded ? store.restorePhotos(plan.excludedIDs) : 0
        if !plan.goneIDs.isEmpty { store.pruneDeletedAssets(plan.goneIDs) }

        var parts: [String] = []
        if plan.newCount > 0 { parts.append("\(plan.newCount) new queued for indexing") }
        if restored > 0 { parts.append("\(restored) restored") }
        if !plan.goneIDs.isEmpty { parts.append("\(plan.goneIDs.count) removed (gone from camera roll)") }
        resultMessage = parts.isEmpty ? "Already in sync." : "Sync: " + parts.joined(separator: ", ") + "."

        Task {
            if restored > 0 {
                await store.reclusterPeople()  // restored faces rejoin People first
            }
            if plan.newCount > 0 {
                await indexer.indexNewPhotos(from: library)
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch mode {
        case .all:
            // Indexed grid has the full toolset (Select, folders, delete,
            // detail view with trash) — same grid Months/Years drill into.
            // The raw-asset grid is only the pre-index fallback so photos
            // show instantly on first launch.
            if store.photos.isEmpty {
                AllAssetsGrid(assets: library.assets)
            } else {
                // membershipVersion id: restore/delete/prune don't change
                // photos.count, but they must refresh this grid's paged
                // snapshot — recreate it so restored photos appear at once.
                AllIndexedGrid().id(store.membershipVersion)
            }
        case .years:   periodContent(buckets: store.yearsIndex)
        case .months:  periodContent(buckets: store.monthsIndex)
        case .folders: FoldersGrid()
        }
    }

    @ViewBuilder
    private func periodContent(buckets: [PhotoStore.PeriodInfo]) -> some View {
        if buckets.isEmpty {
            ContentUnavailableView(
                "Not indexed yet", systemImage: "photo",
                description: Text("Years and Months appear as your library finishes indexing."))
        } else if mode == .years {
            YearsGrid(buckets: buckets)
        } else {
            MonthsGrid(buckets: buckets)
        }
    }
}

// MARK: - All photos (indexed) — full-featured grid with Select/folders/delete

private struct AllIndexedGrid: View {
    @StateObject private var loader = PagedPhotoLoader()

    var body: some View {
        Group {
            if loader.results.isEmpty && loader.isLoading {
                ProgressView()
            } else {
                PhotoResultsGrid(
                    results: loader.results,
                    onReachEnd: { Task { await loader.loadMore() } },
                    onDelete: { loader.remove(photoID: $0) }
                )
            }
        }
        .task {
            if !loader.hasLoadedOnce {
                await loader.start { limit, offset in
                    let all = PhotoStore.shared.allPhotos()
                    return Array(all.dropFirst(offset).prefix(limit))
                }
            }
        }
    }
}

// MARK: - All assets grid (shows every PHAsset immediately, no indexing needed)

private struct AllAssetsGrid: View {
    let assets: [PHAsset]

    private let spacing: CGFloat = 2
    private let columns = 3
    @State private var selected: Int? = nil   // index into assets for full-screen

    var body: some View {
        GeometryReader { geo in
            let side = (geo.size.width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
            ScrollView {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: columns),
                    spacing: spacing
                ) {
                    ForEach(Array(assets.enumerated()), id: \.element.localIdentifier) { idx, asset in
                        Button { selected = idx } label: {
                            PHImageView(assetID: asset.localIdentifier,
                                        targetSize: CGSize(width: side * 2, height: side * 2))
                                .frame(width: side, height: side)
                                .clipped()
                                .contentShape(Rectangle())
                                .overlay(alignment: .bottomLeading) {
                                    if asset.mediaType == .video {
                                        VideoDurationBadge(duration: asset.duration)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .fullScreenCover(item: $selected) { idx in
            AssetPageViewer(assets: assets, startIndex: idx)
        }
    }
}

private struct AssetPageViewer: View {
    let assets: [PHAsset]
    let startIndex: Int
    @State private var selection: Int
    @State private var isZoomed = false
    @Environment(\.dismiss) private var dismiss

    init(assets: [PHAsset], startIndex: Int) {
        self.assets = assets
        self.startIndex = startIndex
        _selection = State(initialValue: startIndex)
    }

    var body: some View {
        NavigationStack {
            TabView(selection: $selection) {
                ForEach(Array(assets.enumerated()), id: \.element.localIdentifier) { idx, asset in
                    Group {
                        if asset.mediaType == .video {
                            VideoPage(assetID: asset.localIdentifier)
                        } else {
                            PHFullImageView(assetID: asset.localIdentifier, isZoomed: $isZoomed)
                        }
                    }
                    .tag(idx)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .background(Color.black.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear { selection = startIndex }
    }
}

// Allow optional Int to be used as sheet `item`
extension Int: @retroactive Identifiable {
    public var id: Int { self }
}

// MARK: - Years grid (Photos-app style: tall cards, year top-left,
// most recent year first)

private struct YearsGrid: View {
    let buckets: [PhotoStore.PeriodInfo]   // store order is newest-first

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 20) {
                ForEach(buckets) { bucket in
                    NavigationLink {
                        PeriodPhotosView(bucket: bucket)
                    } label: {
                        YearCard(bucket: bucket)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
        }
    }
}

private struct YearCard: View {
    let bucket: PhotoStore.PeriodInfo

    var body: some View {
        // Size the card FIRST (Color.clear), then overlay the image and label.
        // Anchoring the label inside a ZStack with the .fill image would pin
        // it to the (oversized) image's corner — off-card for landscape
        // covers, which is exactly a "year number clipped on the left".
        Color.clear
            .aspectRatio(3 / 4, contentMode: .fit)
            .overlay {
                PHImageView(assetID: bucket.coverAssetID,
                            targetSize: CGSize(width: 700, height: 900))
            }
            .overlay {
                LinearGradient(colors: [.black.opacity(0.45), .clear],
                               startPoint: .top, endPoint: .center)
            }
            .overlay(alignment: .topLeading) {
                Text(bucket.label)
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(20)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16))
            // Limit the tap target to the visible card — the .fill image
            // overlay can lay out beyond the card and steal neighbors' taps.
            .contentShape(Rectangle())
    }
}

// MARK: - Months (Photos-app style: "Jun 2024" header + per-day mosaic,
// day numbers overlaid, most recent month first)

private struct MonthsGrid: View {
    let buckets: [PhotoStore.PeriodInfo]   // store order is newest-first

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 32) {
                ForEach(buckets) { bucket in
                    MonthSection(bucket: bucket)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }
}

/// One day's photos within a month — a tappable mosaic tile.
private struct DayBucket: Identifiable {
    let day: Int
    let coverAssetID: String
    let filter: String      // "2024-06-13"
    let title: String       // "Jun 13, 2024"
    var id: Int { day }
}

private struct MonthSection: View {
    let bucket: PhotoStore.PeriodInfo

    private var headerText: String {
        guard let m = bucket.month,
              let d = Calendar.current.date(from: DateComponents(year: bucket.year, month: m))
        else { return bucket.label }
        return d.formatted(.dateTime.month(.abbreviated).year())
    }

    private var days: [DayBucket] {
        let monthPhotos = PhotoStore.shared.photos(forPeriod: bucket.timestampFilter)
        let cal = Calendar.current
        var byDay: [Int: LocalPhoto] = [:]
        for p in monthPhotos {
            guard let d = p.createdAt else { continue }
            let day = cal.component(.day, from: d)
            if byDay[day] == nil { byDay[day] = p }   // photos are newest-first; any cover works
        }
        return byDay.sorted { $0.key < $1.key }.map { day, photo in
            let title = photo.createdAt?.formatted(.dateTime.month(.abbreviated).day().year())
                ?? "\(headerText) \(day)"
            return DayBucket(
                day: day,
                coverAssetID: photo.assetID,
                filter: bucket.timestampFilter + String(format: "-%02d", day),
                title: title)
        }
    }

    private let columns = [GridItem(.flexible(), spacing: 8),
                           GridItem(.flexible(), spacing: 8),
                           GridItem(.flexible(), spacing: 8)]

    var body: some View {
        let days = self.days
        VStack(alignment: .leading, spacing: 10) {
            Text(headerText)
                .font(.system(size: 32, weight: .bold))

            if let hero = days.first {
                DayTile(bucket: hero, isHero: true)
            }
            if days.count > 1 {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(days.dropFirst()) { day in
                        DayTile(bucket: day, isHero: false)
                    }
                }
            }
        }
    }
}

private struct DayTile: View {
    let bucket: DayBucket
    let isHero: Bool

    var body: some View {
        NavigationLink {
            DayPhotosView(filter: bucket.filter, title: bucket.title)
        } label: {
            // Same pattern as YearCard: size the tile first, anchor the day
            // number to the tile's bounds (not the .fill image's), clip last.
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    PHImageView(assetID: bucket.coverAssetID,
                                targetSize: isHero ? CGSize(width: 800, height: 800)
                                                   : CGSize(width: 300, height: 300))
                }
                .overlay(alignment: .topLeading) {
                    Text("\(bucket.day)")
                        .font(.system(size: isHero ? 30 : 20, weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.55), radius: 3, y: 1)
                        .padding(isHero ? 16 : 10)
                }
                .clipShape(RoundedRectangle(cornerRadius: isHero ? 14 : 10))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Grid of one day's photos (drill-in from a month's day tile).
private struct DayPhotosView: View {
    let filter: String
    let title: String
    @StateObject private var loader = PagedPhotoLoader()

    var body: some View {
        Group {
            if loader.results.isEmpty && loader.isLoading {
                ProgressView()
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
        .navigationTitle(title)
        .task {
            if !loader.hasLoadedOnce {
                let f = filter
                await loader.start { limit, offset in
                    let all = PhotoStore.shared.photos(forPeriod: f)
                    return Array(all.dropFirst(offset).prefix(limit))
                }
            }
        }
    }
}

// MARK: - Period drill-in

struct PeriodPhotosView: View {
    let bucket: PhotoStore.PeriodInfo
    @StateObject private var loader = PagedPhotoLoader()

    var body: some View {
        Group {
            if loader.results.isEmpty && loader.isLoading {
                ProgressView()
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
        .navigationTitle(bucket.label)
        .task {
            if !loader.hasLoadedOnce {
                let filter = bucket.timestampFilter
                await loader.start { limit, offset in
                    let all = PhotoStore.shared.photos(forPeriod: filter)
                    return Array(all.dropFirst(offset).prefix(limit))
                }
            }
        }
    }
}

