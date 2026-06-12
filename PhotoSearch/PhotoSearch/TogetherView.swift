import SwiftUI

/// Identifiable + Hashable wrapper so a multi-person selection can drive
/// navigationDestination(item:) — [PersonCluster] alone has no stable id.
struct TogetherSelection: Identifiable, Hashable {
    let clusters: [PersonCluster]
    var id: String { clusters.map { String($0.id) }.sorted().joined(separator: "-") }
}

/// Relationship timeline for 2+ people: every photo where ALL of them appear,
/// oldest first — "first photo together" hero, a per-year sparkline, shared
/// places, and the full grid.
struct TogetherView: View {
    let clusters: [PersonCluster]

    @ObservedObject private var store = PhotoStore.shared
    @State private var all: [LocalPhoto] = []
    @State private var loaded = false
    @State private var yearFilter: Int?
    @State private var placeFilter: String?

    var body: some View {
        Group {
            if !loaded {
                ProgressView()
            } else if all.isEmpty {
                ContentUnavailableView(
                    "No photos together yet",
                    systemImage: "person.2",
                    description: Text("Photos with \(title) all in the frame will show up here.")
                )
            } else {
                content
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        // Keyed on membershipVersion: merges/reclusters/deletes change who is
        // in which photo, so the together-set must be recomputed — but NOT on
        // every body pass (photos(forClusters:) walks the whole library).
        .task(id: store.membershipVersion) {
            all = store.photos(forClusters: clusters.map(\.id))
            loaded = true
        }
    }

    private var title: String {
        clusters
            .map { ($0.name?.isEmpty == false) ? $0.name! : "Unnamed" }
            .joined(separator: " & ")
    }

    // MARK: - Derived data

    private var filtered: [LocalPhoto] {
        all.filter { p in
            if let yearFilter {
                guard let d = p.createdAt,
                      Calendar.current.component(.year, from: d) == yearFilter else { return false }
            }
            if let placeFilter {
                guard p.locationName == placeFilter else { return false }
            }
            return true
        }
    }

    /// One entry per calendar year between the first and last photo —
    /// including empty years, so gaps in the relationship are visible.
    private var yearCounts: [(year: Int, count: Int)] {
        let cal = Calendar.current
        var counts: [Int: Int] = [:]
        for p in all {
            if let d = p.createdAt { counts[cal.component(.year, from: d), default: 0] += 1 }
        }
        guard let lo = counts.keys.min(), let hi = counts.keys.max() else { return [] }
        return (lo...hi).map { ($0, counts[$0] ?? 0) }
    }

    private var placeCounts: [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for p in all {
            if let n = p.locationName, !n.isEmpty { counts[n, default: 0] += 1 }
        }
        return counts.sorted { $0.value > $1.value }.prefix(8).map { ($0.key, $0.value) }
    }

    // MARK: - Layout

    private var content: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                firstPhotoCard
                if yearCounts.count > 1 {
                    YearSparkline(years: yearCounts, selected: $yearFilter)
                }
                if !placeCounts.isEmpty {
                    placeChips
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)

            Divider()

            PhotoResultsGrid(
                results: filtered,
                onDelete: { id in all.removeAll { $0.photoID == id } }
            )
        }
    }

    @ViewBuilder
    private var firstPhotoCard: some View {
        if let first = all.first {
            NavigationLink {
                PhotoDetailView(
                    results: all,
                    startID: first.photoID,
                    onDelete: { id in all.removeAll { $0.photoID == id } }
                )
            } label: {
                ZStack(alignment: .bottomLeading) {
                    PHImageView(assetID: first.assetID,
                                targetSize: CGSize(width: 900, height: 900))
                        .frame(height: 170)
                        .frame(maxWidth: .infinity)
                        .clipped()
                    LinearGradient(colors: [.clear, .black.opacity(0.65)],
                                   startPoint: .center, endPoint: .bottom)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("First photo together")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.85))
                        Text(first.createdAt.map { $0.formatted(.dateTime.month(.wide).year()) }
                             ?? "Date unknown")
                            .font(.title3.bold())
                            .foregroundStyle(.white)
                    }
                    .padding(12)
                }
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
        }
    }

    private var placeChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(placeCounts, id: \.name) { place in
                    let isOn = placeFilter == place.name
                    Button {
                        placeFilter = isOn ? nil : place.name
                    } label: {
                        Text("\(place.name) (\(place.count))")
                            .font(.subheadline)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(isOn ? Color.accentColor : Color(.secondarySystemBackground),
                                        in: Capsule())
                            .foregroundStyle(isOn ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Year sparkline

/// Hand-rolled capsule bars (no Swift Charts — keeping dependencies at zero).
/// One bar per year, height proportional to photo count; tap to filter.
private struct YearSparkline: View {
    let years: [(year: Int, count: Int)]
    @Binding var selected: Int?

    private let maxBarHeight: CGFloat = 44

    var body: some View {
        let maxCount = max(1, years.map(\.count).max() ?? 1)
        // Cap visible labels at ~6 so they never collide on dense ranges.
        let labelStride = max(1, Int((Double(years.count) / 6).rounded(.up)))
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(Array(years.enumerated()), id: \.element.year) { i, item in
                let isOn = selected == item.year
                let showLabel = i % labelStride == 0 || i == years.count - 1
                VStack(spacing: 3) {
                    Capsule()
                        .fill(isOn
                              ? Color.accentColor
                              : (item.count == 0
                                 ? Color(.tertiarySystemFill)
                                 : Color.accentColor.opacity(0.35)))
                        .frame(height: barHeight(item.count, maxCount: maxCount))
                        .frame(maxWidth: .infinity)
                    // Invisible labels keep every column the same height so
                    // the bars share one baseline.
                    Text(String(item.year))
                        .font(.caption2)
                        .foregroundStyle(isOn ? .primary : .secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .opacity(showLabel ? 1 : 0)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    selected = isOn ? nil : item.year
                }
            }
        }
    }

    private func barHeight(_ count: Int, maxCount: Int) -> CGFloat {
        guard count > 0 else { return 3 }  // empty years stay visible as a sliver
        return max(8, maxBarHeight * CGFloat(count) / CGFloat(maxCount))
    }
}

// MARK: - People picker

/// Face-circle picker reused by both Together entry points: multi-select from
/// PeopleView (Done enables at 2+), or single-pick from PersonPhotosView
/// ("Together with…" — the viewed person is excluded and pre-counted).
struct TogetherPickerSheet: View {
    /// Cluster to hide from the list (the person already being viewed).
    var excludeID: Int? = nil
    /// true → tapping a row picks immediately (no Done button).
    var singlePick = false
    let onDone: ([PersonCluster]) -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = PhotoStore.shared
    @State private var selectedIDs: [Int] = []   // ordered, so the title reads in pick order

    private var people: [PersonCluster] {
        guard let excludeID else { return store.activeClusters }
        // Resolve through merges so a pre-merge alias of the viewed person
        // can't be offered as their own "other" person.
        let excluded = store.resolvedClusterID(excludeID)
        return store.activeClusters.filter { store.resolvedClusterID($0.id) != excluded }
    }

    var body: some View {
        NavigationStack {
            Group {
                if people.isEmpty {
                    ContentUnavailableView(
                        "No other people",
                        systemImage: "person.2",
                        description: Text("More people appear here as your library is indexed.")
                    )
                } else {
                    List(people) { cluster in
                        row(cluster)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle(singlePick ? "Together With" : "Choose People")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                if !singlePick {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") {
                            let picked = selectedIDs.compactMap { id in
                                people.first { $0.id == id }
                            }
                            dismiss()
                            onDone(picked)
                        }
                        .disabled(selectedIDs.count < 2)
                    }
                }
            }
        }
    }

    private func row(_ cluster: PersonCluster) -> some View {
        let isSelected = selectedIDs.contains(cluster.id)
        return Button {
            if singlePick {
                dismiss()
                onDone([cluster])
            } else if isSelected {
                selectedIDs.removeAll { $0 == cluster.id }
            } else {
                selectedIDs.append(cluster.id)
            }
        } label: {
            HStack(spacing: 14) {
                PHFaceView(assetID: cluster.representativeAssetID, faceRect: cluster.faceRect)
                    .frame(width: 52, height: 52)
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text((cluster.name?.isEmpty == false) ? cluster.name! : "Unnamed")
                    Text("\(cluster.photoCount) photos")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if !singlePick {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                }
            }
        }
        .buttonStyle(.plain)
    }
}
