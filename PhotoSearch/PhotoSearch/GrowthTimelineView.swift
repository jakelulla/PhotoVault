import Photos
import SwiftUI
import UIKit

/// "Watch Them Grow" — one best face of a person per calendar year, with a
/// scrubbable filmstrip and a shareable collage. Data comes from
/// store.growthTimeline: best face per year by sharpness × √(face area),
/// falling back to the year's latest whole photo when per-photo face data
/// hasn't been backfilled yet (rect == nil).
struct GrowthTimelineView: View {
    let cluster: PersonCluster

    @ObservedObject private var store = PhotoStore.shared
    @State private var entries: [YearFace] = []
    @State private var loaded = false
    @State private var selection = 0
    @State private var collage: UIImage?
    @State private var buildingCollage = false
    @State private var showShare = false

    private var personName: String {
        (cluster.name?.isEmpty == false) ? cluster.name! : "This person"
    }

    /// entries can shrink mid-session (recluster/merge while we're open) —
    /// never index the array with a stale selection.
    private var sel: Int { min(selection, max(0, entries.count - 1)) }

    var body: some View {
        Group {
            if !loaded {
                ProgressView()
            } else if entries.count < 2 {
                ContentUnavailableView(
                    "Need photos from more than one year",
                    systemImage: "calendar",
                    description: Text("\(personName) only has photos from a single year so far. The timeline lights up once there's more than one.")
                )
            } else {
                timeline
            }
        }
        .navigationTitle("Watch Them Grow")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if buildingCollage {
                    ProgressView()
                } else {
                    Button { buildCollage() } label: {
                        Label("Share Collage", systemImage: "square.and.arrow.up")
                    }
                    .disabled(entries.count < 2)
                }
            }
        }
        // Keyed on membershipVersion so merges/reclusters refresh the strip;
        // growthTimeline walks the person's photos, so don't call it per body.
        .task(id: store.membershipVersion) {
            entries = store.growthTimeline(forCluster: cluster.id)
            loaded = true
        }
        .sheet(isPresented: $showShare) {
            if let collage {
                ActivityShareSheet(items: [collage])
                    .presentationDetents([.medium, .large])
            }
        }
    }

    // MARK: - Timeline

    private var timeline: some View {
        VStack(spacing: 20) {
            bigCrop
            filmstrip
            Spacer(minLength: 0)
        }
        .padding()
    }

    private var bigCrop: some View {
        GeometryReader { geo in
            let side = geo.size.width
            ZStack {
                // Selected ±1 stay mounted (just hidden) so the neighbor's
                // image has already loaded by the time a scrub lands on it.
                ForEach(neighborIndices, id: \.self) { i in
                    cropView(entries[i])
                        .frame(width: side, height: side)
                        .clipped()
                        .opacity(i == sel ? 1 : 0)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(alignment: .bottomLeading) {
                Text(verbatim: String(entries[sel].year))
                    .font(.system(size: 42, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.6), radius: 5)
                    .padding(14)
            }
            .animation(.easeInOut(duration: 0.2), value: sel)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private var neighborIndices: [Int] {
        let lo = max(0, sel - 1)
        let hi = min(entries.count - 1, sel + 1)
        return Array(lo...hi)
    }

    @ViewBuilder
    private func cropView(_ entry: YearFace) -> some View {
        if let rect = entry.rect {
            PHFaceView(assetID: entry.assetID, faceRect: rect)
        } else {
            // Pre-backfill year: no face rect stored, show the whole photo.
            PHImageView(assetID: entry.assetID, targetSize: CGSize(width: 900, height: 900))
        }
    }

    private var filmstrip: some View {
        GeometryReader { geo in
            let count = entries.count
            let cellW = geo.size.width / CGFloat(count)
            let dim = max(24, min(56, cellW - 8))
            // Hide captions that would collide when years outnumber the width.
            // Guard the divisor: a zero-width layout pass (cellW == 0) makes
            // 34/cellW non-finite and Int() of that traps.
            let labelStride = cellW >= 1 ? max(1, Int((34 / cellW).rounded(.up))) : 1
            HStack(spacing: 0) {
                ForEach(entries.indices, id: \.self) { i in
                    VStack(spacing: 4) {
                        cropView(entries[i])
                            .frame(width: dim, height: dim)
                            .clipShape(Circle())
                            .overlay(
                                Circle().stroke(i == sel ? Color.accentColor : Color(.systemFill),
                                                lineWidth: 2)
                            )
                            .scaleEffect(i == sel ? 1.1 : 1)
                        Text(verbatim: String(entries[i].year))
                            .font(.caption2)
                            .foregroundStyle(i == sel ? .primary : .secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .opacity(i % labelStride == 0 ? 1 : 0)
                    }
                    .frame(width: cellW)
                }
            }
            .contentShape(Rectangle())
            // minimumDistance 0 makes a plain tap select too — one gesture
            // covers both tap-to-select and continuous scrubbing.
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let i = max(0, min(count - 1, Int(v.location.x / cellW)))
                        if i != selection {
                            withAnimation(.easeInOut(duration: 0.15)) { selection = i }
                        }
                    }
            )
        }
        .frame(height: 86)
        .sensoryFeedback(.selection, trigger: selection)
    }

    // MARK: - Collage export

    private func buildCollage() {
        buildingCollage = true
        let items = entries
        // Image fetches + orientation normalization + grid rendering are all
        // CPU work — keep them off the main actor; only the share
        // presentation hops back.
        Task.detached(priority: .userInitiated) {
            let image = await GrowthCollage.build(entries: items)
            await MainActor.run {
                buildingCollage = false
                collage = image
                showShare = image != nil
            }
        }
    }
}

// MARK: - Collage builder

/// Renders the year-by-year face grid into a single shareable UIImage.
/// Crop math mirrors PHFaceView (orient-up first, then crop with 10% padding)
/// — duplicated here as a small helper per the no-touch rule on PHImageView.swift.
private enum GrowthCollage {
    static let cellSide: CGFloat = 480
    static let labelHeight: CGFloat = 64

    static func build(entries: [YearFace]) async -> UIImage? {
        var crops: [(year: Int, image: UIImage)] = []
        for entry in entries {
            if let img = await faceImage(assetID: entry.assetID, rect: entry.rect) {
                crops.append((entry.year, img))
            }
        }
        guard !crops.isEmpty else { return nil }

        let cols = Int(ceil(Double(crops.count).squareRoot()))
        let rows = Int(ceil(Double(crops.count) / Double(cols)))
        let size = CGSize(width: CGFloat(cols) * cellSide,
                          height: CGFloat(rows) * (cellSide + labelHeight))
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1  // canvas size is already in pixels; @3x would triple memory
        return UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let para = NSMutableParagraphStyle()
            para.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 34, weight: .bold),
                .foregroundColor: UIColor.white,
                .paragraphStyle: para,
            ]
            for (i, item) in crops.enumerated() {
                let col = i % cols, row = i / cols
                let cell = CGRect(x: CGFloat(col) * cellSide,
                                  y: CGFloat(row) * (cellSide + labelHeight),
                                  width: cellSide, height: cellSide)
                drawAspectFill(item.image, in: cell, context: ctx.cgContext)
                let labelRect = CGRect(x: cell.minX, y: cell.maxY + 10,
                                       width: cellSide, height: labelHeight - 16)
                NSAttributedString(string: String(item.year), attributes: attrs)
                    .draw(in: labelRect)
            }
        }
    }

    /// Fetches the photo and crops to the face. Sizing mirrors PHFaceView:
    /// request enough pixels that the *crop* (not the whole photo) comes out
    /// ≥ ~512px — a face that's 15% of the frame needs the photo at ~3400px.
    static func faceImage(assetID: String, rect: CGRect?) async -> UIImage? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil)
                .firstObject else { return nil }
        let dim: CGFloat
        if let rect, rect != .zero {
            let faceFrac = max(min(rect.width, rect.height), 0.05)
            dim = min(512.0 / faceFrac, 2400.0)
        } else {
            dim = 1024
        }
        let opts = PHImageRequestOptions()
        opts.isNetworkAccessAllowed = true
        opts.deliveryMode = .highQualityFormat
        let img = await withCheckedContinuation { (cont: CheckedContinuation<UIImage?, Never>) in
            PHImageManager.default().requestImage(
                for: asset, targetSize: CGSize(width: dim, height: dim),
                contentMode: .aspectFit, options: opts
            ) { image, info in
                // highQualityFormat can still deliver a degraded preview
                // first; only resume on the final callback (same guard as
                // PHImageView, avoids double-resume crashes).
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if !degraded { cont.resume(returning: image) }
            }
        }
        guard let img else { return nil }
        guard let rect, rect != .zero else { return img }
        return faceCrop(img, to: rect)
    }

    /// EXIF-aware face crop — same math as PHFaceView.crop: the rect is in
    /// display-oriented coordinates, but cgImage.cropping(to:) operates on the
    /// raw (possibly rotated) bitmap, so normalize to .up before cropping.
    static func faceCrop(_ img: UIImage, to rect: CGRect) -> UIImage {
        let up: UIImage
        if img.imageOrientation == .up {
            up = img
        } else {
            let fmt = UIGraphicsImageRendererFormat.default()
            fmt.scale = 1
            up = UIGraphicsImageRenderer(size: img.size, format: fmt).image { _ in
                img.draw(in: CGRect(origin: .zero, size: img.size))
            }
        }
        guard let cgFull = up.cgImage else { return img }
        let iw = CGFloat(cgFull.width), ih = CGFloat(cgFull.height)
        let cropRect = CGRect(x: rect.minX * iw, y: rect.minY * ih,
                              width: rect.width * iw, height: rect.height * ih)
            .insetBy(dx: -rect.width * iw * 0.1, dy: -rect.height * ih * 0.1)  // 10% padding
            .intersection(CGRect(x: 0, y: 0, width: iw, height: ih))
        guard cropRect.width > 0, cropRect.height > 0,
              let cg = cgFull.cropping(to: cropRect) else { return img }
        return UIImage(cgImage: cg)
    }

    static func drawAspectFill(_ img: UIImage, in rect: CGRect, context: CGContext) {
        guard img.size.width > 0, img.size.height > 0 else { return }
        context.saveGState()
        context.addRect(rect)
        context.clip()
        let scale = max(rect.width / img.size.width, rect.height / img.size.height)
        let w = img.size.width * scale
        let h = img.size.height * scale
        img.draw(in: CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h))
        context.restoreGState()
    }
}

// MARK: - Share sheet

/// Minimal UIActivityViewController wrapper — ShareLink can't take a UIImage
/// without a Transferable shim, and the codebase has no existing wrapper.
private struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
