import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

/// The tiny JSON snapshot the APP writes into the shared App Group container
/// for its extensions: the widget renders pending counts + recent activity,
/// and the share extension lists the albums it can upload into.
///
/// The extensions ship their OWN copy of this struct (they are separate,
/// self-contained targets by design — no shared framework) — keep the wire
/// format additive: new fields must be optional.
struct AppGroupSummary: Codable {
    struct Album: Codable, Identifiable {
        var id: String            // zone name
        var name: String
        var zoneName: String
        var zoneOwnerName: String
        var isOwnedByMe: Bool
        var photoCount: Int
    }

    var pendingInvitations: Int = 0
    var pendingRequests: Int = 0
    var albums: [Album] = []
    /// Human lines for the widget ("3 new in Tahoe ’26").
    var recentActivity: [String] = []
    var updatedAt = Date()

    static let appGroupID = "group.com.jakelulla.PhotoSearch"
    static let fileName = "widget_summary.json"

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    /// Write the snapshot (no-op when the App Group entitlement is absent —
    /// e.g. before the provisioning profile knows the group).
    static func write(_ summary: AppGroupSummary) {
        guard let container = containerURL else { return }
        let url = container.appendingPathComponent(fileName)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(summary) {
            try? data.write(to: url, options: .atomic)
        }
    }

    // NOTE: no read() here — the APP only writes this file. The widget and
    // share extension read it through their own self-contained copies of the
    // struct (see PhotoVaultWidget/ and PhotoVaultShare/).
}

/// Central refresh point: gathers current store state into the summary and
/// nudges WidgetKit. Called after album loads and inbox refreshes; cheap.
@MainActor
enum AppGroupSummaryWriter {
    static func refresh() {
        let store = SharedAlbumStore.shared
        let invitations = InvitationStore.shared
        let requests = RequestStore.shared

        var summary = AppGroupSummary()
        summary.pendingInvitations = invitations.pendingInvitations.count
        summary.pendingRequests = requests.pendingRequests.count
        summary.albums = store.albums.map {
            AppGroupSummary.Album(
                id: $0.id, name: $0.name,
                zoneName: $0.zoneName, zoneOwnerName: $0.zoneOwnerName,
                isOwnedByMe: $0.isOwnedByMe, photoCount: $0.photoCount)
        }
        summary.recentActivity = invitations.pendingInvitations.prefix(3).map {
            "Invitation from @\($0.fromUsername): \u{201C}\($0.albumName)\u{201D}"
        }
        AppGroupSummary.write(summary)

        // Nudge the widget timeline. WidgetKit is always linkable on iOS 18.
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }
}
