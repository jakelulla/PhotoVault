import Photos
import SwiftUI

/// "Reclaim Space": the three kinds of clutter almost every library
/// accumulates — screenshots, extra copies of the same shot, and the blurriest
/// frames — gathered into reviewable buckets with a running size estimate.
///
/// Unlike the app's own delete (a soft, app-only hide — see
/// `PhotoStore.deletePhoto`), this one really removes assets from the system
/// photo library, because hiding a screenshot inside PhotoVault frees exactly
/// zero bytes. iOS moves deletions to Recently Deleted for 30 days and shows
/// its own confirmation sheet, so the action is both confirmed twice and
/// recoverable.
@MainActor
final class ReclaimScanner: ObservableObject {

    struct Bucket: Identifiable {
        enum Kind: String { case screenshots, duplicates, blurry }
        let kind: Kind
        let title: String
        let icon: String
        let blurb: String
        /// Every photo the bucket shows — all of them selectable, including
        /// the one we suggest keeping. The suggestion is advice, not a rule.
        var assetIDs: [String]
        /// What starts ticked: the deletions we actually recommend.
        var suggestedIDs: Set<String> = []
        /// Size of the SUGGESTED deletions, not of everything shown — the
        /// headline figure has to describe the default action.
        var estimatedBytes: Int64
        /// Duplicates only: each near-duplicate set, so the review screen can
        /// show the decision instead of hiding it.
        var groups: [DupGroup] = []
        /// Assets the user has signalled they care about — favourited or
        /// edited. Still listed, never pre-selected, and badged in the UI.
        var protectedIDs: Set<String> = []
        var id: String { kind.rawValue }
    }

    /// One near-duplicate set. Every member is deletable; `suggestedKeepID`
    /// is only the photo we propose surviving, so the user can keep a
    /// different one, delete the suggested one, or delete the whole group.
    struct DupGroup: Identifiable, Sendable {
        let id: String
        /// All members, suggested keeper first.
        let memberIDs: [String]
        let suggestedKeepID: String
        let keepReason: String
    }

    /// Which photo survives a duplicate group. Favourites and edits always win
    /// regardless; this only breaks the remaining ties.
    enum KeepRule: String, CaseIterable, Identifiable {
        case sharpest, newest
        var id: String { rawValue }
        var label: String { self == .sharpest ? "Sharpest" : "Newest" }
    }

    @Published private(set) var buckets: [Bucket] = []
    @Published private(set) var scanning = false
    @Published private(set) var hasScanned = false

    var totalBytes: Int64 { buckets.reduce(0) { $0 + $1.estimatedBytes } }
    /// Counts the suggested deletions, not every photo on screen — otherwise
    /// the headline would include photos we are recommending you keep.
    var totalCount: Int { buckets.reduce(0) { $0 + $1.suggestedIDs.count } }

    /// One photo's inputs to classification — a plain value so the scan can
    /// leave the main actor (PhotoStore is @MainActor; PHAsset is not).
    private struct Candidate: Sendable {
        let assetID: String
        let sharpness: Float?
        let dupGroupID: String?
        let isVideo: Bool
        let duration: Double
        let createdAt: Date?
    }

    /// Tie-break for which photo survives a duplicate group. Exposed in the UI
    /// because the app's other duplicate sweep keeps the NEWEST — leaving the
    /// two screens silently disagreeing was worse than making the rule visible.
    @Published var keepRule: KeepRule = .sharpest {
        didSet { guard oldValue != keepRule else { return }; Task { await scan() } }
    }

    func scan() async {
        guard !scanning else { return }
        scanning = true
        defer { scanning = false; hasScanned = true }

        let candidates = PhotoStore.shared.allPhotos().map {
            Candidate(assetID: $0.assetID, sharpness: $0.sharpness, dupGroupID: $0.dupGroupID,
                      isVideo: $0.video, duration: $0.duration ?? 0, createdAt: $0.createdAt)
        }
        let rule = keepRule
        buckets = await Task.detached { Self.classify(candidates, rule: rule) }.value
    }

    // MARK: - Classification

    /// Buckets are mutually exclusive — a photo claimed by an earlier bucket
    /// can't be claimed again, or the same bytes would be counted twice in the
    /// headline total. Precedence runs most-certain to least: an exact
    /// screenshot flag, then duplicate-group membership, then a purely
    /// relative blur judgement.
    private nonisolated static func classify(_ candidates: [Candidate], rule: KeepRule) -> [Bucket] {
        let assets = fetchAssets(for: candidates.map(\.assetID))
        var claimed = Set<String>()
        var buckets: [Bucket] = []

        /// Favouriting is the clearest signal a user cares about a specific
        /// photo. Cheap to read — it is a property on the already-fetched asset.
        func isFavourite(_ id: String) -> Bool { assets[id]?.isFavorite ?? false }

        func bytes(_ c: Candidate, screenshot: Bool) -> Int64 {
            estimatedBytes(assets[c.assetID], isVideo: c.isVideo, duration: c.duration,
                           screenshot: screenshot)
        }

        // 1. Screenshots — Photos records this exactly, so no inference and no
        //    false positives (the CLIP auto-category is a fuzzy guess by
        //    comparison, and this is free).
        var shotIDs: [String] = []
        var shotBytes: Int64 = 0
        var shotProtected = Set<String>()
        for c in candidates {
            guard let a = assets[c.assetID],
                  a.mediaSubtypes.contains(.photoScreenshot) else { continue }
            shotIDs.append(c.assetID)
            shotBytes += bytes(c, screenshot: true)
            if a.isFavorite { shotProtected.insert(c.assetID) }
            claimed.insert(c.assetID)
        }
        if !shotIDs.isEmpty {
            buckets.append(Bucket(kind: .screenshots, title: "Screenshots",
                                  icon: "camera.viewfinder",
                                  blurb: "Flagged by iOS, not guessed.",
                                  assetIDs: shotIDs,
                                  suggestedIDs: Set(shotIDs).subtracting(shotProtected),
                                  estimatedBytes: shotBytes,
                                  protectedIDs: shotProtected))
        }

        // 2. Duplicate extras. Every group keeps exactly one photo, and the
        //    review screen shows WHICH — a flat list of condemned photos with
        //    no sight of the survivor cannot be reviewed, only trusted.
        //
        //    Keeper precedence: a favourite wins, then an edited photo, then
        //    the chosen tie-break. Favouriting and editing are explicit acts of
        //    user intent and outrank any score we compute.
        var byGroup: [String: [Candidate]] = [:]
        for c in candidates where !claimed.contains(c.assetID) {
            guard let g = c.dupGroupID else { continue }
            byGroup[g, default: []].append(c)
        }

        var dupAll: [String] = []
        var dupSuggested = Set<String>()
        var dupBytes: Int64 = 0
        var dupGroups: [DupGroup] = []
        var dupProtected = Set<String>()

        for (gid, members) in byGroup where members.count > 1 {
            let edited = editedIDs(among: members.map(\.assetID), assets: assets)

            func rank(_ c: Candidate) -> (Int, Int, Double) {
                (isFavourite(c.assetID) ? 1 : 0,
                 edited.contains(c.assetID) ? 1 : 0,
                 rule == .sharpest ? Double(c.sharpness ?? 0)
                                   : (c.createdAt ?? .distantPast).timeIntervalSince1970)
            }
            let sorted = members.sorted { rank($0) > rank($1) }
            guard let keeper = sorted.first else { continue }

            let reason: String
            if isFavourite(keeper.assetID)          { reason = "Favourite" }
            else if edited.contains(keeper.assetID) { reason = "Edited" }
            else                                    { reason = rule.label }

            for c in sorted {
                dupAll.append(c.assetID)
                claimed.insert(c.assetID)
                if isFavourite(c.assetID) || edited.contains(c.assetID) {
                    dupProtected.insert(c.assetID)
                }
                // Suggested for deletion = everything except the keeper, minus
                // anything the user has signalled they care about.
                let isKeeper = c.assetID == keeper.assetID
                if !isKeeper && !dupProtected.contains(c.assetID) {
                    dupSuggested.insert(c.assetID)
                    dupBytes += bytes(c, screenshot: false)
                }
            }
            dupGroups.append(DupGroup(id: gid, memberIDs: sorted.map(\.assetID),
                                      suggestedKeepID: keeper.assetID, keepReason: reason))
        }

        if !dupGroups.isEmpty {
            buckets.append(Bucket(kind: .duplicates, title: "Duplicates",
                                  icon: "square.on.square",
                                  blurb: "One suggested keep per set — change or override it.",
                                  assetIDs: dupAll,
                                  suggestedIDs: dupSuggested,
                                  estimatedBytes: dupBytes,
                                  groups: dupGroups.sorted { $0.memberIDs.count > $1.memberIDs.count },
                                  protectedIDs: dupProtected))
        }

        // 3. Blurriest — RELATIVE, deliberately. Sharpness here is a Laplacian
        //    variance whose absolute scale depends on content and resolution,
        //    and nothing in the app has ever calibrated a "this is blurry"
        //    cutoff. So this is the bottom decile of the user's OWN library
        //    rather than a made-up constant, it excludes videos (whose stills
        //    aren't scored the same way), and it stays review-only — never a
        //    one-tap sweep — because a low score can still be a keeper.
        let scored = candidates.filter { !claimed.contains($0.assetID) && !$0.isVideo && $0.sharpness != nil }
        if scored.count >= 20 {
            let sorted = scored.sorted { ($0.sharpness ?? 0) < ($1.sharpness ?? 0) }
            let take = max(1, sorted.count / 10)
            let worst = Array(sorted.prefix(take))
            buckets.append(Bucket(kind: .blurry, title: "Blurriest",
                                  icon: "camera.metering.unknown",
                                  blurb: "Bottom 10% of your library — review before deleting.",
                                  assetIDs: worst.map(\.assetID),
                                  // Nothing suggested: a low score can still be
                                  // a keeper, so this bucket is opt-in per photo.
                                  suggestedIDs: [],
                                  estimatedBytes: worst.reduce(0) { $0 + bytes($1, screenshot: false) },
                                  protectedIDs: Set(worst.map(\.assetID).filter(isFavourite))))
        }
        return buckets
    }

    /// Which of these assets carry user edits. `assetResources` is a
    /// relatively heavy per-asset call, so this is only ever run over the
    /// members of a duplicate group — never the whole library.
    private nonisolated static func editedIDs(among ids: [String],
                                              assets: [String: PHAsset]) -> Set<String> {
        var out = Set<String>()
        for id in ids {
            guard let asset = assets[id] else { continue }
            let edited = PHAssetResource.assetResources(for: asset)
                .contains { $0.type == .adjustmentData }
            if edited { out.insert(id) }
        }
        return out
    }

    /// Batch-resolve local identifiers to PHAssets in one round trip.
    private nonisolated static func fetchAssets(for ids: [String]) -> [String: PHAsset] {
        guard !ids.isEmpty else { return [:] }
        var map: [String: PHAsset] = [:]
        let result = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        result.enumerateObjects { asset, _, _ in map[asset.localIdentifier] = asset }
        return map
    }

    /// Rough on-disk size. Deliberately an ESTIMATE from pixel count and
    /// duration: the exact byte size lives on an undocumented PHAssetResource
    /// key, and shipping a private-API read to win some decimal places is a
    /// bad trade. Every figure this feeds is prefixed "≈" in the UI.
    private nonisolated static func estimatedBytes(_ asset: PHAsset?, isVideo: Bool,
                                                   duration: Double, screenshot: Bool) -> Int64 {
        if isVideo {
            // ~2 MB/s is typical for 1080p HEVC; 4K runs far higher, so this
            // under-promises rather than over-promises.
            return Int64(max(duration, 1) * 2_000_000)
        }
        guard let asset else { return 1_500_000 }         // unresolved: a middling HEIC
        let pixels = Int64(asset.pixelWidth) * Int64(asset.pixelHeight)
        // HEIC of a photograph ≈ 0.25 B/px. A screenshot is flat UI, which
        // compresses much harder ≈ 0.15 B/px.
        return screenshot ? pixels * 15 / 100 : pixels / 4
    }
}

// MARK: - Hub

struct ReclaimSpaceView: View {
    @StateObject private var scanner = ReclaimScanner()

    var body: some View {
        List {
            if scanner.scanning {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Scanning your library…").foregroundStyle(.secondary)
                }
            } else if scanner.buckets.isEmpty && scanner.hasScanned {
                ContentUnavailableView("Nothing to clean up",
                                       systemImage: "sparkles",
                                       description: Text("No screenshots, duplicate extras, or unusually blurry photos were found."))
            } else {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("≈ \(formatted(scanner.totalBytes))")
                            .font(.largeTitle.bold())
                        Text("\(scanner.totalCount) item\(scanner.totalCount == 1 ? "" : "s") you can review")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                } footer: {
                    Text("Sizes are estimates. Deleting moves items to Recently Deleted, where iOS keeps them for 30 days.")
                }

                // The keep rule is surfaced rather than hidden: the Photos
                // tab's duplicate sweep keeps the NEWEST of a group, so an
                // invisible "sharpest" rule here would have the two screens
                // quietly disagreeing about the same photos.
                if scanner.buckets.contains(where: { $0.kind == .duplicates }) {
                    Section {
                        Picker("Keep", selection: $scanner.keepRule) {
                            ForEach(ReclaimScanner.KeepRule.allCases) { rule in
                                Text(rule.label).tag(rule)
                            }
                        }
                        .pickerStyle(.segmented)
                    } header: {
                        Text("Which duplicate to keep")
                    } footer: {
                        Text("Favourited and edited photos are always kept, whichever rule is set, and are never pre-selected for deletion.")
                    }
                }

                Section("Found") {
                    ForEach(scanner.buckets) { bucket in
                        NavigationLink {
                            ReclaimBucketView(bucket: bucket) { await scanner.scan() }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: bucket.icon)
                                    .font(.title3)
                                    .foregroundStyle(.tint)
                                    .frame(width: 30)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(bucket.title)
                                    Text(bucket.blurb)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text("\(bucket.assetIDs.count)")
                                        .font(.subheadline.monospacedDigit())
                                    Text("≈ \(formatted(bucket.estimatedBytes))")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Reclaim Space")
        .task { if !scanner.hasScanned { await scanner.scan() } }
        .refreshable { await scanner.scan() }
    }

    private func formatted(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// Entry card for FoldersGrid, visually consistent with its siblings.
struct ReclaimSpaceEntryCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color(.secondarySystemBackground)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    Image(systemName: "internaldrive")
                        .font(.system(size: 40))
                        .foregroundStyle(.tint)
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
            Text("Reclaim Space")
                .font(.subheadline.bold())
                .lineLimit(1)
                .foregroundStyle(.primary)
            Text("Screenshots, dupes, blurry")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Bucket review

/// The review grid. Everything starts SELECTED for the two high-confidence
/// buckets and DESELECTED for the blurry one, matching how much the app
/// actually knows in each case.
private struct ReclaimBucketView: View {
    let bucket: ReclaimScanner.Bucket
    let onDeleted: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String> = []
    @State private var confirming = false
    @State private var deleting = false
    @State private var errorMessage: String?
    /// Guards the one-time default selection so re-appearing (after a sheet or
    /// a back-swipe) never silently re-ticks what the user unticked.
    @State private var didPrime = false

    // Same geometry as PhotoResultsGrid so this grid matches every other one
    // in the app: a fixed column count with the cell side computed from the
    // available width, rather than adaptive columns.
    private let spacing: CGFloat = 2
    private let columnCount = 3

    var body: some View {
        GeometryReader { geo in
            // Exact square side. PHImageView has no intrinsic size, so cells
            // must be given a frame — without one the images collapse and the
            // rows come out ragged.
            let side = (geo.size.width - spacing * CGFloat(columnCount - 1)) / CGFloat(columnCount)
            ScrollView {
                if bucket.groups.isEmpty {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: spacing),
                                       count: columnCount),
                        spacing: spacing
                    ) {
                        ForEach(bucket.assetIDs, id: \.self) { id in
                            Button { toggle(id) } label: {
                                cell(id: id, side: side)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } else {
                    // Duplicates: show each group as keeper + extras, so the
                    // decision is visible and correctable rather than implied.
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(bucket.groups) { group in
                            groupRow(group, side: min(side, 108))
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                }
            }
        }
        .navigationTitle(bucket.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if bucket.kind == .duplicates {
                        Button("Keep suggested in every set") { selected = bucket.suggestedIDs }
                        Button("Keep everything (clear)") { selected = [] }
                        Divider()
                        Button("Select every duplicate", role: .destructive) {
                            // Screen-wide, so it still skips favourited and
                            // edited photos — those need a deliberate tap, or
                            // a per-set "Keep: None".
                            selected = Set(bucket.assetIDs).subtracting(bucket.protectedIDs)
                        }
                    } else {
                        Button("Select suggested") { selected = bucket.suggestedIDs }
                        Button("Select all") {
                            selected = Set(bucket.assetIDs).subtracting(bucket.protectedIDs)
                        }
                        Button("Clear selection") { selected = [] }
                    }
                } label: {
                    Text("Select")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                confirming = true
            } label: {
                if deleting {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Text("Delete \(selected.count) item\(selected.count == 1 ? "" : "s")")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(selected.isEmpty || deleting)
            .padding()
            .background(.bar)
        }
        .onAppear {
            // The scanner already decided what to recommend: extras but not
            // keepers, nothing at all for the blurry bucket, and never a
            // favourited or edited photo. Everything shown stays selectable —
            // the suggestion is a starting point, not a constraint.
            if !didPrime { selected = bucket.suggestedIDs }
            didPrime = true
        }
        .confirmationDialog("Delete \(selected.count) item\(selected.count == 1 ? "" : "s")?",
                            isPresented: $confirming, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await performDelete() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They move to Recently Deleted in Photos and are removed for good after 30 days.")
        }
        .alert("Couldn't delete",
               isPresented: Binding(get: { errorMessage != nil },
                                    set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    /// One near-duplicate set. Every member is tappable, including the one we
    /// suggest keeping — so the user can keep a different photo, delete the
    /// suggested one, or select the whole set.
    @ViewBuilder
    private func groupRow(_ group: ReclaimScanner.DupGroup, side: CGFloat) -> some View {
        let keptCount = group.memberIDs.filter { !selected.contains($0) }.count
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("\(group.memberIDs.count) near-identical")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                // Live consequence of the current selection, stated plainly —
                // including the case where the whole set is being deleted.
                Text(keptCount == 0 ? "Deleting all"
                                    : "Keeping \(keptCount) of \(group.memberIDs.count)")
                    .font(.caption.bold())
                    .foregroundStyle(keptCount == 0 ? Color.red : Color.green)
            }
            // Per-set shortcuts, framed as KEEP — inside a set of near-identical
            // photos the question a person is actually asking is "which do I
            // keep?", not "which do I delete?". Tapping a photo still toggles
            // it, so "keep two of these" is: Keep None, then tap the two.
            HStack(spacing: 6) {
                Text("Keep:")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                keepButton("Suggested", group: group) {
                    selected.formUnion(group.memberIDs)
                    selected.remove(group.suggestedKeepID)
                }
                keepButton("All", group: group) {
                    selected.subtract(group.memberIDs)
                }
                keepButton("None", group: group) {
                    // Scoped and explicit, so this DOES include a favourited or
                    // edited photo — unlike the screen-wide bulk actions, which
                    // always skip them.
                    selected.formUnion(group.memberIDs)
                }
                Spacer()
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(group.memberIDs, id: \.self) { id in
                        VStack(spacing: 3) {
                            Button { toggle(id) } label: {
                                cell(id: id, side: side,
                                     suggestedKeep: id == group.suggestedKeepID)
                            }
                            .buttonStyle(.plain)
                            if id == group.suggestedKeepID {
                                Text(selected.contains(id) ? "was suggested" : group.keepReason)
                                    .font(.caption2)
                                    .foregroundStyle(selected.contains(id) ? Color.secondary : Color.green)
                            } else {
                                Text(" ").font(.caption2)
                            }
                        }
                    }
                }
                .padding(.bottom, 2)
            }
        }
        .padding(.bottom, 4)
    }

    /// A small per-set keep shortcut, highlighted when the set is already in
    /// that state so the current choice is visible at a glance.
    @ViewBuilder
    private func keepButton(_ title: String, group: ReclaimScanner.DupGroup,
                            action: @escaping () -> Void) -> some View {
        let kept = Set(group.memberIDs).subtracting(selected)
        let isActive: Bool = {
            switch title {
            case "Suggested": return kept == [group.suggestedKeepID]
            case "All":       return kept.count == group.memberIDs.count
            default:          return kept.isEmpty
            }
        }()
        Button(action: action) {
            Text(title)
                .font(.caption2.bold())
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(isActive ? Color.accentColor : Color(.tertiarySystemFill),
                            in: Capsule())
                .foregroundStyle(isActive ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }

    /// One square thumbnail. Requests at 2× the drawn side so it stays sharp on
    /// Retina, and takes its selection chrome from the same vocabulary the
    /// results grid uses. A protected photo — favourited or edited — is badged
    /// and never pre-selected.
    private func cell(id: String, side: CGFloat, suggestedKeep: Bool = false) -> some View {
        let isSel = selected.contains(id)
        let isProtected = bucket.protectedIDs.contains(id)
        // Green ring = this one survives the current selection.
        let ring: Color = isSel ? .accentColor : (suggestedKeep ? .green : .clear)
        return PHImageView(assetID: id,
                           targetSize: CGSize(width: side * 2, height: side * 2))
            .frame(width: side, height: side)
            .clipped()
            .contentShape(Rectangle())
            .opacity(isSel ? 0.55 : 1)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(ring, lineWidth: isSel ? 3 : (suggestedKeep ? 2 : 0))
            )
            .overlay(alignment: .topLeading) {
                if isProtected {
                    Image(systemName: "heart.fill")
                        .font(.caption2)
                        .foregroundStyle(.white)
                        .padding(3)
                        .background(.black.opacity(0.5), in: Circle())
                        .padding(4)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: isSel ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(.white, isSel ? Color.accentColor : .black.opacity(0.45))
                    .padding(5)
            }
    }

    private func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    private func performDelete() async {
        let ids = Array(selected)
        guard !ids.isEmpty else { return }
        deleting = true
        defer { deleting = false }

        let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        guard assets.count > 0 else {
            errorMessage = "Those photos are no longer in your library."
            return
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets)
            }
            // Keep the index consistent immediately rather than waiting on the
            // library change observer; pruneDeletedAssets also strips folder
            // membership, which is right — these are gone for good.
            PhotoStore.shared.pruneDeletedAssets(Set(ids))
            await onDeleted()
            dismiss()
        } catch {
            // The user declining the system confirmation lands here too, which
            // is not an error worth shouting about.
            let cancelled = (error as NSError).code == 3072
            if !cancelled { errorMessage = error.localizedDescription }
        }
    }
}
