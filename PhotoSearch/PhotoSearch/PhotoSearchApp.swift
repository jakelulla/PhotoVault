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
            // window to keep indexing (no-op if indexing is already done —
            // the indexer skips already-indexed photos and exits).
            if phase == .background {
                BackgroundIndexer.schedule()
            }
        }
    }
}
