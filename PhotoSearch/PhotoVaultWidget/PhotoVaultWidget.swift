import SwiftUI
import WidgetKit

// MARK: - Shared summary (extension-local copy)

/// Wire-format twin of the app's AppGroupSummary (kept in each target on
/// purpose — no shared framework). Fields must stay additive/optional.
private struct AppGroupSummary: Codable {
    struct Album: Codable, Identifiable {
        var id: String
        var name: String
        var zoneName: String
        var zoneOwnerName: String
        var isOwnedByMe: Bool
        var photoCount: Int
    }

    var pendingInvitations: Int = 0
    var pendingRequests: Int = 0
    var albums: [Album] = []
    var recentActivity: [String] = []
    var updatedAt = Date()

    static let appGroupID = "group.com.jakelulla.PhotoSearch"
    static let fileName = "widget_summary.json"

    static func read() -> AppGroupSummary? {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else { return nil }
        guard let data = try? Data(contentsOf: container.appendingPathComponent(fileName)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(AppGroupSummary.self, from: data)
    }
}

// MARK: - Timeline

struct SharedAlbumsEntry: TimelineEntry {
    let date: Date
    let pending: Int
    let albumCount: Int
    let activity: [String]
}

struct SharedAlbumsProvider: TimelineProvider {
    func placeholder(in context: Context) -> SharedAlbumsEntry {
        SharedAlbumsEntry(date: Date(), pending: 1, albumCount: 3,
                          activity: ["Invitation from @sam: \u{201C}Tahoe \u{2019}26\u{201D}"])
    }

    func getSnapshot(in context: Context, completion: @escaping (SharedAlbumsEntry) -> Void) {
        completion(entry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SharedAlbumsEntry>) -> Void) {
        // The app reloads timelines on every refresh; the hourly fallback just
        // keeps "x minutes ago" style staleness bounded when the app is idle.
        let next = Calendar.current.date(byAdding: .hour, value: 1, to: Date()) ?? Date().addingTimeInterval(3600)
        completion(Timeline(entries: [entry()], policy: .after(next)))
    }

    private func entry() -> SharedAlbumsEntry {
        let summary = AppGroupSummary.read()
        return SharedAlbumsEntry(
            date: Date(),
            pending: (summary?.pendingInvitations ?? 0) + (summary?.pendingRequests ?? 0),
            albumCount: summary?.albums.count ?? 0,
            activity: summary?.recentActivity ?? [])
    }
}

// MARK: - Views

struct SharedAlbumsWidgetView: View {
    var entry: SharedAlbumsEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        content
            .containerBackground(.fill.tertiary, for: .widget)
            .widgetURL(URL(string: "photovault://shared"))
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .systemMedium:
            HStack(alignment: .top, spacing: 12) {
                header
                Spacer()
                VStack(alignment: .leading, spacing: 4) {
                    if entry.activity.isEmpty {
                        Text("No new activity")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(entry.activity.prefix(3), id: \.self) { line in
                            Text(line)
                                .font(.caption2)
                                .lineLimit(1)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 2)
        default:
            VStack(alignment: .leading, spacing: 6) {
                header
                Spacer()
                Text(entry.pending > 0
                     ? "\(entry.pending) waiting for you"
                     : "\(entry.albumCount) shared album\(entry.albumCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(entry.pending > 0 ? .primary : .secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "person.2.crop.square.stack.fill")
                    .foregroundStyle(.tint)
                if entry.pending > 0 {
                    Text("\(entry.pending)")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(.red, in: Capsule())
                }
            }
            .font(.title3)
            Text("Shared Albums")
                .font(.headline)
        }
    }
}

// MARK: - Widget

struct SharedAlbumsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "PhotoVaultSharedAlbums",
                            provider: SharedAlbumsProvider()) { entry in
            SharedAlbumsWidgetView(entry: entry)
        }
        .configurationDisplayName("Shared Albums")
        .description("Pending invitations and activity in your shared albums.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct PhotoVaultWidgetBundle: WidgetBundle {
    var body: some Widget {
        SharedAlbumsWidget()
    }
}
