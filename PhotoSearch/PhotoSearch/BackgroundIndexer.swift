import BackgroundTasks
import Photos

/// Continues ML indexing after the app leaves the foreground.
///
/// `beginBackgroundTask` (used inside Indexer) only buys ~30s–3min of grace
/// after backgrounding. For a multi-minute indexing run we also schedule a
/// `BGProcessingTask` — iOS relaunches/wakes the app when conditions are good
/// (typically idle, often charging) and grants several minutes of runtime.
/// The indexer is resumable (already-indexed assets are skipped), so each
/// window makes progress and we reschedule until the library is fully indexed.
///
/// Note: if the user force-quits (swipes the app away), iOS will NOT run any
/// scheduled background task until the app is opened again — that's an OS
/// policy no app can override.
enum BackgroundIndexer {
    static let taskID = "com.photosearch.index"

    /// Must be called before the app finishes launching (PhotoSearchApp.init).
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskID, using: nil) { task in
            guard let task = task as? BGProcessingTask else { return }
            handle(task)
        }
    }

    /// Ask iOS for a background-processing window. Safe to call repeatedly —
    /// resubmitting the same identifier just replaces the pending request.
    static func schedule() {
        let request = BGProcessingTaskRequest(identifier: taskID)
        request.requiresNetworkConnectivity = false  // models are on-device
        request.requiresExternalPower = false        // run on battery too; iOS still favors charging
        try? BGTaskScheduler.shared.submit(request)
    }

    /// Schedule a window only if the library still has unindexed assets.
    /// Cheap count comparison (no asset enumeration), so it's fine on every
    /// backgrounding. Scheduling when there's nothing left makes iOS wake the
    /// app for no-op runs and deprioritize the identifier over time.
    @MainActor
    static func scheduleIfWorkRemains() {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return }
        let libraryCount = PHAsset.fetchAssets(with: .image, options: nil).count
                         + PHAsset.fetchAssets(with: .video, options: nil).count
        let indexedCount = PhotoStore.shared.photos.filter { !$0.isDeleted }.count
        if libraryCount != indexedCount { schedule() }
    }

    private static func handle(_ task: BGProcessingTask) {
        let work = Task { @MainActor in
            let library = PhotoLibraryModel()
            library.refreshStatus()
            guard library.isAuthorized else {
                // No photo access — a follow-up window couldn't make progress
                // either, so don't reschedule.
                task.setTaskCompleted(success: false)
                return
            }
            let indexer = Indexer()
            await indexer.indexNewPhotos(from: library)
            // Await the off-main embeddings flush too — the process may be
            // suspended right after setTaskCompleted.
            await PhotoStore.shared.persistAndWait()
            // Ask for another window only while there's still work: assets we
            // haven't indexed, or a run cut short by expiration. Rescheduling
            // unconditionally would have iOS wake the app forever once the
            // library is fully indexed.
            let store = PhotoStore.shared
            let workRemains = library.assets.contains { !store.contains(assetID: $0.localIdentifier) }
            if workRemains || Task.isCancelled { schedule() }
            task.setTaskCompleted(success: !Task.isCancelled)
        }

        task.expirationHandler = {
            // Indexer checks Task.isCancelled per photo, breaks out, and the
            // store persists — so progress made this window is kept.
            work.cancel()
        }
    }
}
