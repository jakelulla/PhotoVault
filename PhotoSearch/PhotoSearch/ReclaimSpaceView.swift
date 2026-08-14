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
        var assetIDs: [String]
        var estimatedBytes: Int64
        var id: String { kind.rawValue }
    }

    @Published private(set) var buckets: [Bucket] = []
    @Published private(set) var scanning = false
    @Published private(set) var hasScanned = false

    var totalBytes: Int64 { buckets.reduce(0) { $0 + $1.estimatedBytes } }
    var totalCount: Int { buckets.reduce(0) { $0 + $1.assetIDs.count } }

    /// One photo's inputs to classification — a plain value so the scan can
    /// leave the main actor (PhotoStore is @MainActor; PHAsset is not).
    private struct Candidate: Sendable {
        let assetID: String
        let sharpness: Float?
        let dupGroupID: String?
        let isVideo: Bool
        let duration: Double
    }

    func scan() async {
        guard !scanning else { return }
        scanning = true
        defer { scanning = false; hasScanned = true }

        let candidates = PhotoStore.shared.allPhotos().map {
            Candidate(assetID: $0.assetID, sharpness: $0.sharpness, dupGroupID: $0.dupGroupID,
                      isVideo: $0.video, duration: $0.duration ?? 0)
        }
        buckets = await Task.detached { Self.classify(candidates) }.value
    }

    // MARK: - Classification

    /// Buckets are mutually exclusive — a photo claimed by an earlier bucket
    /// can't be claimed again, or the same bytes would be counted twice in the
    /// headline total. Precedence runs most-certain to least: an exact
    /// screenshot flag, then duplicate-group membership, then a purely
    /// relative blur judgement.
    private nonisolated static func classify(_ candidates: [Candidate]) -> [Bucket] {
        let assets = fetchAssets(for: candidates.map(\.assetID))
        var claimed = Set<String>()
        var buckets: [Bucket] = []

        func bytes(_ c: Candidate, screenshot: Bool) -> Int64 {
            estimatedBytes(assets[c.assetID], isVideo: c.isVideo, duration: c.duration,
                           screenshot: screenshot)
        }

        // 1. Screenshots — Photos records this exactly, so no inference and no
        //    false positives (the CLIP auto-category is a fuzzy guess by
        //    comparison, and this is free).
        var shotIDs: [String] = []
        var shotBytes: Int64 = 0
        for c in candidates {
            guard let a = assets[c.assetID],
                  a.mediaSubtypes.contains(.photoScreenshot) else { continue }
            shotIDs.append(c.assetID)
            shotBytes += bytes(c, screenshot: true)
            claimed.insert(c.assetID)
        }
        if !shotIDs.isEmpty {
            buckets.append(Bucket(kind: .screenshots, title: "Screenshots",
                                  icon: "camera.viewfinder",
                                  blurb: "Flagged by iOS, not guessed.",
                                  assetIDs: shotIDs, estimatedBytes: shotBytes))
        }

        // 2. Duplicate extras — every member of a near-duplicate group except
        //    its sharpest, which is the one worth keeping.
        var groups: [String: [Candidate]] = [:]
        for c in candidates where !claimed.contains(c.assetID) {
            guard let g = c.dupGroupID else { continue }
            groups[g, default: []].append(c)
        }
        var dupIDs: [String] = []
        var dupBytes: Int64 = 0
        for (_, members) in groups where members.count > 1 {
            let sorted = members.sorted { ($0.sharpness ?? 0) > ($1.sharpness ?? 0) }
            for c in sorted.dropFirst() {
                dupIDs.append(c.assetID)
                dupBytes += bytes(c, screenshot: false)
                claimed.insert(c.assetID)
            }
        }
        if !dupIDs.isEmpty {
            buckets.append(Bucket(kind: .duplicates, title: "Duplicate extras",
                                  icon: "square.on.square",
                                  blurb: "Keeps the sharpest of each group.",
                                  assetIDs: dupIDs, estimatedBytes: dupBytes))
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
                                  estimatedBytes: worst.reduce(0) { $0 + bytes($1, screenshot: false) }))
        }
        return buckets
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

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 3)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 3) {
                ForEach(bucket.assetIDs, id: \.self) { id in
                    Button { toggle(id) } label: {
                        PHImageView(assetID: id, targetSize: CGSize(width: 220, height: 220))
                            .aspectRatio(1, contentMode: .fill)
                            .clipped()
                            .overlay(alignment: .bottomTrailing) {
                                Image(systemName: selected.contains(id)
                                      ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(.white, selected.contains(id) ? Color.accentColor : .black.opacity(0.4))
                                    .padding(4)
                            }
                            .overlay {
                                if selected.contains(id) {
                                    Rectangle().strokeBorder(Color.accentColor, lineWidth: 3)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
        }
        .navigationTitle(bucket.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(selected.count == bucket.assetIDs.count ? "Deselect All" : "Select All") {
                    selected = selected.count == bucket.assetIDs.count ? [] : Set(bucket.assetIDs)
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
            // Blurry is a relative guess, so it opens with nothing selected —
            // the user opts in per photo. The other two are factual.
            if selected.isEmpty && bucket.kind != .blurry {
                selected = Set(bucket.assetIDs)
            }
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
