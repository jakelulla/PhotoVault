import Foundation
import UIKit
import UserNotifications

/// Cross-tab navigation intents raised outside the view hierarchy (notification
/// taps, widget deep links). MainTabs observes it and presents the target.
@MainActor
final class AppRouter: ObservableObject {
    static let shared = AppRouter()
    /// Present the Shared Albums screen (as a sheet over the tabs).
    @Published var showSharedAlbums = false
    private init() {}
}

/// Owns everything user-visible about notifications: the permission ask, the
/// foreground-presentation policy, tap routing, and the local "N new photos"
/// notification posted after a background delta sync.
///
/// Hermeticity: nothing here runs at launch except `install()` (pure delegate
/// wiring — no prompt, no network). The permission REQUEST happens only from
/// the Shared Albums screen, and is gated on `runningTests`, so the test suite
/// and simulator never see a system dialog.
@MainActor
final class NotificationManager: NSObject, ObservableObject {
    static let shared = NotificationManager()

    private static let runningTests =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    /// Persisted "we asked already" marker (file-based, consistent with the
    /// app's no-UserDefaults privacy-manifest stance).
    private static var askedURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("photosearch/notifications_asked.flag")
    }

    private override init() { super.init() }

    /// Wire the notification-center delegate. Called from app-delegate launch;
    /// does NOT prompt and touches no network.
    func install() {
        UNUserNotificationCenter.current().delegate = self
    }

    /// Ask for alert/sound/badge permission ONCE, the first time the user
    /// enters the sharing feature (a contextual moment: they are about to send
    /// or receive invitations). Subsequent calls are no-ops.
    func requestAuthorizationIfNeeded() async {
        guard !Self.runningTests else { return }
        guard !FileManager.default.fileExists(atPath: Self.askedURL.path) else { return }
        try? Data().write(to: Self.askedURL, options: .atomic)
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])
    }

    /// Post a local notification summarizing photos that arrived via a
    /// BACKGROUND delta sync ("3 new photos in “Tahoe ’26”"). Foreground
    /// arrivals skip this — the UI is already visibly updating.
    func postNewPhotos(count: Int, albumNames: [String]) {
        guard !Self.runningTests, count > 0 else { return }
        let content = UNMutableNotificationContent()
        content.title = albumNames.count == 1
            ? "New photos in \u{201C}\(albumNames[0])\u{201D}"
            : "New shared photos"
        content.body = albumNames.count <= 1
            ? "\(count) new photo\(count == 1 ? "" : "s") arrived."
            : "\(count) new photo\(count == 1 ? "" : "s") across \(albumNames.count) albums."
        content.sound = .default
        content.userInfo = ["route": "sharedAlbums"]
        let request = UNNotificationRequest(
            identifier: "new-shared-photos-\(UUID().uuidString)",
            content: content,
            trigger: nil)   // deliver immediately
        UNUserNotificationCenter.current().add(request)
    }
}

extension NotificationManager: UNUserNotificationCenterDelegate {
    /// Show remote/local notification banners even while the app is frontmost
    /// (an invitation alert while the user is on the Search tab should still
    /// be visible).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// A tapped notification routes to the Shared Albums screen — every
    /// notification this app produces (invitation, photo request, new photos)
    /// lands there.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        await MainActor.run {
            AppRouter.shared.showSharedAlbums = true
        }
        // Refresh the inboxes behind the sheet so the content is fresh by the
        // time it appears. All internally gated (tests/availability).
        await InvitationStore.shared.refreshPendingInvitations()
        await RequestStore.shared.refreshPendingRequests()
        _ = await SharedAlbumStore.shared.syncChanges()
    }
}
