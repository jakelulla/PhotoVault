import Photos
import SwiftUI
import UIKit

/// Full-screen slideshow player: crossfading slides with a slow Ken Burns
/// drift, generative background music, and minimal controls (tap to reveal).
/// Photos load on demand at screen resolution with the next two prefetched;
/// videos appear as their poster frame (PHImageManager handles that).
struct SlideshowPlayerView: View {
    let slideshow: Slideshow

    @Environment(\.dismiss) private var dismiss

    @State private var index = 0
    @State private var playing = true
    @State private var showControls = true
    @State private var musicOn = true
    @State private var finished = false
    /// Increments every manual jump/replay so the auto-advance task restarts
    /// its clock (its .task(id:) keys off this + index).
    @State private var runID = 0

    @StateObject private var loader = SlideImageLoader()
    @State private var music = SlideshowMusic()

    /// Seconds each slide holds (crossfade rides inside it).
    private let slideSeconds: Double = 4.0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Current slide, crossfaded by keying the view on the index.
            if let image = loader.image(at: index) {
                SlideImage(image: image, zoomIn: index.isMultiple(of: 2))
                    .id(index)
                    .transition(.opacity.animation(.easeInOut(duration: 1.1)))
            } else {
                ProgressView().tint(.white)
            }

            if finished { replayOverlay }
            if showControls && !finished { controls }
        }
        .statusBarHidden(!showControls)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) { showControls.toggle() }
        }
        .task {
            loader.configure(assetIDs: slideshow.assetIDs)
            loader.prefetch(around: 0)
            if musicOn { music.start(mood: slideshow.mood) }
            scheduleControlsAutoHide()
        }
        // The advance clock: one slide per firing; restarts whenever the index
        // moves (auto or manual) so every slide gets its full duration.
        .task(id: "\(index)-\(runID)-\(playing)") {
            guard playing, !finished else { return }
            try? await Task.sleep(nanoseconds: UInt64(slideSeconds * 1_000_000_000))
            guard !Task.isCancelled, playing, !finished else { return }
            advance()
        }
        .onChange(of: index) { _, new in
            loader.prefetch(around: new)
        }
        .onDisappear {
            music.stop()
        }
    }

    // MARK: - Pieces

    private var controls: some View {
        VStack {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(slideshow.title)
                        .font(.headline)
                        .foregroundStyle(.white)
                    if let subtitle = slideshow.subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                Spacer()
                Button {
                    music.stop()
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title)
                        .foregroundStyle(.white, .black.opacity(0.4))
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)

            Spacer()

            VStack(spacing: 14) {
                ProgressView(value: Double(index + 1), total: Double(slideshow.assetIDs.count))
                    .tint(.white)
                    .padding(.horizontal, 24)
                HStack(spacing: 44) {
                    Button { back() } label: {
                        Image(systemName: "backward.fill")
                    }
                    Button {
                        playing.toggle()
                        scheduleControlsAutoHide()
                    } label: {
                        Image(systemName: playing ? "pause.fill" : "play.fill")
                            .font(.title)
                    }
                    Button { advance(manual: true) } label: {
                        Image(systemName: "forward.fill")
                    }
                    Button {
                        musicOn.toggle()
                        if musicOn { music.start(mood: slideshow.mood) } else { music.stop() }
                    } label: {
                        Image(systemName: musicOn ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    }
                }
                .font(.title3)
                .foregroundStyle(.white)
                Text("\(index + 1) of \(slideshow.assetIDs.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(.bottom, 30)
        }
        .background(
            VStack {
                LinearGradient(colors: [.black.opacity(0.5), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 120)
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 170)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        )
        .transition(.opacity)
    }

    private var replayOverlay: some View {
        VStack(spacing: 18) {
            Text("The End")
                .font(.title2.bold())
                .foregroundStyle(.white)
            HStack(spacing: 24) {
                Button {
                    finished = false
                    index = 0
                    runID += 1
                    playing = true
                    if musicOn { music.start(mood: slideshow.mood) }
                } label: {
                    Label("Replay", systemImage: "arrow.counterclockwise")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                Button {
                    dismiss()
                } label: {
                    Text("Done").padding(.horizontal, 6)
                }
                .buttonStyle(.bordered)
                .tint(.white)
            }
        }
        .padding(28)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 20))
    }

    // MARK: - Navigation

    private func advance(manual: Bool = false) {
        if index + 1 >= slideshow.assetIDs.count {
            finished = true
            playing = false
            music.stop()
            withAnimation(.easeInOut(duration: 0.2)) { showControls = false }
            return
        }
        index += 1
        if manual { runID += 1 }
    }

    private func back() {
        guard index > 0 else { return }
        index -= 1
        runID += 1
    }

    private func scheduleControlsAutoHide() {
        guard playing else { return }
        Task {
            try? await Task.sleep(nanoseconds: 3_200_000_000)
            if playing, !finished {
                withAnimation(.easeInOut(duration: 0.4)) { showControls = false }
            }
        }
    }
}

// MARK: - One slide with a Ken Burns drift

/// Renders one image filling the screen with a slow zoom (in on even slides,
/// out on odd) — the classic Ken Burns feel without any per-frame timers.
private struct SlideImage: View {
    let image: UIImage
    let zoomIn: Bool

    @State private var animate = false

    var body: some View {
        GeometryReader { geo in
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: geo.size.width, height: geo.size.height)
                .scaleEffect(animate ? (zoomIn ? 1.12 : 1.0) : (zoomIn ? 1.0 : 1.12))
                .offset(x: animate ? (zoomIn ? -8 : 8) : 0)
                .clipped()
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.linear(duration: 5.6)) { animate = true }
        }
    }
}

// MARK: - Screen-resolution image loader with prefetch

/// Loads slides at screen resolution via PHImageManager, holding a small
/// sliding window (current ± 2) so long slideshows stay memory-bounded.
@MainActor
private final class SlideImageLoader: ObservableObject {
    @Published private var images: [Int: UIImage] = [:]
    private var assetIDs: [String] = []
    private var requested: Set<Int> = []
    private let manager = PHImageManager.default()

    func configure(assetIDs: [String]) {
        self.assetIDs = assetIDs
    }

    func image(at index: Int) -> UIImage? { images[index] }

    /// Ensure current ± 2 are loading; evict everything else.
    func prefetch(around index: Int) {
        let window = (index - 1)...(index + 2)
        for i in window where i >= 0 && i < assetIDs.count {
            load(i)
        }
        for key in images.keys where !window.contains(key) {
            images[key] = nil
            requested.remove(key)
        }
    }

    private func load(_ index: Int) {
        guard images[index] == nil, !requested.contains(index) else { return }
        requested.insert(index)
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [assetIDs[index]], options: nil)
        guard let asset = fetch.firstObject else { return }

        let scale = UIScreen.main.scale
        let bounds = UIScreen.main.bounds.size
        let target = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .opportunistic   // fast degraded, then final
        options.resizeMode = .fast
        manager.requestImage(for: asset, targetSize: target,
                             contentMode: .aspectFill, options: options) { [weak self] image, _ in
            guard let image else { return }
            Task { @MainActor [weak self] in
                self?.images[index] = image   // degraded then final overwrite
            }
        }
    }
}
