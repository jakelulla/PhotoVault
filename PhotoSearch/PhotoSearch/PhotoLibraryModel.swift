import AVFoundation
import Photos
import SwiftUI

/// Photo-library authorization + access to the device's photos. The Photos tab
/// shows these immediately; the Indexer ships them to the Mac for embedding.
@MainActor
final class PhotoLibraryModel: ObservableObject {
    @Published var status: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @Published var assets: [PHAsset] = []

    private let imageManager = PHCachingImageManager()

    var isAuthorized: Bool { status == .authorized || status == .limited }

    func refreshStatus() {
        status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if isAuthorized && assets.isEmpty { fetchAssets() }
    }

    func requestAccess() {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] newStatus in
            Task { @MainActor in
                guard let self else { return }
                self.status = newStatus
                if self.isAuthorized { self.fetchAssets() }
            }
        }
    }

    func fetchAssets() {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(format: "mediaType == %d OR mediaType == %d",
                                        PHAssetMediaType.image.rawValue,
                                        PHAssetMediaType.video.rawValue)
        let result = PHAsset.fetchAssets(with: options)
        var fetched: [PHAsset] = []
        fetched.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in fetched.append(asset) }
        assets = fetched
    }

    func requestImage(for asset: PHAsset, targetSize: CGSize, contentMode: PHImageContentMode,
                      completion: @escaping (UIImage?) -> Void) {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        imageManager.requestImage(for: asset, targetSize: targetSize, contentMode: contentMode,
                                  options: options) { image, _ in completion(image) }
    }

    /// Full-resolution image for the full-screen viewer (sharp, zoomable).
    /// `.highQualityFormat` returns the full original once (downloading from
    /// iCloud if needed), rather than a cached thumbnail.
    func requestFullImage(for asset: PHAsset, completion: @escaping (UIImage?) -> Void) {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .none
        imageManager.requestImage(
            for: asset,
            targetSize: PHImageManagerMaximumSize,
            contentMode: .aspectFit,
            options: options
        ) { image, info in
            // Ignore the degraded placeholder; only show the final full image.
            let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            if let image, !degraded { completion(image) }
        }
    }

    /// Evenly spaced frames from a video (10%/50%/90%), JPEG-encoded at
    /// ≤1280px — the indexer CLIP-embeds each and averages so a video is
    /// findable by anything that appears in it, and faces are picked up
    /// from every sampled frame.
    func videoFrameData(for asset: PHAsset, maxPixel: CGFloat = 1280) async -> [Data] {
        let avAsset: AVAsset? = await withCheckedContinuation { cont in
            let opts = PHVideoRequestOptions()
            opts.isNetworkAccessAllowed = true
            opts.deliveryMode = .mediumQualityFormat
            PHImageManager.default().requestAVAsset(forVideo: asset, options: opts) { av, _, _ in
                cont.resume(returning: av)
            }
        }
        guard let avAsset else { return [] }
        let gen = AVAssetImageGenerator(asset: avAsset)
        gen.appliesPreferredTrackTransform = true   // bakes in rotation metadata
        gen.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        let duration = asset.duration > 0 ? asset.duration
            : ((try? await avAsset.load(.duration).seconds) ?? 0)
        let fractions: [Double] = duration > 3 ? [0.1, 0.5, 0.9] : [0.5]
        var frames: [Data] = []
        for f in fractions {
            let t = CMTime(seconds: max(0, duration * f), preferredTimescale: 600)
            if let cg = try? await gen.image(at: t).image,
               let jpeg = UIImage(cgImage: cg).jpegData(compressionQuality: 0.85) {
                frames.append(jpeg)
            }
        }
        return frames
    }

    /// A downscaled JPEG (longest side ~`maxPixel`) for the one-time metadata
    /// backfill — much cheaper than the full original, and its perceptual hash
    /// still matches the full-res upload so the backend dedups against it.
    /// `.highQualityFormat` yields a single (non-degraded) callback, so the
    /// continuation resumes exactly once.
    func thumbnailData(for asset: PHAsset, maxPixel: CGFloat) async -> Data? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .fast
            let target = CGSize(width: maxPixel, height: maxPixel)
            imageManager.requestImage(for: asset, targetSize: target, contentMode: .aspectFit,
                                      options: options) { image, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if degraded { return }   // wait for the final, full-quality result
                continuation.resume(returning: image?.jpegData(compressionQuality: 0.9))
            }
        }
    }
}
