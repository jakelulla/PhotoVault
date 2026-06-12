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
                BackgroundIndexer.scheduleIfWorkRemains()
            }
        }
    }
}
