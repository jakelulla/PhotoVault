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
    /// Play today's On This Day slideshow (from a memory notification tap).
    @Published var showOnThisDay = false
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

    // MARK: - Memory notifications

    /// Opt-in marker for On This Day reminders. File-based like `askedURL`,
    /// keeping the app's no-UserDefaults stance.
    private static var memoriesURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("photosearch/memories_enabled.flag")
    }

    /// Notification identifiers this feature owns, so rescheduling can clear
    /// its own pending requests without touching shared-album ones.
    private static let memoryPrefix = "memory-"

    /// How far ahead to schedule. Local notifications can't evaluate content
    /// at fire time, so each day with memories gets its own pre-computed
    /// request; the window is refreshed whenever the app runs.
    private static let memoryHorizonDays = 14
    private static let memoryHour = 10

    @Published private(set) var memoriesEnabled =
        FileManager.default.fileExists(atPath: NotificationManager.memoriesURL.path)

    /// Turn On This Day reminders on or off. Turning them ON asks for
    /// notification permission if it hasn't been granted yet — a contextual
    /// ask, at the moment the user opted in.
    func setMemoriesEnabled(_ on: Bool) async {
        memoriesEnabled = on
        if on {
            try? Data().write(to: Self.memoriesURL, options: .atomic)
            guard !Self.runningTests else { return }
            let center = UNUserNotificationCenter.current()
            let status = await center.notificationSettings().authorizationStatus
            if status == .notDetermined {
                _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            }
        } else {
            try? FileManager.default.removeItem(at: Self.memoriesURL)
        }
        await rescheduleMemoryNotifications()
    }

    /// Rebuild the pending memory notifications from the current index.
    /// Idempotent: it clears everything it previously scheduled first, so
    /// calling it after each index pass simply keeps the window fresh.
    func rescheduleMemoryNotifications() async {
        guard !Self.runningTests else { return }
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let mine = pending.map(\.identifier).filter { $0.hasPrefix(Self.memoryPrefix) }
        if !mine.isEmpty { center.removePendingNotificationRequests(withIdentifiers: mine) }

        guard memoriesEnabled else { return }
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else { return }

        let cal = Calendar.current
        let now = Date()
        for offset in 0..<Self.memoryHorizonDays {
            guard let day = cal.date(byAdding: .day, value: offset, to: now) else { continue }
            var comps = cal.dateComponents([.year, .month, .day], from: day)
            comps.hour = Self.memoryHour
            comps.minute = 0
            // Skip a slot that has already passed (typically today's).
            if let fire = cal.date(from: comps), fire <= now { continue }

            let groups = PhotoStore.shared.onThisDay(reference: day)
            let count = groups.reduce(0) { $0 + $1.photos.count }
            // Three is the same floor SlideshowBuilder uses — below it there's
            // nothing worth interrupting someone for.
            guard count >= 3 else { continue }

            let content = UNMutableNotificationContent()
            content.title = "On This Day"
            content.body = Self.memoryBody(groups: groups, count: count)
            content.sound = .default
            content.userInfo = ["route": "onThisDay"]
            let id = "\(Self.memoryPrefix)\(comps.year ?? 0)-\(comps.month ?? 0)-\(comps.day ?? 0)"
            try? await center.add(UNNotificationRequest(
                identifier: id, content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
        }
    }

    /// "12 photos with Emma, from 2019 and 2021" — names the people when the
    /// day has a clear protagonist, since that's what makes a memory land.
    private static func memoryBody(groups: [PhotoStore.OnThisDayGroup], count: Int) -> String {
        let years = groups.map(\.year).sorted()
        let yearsText: String
        switch years.count {
        case 1:  yearsText = "\(years[0])"
        case 2:  yearsText = "\(years[0]) and \(years[1])"
        default: yearsText = "\(years.first!)–\(years.last!)"
        }
        let photos = groups.flatMap(\.photos)
        let names = PhotoStore.shared.topNamedPeople(in: photos, limit: 2)
        let who = names.isEmpty ? "" : " with \(ListFormatter.localizedString(byJoining: names))"
        return "\(count) photo\(count == 1 ? "" : "s")\(who), from \(yearsText)."
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

    /// Route a tapped notification. Memory notifications open today's On This
    /// Day slideshow; everything else (invitation, photo request, new photos)
    /// lands on Shared Albums.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let route = response.notification.request.content.userInfo["route"] as? String
        if route == "onThisDay" {
            await MainActor.run { AppRouter.shared.showOnThisDay = true }
            return   // nothing here needs a CloudKit refresh
        }
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
