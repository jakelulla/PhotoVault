import SwiftUI

@MainActor
final class FolderStore: ObservableObject {
    @Published var folders: [LocalFolder] = []
    private var loaded = false

    /// Re-read from PhotoStore — done after every mutation so folder photo
    /// counts shown in pickers/cards never go stale.
    private func refresh() {
        folders = PhotoStore.shared.folders
    }

    func load() async {
        guard !loaded else { return }
        loaded = true
        refresh()
    }

    func reload() async {
        refresh()
    }

    func create(name: String, query: String? = nil) async {
        _ = PhotoStore.shared.createFolder(name: name, query: query)
        refresh()
    }

    func setQuery(id: String, query: String) async {
        PhotoStore.shared.setFolderQuery(id: id, query: query)
        refresh()
    }

    @discardableResult
    func createAndReturn(name: String) async -> LocalFolder {
        let f = PhotoStore.shared.createFolder(name: name)
        refresh()
        return f
    }

    func rename(id: String, name: String) async {
        PhotoStore.shared.renameFolder(id: id, name: name)
        refresh()
    }

    func delete(id: String, deletePhotos: Bool) async {
        PhotoStore.shared.deleteFolder(id: id, deletePhotos: deletePhotos)
        refresh()
    }

    func addPhotos(_ assetIDs: [String], to folderID: String) async {
        PhotoStore.shared.addPhotos(assetIDs, toFolder: folderID)
        refresh()
    }

    func removePhotos(_ assetIDs: [String], from folderID: String) async {
        PhotoStore.shared.removePhotos(assetIDs, fromFolder: folderID)
        refresh()
    }
}
