import Photos
import SwiftUI
import UIKit

/// Loads and displays a photo library asset thumbnail using PHImageManager.
struct PHImageView: View {
    let assetID: String
    var targetSize: CGSize = CGSize(width: 300, height: 300)
    var contentMode: PHImageContentMode = .aspectFill

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Color(.secondarySystemBackground)
            }
        }
        .task(id: assetID) { await load() }
    }

    private func load() async {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil)
                .firstObject else { return }
        let opts = PHImageRequestOptions()
        opts.isNetworkAccessAllowed = true
        opts.deliveryMode = .opportunistic
        opts.resizeMode = .fast
        let img = await withCheckedContinuation { (cont: CheckedContinuation<UIImage?, Never>) in
            PHImageManager.default().requestImage(
                for: asset, targetSize: targetSize,
                contentMode: contentMode, options: opts
            ) { image, info in
                // .opportunistic can fire twice (degraded preview, then final).
                // Only resume on the final (non-degraded) callback to avoid
                // "checked continuation resumed twice" crash.
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if !degraded { cont.resume(returning: image) }
            }
        }
        image = img
    }
}

/// Full-resolution image from PHAsset — for the zoomable detail viewer.
struct PHFullImageView: View {
    let assetID: String
    @Binding var isZoomed: Bool

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                ZoomableImageView(image: image, onZoomChange: { isZoomed = $0 })
            } else {
                ProgressView().tint(.white)
            }
        }
        .task(id: assetID) { await load() }
    }

    private func load() async {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil)
                .firstObject else { return }
        let opts = PHImageRequestOptions()
        opts.isNetworkAccessAllowed = true
        opts.deliveryMode = .highQualityFormat
        opts.resizeMode = .none
        let img = await withCheckedContinuation { (cont: CheckedContinuation<UIImage?, Never>) in
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: PHImageManagerMaximumSize,
                contentMode: .aspectFit,
                options: opts
            ) { image, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if !degraded, let image { cont.resume(returning: image) }
            }
        }
        image = img
    }
}

/// Face thumbnail: loads the representative asset and crops to the stored face rect.
struct PHFaceView: View {
    let assetID: String
    let faceRect: CGRect  // normalized 0…1 in image space

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Color(.secondarySystemBackground)
            }
        }
        .task(id: assetID) { await load() }
    }

    private func load() async {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil)
                .firstObject else { return }
        // Request enough pixels that the *face crop* (not the whole photo)
        // comes out ≥ ~256px. A face that's 15% of the frame needs the photo
        // fetched at ~1700px — fetching at 200px and cropping gave ~30px
        // faces, which is why covers looked blurry.
        let faceFrac = max(min(faceRect.width, faceRect.height), 0.05)
        let dim = min(256.0 / faceFrac, 2048.0)
        let size = CGSize(width: dim, height: dim)
        let opts = PHImageRequestOptions()
        opts.isNetworkAccessAllowed = true
        opts.deliveryMode = .highQualityFormat
        let img = await withCheckedContinuation { (cont: CheckedContinuation<UIImage?, Never>) in
            PHImageManager.default().requestImage(
                for: asset, targetSize: size,
                contentMode: .aspectFit, options: opts
            ) { image, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if !degraded { cont.resume(returning: image) }
            }
        }
        guard let img else { return }
        image = crop(img, to: faceRect)
    }

    private func crop(_ img: UIImage, to rect: CGRect) -> UIImage {
        guard rect != .zero else { return img }
        // Normalize to .up first: rect is in display-oriented coordinates,
        // but cgImage.cropping(to:) operates on the raw (possibly rotated)
        // bitmap. Cropping the raw bitmap with display coords grabs the
        // wrong region for any photo with an EXIF orientation.
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
}
