import SwiftUI
import UniformTypeIdentifiers

/// Frequent faces. Tap a face to see photos, tap name to rename, drag to merge.
struct PeopleView: View {
    @EnvironmentObject private var folderStore: FolderStore
    @EnvironmentObject private var indexer: Indexer
    @EnvironmentObject private var library: PhotoLibraryModel
    @ObservedObject private var store = PhotoStore.shared
    @State private var names: [Int: String] = [:]
    @State private var openCluster: PersonCluster?
    @State private var membersOf: PersonCluster?
    @State private var pendingMerge: PendingMerge?
    @State private var showReindexConfirm = false
    @FocusState private var focusedID: Int?

    private var people: [PersonCluster] { store.activeClusters }

    var body: some View {
        NavigationStack {
            Group {
                if people.isEmpty {
                    ContentUnavailableView(
                        "No people yet",
                        systemImage: "person.2",
                        description: Text("Faces appear here once your library has been indexed.")
                    )
                } else {
                    peopleList
                }
            }
            .navigationTitle("People")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    // Non-destructive: re-groups people from stored face
                    // embeddings (global DBSCAN, same pass the backend used).
                    // Names carry over; no re-indexing involved.
                    Button {
                        Task { await store.reclusterPeople() }
                    } label: {
                        if store.isReclustering {
                            ProgressView()
                        } else {
                            Image(systemName: "wand.and.stars")
                        }
                    }
                    .disabled(store.isReclustering)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showReindexConfirm = true } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                }
            }
            .confirmationDialog("Re-index all photos?",
                                isPresented: $showReindexConfirm,
                                titleVisibility: .visible) {
                Button("Re-index", role: .destructive) {
                    indexer.resetTracking()
                    Task { await indexer.indexNewPhotos(from: library) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This clears all people, places, and embeddings, then rebuilds everything from scratch. It may take several minutes.")
            }
            .navigationDestination(item: $openCluster) { cluster in
                PersonPhotosView(cluster: cluster)
            }
            .sheet(item: $membersOf) { cluster in
                PersonMembersView(cluster: cluster) { }
            }
            .alert("Merge people?", isPresented: mergeAlertShown, presenting: pendingMerge) { merge in
                Button("Merge") { doMerge(source: merge.source, into: merge.target) }
                Button("Cancel", role: .cancel) {}
            } message: { merge in
                Text("\(label(merge.source)) and \(label(merge.target)) will be combined.")
            }
        }
        .onAppear {
            for p in people { names[p.id] = p.name ?? "" }
        }
        .onChange(of: focusedID) { previous, _ in
            if let previous { saveName(previous) }
        }
    }

    private var mergeAlertShown: Binding<Bool> {
        Binding(get: { pendingMerge != nil }, set: { if !$0 { pendingMerge = nil } })
    }

    private func label(_ id: Int) -> String {
        let name = names[id] ?? ""
        return name.isEmpty ? "an unnamed person" : "\u{201C}\(name)\u{201D}"
    }

    private var peopleList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                Text("\(people.count) frequent faces — drag one face onto another to merge")
                    .font(.footnote).foregroundStyle(.secondary)
                    .padding(.horizontal).padding(.vertical, 8)

                ForEach(people) { cluster in
                    PersonRow(
                        cluster: cluster,
                        name: nameBinding(for: cluster.id),
                        focusedID: $focusedID,
                        onSave: { saveName(cluster.id) },
                        onOpen: { openCluster = cluster },
                        onDelete: { deleteCluster(cluster) },
                        onShowMembers: { membersOf = cluster },
                        onMerge: { source in
                            pendingMerge = PendingMerge(source: source, target: cluster.id)
                        }
                    )
                    Divider().padding(.leading, 92)
                }
            }
        }
    }

    private func nameBinding(for id: Int) -> Binding<String> {
        Binding(get: { names[id] ?? "" }, set: { names[id] = $0 })
    }

    private func saveName(_ id: Int) {
        PhotoStore.shared.setClusterName(id: id, name: names[id] ?? "")
    }

    private func deleteCluster(_ cluster: PersonCluster) {
        PhotoStore.shared.deleteCluster(id: cluster.id)
    }

    private func doMerge(source: Int, into target: Int) {
        guard source != target else { return }
        PhotoStore.shared.mergeClusters(source: source, into: target)
        names[source] = nil
    }
}

// MARK: - Person row

private struct PersonRow: View {
    let cluster: PersonCluster
    @Binding var name: String
    var focusedID: FocusState<Int?>.Binding
    let onSave: () -> Void
    let onOpen: () -> Void
    let onDelete: () -> Void
    let onShowMembers: () -> Void
    let onMerge: (Int) -> Void

    @State private var isDropTarget = false

    var body: some View {
        HStack(spacing: 14) {
            Button(action: onOpen) {
                PHFaceView(assetID: cluster.representativeAssetID, faceRect: cluster.faceRect)
                    .frame(width: 64, height: 64)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .onDrag {
                let provider = NSItemProvider()
                provider.registerDataRepresentation(
                    forTypeIdentifier: UTType.personDrag.identifier, visibility: .all
                ) { completion in
                    completion(Data(String(cluster.id).utf8), nil); return nil
                }
                return provider
            }

            VStack(alignment: .leading, spacing: 4) {
                TextField("Add a name", text: $name)
                    .textInputAutocapitalization(.words)
                    .focused(focusedID, equals: cluster.id)
                    .onSubmit(onSave)
                    .submitLabel(.done)
                Text("\(cluster.photoCount) photos")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Menu {
                Button { onOpen() }         label: { Label("See Photos", systemImage: "photo.on.rectangle") }
                Button { onShowMembers() }  label: { Label("Merged Faces", systemImage: "person.2") }
                Button(role: .destructive, action: onDelete) { Label("Remove", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 44)
                    .contentShape(Rectangle())
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .background(isDropTarget ? Color.accentColor.opacity(0.2) : Color.clear)
        .onDrop(of: [.personDrag], isTargeted: $isDropTarget) { providers in
            guard let provider = providers.first else { return false }
            provider.loadDataRepresentation(forTypeIdentifier: UTType.personDrag.identifier) { data, _ in
                guard let data, let s = String(data: data, encoding: .utf8),
                      let source = Int(s), source != cluster.id else { return }
                DispatchQueue.main.async { onMerge(source) }
            }
            return true
        }
    }
}

extension UTType {
    static let personDrag = UTType(exportedAs: "com.jakelulla.PhotoSearch.persondrag")
}

struct PendingMerge: Identifiable {
    let source: Int
    let target: Int
    var id: String { "\(source)->\(target)" }
}
