import SwiftUI
import UniformTypeIdentifiers

/// Reusable thumbnail grid of local photos.
struct PhotoResultsGrid: View {
    let results: [LocalPhoto]
    var onReachEnd: (() -> Void)? = nil
    var onDelete: ((Int) -> Void)? = nil   // called with photoID
    /// When set (folder context), the selection bar gains a "remove from this
    /// folder" action — called with the selected assetIDs.
    var onRemoveSelected: (([String]) -> Void)? = nil
    /// When the grid is backed by a paged loader, Select All must first load
    /// every remaining page — otherwise it silently selects only the pages
    /// scrolled in so far (dangerous right before a bulk delete). Returns the
    /// full result set to select.
    var onLoadAll: (() async -> [LocalPhoto])? = nil

    private let spacing: CGFloat = 2
    private let columns = 3

    @State private var selecting = false
    @State private var selected: Set<Int> = []   // photoIDs
    @State private var confirming = false
    @State private var deleting = false
    @State private var dupFor: LocalPhoto?
    @State private var dropTargetID: Int?
    @State private var pendingMerge: (Int, Int)?
    @State private var merging = false
    @State private var selectingAll = false
    @State private var showAddToFolder = false

    var body: some View {
        GeometryReader { geo in
            let side = (geo.size.width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
            ScrollView {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: columns),
                    spacing: spacing
                ) {
                    ForEach(results) { result in
                        cell(result, side: side)
                            .onAppear {
                                if result.id == results.last?.id { onReachEnd?() }
                            }
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                if selecting {
                    Text(selected.isEmpty ? "Select Items" : "\(selected.count) Selected")
                        .font(.headline)
                        .contentTransition(.numericText())
                        .animation(.default, value: selected.count)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if selecting {
                    Button("Cancel") { exitSelection() }
                } else if !results.isEmpty {
                    Button("Select") {
                        withAnimation(.easeInOut(duration: 0.2)) { selecting = true }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if selecting {
                HStack {
                    if selectingAll {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Select All") { selectAll() }
                            .font(.body)
                    }
                    Spacer()
                    Button {
                        showAddToFolder = true
                    } label: {
                        Image(systemName: "folder.badge.plus").font(.body.bold())
                    }
                    .disabled(selected.isEmpty)
                    Spacer()
                    if onRemoveSelected != nil {
                        Button {
                            let assetIDs = results.filter { selected.contains($0.photoID) }.map(\.assetID)
                            onRemoveSelected?(assetIDs)
                            exitSelection()
                        } label: {
                            Image(systemName: "folder.badge.minus").font(.body.bold())
                        }
                        .disabled(selected.isEmpty)
                        Spacer()
                    }
                    Button(role: .destructive) { confirming = true } label: {
                        Label("Delete", systemImage: "trash").font(.body.bold())
                    }
                    .disabled(selected.isEmpty)
                    .tint(.red)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: selecting)
        .sheet(item: $dupFor) { photo in
            DuplicatesView(photoID: photo.photoID) { deletedIDs in
                deletedIDs.forEach { onDelete?($0) }
            }
        }
        .sheet(isPresented: $showAddToFolder) {
            let assetIDs = results.filter { selected.contains($0.photoID) }.map(\.assetID)
            AddToFolderSheet(assetIDs: assetIDs) { exitSelection() }
        }
        .confirmationDialog(
            "Delete \(selected.count) photo\(selected.count == 1 ? "" : "s")?",
            isPresented: $confirming, titleVisibility: .visible
        ) {
            Button("Delete \(selected.count)", role: .destructive) { deleteSelected() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removed from Search, People, and Places. Your camera roll isn't affected.")
        }
        .confirmationDialog(
            "Mark as duplicates?",
            isPresented: Binding(get: { pendingMerge != nil }, set: { if !$0 { pendingMerge = nil } }),
            titleVisibility: .visible
        ) {
            Button("Mark as Duplicates") {
                if let (a, b) = pendingMerge { doMerge(a: a, b: b) }
            }
            Button("Cancel", role: .cancel) { pendingMerge = nil }
        } message: {
            Text("These photos will be grouped as duplicates.")
        }
        .allowsHitTesting(!deleting && !merging && !selectingAll)
        .overlay { if deleting || merging { ProgressView().controlSize(.large) } }
    }

    @ViewBuilder
    private func cell(_ result: LocalPhoto, side: CGFloat) -> some View {
        let isSel = selected.contains(result.photoID)
        let isDrop = dropTargetID == result.photoID
        if selecting {
            Button { toggle(result.photoID) } label: {
                Thumb(photo: result, side: side, selecting: true, selected: isSel,
                      isDropTarget: false, onBadge: nil)
            }
            .buttonStyle(.plain)
        } else {
            NavigationLink {
                PhotoDetailView(results: results, startID: result.photoID, onDelete: onDelete)
            } label: {
                Thumb(photo: result, side: side, selecting: false, selected: false,
                      isDropTarget: isDrop) {
                    dupFor = result
                }
            }
            .buttonStyle(.plain)
            .onDrag { NSItemProvider(object: "\(result.photoID)" as NSString) }
            .onDrop(
                of: [UTType.plainText],
                isTargeted: Binding(
                    get: { dropTargetID == result.photoID },
                    set: { dropTargetID = $0 ? result.photoID : nil }
                )
            ) { providers in
                providers.first?.loadObject(ofClass: NSString.self) { obj, _ in
                    guard let s = obj as? String,
                          let fromID = Int(s), fromID != result.photoID else { return }
                    DispatchQueue.main.async { pendingMerge = (fromID, result.photoID) }
                }
                return true
            }
        }
    }

    private func toggle(_ id: Int) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    private func selectAll() {
        guard let onLoadAll else {
            selected = Set(results.map(\.photoID))   // unpaged: results are complete
            return
        }
        selectingAll = true
        Task {
            // Pull in every remaining page first so "Select All" really means
            // the whole result set, then select the returned full list (the
            // captured `results` is the stale pre-load snapshot).
            let all = await onLoadAll()
            selected = Set(all.map(\.photoID))
            selectingAll = false
        }
    }

    private func exitSelection() {
        withAnimation(.easeInOut(duration: 0.2)) { selecting = false; selected = [] }
    }

    private func doMerge(a: Int, b: Int) {
        merging = true
        pendingMerge = nil
        PhotoStore.shared.mergeDuplicates(a: a, b: b)
        merging = false
    }

    private func deleteSelected() {
        deleting = true
        let ids = selected
        ids.forEach { id in
            PhotoStore.shared.deletePhoto(photoID: id)
            onDelete?(id)
        }
        deleting = false
        exitSelection()
    }
}

// MARK: - Thumbnail cell

private struct Thumb: View {
    let photo: LocalPhoto
    let side: CGFloat
    let selecting: Bool
    let selected: Bool
    var isDropTarget: Bool = false
    var onBadge: (() -> Void)?

    @State private var dupCount = 0

    var body: some View {
        PHImageView(assetID: photo.assetID,
                    targetSize: CGSize(width: side * 2, height: side * 2))
        .frame(width: side, height: side)
        .clipped()
        .contentShape(Rectangle())
        .overlay(RoundedRectangle(cornerRadius: 4)
            .stroke(isDropTarget ? Color.green : Color.accentColor,
                    lineWidth: (selected || isDropTarget) ? 3 : 0))
        .overlay(alignment: .topLeading) {
            if !selecting && dupCount > 1 {
                Label("\(dupCount)", systemImage: "square.on.square")
                    .font(.caption2.bold())
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(5)
                    .highPriorityGesture(TapGesture().onEnded { onBadge?() })
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if selecting {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? Color.accentColor : .white)
                    .background(Circle().fill(.black.opacity(0.35)).padding(2))
                    .padding(5)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if photo.video {
                VideoDurationBadge(duration: photo.duration ?? 0)
            }
        }
        .opacity(selecting && !selected ? 0.55 : 1)
        .onAppear {
            if let gid = photo.dupGroupID {
                dupCount = PhotoStore.shared.duplicateCount(forGroupID: gid)
            }
        }
    }
}

// MARK: - Video duration badge

/// "▶ 0:42" capsule overlaid on video cells so they're distinguishable
/// from stills at a glance. Shared by the search, browse, and duplicate grids.
struct VideoDurationBadge: View {
    let duration: TimeInterval

    var body: some View {
        let s = Int(duration)
        Label(String(format: "%d:%02d", s / 60, s % 60), systemImage: "play.fill")
            .font(.caption2.bold())
            .foregroundStyle(.white)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(.black.opacity(0.55), in: Capsule())
            .padding(4)
    }
}
