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

    private static func handle(_ task: BGProcessingTask) {
        // Keep a follow-up window scheduled while there may be work left.
        schedule()

        let work = Task { @MainActor in
            let library = PhotoLibraryModel()
            library.refreshStatus()
            guard library.isAuthorized else {
                task.setTaskCompleted(success: false)
                return
            }
            let indexer = Indexer()
            await indexer.indexNewPhotos(from: library)
            PhotoStore.shared.persist()
            task.setTaskCompleted(success: !Task.isCancelled)
        }

        task.expirationHandler = {
            // Indexer checks Task.isCancelled per photo, breaks out, and the
            // store persists — so progress made this window is kept.
            work.cancel()
        }
    }
}
