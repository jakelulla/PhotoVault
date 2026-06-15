import SwiftUI

@main
struct PhotoSearchApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // BGTask handlers must be registered before launch completes.
        BackgroundIndexer.register()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: scenePhase) { _, phase in
            // Whenever the user leaves the app, ask iOS for a background
            // window to keep indexing — but only while unindexed assets
            // remain, so a fully indexed library doesn't keep iOS waking
            // the app for nothing.
            if phase == .background {
                // Flush dirty JSON stores synchronously before backgrounding:
                // user edits (renames, folder/cluster changes, deletes) ride a
                // 3s schedulePersist debounce, so an edit made just before the
                // app suspends would otherwise be lost if iOS kills it inside
                // that window. JSON-only, so it's cheap (the ~100MB embeddings
                // binary still flushes async via persist()).
                PhotoStore.shared.persist()
                BackgroundIndexer.scheduleIfWorkRemains()
            }
        }
    }
}
