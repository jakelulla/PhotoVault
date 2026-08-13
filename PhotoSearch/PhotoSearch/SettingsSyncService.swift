import CloudKit
import Foundation
import Photos

extension Notification.Name {
    /// Posted by PhotoStore after any LOCAL folder mutation (create, rename,
    /// membership edit, smart-definition change, delete). SettingsSyncService
    /// observes it with a debounce and pushes the changes to iCloud.
    static let photoVaultFoldersChanged = Notification.Name("photoVaultFoldersChanged")
}

/// Cross-device sync of the user's OWN folders + smart folders (#11), via one
/// "user-settings" zone in the private database — no server, invisible to
/// other users.
///
/// Design:
/// - One "FolderMirror" record per folder (recordName == folder.id), carrying
///   the folder's definition. Merge is last-writer-wins on `modifiedAt`;
///   deletions travel as tombstones (`deleted == 1`).
/// - Photo membership crosses devices as **PHCloudIdentifiers** (portable for
///   iCloud Photos libraries), mapped back to local PHAsset identifiers on
///   arrival. Assets that don't map on a device are silently skipped there —
///   the cloud IDs are preserved on the record, so nothing is lost.
/// - **Face data never syncs.** Person clusters and their names are computed
///   per device and stay there — "your face data never leaves your device" is
///   a brand promise this feature must not erode. (Cluster IDs wouldn't match
///   across devices anyway; matching them would require uploading prototype
///   embeddings, i.e. biometrics.)
///
/// Hermeticity: every entry point gates on `runningTests` + CloudKit
/// availability, and the activation path additionally requires either local
/// folders or a not-yet-done first remote probe — so idle users cost one zone
/// fetch ever, and tests/simulator stay inert.
@MainActor
final class SettingsSyncService {
    static let shared = SettingsSyncService()

    private let cloud = CloudKitService.shared

    private static let zoneName = "user-settings"
    private static let recordType = "FolderMirror"

    private enum Field {
        static let name = "name"
        static let query = "query"
        static let minusQuery = "minusQuery"
        static let minScore = "minScore"
        static let anchorCloudID = "anchorCloudID"
        static let memberCloudIDs = "memberCloudIDs"
        static let includeCloudIDs = "includeCloudIDs"
        static let excludeCloudIDs = "excludeCloudIDs"
        static let deleted = "deleted"
        static let modifiedAt = "folderModifiedAt"
    }

    private static let runningTests =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    // MARK: - Local bookkeeping

    /// folderID → modifiedAt at the last successful sync. Two jobs: detect
    /// LOCAL deletions (id known here, folder gone locally → push tombstone)
    /// and skip unchanged folders on push.
    private var lastSynced: [String: Date] = [:]
    private var stateLoaded = false
    /// True after the first-ever remote probe, so devices with zero folders
    /// don't re-fetch the zone on every activation.
    private var probedOnce = false

    private static var stateURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("photosearch/settings_sync_state.json")
    }

    private struct PersistedState: Codable {
        var lastSynced: [String: Date]
        var probedOnce: Bool
    }

    private init() {
        // Debounced push on local folder edits. The observer only SCHEDULES —
        // all gating happens inside syncNow().
        NotificationCenter.default.addObserver(
            forName: .photoVaultFoldersChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleDebouncedSync()
            }
        }
    }

    private var debounceTask: Task<Void, Never>?
    private func scheduleDebouncedSync() {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            await self.syncNow()
        }
    }

    private func loadStateIfNeeded() {
        guard !stateLoaded else { return }
        stateLoaded = true
        if let data = try? Data(contentsOf: Self.stateURL),
           let decoded = try? JSONDecoder().decode(PersistedState.self, from: data) {
            lastSynced = decoded.lastSynced
            probedOnce = decoded.probedOnce
        }
    }

    private func persistState() {
        let state = PersistedState(lastSynced: lastSynced, probedOnce: probedOnce)
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: Self.stateURL, options: .atomic)
        }
    }

    // MARK: - Entry points

    /// Activation hook: sync when the user has folders, or once ever to import
    /// folders created on another device.
    func syncOnActivateIfWorthwhile() async {
        guard !Self.runningTests else { return }
        loadStateIfNeeded()
        guard !PhotoStore.shared.folders.isEmpty || !probedOnce else { return }
        await syncNow()
    }

    /// Full two-way sync: pull remote mirrors, merge LWW, push local wins.
    func syncNow() async {
        guard !Self.runningTests else { return }
        loadStateIfNeeded()
        await cloud.accountStatus()
        guard cloud.isAvailable else { return }

        let zoneID = CKRecordZone.ID(zoneName: Self.zoneName, ownerName: CKCurrentUserDefaultName)
        do {
            _ = try await cloud.createAlbumZone(named: Self.zoneName)   // idempotent
            let records = try await cloud.allRecords(inZone: zoneID, database: cloud.privateDB)
                .filter { $0.recordType == Self.recordType }
            probedOnce = true

            var remoteByID: [String: CKRecord] = [:]
            for record in records { remoteByID[record.recordID.recordName] = record }

            let store = PhotoStore.shared
            var localByID: [String: LocalFolder] = [:]
            for folder in store.folders { localByID[folder.id] = folder }

            var toPush: [CKRecord] = []

            // 1. Walk the union of ids; LWW per folder.
            let allIDs = Set(remoteByID.keys).union(localByID.keys).union(lastSynced.keys)
            for id in allIDs {
                let local = localByID[id]
                let remote = remoteByID[id]
                let remoteModified = (remote?[Field.modifiedAt] as? Date) ?? .distantPast
                let remoteDeleted = ((remote?[Field.deleted] as? Int64) ?? 0) == 1
                let localModified = local?.modifiedAt ?? .distantPast

                switch (local, remote) {
                case (nil, nil):
                    lastSynced[id] = nil

                case (nil, .some):
                    if remoteDeleted {
                        lastSynced[id] = nil
                    } else if lastSynced[id] != nil {
                        // We knew it and deleted it locally → push tombstone.
                        toPush.append(tombstone(for: id, zoneID: zoneID))
                        lastSynced[id] = nil
                    } else {
                        // New from another device → apply locally.
                        if let folder = await folderFromRecord(remote!) {
                            store.applySyncedFolder(folder)
                            lastSynced[id] = remoteModified
                        }
                    }

                case (.some(let folder), nil):
                    // Not on the server yet → push.
                    if let record = await record(for: folder, zoneID: zoneID) {
                        toPush.append(record)
                        lastSynced[id] = folder.modifiedAt ?? .distantPast
                    }

                case (.some(let folder), .some):
                    if remoteDeleted && remoteModified > localModified {
                        store.removeSyncedFolder(id: id)
                        lastSynced[id] = nil
                    } else if remoteModified > localModified {
                        if let merged = await folderFromRecord(remote!) {
                            store.applySyncedFolder(merged)
                            lastSynced[id] = remoteModified
                        }
                    } else if localModified > remoteModified {
                        if let record = await record(for: folder, zoneID: zoneID) {
                            toPush.append(record)
                            lastSynced[id] = localModified
                        }
                    } else {
                        lastSynced[id] = localModified
                    }
                }
            }

            if !toPush.isEmpty {
                _ = try await cloud.save(toPush, to: cloud.privateDB)
                SharedAlbumLog.logger.notice("SettingsSync: pushed \(toPush.count) folder mirror(s)")
            }
            persistState()
        } catch {
            SharedAlbumLog.logger.error(
                "SettingsSync: sync failed — \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Folder ⇄ record mapping

    private func tombstone(for id: String, zoneID: CKRecordZone.ID) -> CKRecord {
        let rec = CKRecord(recordType: Self.recordType,
                           recordID: CKRecord.ID(recordName: id, zoneID: zoneID))
        rec[Field.deleted] = 1 as CKRecordValue
        rec[Field.modifiedAt] = Date() as CKRecordValue
        return rec
    }

    /// Local folder → mirror record; asset IDs become PHCloudIdentifiers.
    private func record(for folder: LocalFolder, zoneID: CKRecordZone.ID) async -> CKRecord? {
        let rec = CKRecord(recordType: Self.recordType,
                           recordID: CKRecord.ID(recordName: folder.id, zoneID: zoneID))
        rec[Field.name] = folder.name as CKRecordValue
        if let q = folder.query { rec[Field.query] = q as CKRecordValue }
        if let m = folder.minusQuery { rec[Field.minusQuery] = m as CKRecordValue }
        if let s = folder.minScore { rec[Field.minScore] = Double(s) as CKRecordValue }
        rec[Field.deleted] = 0 as CKRecordValue
        rec[Field.modifiedAt] = (folder.modifiedAt ?? Date()) as CKRecordValue

        let mapper = CloudIDMapper()
        if let anchor = folder.anchorAssetID,
           let cloudID = await mapper.cloudIDs(for: [anchor]).first {
            rec[Field.anchorCloudID] = cloudID as CKRecordValue
        }
        let members = await mapper.cloudIDs(for: folder.photoAssetIDs)
        if !members.isEmpty { rec[Field.memberCloudIDs] = members as CKRecordValue }
        let includes = await mapper.cloudIDs(for: folder.manualIncludeAssetIDs ?? [])
        if !includes.isEmpty { rec[Field.includeCloudIDs] = includes as CKRecordValue }
        let excludes = await mapper.cloudIDs(for: folder.manualExcludeAssetIDs ?? [])
        if !excludes.isEmpty { rec[Field.excludeCloudIDs] = excludes as CKRecordValue }
        return rec
    }

    /// Mirror record → local folder; PHCloudIdentifiers map back to local
    /// asset IDs (unmappable ones are skipped on THIS device, preserved on the
    /// record).
    private func folderFromRecord(_ record: CKRecord) async -> LocalFolder? {
        guard let name = record[Field.name] as? String else { return nil }
        let mapper = CloudIDMapper()
        var folder = LocalFolder(
            id: record.recordID.recordName,
            name: name,
            photoAssetIDs: await mapper.localIDs(for: record[Field.memberCloudIDs] as? [String] ?? []),
            query: record[Field.query] as? String)
        if let anchorCloud = record[Field.anchorCloudID] as? String {
            folder.anchorAssetID = await mapper.localIDs(for: [anchorCloud]).first
        }
        folder.minusQuery = record[Field.minusQuery] as? String
        folder.minScore = (record[Field.minScore] as? Double).map(Float.init)
        let includes = await mapper.localIDs(for: record[Field.includeCloudIDs] as? [String] ?? [])
        folder.manualIncludeAssetIDs = includes.isEmpty ? nil : includes
        let excludes = await mapper.localIDs(for: record[Field.excludeCloudIDs] as? [String] ?? [])
        folder.manualExcludeAssetIDs = excludes.isEmpty ? nil : excludes
        folder.modifiedAt = record[Field.modifiedAt] as? Date
        return folder
    }
}

/// Thin PHCloudIdentifier bridge. Mapping calls are synchronous Photos APIs
/// that can touch the library database — run them off the main actor.
private struct CloudIDMapper {
    /// localIdentifiers → cloud identifier strings (unmappable IDs skipped:
    /// local-only assets, no iCloud Photos, etc.).
    func cloudIDs(for localIDs: [String]) async -> [String] {
        guard !localIDs.isEmpty else { return [] }
        return await Task.detached(priority: .utility) {
            let mappings = PHPhotoLibrary.shared()
                .cloudIdentifierMappings(forLocalIdentifiers: localIDs)
            // Preserve input order.
            return localIDs.compactMap { id in
                if case .success(let cloudID)? = mappings[id] {
                    return cloudID.stringValue
                }
                return nil
            }
        }.value
    }

    /// Cloud identifier strings → localIdentifiers present in THIS library.
    func localIDs(for cloudIDs: [String]) async -> [String] {
        guard !cloudIDs.isEmpty else { return [] }
        return await Task.detached(priority: .utility) {
            let ids = cloudIDs.map(PHCloudIdentifier.init(stringValue:))
            let mappings = PHPhotoLibrary.shared().localIdentifierMappings(for: ids)
            return ids.compactMap { id in
                if case .success(let localID)? = mappings[id] {
                    return localID
                }
                return nil
            }
        }.value
    }
}
