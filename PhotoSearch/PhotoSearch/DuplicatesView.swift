import SwiftUI

/// Review a duplicate group and keep/delete individual photos.
struct DuplicatesView: View {
    let photoID: Int
    var onResolved: ([Int]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var photos: [LocalPhoto] = []
    @State private var selected: Set<Int> = []
    @State private var loading = true
    @State private var working = false
    @State private var reviewing = false
    @State private var reviewStart = 0
    @State private var pending: DupAction?

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 4)]
    private enum DupAction { case keep, delete, ungroup }

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView()
                } else if photos.count <= 1 {
                    ContentUnavailableView("No duplicates", systemImage: "checkmark.circle")
                } else {
                    grid
                }
            }
            .navigationTitle("\(photos.count) duplicates")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                if photos.count > 1 {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Not duplicates") { pending = .ungroup }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { if photos.count > 1 { actionBar } }
            .overlay { if working { Color.black.opacity(0.2).ignoresSafeArea(); ProgressView().controlSize(.large) } }
            .task { loadGroup() }
            .fullScreenCover(isPresented: $reviewing) {
                DuplicateReviewer(photos: photos, startIndex: reviewStart, selected: $selected)
            }
            .confirmationDialog(confirmTitle, isPresented: confirmShown, presenting: pending) { action in
                confirmButtons(action)
                Button("Cancel", role: .cancel) {}
            } message: { action in Text(confirmMessage(action)) }
        }
    }

    private var grid: some View {
        ScrollView {
            Text("Select photos (tap the circle), or tap one to view full-screen.")
                .font(.footnote).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.horizontal, .top])
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(Array(photos.enumerated()), id: \.element.id) { idx, p in
                    cell(p, idx: idx)
                }
            }
            .padding(4)
        }
    }

    private func cell(_ p: LocalPhoto, idx: Int) -> some View {
        let isSel = selected.contains(p.photoID)
        return Button { reviewStart = idx; reviewing = true } label: {
            PHImageView(assetID: p.assetID, targetSize: CGSize(width: 220, height: 220))
                .frame(height: 110).frame(maxWidth: .infinity).clipped()
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.accentColor, lineWidth: isSel ? 3 : 0))
                .overlay(alignment: .topTrailing) {
                    Image(systemName: isSel ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSel ? Color.accentColor : .white)
                        .background(Circle().fill(.black.opacity(0.35)).padding(2))
                        .padding(5)
                        .highPriorityGesture(TapGesture().onEnded { toggle(p.photoID) })
                }
        }
        .buttonStyle(.plain)
    }

    private var actionBar: some View {
        let n = selected.count
        let others = photos.count - n
        return VStack(spacing: 8) {
            Button { pending = .keep } label: {
                Text(n == 0 ? "Keep selected" : "Keep \(n), delete \(others)")
                    .bold().frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(n == 0 || others == 0)

            Button(role: .destructive) { pending = .delete } label: {
                Text(n == 0 ? "Delete selected" : "Delete \(n)")
                    .bold().frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered).tint(.red)
            .disabled(n == 0)
        }
        .padding().background(.ultraThinMaterial)
    }

    private var confirmShown: Binding<Bool> {
        Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })
    }
    private var confirmTitle: String {
        switch pending {
        case .keep:   return "Keep \(selected.count), delete \(photos.count - selected.count)?"
        case .delete: return "Delete \(selected.count) photo\(selected.count == 1 ? "" : "s")?"
        case .ungroup: return "Stop grouping these \(photos.count)?"
        case nil: return ""
        }
    }
    private func confirmMessage(_ a: DupAction) -> String {
        switch a {
        case .keep, .delete: return "Removed photos leave Search, People, and Places. Camera roll unaffected."
        case .ungroup: return "They'll appear separately. Nothing is deleted."
        }
    }
    @ViewBuilder private func confirmButtons(_ a: DupAction) -> some View {
        switch a {
        case .keep:
            Button("Keep \(selected.count), delete \(photos.count - selected.count)", role: .destructive) {
                resolve(keep: Array(selected))
            }
        case .delete:
            Button("Delete \(selected.count)", role: .destructive) {
                let keep = photos.map(\.photoID).filter { !selected.contains($0) }
                resolve(keep: keep)
            }
        case .ungroup:
            Button("Not duplicates") { ungroup() }
        }
    }

    private func toggle(_ id: Int) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    private func loadGroup() {
        loading = true
        photos = PhotoStore.shared.duplicateGroup(forPhotoID: photoID)
        selected = []
        loading = false
    }

    private func resolve(keep: [Int]) {
        working = true
        let deleted = PhotoStore.shared.keepDuplicates(groupOf: photoID, keepIDs: keep)
        working = false
        onResolved(deleted)
        dismiss()
    }

    private func ungroup() {
        working = true
        PhotoStore.shared.ungroupDuplicates(forPhotoID: photoID)
        working = false
        onResolved([])
        dismiss()
    }
}

/// Swipeable full-screen viewer over the duplicate group.
private struct DuplicateReviewer: View {
    let photos: [LocalPhoto]
    let startIndex: Int
    @Binding var selected: Set<Int>

    @Environment(\.dismiss) private var dismiss
    @State private var selection = 0
    @State private var isZoomed = false

    var body: some View {
        NavigationStack {
            TabView(selection: $selection) {
                ForEach(Array(photos.enumerated()), id: \.element.id) { idx, p in
                    ReviewerPage(photo: p, isZoomed: $isZoomed).tag(idx)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("\(selection + 1) of \(photos.count)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    let id = photos[safe: selection]?.photoID ?? -1
                    let isSel = selected.contains(id)
                    Button {
                        if isSel { selected.remove(id) } else { selected.insert(id) }
                    } label: {
                        Label(isSel ? "Selected" : "Select",
                              systemImage: isSel ? "checkmark.circle.fill" : "circle")
                    }
                    .tint(isSel ? .green : .white)
                }
            }
            .onAppear { selection = startIndex }
        }
    }
}

private struct ReviewerPage: View {
    let photo: LocalPhoto
    @Binding var isZoomed: Bool

    var body: some View {
        PHFullImageView(assetID: photo.assetID, isZoomed: $isZoomed)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Global duplicates sweep

/// Every duplicate group in the library — review and clean them all from
/// one place instead of stumbling on them photo by photo.
struct DuplicatesSweepView: View {
    @ObservedObject private var store = PhotoStore.shared
    @State private var reviewing: LocalPhoto?

    var body: some View {
        let groups = store.duplicateGroups
        Group {
            if groups.isEmpty {
                ContentUnavailableView(
                    "No duplicates", systemImage: "checkmark.circle",
                    description: Text("Near-identical photos are grouped automatically as your library is indexed."))
            } else {
                List {
                    Section {
                        ForEach(groups, id: \.first!.assetID) { group in
                            Button { reviewing = group.first } label: {
                                GroupRow(group: group)
                            }
                            .foregroundStyle(.primary)
                        }
                    } header: {
                        let removable = groups.reduce(0) { $0 + $1.count - 1 }
                        Text("\(groups.count) group\(groups.count == 1 ? "" : "s") · \(removable) photo\(removable == 1 ? "" : "s") could be removed")
                    }
                }
            }
        }
        .navigationTitle("Duplicates")
        .sheet(item: $reviewing) { photo in
            DuplicatesView(photoID: photo.photoID) { _ in }
        }
    }

    private struct GroupRow: View {
        let group: [LocalPhoto]

        var body: some View {
            HStack(spacing: 6) {
                ForEach(group.prefix(4)) { p in
                    PHImageView(assetID: p.assetID,
                                targetSize: CGSize(width: 120, height: 120))
                        .frame(width: 56, height: 56)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                if group.count > 4 {
                    Text("+\(group.count - 4)")
                        .font(.subheadline.bold())
                        .foregroundStyle(.secondary)
                        .frame(width: 56, height: 56)
                        .background(Color(.secondarySystemBackground),
                                    in: RoundedRectangle(cornerRadius: 6))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(group.count) photos")
                        .font(.subheadline)
                    if let d = group.first?.createdAt {
                        Text(d.formatted(date: .abbreviated, time: .omitted))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }
}
