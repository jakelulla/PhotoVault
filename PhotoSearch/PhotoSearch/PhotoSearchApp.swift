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
            // Foregrounding: keep the SOCIAL layer fresh without requiring a
            // manual trip to the Shared Albums screen — refresh the invitation
            // inbox, ensure push subscriptions, and delta-sync shared albums.
            // Both hooks are no-ops unless the user actually uses the feature
            // (local profile / cached albums exist), are gated on runningTests
            // internally, and short-circuit when iCloud is unavailable — so
            // launch, the simulator, and the test host stay inert.
            if phase == .active {
                Task { @MainActor in
                    await InvitationStore.shared.onAppActivate()
                    await SharedAlbumStore.shared.onAppActivate()
                    // Cross-device folder/smart-folder sync (own private DB;
                    // gated internally: tests, availability, has-folders).
                    await SettingsSyncService.shared.syncOnActivateIfWorthwhile()
                }
            }
        }
    }
}

/// Scene delegate — REQUIRED for CloudKit share links to work in a SwiftUI
/// scene-based app. iOS delivers share acceptance to the WINDOW SCENE delegate
/// (`windowScene(_:userDidAcceptCloudKitShareWith:)` when the app is running,
/// `connectionOptions.cloudKitShareMetadata` on a cold launch from the link) —
/// NOT to the app delegate's `userDidAcceptCloudKitShareWith`, which is dead
/// code under scenes. Without this class, tapping a share link opened the app
/// and silently did nothing. SwiftUI still owns the window/UI: we implement no
/// window management here, only the CloudKit hand-off.
final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    /// Cold launch from a share link: the metadata rides the connection options.
    func scene(_ scene: UIScene,
               willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        if let metadata = connectionOptions.cloudKitShareMetadata {
            Task { @MainActor in
                await SharedAlbumStore.shared.acceptShare(metadata)
            }
        }
    }

    /// Warm path: the app is running (or suspended) and the user taps a link.
    func windowScene(_ windowScene: UIWindowScene,
                     userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata) {
        Task { @MainActor in
            await SharedAlbumStore.shared.acceptShare(cloudKitShareMetadata)
        }
    }
}

/// Receives CloudKit share-acceptance callbacks. When a user taps a CKShare
/// link (or accepts an invite), iOS hands the app the share's metadata here;
/// we forward it to SharedAlbumStore on the main actor. This is invoked only in
/// response to a user action after launch — never at startup and never during
/// the in-host XCTest run — so it has no effect on launch or the test suite.
final class AppDelegate: NSObject, UIApplicationDelegate {
    /// Wire the notification-center delegate (banner policy + tap routing).
    /// Pure delegate assignment: no prompt, no network, test-safe.
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        MainActor.assumeIsolated {
            NotificationManager.shared.install()
        }
        return true
    }

    /// Route every window scene through SceneDelegate — the ONLY way iOS
    /// delivers CloudKit share-acceptance metadata to a scene-based app. SwiftUI
    /// keeps managing the window/content as usual.
    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        if connectingSceneSession.role == .windowApplication {
            config.delegateClass = SceneDelegate.self
        }
        return config
    }

    /// Legacy fallback (non-scene contexts). Under scenes iOS calls the SCENE
    /// delegate instead — see SceneDelegate. Kept because it is harmless and
    /// covers any path where a scene delegate isn't consulted.
    func application(_ application: UIApplication,
                     userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        Task { @MainActor in
            await SharedAlbumStore.shared.acceptShare(metadata)
        }
    }

    /// Diagnostics: a failed APNs registration means CloudKit's silent pushes
    /// (album sync + invitation inbox) will never arrive — worth a loud log
    /// instead of silence, since the UI then depends entirely on manual refresh.
    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        SharedAlbumLog.logger.error(
            "remote-notification registration FAILED: \(error.localizedDescription, privacy: .public) — shared-album pushes will not arrive")
    }

    /// Silent CloudKit push: a shared-albums database subscription fired because
    /// a record zone changed. Delta-sync and report the fetch result so iOS
    /// keeps granting background time. This is reached ONLY when a real remote
    /// notification arrives after launch (never at startup, never in the test
    /// host — no subscription is ever registered there), and the sync itself
    /// re-guards on `isAvailable`, so it stays inert on the simulator / in tests.
    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        // Only handle CloudKit pushes; ignore anything else.
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) else {
            completionHandler(.noData)
            return
        }
        // Three kinds of push reach us, all routed by subscriptionID so each does
        // the right work and the completion handler is called EXACTLY ONCE on
        // every path:
        //   1. the public-DB INVITATION query subscription → invitation inbox,
        //   2. the public-DB PHOTO-REQUEST query subscription → request inbox,
        //   3. the zone/database subscriptions (private + shared DB) → delta sync.
        // Both query subscriptions surface as CKQueryNotification, so we must
        // distinguish them by subscriptionID (not by type). Every store re-guards
        // on `isAvailable`, so this stays inert on the simulator / in tests (where
        // no subscription is registered).
        let subID = notification.subscriptionID
        Task { @MainActor in
            switch subID {
            case DirectoryService.invitationSubscriptionID,
                 DirectoryService.legacyInvitationSubscriptionID:
                await InvitationStore.shared.refreshPendingInvitations()
                completionHandler(.newData)
            case DirectoryService.requestSubscriptionID,
                 DirectoryService.legacyRequestSubscriptionID:
                await RequestStore.shared.refreshPendingRequests()
                completionHandler(.newData)
            default:
                if notification is CKQueryNotification {
                    // An unrecognized public-DB query push (schema/id skew):
                    // refresh both public inboxes so nothing is missed.
                    await InvitationStore.shared.refreshPendingInvitations()
                    await RequestStore.shared.refreshPendingRequests()
                    completionHandler(.newData)
                } else {
                    // Album/photo zone change → delta sync. When the sync ran
                    // in the BACKGROUND and brought in photos from other
                    // people, surface a visible local notification — the UI
                    // isn't on screen to show them.
                    let news = await SharedAlbumStore.shared.syncChanges()
                    if news.totalNewPhotos > 0,
                       application.applicationState != .active {
                        NotificationManager.shared.postNewPhotos(
                            count: news.totalNewPhotos,
                            albumNames: Array(news.newPhotosByAlbumName.keys))
                    }
                    completionHandler(news.changed ? .newData : .noData)
                }
            }
        }
    }
}
