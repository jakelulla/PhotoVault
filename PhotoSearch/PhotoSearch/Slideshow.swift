import Foundation

/// A ready-to-play slideshow: a curated, ordered list of local photo asset IDs
/// plus presentation metadata. Pure value type — the player renders it, the
/// builders below produce it.
struct Slideshow: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var subtitle: String?
    var assetIDs: [String]
    /// Which generative music mood the player starts with.
    var mood: SlideshowMusic.Mood = .calm
}

/// Prebuilt slideshow generators over the local index. All read-only over
/// PhotoStore (@MainActor to match it); no CloudKit, no network — slideshows
/// are a fully on-device feature, like the rest of the ML.
@MainActor
enum SlideshowBuilder {
    /// Hard cap so an all-library slideshow stays watchable (~5 minutes at 4s
    /// a slide) and memory stays bounded.
    static let maxSlides = 80

    // MARK: - Curation

    /// Shared curation pass: drop deleted, collapse near-duplicate groups to
    /// their sharpest member, sort chronologically, and — when over the cap —
    /// sample EVENLY across the timeline (never just the first N, which would
    /// truncate the story).
    static func curate(_ photos: [LocalPhoto], cap: Int = maxSlides) -> [String] {
        var best: [String: LocalPhoto] = [:]   // dupGroupID → sharpest member
        var uniques: [LocalPhoto] = []
        for photo in photos where !photo.isDeleted {
            if let group = photo.dupGroupID {
                if let current = best[group] {
                    if (photo.sharpness ?? 0) > (current.sharpness ?? 0) {
                        best[group] = photo
                    }
                } else {
                    best[group] = photo
                }
            } else {
                uniques.append(photo)
            }
        }
        var all = uniques + Array(best.values)
        all.sort { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
        guard all.count > cap else { return all.map(\.assetID) }
        // Even timeline sampling.
        let step = Double(all.count) / Double(cap)
        return (0..<cap).map { all[Int(Double($0) * step)].assetID }
    }

    // MARK: - Prebuilt slideshows

    /// Chronological story of one person, from their earliest photo to today.
    static func person(_ cluster: PersonCluster) -> Slideshow? {
        let photos = PhotoStore.shared.photos(forCluster: cluster.id)
        let ids = curate(photos)
        guard ids.count >= 3 else { return nil }
        let name = cluster.name?.isEmpty == false ? cluster.name! : "Them"
        return Slideshow(
            title: name,
            subtitle: "Their story, in \(ids.count) photos",
            assetIDs: ids,
            mood: .warm)
    }

    /// Best-of for a calendar year: per month, keep the sharpest photos, then
    /// play the year in order.
    static func yearInReview(_ year: Int) -> Slideshow? {
        let cal = Calendar.current
        let store = PhotoStore.shared
        var byMonth: [Int: [LocalPhoto]] = [:]
        for photo in store.photos where !photo.isDeleted {
            guard let date = photo.createdAt, cal.component(.year, from: date) == year else { continue }
            byMonth[cal.component(.month, from: date), default: []].append(photo)
        }
        guard !byMonth.isEmpty else { return nil }
        // Budget slides per month, biased to sharpness within each month.
        let perMonth = max(3, maxSlides / max(1, byMonth.count))
        var picked: [LocalPhoto] = []
        for (_, monthPhotos) in byMonth {
            let top = monthPhotos
                .sorted { ($0.sharpness ?? 0) > ($1.sharpness ?? 0) }
                .prefix(perMonth)
            picked.append(contentsOf: top)
        }
        let ids = curate(picked)
        guard ids.count >= 3 else { return nil }
        return Slideshow(
            title: "\(year)",
            subtitle: "Your year in \(ids.count) photos",
            assetIDs: ids,
            mood: .bright)
    }

    /// Today's month/day across all previous years, oldest first.
    static func onThisDay() -> Slideshow? {
        let groups = PhotoStore.shared.onThisDay()
        guard !groups.isEmpty else { return nil }
        let photos = groups.flatMap(\.photos)
        let ids = curate(photos)
        guard ids.count >= 3 else { return nil }
        let years = groups.map(\.year).sorted()
        return Slideshow(
            title: "On This Day",
            subtitle: years.count == 1
                ? "From \(years[0])"
                : "\(years.first!)–\(years.last!), \(ids.count) photos",
            assetIDs: ids,
            mood: .calm)
    }

    /// Free-form: whatever the user describes, through the SAME search engine
    /// as the Search tab (structured filters + CLIP ranking), chronological.
    static func custom(query rawQuery: String) -> Slideshow? {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }
        let hits = PhotoStore.shared.searchPhotos(query: query)
        let ids = curate(hits)
        guard ids.count >= 3 else { return nil }
        return Slideshow(
            title: query.prefix(1).uppercased() + query.dropFirst(),
            subtitle: "\(ids.count) matching photos",
            assetIDs: ids,
            mood: .calm)
    }

    /// A saved slideshow: the SAME builder as `custom`, re-run against today's
    /// index, but titled with the user's name instead of the raw query. Nil
    /// when the saved search no longer clears the 3-photo floor (e.g. its
    /// photos were deleted) — callers surface that rather than play an
    /// almost-empty show.
    static func saved(_ show: SavedSlideshow) -> Slideshow? {
        let hits = PhotoStore.shared.searchPhotos(query: show.query)
        let ids = curate(hits)
        guard ids.count >= 3 else { return nil }
        return Slideshow(
            title: show.name,
            subtitle: "\(ids.count) matching photos",
            assetIDs: ids,
            mood: show.mood)
    }

    /// A folder (static or smart), played chronologically.
    static func folder(_ folder: LocalFolder) -> Slideshow? {
        let photos = PhotoStore.shared.photosForFolder(folder)
        let ids = curate(photos)
        guard ids.count >= 3 else { return nil }
        return Slideshow(
            title: folder.name,
            subtitle: "\(ids.count) photos",
            assetIDs: ids,
            mood: .calm)
    }
}
