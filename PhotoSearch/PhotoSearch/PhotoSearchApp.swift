import CloudKit
import SwiftUI
import UIKit

@main
struct PhotoSearchApp: App {
    @Environment(\.scenePhase) private var scenePhase

    // Minimal AppDelegate purely to receive CloudKit share-acceptance
    // callbacks (there is no other UIKit lifecycle work here). SwiftUI's App
    // lifecycle has no equivalent hook for userDidAcceptCloudKitShareWith, so
    // an adaptor is required. This does NOT touch CloudKit at launch — it only
    // reacts to the user tapping a share link, which by definition happens
    // after launch and never during the test suite.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

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

/// Receives CloudKit share-acceptance callbacks. When a user taps a CKShare
/// link (or accepts an invite), iOS hands the app the share's metadata here;
/// we forward it to SharedAlbumStore on the main actor. This is invoked only in
/// response to a user action after launch — never at startup and never during
/// the in-host XCTest run — so it has no effect on launch or the test suite.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        Task { @MainActor in
            await SharedAlbumStore.shared.acceptShare(metadata)
        }
    }
}
