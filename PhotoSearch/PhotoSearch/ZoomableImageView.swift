import SwiftUI
import UIKit

/// A pinch-/double-tap-zoomable, pannable image backed by UIScrollView.
///
/// Lives inside a paging TabView: scrolling is disabled at minimum zoom so the
/// pager still swipes between photos, and enabled once zoomed so you can pan.
/// Pinch zooms toward your fingers; double-tap toggles fit <-> 3x zoomed to the
/// image center.
struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage
    /// Reports whether the image is currently zoomed in (so the parent can
    /// disable swipe-to-dismiss while zoomed — a drag should pan instead).
    var onZoomChange: ((Bool) -> Void)? = nil

    func makeUIView(context: Context) -> ImageZoomScrollView {
        let view = ImageZoomScrollView()
        view.image = image
        view.onZoomChange = onZoomChange
        return view
    }

    func updateUIView(_ view: ImageZoomScrollView, context: Context) {
        view.onZoomChange = onZoomChange
        if view.image !== image { view.image = image }
    }
}

/// UIScrollView that zooms/pans a single image, kept centered, with the content
/// sized to the image so zoom focal point and panning behave natively.
final class ImageZoomScrollView: UIScrollView, UIScrollViewDelegate {
    var onZoomChange: ((Bool) -> Void)?

    private let imageView = UIImageView()
    private var configuredFor: CGSize = .zero   // bounds size we last set zoom scales for

    var image: UIImage? {
        didSet {
            imageView.image = image
            imageView.frame = CGRect(origin: .zero, size: image?.size ?? .zero)
            contentSize = image?.size ?? .zero
            configuredFor = .zero               // force re-fit on next layout
            setNeedsLayout()
        }
    }

    init() {
        super.init(frame: .zero)
        delegate = self
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        backgroundColor = .clear
        bouncesZoom = true
        decelerationRate = .fast
        contentInsetAdjustmentBehavior = .never
        isScrollEnabled = false                 // pager swipes until zoomed in

        imageView.contentMode = .scaleToFill     // frame matches image, so no distortion
        addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let image, image.size.width > 0, bounds.width > 0 else { return }

        // (Re)compute the fit scale whenever the available size changes.
        if configuredFor != bounds.size {
            configuredFor = bounds.size
            let fit = min(bounds.width / image.size.width, bounds.height / image.size.height)
            minimumZoomScale = fit
            maximumZoomScale = fit * 5
            zoomScale = fit                      // start fitted to screen
            isScrollEnabled = false
        }
        centerImage()
    }

    /// Keep the image centered when it's smaller than the viewport (and while zooming).
    private func centerImage() {
        let insetX = max(0, (bounds.width - contentSize.width) / 2)
        let insetY = max(0, (bounds.height - contentSize.height) / 2)
        contentInset = UIEdgeInsets(top: insetY, left: insetX, bottom: insetY, right: insetX)
    }

    private var isZoomedIn: Bool { zoomScale > minimumZoomScale * 1.01 }

    // MARK: UIScrollViewDelegate

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImage()
        // Pan only makes sense once zoomed; otherwise let the pager swipe.
        isScrollEnabled = isZoomedIn
        onZoomChange?(isZoomedIn)
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        if isZoomedIn {
            setZoomScale(minimumZoomScale, animated: true)
        } else {
            // Zoom toward the point that was double-tapped.
            let point = gesture.location(in: imageView)
            let target = min(minimumZoomScale * 3, maximumZoomScale)
            let w = bounds.width / target
            let h = bounds.height / target
            let rect = CGRect(
                x: point.x - w / 2,
                y: point.y - h / 2,
                width: w, height: h
            )
            zoom(to: rect, animated: true)
        }
    }
}
