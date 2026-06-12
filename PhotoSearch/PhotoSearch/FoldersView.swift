import SwiftUI

// MARK: - Folder filter button (toolbar)

/// Toolbar button that shows the active folder and opens the picker sheet.
struct FolderFilterButton: View {
    @EnvironmentObject var folderStore: FolderStore
    @Binding var selectedFolderID: String?
    @State private var showPicker = false

    var body: some View {
        Button {
            Task { await folderStore.load() }
            showPicker = true
        } label: {
            if let id = selectedFolderID,
               let name = folderStore.folders.first(where: { $0.id == id })?.name {
                Label(name, systemImage: "folder.fill")
                    .font(.caption.bold())
                    .lineLimit(1)
            } else {
                Image(systemName: "folder")
            }
        }
        .sheet(isPresented: $showPicker) {
            FolderPickerSheet(selectedFolderID: $selectedFolderID)
                .environmentObject(folderStore)
        }
    }
}

// MARK: - Picker sheet

struct FolderPickerSheet: View {
    @EnvironmentObject var folderStore: FolderStore
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
                    ForEach(folderStore.folders) { folder in
                        Button {
                            selectedFolderID = folder.id
                            dismiss()
                        } label: {
                            HStack {
                                Label(folder.name, systemImage: "folder")
                                Spacer()
                                Text("\(folder.photoAssetIDs.count)")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                if selectedFolderID == folder.id {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                    if folderStore.folders.isEmpty {
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
                    .environmentObject(folderStore)
            }
        }
    }
}

// MARK: - Manage sheet (create / delete folders)

struct FolderManageSheet: View {
    @EnvironmentObject var folderStore: FolderStore
    @Environment(\.dismiss) private var dismiss
    @State private var newFolderName = ""
    @State private var showCreate = false
    @State private var deletingFolder: LocalFolder?
    @State private var renamingFolder: LocalFolder?
    @State private var renameText = ""
    @State private var deleteAction: DeleteAction = .removeOnly

    enum DeleteAction { case removeOnly, deletePhotos }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(folderStore.folders) { folder in
                        HStack {
                            Label(folder.name, systemImage: "folder")
                            Spacer()
                            Text("\(folder.photoAssetIDs.count) photos")
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
                    if folderStore.folders.isEmpty {
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
                Button("Create") {
                    let name = newFolderName.trimmingCharacters(in: .whitespaces)
                    newFolderName = ""
                    if !name.isEmpty { Task { await folderStore.create(name: name) } }
                }
                Button("Cancel", role: .cancel) { newFolderName = "" }
            }
            .alert("Rename Folder", isPresented: Binding(
                get: { renamingFolder != nil },
                set: { if !$0 { renamingFolder = nil } }
            )) {
                TextField("Folder name", text: $renameText)
                Button("Rename") {
                    let name = renameText.trimmingCharacters(in: .whitespaces)
                    if let f = renamingFolder, !name.isEmpty {
                        Task { await folderStore.rename(id: f.id, name: name) }
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
                Button("Remove from Folder Only", role: .none) {
                    if let f = deletingFolder { Task { await folderStore.delete(id: f.id, deletePhotos: false) } }
                    deletingFolder = nil
                }
                Button("Delete Photos Too", role: .destructive) {
                    if let f = deletingFolder { Task { await folderStore.delete(id: f.id, deletePhotos: true) } }
                    deletingFolder = nil
                }
                Button("Cancel", role: .cancel) { deletingFolder = nil }
            } message: {
                Text("Remove photos from this folder, or also delete them from the index?")
            }
        }
    }
}

// MARK: - Add to folder sheet (used from batch select)

struct AddToFolderSheet: View {
    @EnvironmentObject var folderStore: FolderStore
    let assetIDs: [String]
    let onDone: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var adding = false
    @State private var showCreate = false
    @State private var newFolderName = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(folderStore.folders.filter { !$0.isSmart }) { folder in
                        Button {
                            Task {
                                adding = true
                                await folderStore.addPhotos(assetIDs, to: folder.id)
                                adding = false
                                dismiss()
                                onDone()
                            }
                        } label: {
                            HStack {
                                Label(folder.name, systemImage: "folder")
                                Spacer()
                                Text("\(folder.photoAssetIDs.count)")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .foregroundStyle(.primary)
                        .disabled(adding)
                    }
                    if folderStore.folders.isEmpty {
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
            .overlay { if adding { ProgressView().controlSize(.large) } }
            .alert("New Folder", isPresented: $showCreate) {
                TextField("Folder name", text: $newFolderName)
                Button("Create & Add") {
                    let name = newFolderName.trimmingCharacters(in: .whitespaces)
                    newFolderName = ""
                    guard !name.isEmpty else { return }
                    Task {
                        let folder = await folderStore.createAndReturn(name: name)
                        adding = true
                        await folderStore.addPhotos(assetIDs, to: folder.id)
                        adding = false
                        dismiss()
                        onDone()
                    }
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
    @EnvironmentObject private var folderStore: FolderStore

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
                    Task { await folderStore.create(name: name, query: query.isEmpty ? nil : query) }
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
                    Task { await folderStore.rename(id: f.id, name: name) }
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
            Button("Remove Folder Only") {
                if let f = deleting { Task { await folderStore.delete(id: f.id, deletePhotos: false) } }
                deleting = nil
            }
            Button("Delete Photos Too", role: .destructive) {
                if let f = deleting { Task { await folderStore.delete(id: f.id, deletePhotos: true) } }
                deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            Text("The photos stay in your library and index either way, unless you also delete them from the index.")
        }
        .task {
            await folderStore.load()
            // Zero-shot CLIP categorization over stored embeddings — cached
            // in the store until the photo count changes.
            categories = store.autoCategories()
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color(.secondarySystemBackground)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if folder.isSmart {
                        Image(systemName: "sparkles")
                            .font(.system(size: 40))
                            .foregroundStyle(.tint)
                    } else if let cover = folder.photoAssetIDs.last {
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
                 : "\(folder.photoAssetIDs.count) photo\(folder.photoAssetIDs.count == 1 ? "" : "s")")
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
    @EnvironmentObject private var folderStore: FolderStore
    @Environment(\.dismiss) private var dismiss

    @State private var showRename = false
    @State private var renameText = ""
    @State private var showEditQuery = false
    @State private var queryText = ""
    @State private var confirmDelete = false

    private var folder: LocalFolder? { store.folders.first { $0.id == folderID } }
    private var photos: [LocalPhoto] {
        guard let folder else { return [] }
        return store.photosForFolder(folder)   // smart folders re-run their saved search
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
                PhotoResultsGrid(results: photos)
            } else {
                PhotoResultsGrid(
                    results: photos,
                    onRemoveSelected: { assetIDs in
                        Task { await folderStore.removePhotos(assetIDs, from: folderID) }
                    }
                )
            }
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
                if !name.isEmpty { Task { await folderStore.rename(id: folderID, name: name) } }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Edit Search", isPresented: $showEditQuery) {
            TextField("Search query", text: $queryText)
            Button("Save") {
                let q = queryText.trimmingCharacters(in: .whitespaces)
                if !q.isEmpty { Task { await folderStore.setQuery(id: folderID, query: q) } }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Delete \"\(folder?.name ?? "")\"?",
            isPresented: $confirmDelete, titleVisibility: .visible
        ) {
            Button("Remove Folder Only") {
                Task { await folderStore.delete(id: folderID, deletePhotos: false) }
                dismiss()
            }
            Button("Delete Photos Too", role: .destructive) {
                Task { await folderStore.delete(id: folderID, deletePhotos: true) }
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The photos stay in your library and index either way, unless you also delete them from the index.")
        }
    }
}
