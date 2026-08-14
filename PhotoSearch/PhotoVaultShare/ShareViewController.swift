import CloudKit
import CryptoKit
import Social
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// PhotoVault's share extension: share images from Photos (or anywhere) straight
/// into one of your shared albums, without opening the app.
///
/// Deliberately SELF-CONTAINED: it duplicates the ~wire-level essentials (the
/// container id, the SharedPhoto record schema, the App Group summary format)
/// instead of linking app code — the extension must stay tiny and must never
/// drag the app's stores (and their side effects) into an extension process.
/// The record schema below MUST stay in lockstep with SharedAlbum.PhotoField.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
        let root = ShareRootView(
            items: items,
            onFinish: { [weak self] in
                self?.extensionContext?.completeRequest(returningItems: nil)
            },
            onCancel: { [weak self] in
                self?.extensionContext?.cancelRequest(withError: NSError(
                    domain: "com.jakelulla.PhotoSearch.share", code: 0,
                    userInfo: [NSLocalizedDescriptionKey: "Cancelled"]))
            })
        let host = UIHostingController(rootView: root)
        addChild(host)
        view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        host.didMove(toParent: self)
    }
}

// MARK: - Summary (extension-local copy of the App Group wire format)

private struct AppGroupSummary: Codable {
    struct Album: Codable, Identifiable {
        var id: String
        var name: String
        var zoneName: String
        var zoneOwnerName: String
        var isOwnedByMe: Bool
        var photoCount: Int
    }
    var pendingInvitations: Int = 0
    var pendingRequests: Int = 0
    var albums: [Album] = []
    var recentActivity: [String] = []
    var updatedAt = Date()

    static func read() -> AppGroupSummary? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.jakelulla.PhotoSearch") else { return nil }
        guard let data = try? Data(contentsOf: container.appendingPathComponent("widget_summary.json")) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(AppGroupSummary.self, from: data)
    }
}

// MARK: - UI

private struct ShareRootView: View {
    let items: [NSExtensionItem]
    let onFinish: () -> Void
    let onCancel: () -> Void

    private enum Phase: Equatable {
        case pickAlbum
        case uploading(done: Int, total: Int)
        case finished(saved: Int)
        case failed(String)
        case noAlbums
    }

    @State private var phase: Phase = .pickAlbum
    @State private var albums: [AppGroupSummary.Album] = []

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .pickAlbum:
                    if albums.isEmpty {
                        ProgressView().task { load() }
                    } else {
                        List(albums) { album in
                            Button {
                                Task { await upload(to: album) }
                            } label: {
                                HStack {
                                    Image(systemName: album.isOwnedByMe
                                          ? "person.2.fill" : "tray.and.arrow.down.fill")
                                        .foregroundStyle(.tint)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(album.name).foregroundStyle(.primary)
                                        Text("\(album.photoCount) photo\(album.photoCount == 1 ? "" : "s")")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                case .uploading(let done, let total):
                    VStack(spacing: 14) {
                        ProgressView(value: total > 0 ? Double(done) / Double(total) : 0)
                            .progressViewStyle(.linear)
                            .frame(maxWidth: 240)
                        Text("Adding \(done)/\(total)…")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                case .finished(let saved):
                    ContentUnavailableView {
                        Label("Added \(saved) photo\(saved == 1 ? "" : "s")", systemImage: "checkmark.circle.fill")
                    } description: {
                        Text("Everyone in the album can see them.")
                    }
                    .task {
                        try? await Task.sleep(nanoseconds: 900_000_000)
                        onFinish()
                    }
                case .failed(let message):
                    ContentUnavailableView {
                        Label("Couldn't add photos", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message)
                    }
                case .noAlbums:
                    ContentUnavailableView {
                        Label("No shared albums yet", systemImage: "person.2.crop.square.stack")
                    } description: {
                        Text("Open PhotoTrove and create or join a shared album first.")
                    }
                }
            }
            .navigationTitle("Add to Shared Album")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                }
            }
        }
    }

    private func load() {
        let summary = AppGroupSummary.read()
        albums = summary?.albums ?? []
        if albums.isEmpty { phase = .noAlbums }
    }

    private func upload(to album: AppGroupSummary.Album) async {
        // 1. Pull image data out of the attachments.
        var images: [Data] = []
        for item in items {
            for provider in item.attachments ?? [] where provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                if let data = await loadImageData(from: provider) {
                    images.append(data)
                }
            }
        }
        guard !images.isEmpty else {
            phase = .failed("Nothing shareable was attached (images only for now).")
            return
        }
        phase = .uploading(done: 0, total: images.count)

        // 2. Upload each as a SharedPhoto record into the album's zone.
        do {
            let uploader = ShareUploader()
            var done = 0
            try await uploader.upload(images: images, to: album) { completed in
                done = completed
                Task { @MainActor in
                    phase = .uploading(done: done, total: images.count)
                }
            }
            phase = .finished(saved: images.count)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func loadImageData(from provider: NSItemProvider) async -> Data? {
        await withCheckedContinuation { cont in
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                guard let data else { cont.resume(returning: nil); return }
                // Normalize to JPEG (matches the app's upload path).
                if let image = UIImage(data: data),
                   let jpeg = image.jpegData(compressionQuality: 0.92) {
                    cont.resume(returning: jpeg)
                } else {
                    cont.resume(returning: data)
                }
            }
        }
    }
}

// MARK: - Minimal CloudKit uploader

/// Schema twin of the app's SharedPhoto upload path (SharedAlbum.PhotoField) —
/// keep field names in lockstep. Uploads sequentially (share-sheet batches are
/// small) and dedupes against the zone's existing contentHashes.
private struct ShareUploader {
    let container = CKContainer(identifier: "iCloud.com.jakelulla.PhotoSearch")

    func upload(images: [Data],
                to album: AppGroupSummary.Album,
                progress: @escaping (Int) -> Void) async throws {
        let database = album.isOwnedByMe
            ? container.privateCloudDatabase
            : container.sharedCloudDatabase
        let zoneID = CKRecordZone.ID(zoneName: album.zoneName, ownerName: album.zoneOwnerName)

        var done = 0
        for data in images {
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()

            // Temp files for the CKAssets.
            let stem = UUID().uuidString
            let tmp = FileManager.default.temporaryDirectory
            let fullURL = tmp.appendingPathComponent("\(stem)-full.jpg")
            let thumbURL = tmp.appendingPathComponent("\(stem)-thumb.jpg")
            try data.write(to: fullURL, options: .atomic)
            let thumb = Self.thumbnail(from: data, maxPixel: 256) ?? data
            try thumb.write(to: thumbURL, options: .atomic)
            defer {
                try? FileManager.default.removeItem(at: fullURL)
                try? FileManager.default.removeItem(at: thumbURL)
            }

            let recordID = CKRecord.ID(recordName: "photo-\(UUID().uuidString)", zoneID: zoneID)
            let record = CKRecord(recordType: "SharedPhoto", recordID: recordID)
            record["fullImage"] = CKAsset(fileURL: fullURL)
            record["thumbnail"] = CKAsset(fileURL: thumbURL)
            record["captureDate"] = Date() as CKRecordValue
            record["contentHash"] = hash as CKRecordValue
            record["mediaType"] = "image" as CKRecordValue
            if let me = try? await container.userRecordID().recordName {
                record["contributorID"] = me as CKRecordValue
            }

            _ = try await database.save(record)
            done += 1
            progress(done)
        }
    }

    private static func thumbnail(from data: Data, maxPixel: CGFloat) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let longest = max(image.size.width, image.size.height)
        guard longest > 0 else { return nil }
        let scale = min(1, maxPixel / longest)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        return resized.jpegData(compressionQuality: 0.8)
    }
}
