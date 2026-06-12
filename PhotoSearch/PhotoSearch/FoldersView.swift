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
    @State private var newFolderQuery = ""
    @State private var showCreate = false
    @State private var deletingFolder: LocalFolder?
    @State private var renamingFolder: LocalFolder?
    @State private var renameText = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(store.folders) { folder in
                        HStack {
                            Label(folder.name, systemImage: "folder")
                            Spacer()
                            Text("\(store.activeCount(in: folder)) photos")
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
                    Button { showCreate = true } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .alert("New Folder", isPresented: $showCreate) {
                TextField("Folder name", text: $newFolderName)
                TextField("Smart search (optional), e.g. \"dog\"", text: $newFolderQuery)
                Button("Create") {
                    let name = newFolderName.trimmingCharacters(in: .whitespaces)
                    let query = newFolderQuery.trimmingCharacters(in: .whitespaces)
                    newFolderName = ""; newFolderQuery = ""
                    if !name.isEmpty {
                        store.createFolder(name: name, query: query.isEmpty ? nil : query)
                    }
                }
                Button("Cancel", role: .cancel) { newFolderName = ""; newFolderQuery = "" }
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
                    ForEach(store.folders.filter { !$0.isSmart }) { folder in
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

    @State private var showCreate = false
    @State private var newName = ""
    @State private var renaming: LocalFolder?
    @State private var renameText = ""
    @State private var deleting: LocalFolder?

    private let columns = [GridItem(.flexible(), spacing: 12),
                           GridItem(.flexible(), spacing: 12)]

    @State private var categories: [(category: AutoCategory, photos: [LocalPhoto])] = []
    @State private var newQuery = ""

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

            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(store.folders) { folder in
                    NavigationLink {
                        FolderPhotosView(folderID: folder.id)
                    } label: {
                        FolderCard(folder: folder)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
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
                Button { showCreate = true } label: {
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
        .alert("New Folder", isPresented: $showCreate) {
            TextField("Folder name", text: $newName)
            TextField("Smart search (optional), e.g. \"dog\"", text: $newQuery)
            Button("Create") {
                let name = newName.trimmingCharacters(in: .whitespaces)
                let query = newQuery.trimmingCharacters(in: .whitespaces)
                newName = ""; newQuery = ""
                if !name.isEmpty {
                    store.createFolder(name: name, query: query.isEmpty ? nil : query)
                }
            }
            Button("Cancel", role: .cancel) { newName = ""; newQuery = "" }
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
                    if folder.isSmart {
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
                .clipShape(RoundedRectangle(cornerRadius: 12))

            Text(folder.name)
                .font(.subheadline.bold())
                .lineLimit(1)
                .foregroundStyle(.primary)
            // Smart folders evaluate on open — no static count to show.
            Text(folder.isSmart
                 ? "Smart · \"\(folder.query ?? "")\""
                 : "\(count) photo\(count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Folder detail (photo grid + remove-from-folder)

struct FolderPhotosView: View {
    let folderID: String
    @ObservedObject private var store = PhotoStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var showRename = false
    @State private var renameText = ""
    @State private var showEditQuery = false
    @State private var queryText = ""
    @State private var confirmDelete = false
    @State private var photos: [LocalPhoto] = []

    private var folder: LocalFolder? { store.folders.first { $0.id == folderID } }

    /// Inputs that should re-run the (CLIP-heavy for smart folders) membership
    /// query — folder identity, its saved search, manual membership edits, and
    /// newly indexed photos. Keying .task(id:) on this keeps the search off
    /// every body evaluation.
    private struct LoadKey: Hashable {
        var folderID: String
        var query: String?
        var memberCount: Int
        var photoCount: Int
    }
    private var loadKey: LoadKey {
        LoadKey(folderID: folderID,
                query: folder?.query,
                memberCount: folder?.photoAssetIDs.count ?? 0,
                photoCount: store.photos.count)
    }

    var body: some View {
        let isSmart = folder?.isSmart ?? false
        Group {
            if photos.isEmpty {
                ContentUnavailableView(
                    isSmart ? "No Matches" : "Empty Folder", systemImage: "folder",
                    description: Text(isSmart
                        ? "No photos currently match \"\(folder?.query ?? "")\"."
                        : "Select photos anywhere in the app and tap the folder button to add them here."))
            } else if isSmart {
                // Membership is the query — no manual remove.
                PhotoResultsGrid(
                    results: photos,
                    onDelete: { id in photos.removeAll { $0.photoID == id } }
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
                    Button {
                        renameText = folder?.name ?? ""
                        showRename = true
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    if folder?.isSmart == true {
                        Button {
                            queryText = folder?.query ?? ""
                            showEditQuery = true
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
        .alert("Edit Search", isPresented: $showEditQuery) {
            TextField("Search query", text: $queryText)
            Button("Save") {
                let q = queryText.trimmingCharacters(in: .whitespaces)
                if !q.isEmpty { store.setFolderQuery(id: folderID, query: q) }
            }
            Button("Cancel", role: .cancel) {}
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
