import SwiftUI

// MARK: - Folder filter button (toolbar)

/// Toolbar button that shows the active folder and opens the picker sheet.
struct FolderFilterButton: View {
    @ObservedObject private var store = PhotoStore.shared
    @Binding var selectedFolderID: String?
    @State private var showPicker = false

    var body: some View {
        Button {
            showPicker = true
        } label: {
            if let id = selectedFolderID,
               let name = store.folders.first(where: { $0.id == id })?.name {
                Label(name, systemImage: "folder.fill")
                    .font(.caption.bold())
                    .lineLimit(1)
            } else {
                Image(systemName: "folder")
            }
        }
        .sheet(isPresented: $showPicker) {
            FolderPickerSheet(selectedFolderID: $selectedFolderID)
        }
    }
}

// MARK: - Picker sheet

struct FolderPickerSheet: View {
    @ObservedObject private var store = PhotoStore.shared
    @Binding var selectedFolderID: String?
    @Environment(\.dismiss) private var dismiss
    @State private var showManage = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        selectedFolderID = nil
                        dismiss()
                    } label: {
                        HStack {
                            Label("All Photos", systemImage: "photo.on.rectangle")
                            Spacer()
                            if selectedFolderID == nil {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                }

                Section("Folders") {
                    ForEach(store.folders) { folder in
                        Button {
                            selectedFolderID = folder.id
                            dismiss()
                        } label: {
                            HStack {
                                Label(folder.name, systemImage: folder.isSmart ? "sparkles" : "folder")
                                Spacer()
                                Text(folder.isSmart ? "Smart" : "\(store.activeCount(in: folder))")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                if selectedFolderID == folder.id {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                    if store.folders.isEmpty {
                        Text("No folders yet")
                            .foregroundStyle(.secondary)
                            .font(.subheadline)
                    }
                }
            }
            .navigationTitle("Filter by Folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Manage") { showManage = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showManage) {
                FolderManageSheet()
            }
        }
    }
}

// MARK: - Manage sheet (create / delete folders)

struct FolderManageSheet: View {
    @ObservedObject private var store = PhotoStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var newFolderName = ""
    @State private var showCreate = false
    @State private var showSmartCreate = false
    @State private var deletingFolder: LocalFolder?
    @State private var renamingFolder: LocalFolder?
    @State private var renameText = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(store.folders) { folder in
                        HStack {
                            Label(folder.name, systemImage: folder.isSmart ? "sparkles" : "folder")
                            Spacer()
                            // Smart folders have no static membership to count.
                            Text(folder.isSmart ? "Smart" : "\(store.activeCount(in: folder)) photos")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                deletingFolder = folder
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            Button {
                                renamingFolder = folder
                                renameText = folder.name
                            } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                            .tint(.blue)
                        }
                    }
                    if store.folders.isEmpty {
                        Text("No folders yet")
                            .foregroundStyle(.secondary)
                            .font(.subheadline)
                    }
                }
            }
            .navigationTitle("Manage Folders")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { showCreate = true } label: {
                            Label("New Folder", systemImage: "folder.badge.plus")
                        }
                        Button { showSmartCreate = true } label: {
                            Label("New Smart Folder", systemImage: "sparkles")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .alert("New Folder", isPresented: $showCreate) {
                TextField("Folder name", text: $newFolderName)
                Button("Create") {
                    let name = newFolderName.trimmingCharacters(in: .whitespaces)
                    newFolderName = ""
                    if !name.isEmpty {
                        store.createFolder(name: name)
                    }
                }
                Button("Cancel", role: .cancel) { newFolderName = "" }
            }
            // Smart folders get the full editor (query, anchor, minus terms,
            // sensitivity + live preview) — too much for an alert.
            .sheet(isPresented: $showSmartCreate) {
                SmartFolderEditor(folderID: nil, initialQuery: "", initialAnchor: nil)
            }
            .alert("Rename Folder", isPresented: Binding(
                get: { renamingFolder != nil },
                set: { if !$0 { renamingFolder = nil } }
            )) {
                TextField("Folder name", text: $renameText)
                Button("Rename") {
                    let name = renameText.trimmingCharacters(in: .whitespaces)
                    if let f = renamingFolder, !name.isEmpty {
                        store.renameFolder(id: f.id, name: name)
                    }
                    renamingFolder = nil
                }
                Button("Cancel", role: .cancel) { renamingFolder = nil }
            }
            .confirmationDialog(
                "Delete \"\(deletingFolder?.name ?? "")\"?",
                isPresented: Binding(get: { deletingFolder != nil }, set: { if !$0 { deletingFolder = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete Folder, Keep Photos") {
                    if let f = deletingFolder { store.deleteFolder(id: f.id, deletePhotos: false) }
                    deletingFolder = nil
                }
                if deletingFolder?.isSmart != true {
                    Button("Delete Photos Too", role: .destructive) {
                        if let f = deletingFolder { store.deleteFolder(id: f.id, deletePhotos: true) }
                        deletingFolder = nil
                    }
                }
                Button("Cancel", role: .cancel) { deletingFolder = nil }
            } message: {
                Text(deletingFolder?.isSmart == true
                     ? "The smart folder is deleted. Your photos stay in your library and index."
                     : "Delete just the folder, or also delete its photos from the index?")
            }
        }
    }
}

// MARK: - Add to folder sheet (used from batch select)

struct AddToFolderSheet: View {
    @ObservedObject private var store = PhotoStore.shared
    let assetIDs: [String]
    let onDone: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var showCreate = false
    @State private var newFolderName = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    // Smart folders are valid add targets now: adding routes to
                    // the folder's manual-include set (layered over its query).
                    ForEach(store.folders) { folder in
                        Button {
                            store.addPhotos(assetIDs, toFolder: folder.id)
                            dismiss()
                            onDone()
                        } label: {
                            HStack {
                                Label(folder.name, systemImage: folder.isSmart ? "sparkles" : "folder")
                                Spacer()
                                Text(folder.isSmart ? "Smart" : "\(store.activeCount(in: folder))")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                    if store.folders.isEmpty {
                        Text("No folders yet — create one below")
                            .foregroundStyle(.secondary)
                            .font(.subheadline)
                    }
                }

                Section {
                    Button {
                        showCreate = true
                    } label: {
                        Label("New Folder…", systemImage: "folder.badge.plus")
                    }
                }
            }
            .navigationTitle("Add to Folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
            .alert("New Folder", isPresented: $showCreate) {
                TextField("Folder name", text: $newFolderName)
                Button("Create & Add") {
                    let name = newFolderName.trimmingCharacters(in: .whitespaces)
                    newFolderName = ""
                    guard !name.isEmpty else { return }
                    let folder = store.createFolder(name: name)
                    store.addPhotos(assetIDs, toFolder: folder.id)
                    dismiss()
                    onDone()
                }
                Button("Cancel", role: .cancel) { newFolderName = "" }
            }
        }
    }
}

// MARK: - Folders browse grid (Photos tab segment)

/// First-class folder browsing: cover + name + count cards, tap to open,
/// long-press to rename/delete, "+" card to create.
struct FoldersGrid: View {
    @ObservedObject private var store = PhotoStore.shared

    @State private var showCreateChoice = false
    @State private var showCreate = false
    @State private var showSmartCreate = false
    @State private var newName = ""
    @State private var renaming: LocalFolder?
    @State private var renameText = ""
    @State private var deleting: LocalFolder?
    @State private var sharingFolder: LocalFolder?

    private let columns = [GridItem(.flexible(), spacing: 12),
                           GridItem(.flexible(), spacing: 12)]

    @State private var categories: [(category: AutoCategory, photos: [LocalPhoto])] = []

    var body: some View {
        ScrollView {
            if !categories.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Categories")
                        .font(.title3.bold())
                        .padding(.horizontal, 16)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(categories, id: \.category.id) { entry in
                                NavigationLink {
                                    PhotoResultsGrid(results: entry.photos)
                                        .navigationTitle(entry.category.title)
                                        .navigationBarTitleDisplayMode(.inline)
                                } label: {
                                    CategoryCard(category: entry.category,
                                                 photos: entry.photos)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
                .padding(.top, 12)
            }

            // Shared Albums entry: CloudKit-backed albums you share with other
            // people. Visually consistent with the folder cards below. Tapping
            // is the ONLY path that reaches CloudKit — nothing loads at launch.
            VStack(alignment: .leading, spacing: 10) {
                Text("Shared Albums")
                    .font(.title3.bold())
                    .padding(.horizontal, 16)
                LazyVGrid(columns: columns, spacing: 16) {
                    NavigationLink {
                        SharedAlbumsView()
                    } label: {
                        SharedAlbumsEntryCard()
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
            }
            .padding(.top, 12)

            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(store.folders) { folder in
                    NavigationLink {
                        FolderPhotosView(folderID: folder.id)
                    } label: {
                        FolderCard(folder: folder)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        // Share a regular (non-smart) folder that has photos as a
                        // CloudKit shared album. Smart folders have no static
                        // membership to upload, so the action is hidden for them.
                        if !folder.isSmart && store.activeCount(in: folder) > 0 {
                            Button {
                                sharingFolder = folder
                            } label: {
                                Label("Share Album", systemImage: "person.2.badge.plus")
                            }
                        }
                        Button {
                            renameText = folder.name
                            renaming = folder
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            deleting = folder
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }

                // New-folder card
                Button { showCreateChoice = true } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Color(.secondarySystemBackground)
                            .aspectRatio(1, contentMode: .fit)
                            .overlay {
                                Image(systemName: "plus")
                                    .font(.system(size: 36, weight: .medium))
                                    .foregroundStyle(.tint)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        Text("New Folder")
                            .font(.subheadline.bold())
                            .foregroundStyle(.tint)
                        Text(" ")
                            .font(.caption)
                    }
                }
                .buttonStyle(.plain)
            }
            .padding(16)
        }
        .confirmationDialog("New Folder", isPresented: $showCreateChoice,
                            titleVisibility: .visible) {
            Button("Folder") { showCreate = true }
            Button("Smart Folder") { showSmartCreate = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A folder holds photos you add. A smart folder fills itself from a live search.")
        }
        .alert("New Folder", isPresented: $showCreate) {
            TextField("Folder name", text: $newName)
            Button("Create") {
                let name = newName.trimmingCharacters(in: .whitespaces)
                newName = ""
                if !name.isEmpty {
                    store.createFolder(name: name)
                }
            }
            Button("Cancel", role: .cancel) { newName = "" }
        }
        // Smart folders get the full editor (query, anchor, minus terms,
        // sensitivity + live preview) — too much for an alert.
        .sheet(isPresented: $showSmartCreate) {
            SmartFolderEditor(folderID: nil, initialQuery: "", initialAnchor: nil)
        }
        .alert("Rename Folder", isPresented: Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        )) {
            TextField("Folder name", text: $renameText)
            Button("Rename") {
                let name = renameText.trimmingCharacters(in: .whitespaces)
                if let f = renaming, !name.isEmpty {
                    store.renameFolder(id: f.id, name: name)
                }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .confirmationDialog(
            "Delete \"\(deleting?.name ?? "")\"?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Folder, Keep Photos") {
                if let f = deleting { store.deleteFolder(id: f.id, deletePhotos: false) }
                deleting = nil
            }
            if deleting?.isSmart != true {
                Button("Delete Photos Too", role: .destructive) {
                    if let f = deleting { store.deleteFolder(id: f.id, deletePhotos: true) }
                    deleting = nil
                }
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            Text(deleting?.isSmart == true
                 ? "The smart folder is deleted. Your photos stay in your library and index."
                 : "Delete just the folder, or also delete its photos from the index?")
        }
        // Share a folder as a CloudKit shared album (create + upload + invite).
        // We pass the folder's ACTIVE (non-soft-deleted) members so we never try
        // to upload photos the user has hidden.
        .sheet(item: $sharingFolder) { folder in
            ShareFolderView(folderName: folder.name,
                            assetIDs: store.activeMemberAssetIDs(in: folder))
        }
        .task {
            // Zero-shot CLIP categorization over stored embeddings — cached
            // in the store until the photo count changes.
            categories = await store.autoCategories()
        }
    }
}

private struct CategoryCard: View {
    let category: AutoCategory
    let photos: [LocalPhoto]

    var body: some View {
        Color.clear
            .frame(width: 130, height: 130)
            .overlay {
                if let cover = photos.first {
                    PHImageView(assetID: cover.assetID,
                                targetSize: CGSize(width: 260, height: 260))
                }
            }
            .overlay {
                LinearGradient(colors: [.clear, .black.opacity(0.65)],
                               startPoint: .center, endPoint: .bottom)
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 1) {
                    Label(category.title, systemImage: category.icon)
                        .font(.caption.bold()).foregroundStyle(.white)
                        .lineLimit(1)
                    Text("\(photos.count)")
                        .font(.caption2).foregroundStyle(.white.opacity(0.85))
                }
                .padding(8)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
    }
}

private struct FolderCard: View {
    let folder: LocalFolder
    @ObservedObject private var store = PhotoStore.shared

    var body: some View {
        let count = store.activeCount(in: folder)
        VStack(alignment: .leading, spacing: 6) {
            Color(.secondarySystemBackground)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if folder.isSmart, let anchor = folder.anchorAssetID {
                        // Anchored smart folder: the anchor photo is the
                        // folder's definition, so it makes the best cover.
                        PHImageView(assetID: anchor,
                                    targetSize: CGSize(width: 400, height: 400))
                    } else if folder.isSmart {
                        Image(systemName: "sparkles")
                            .font(.system(size: 40))
                            .foregroundStyle(.tint)
                    } else if let cover = PhotoStore.shared.activeCoverAssetID(in: folder) {
                        PHImageView(assetID: cover,
                                    targetSize: CGSize(width: 400, height: 400))
                    } else {
                        Image(systemName: "folder")
                            .font(.system(size: 40))
                            .foregroundStyle(.tertiary)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    // Distinguish "anchored smart" from a plain photo cover.
                    if folder.isSmart && folder.anchorAssetID != nil {
                        Image(systemName: "sparkles")
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                            .padding(6)
                            .background(.black.opacity(0.4), in: Circle())
                            .padding(6)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))

            Text(folder.name)
                .font(.subheadline.bold())
                .lineLimit(1)
                .foregroundStyle(.primary)
            // Smart folders evaluate on open — no static count to show.
            Text(folder.isSmart ? smartSubtitle : "\(count) photo\(count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
    }

    private var smartSubtitle: String {
        if let q = folder.query, !q.isEmpty { return "Smart · \"\(q)\"" }
        if folder.anchorAssetID != nil { return "Smart · looks like the cover" }
        return "Smart"
    }
}

// MARK: - Folder detail (photo grid + remove-from-folder)

struct FolderPhotosView: View {
    let folderID: String
    @ObservedObject private var store = PhotoStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var showRename = false
    @State private var renameText = ""
    @State private var showEditor = false
    @State private var confirmDelete = false
    @State private var showShare = false
    @State private var photos: [LocalPhoto] = []

    private var folder: LocalFolder? { store.folders.first { $0.id == folderID } }

    /// Anchored smart folders may have no query text, so don't render an
    /// empty quoted string; embedding-backed folders also evaluate empty
    /// where the on-device models can't run (simulator).
    private var smartEmptyDescription: String {
        if let q = folder?.query, !q.isEmpty {
            return "No photos currently match \"\(q)\"."
        }
        return "No photos currently match this folder's smart search."
    }

    /// Inputs that should re-run the (CLIP-heavy for smart folders) membership
    /// query — folder identity, its saved search (all four smart fields, so
    /// SmartFolderEditor saves re-evaluate immediately), manual membership
    /// edits, and newly indexed photos. Keying .task(id:) on this keeps the
    /// search off every body evaluation.
    private struct LoadKey: Hashable {
        var folderID: String
        var query: String?
        var anchorAssetID: String?
        var minusQuery: String?
        var minScore: Float?
        var memberCount: Int
        // For a smart folder photoAssetIDs stays empty, so memberCount never
        // moves on a manual add/remove — include the manual-set counts so an
        // include/exclude edit forces exactly one re-evaluation.
        var manualIncludeCount: Int
        var manualExcludeCount: Int
        var photoCount: Int
    }
    private var loadKey: LoadKey {
        LoadKey(folderID: folderID,
                query: folder?.query,
                anchorAssetID: folder?.anchorAssetID,
                minusQuery: folder?.minusQuery,
                minScore: folder?.minScore,
                memberCount: folder?.photoAssetIDs.count ?? 0,
                manualIncludeCount: folder?.manualIncludeAssetIDs?.count ?? 0,
                manualExcludeCount: folder?.manualExcludeAssetIDs?.count ?? 0,
                photoCount: store.photos.count)
    }

    var body: some View {
        let isSmart = folder?.isSmart ?? false
        Group {
            if photos.isEmpty {
                ContentUnavailableView(
                    isSmart ? "No Matches" : "Empty Folder", systemImage: "folder",
                    description: Text(isSmart
                        ? smartEmptyDescription
                        : "Select photos anywhere in the app and tap the folder button to add them here."))
            } else if isSmart {
                // Smart folders now support manual remove: Remove routes to the
                // folder's manual-exclude set (a force-remove over the query).
                PhotoResultsGrid(
                    results: photos,
                    onDelete: { id in photos.removeAll { $0.photoID == id } },
                    onRemoveSelected: { assetIDs in
                        store.removePhotos(assetIDs, fromFolder: folderID)
                    }
                )
            } else {
                PhotoResultsGrid(
                    results: photos,
                    onDelete: { id in photos.removeAll { $0.photoID == id } },
                    onRemoveSelected: { assetIDs in
                        store.removePhotos(assetIDs, fromFolder: folderID)
                    }
                )
            }
        }
        .task(id: loadKey) {
            photos = folder.map { store.photosForFolder($0) } ?? []
        }
        .navigationTitle(folder?.name ?? "Folder")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    // Share a regular folder that has photos as a shared album.
                    if folder?.isSmart != true, !photos.isEmpty {
                        Button {
                            showShare = true
                        } label: {
                            Label("Share Album", systemImage: "person.2.badge.plus")
                        }
                    }
                    Button {
                        renameText = folder?.name ?? ""
                        showRename = true
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    if folder?.isSmart == true {
                        Button {
                            showEditor = true
                        } label: {
                            Label("Edit Search", systemImage: "sparkles")
                        }
                    }
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Label("Delete Folder", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .alert("Rename Folder", isPresented: $showRename) {
            TextField("Folder name", text: $renameText)
            Button("Rename") {
                let name = renameText.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { store.renameFolder(id: folderID, name: name) }
            }
            Button("Cancel", role: .cancel) {}
        }
        // Full smart-folder editor (query + anchor + minus terms + sensitivity);
        // saving mutates the folder, which changes loadKey → photos re-evaluate.
        .sheet(isPresented: $showEditor) {
            SmartFolderEditor(folderID: folderID,
                              initialQuery: folder?.query ?? "",
                              initialAnchor: folder?.anchorAssetID)
        }
        // Share this folder as a CloudKit shared album. The visible grid is the
        // folder's active (non-deleted) membership, so its asset IDs are exactly
        // what should be uploaded.
        .sheet(isPresented: $showShare) {
            ShareFolderView(folderName: folder?.name ?? "Shared Album",
                            assetIDs: photos.map(\.assetID))
        }
        .confirmationDialog(
            "Delete \"\(folder?.name ?? "")\"?",
            isPresented: $confirmDelete, titleVisibility: .visible
        ) {
            Button("Delete Folder, Keep Photos") {
                store.deleteFolder(id: folderID, deletePhotos: false)
                dismiss()
            }
            if folder?.isSmart != true {
                Button("Delete Photos Too", role: .destructive) {
                    store.deleteFolder(id: folderID, deletePhotos: true)
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(folder?.isSmart == true
                 ? "The smart folder is deleted. Your photos stay in your library and index."
                 : "Delete just the folder, or also delete its photos from the index?")
        }
    }
}
