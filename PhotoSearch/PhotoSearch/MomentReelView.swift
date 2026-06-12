import AVFoundation
import Photos
import SwiftUI
import UIKit

// MARK: - MomentReelView

/// Full-screen, auto-playing "moment reel" over videoMoments(matching:) hits.
/// For each hit we seek the video to just before the matched frame and play a
/// ~5 s window, then auto-advance — story-player UX over your own library.
/// Presented via .fullScreenCover from SearchView.
struct MomentReelView: View {
    let hits: [MomentHit]
    let title: String

    @StateObject private var model: ReelPlayerModel
    @State private var chromeVisible = true
    @State private var showingExport = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    init(hits: [MomentHit], title: String) {
        self.hits = hits
        self.title = title
        _model = StateObject(wrappedValue: ReelPlayerModel(hits: hits))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if hits.isEmpty {
                // The caller guards against empty hits, but defend anyway so a
                // stray presentation explains itself instead of a black void.
                ContentUnavailableView("No Moments", systemImage: "film",
                                       description: Text("No video moments to play."))
            } else if model.exhausted {
                // Every hit failed to load (e.g. iCloud-only videos, offline).
                // Without this terminal state the reel would skip-loop forever.
                ContentUnavailableView("Couldn't Play Videos", systemImage: "wifi.exclamationmark",
                                       description: Text("These videos couldn't be loaded — they may be in iCloud and unavailable right now."))
            } else {
                PlayerLayerView(player: model.player)
                    .ignoresSafeArea()

                if model.isLoading {
                    ProgressView().tint(.white)
                }

                tapZones

                if chromeVisible {
                    chrome.transition(.opacity)
                }
            }

            // The chrome owns the close button in the playing state; the
            // empty/exhausted states still need a way out.
            if hits.isEmpty || model.exhausted {
                standaloneCloseButton
            }
        }
        .environment(\.colorScheme, .dark)
        .swipeToDismiss(isEnabled: true)
        .statusBarHidden()
        .onAppear { model.start() }
        .onDisappear { model.teardown() }
        // Backgrounding/locking pauses the AVPlayer behind the model's back
        // (isPaused still reads false) — re-kick playback on return or the
        // reel sits frozen under playing-state chrome.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.resumeIfNeeded() }
        }
        .onChange(of: showingExport) { _, showing in
            // Freeze playback while the export sheet is up; resume after.
            model.setPaused(showing)
        }
        .sheet(isPresented: $showingExport) {
            ReelExportSheet(hits: hits, title: title)
        }
    }

    // MARK: Tap zones

    /// Story-standard layout: left quarter rewinds, right quarter skips, the
    /// wide middle toggles the chrome. Long-press anywhere pauses.
    private var tapZones: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                tapZone(width: geo.size.width * 0.25) { model.skipBack() }
                tapZone(width: geo.size.width * 0.50) {
                    withAnimation(.easeInOut(duration: 0.15)) { chromeVisible.toggle() }
                }
                tapZone(width: geo.size.width * 0.25) { model.skipForward() }
            }
        }
    }

    private func tapZone(width: CGFloat, action: @escaping () -> Void) -> some View {
        Color.clear
            .frame(width: width)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .onLongPressGesture(minimumDuration: 0.35) { model.togglePause() }
    }

    // MARK: Chrome

    private var chrome: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                SegmentedProgressBar(count: hits.count,
                                     current: model.currentIndex,
                                     progress: model.segmentProgress)
                HStack(spacing: 12) {
                    chromeButton("xmark", label: "Close") { dismiss() }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(.headline).foregroundStyle(.white).lineLimit(1)
                        Text(subtitle)
                            .font(.caption).foregroundStyle(.white.opacity(0.8))
                    }
                    Spacer()
                    chromeButton("square.and.arrow.up", label: "Export Reel") {
                        showingExport = true
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .background(alignment: .top) {
                // Legibility scrim over bright video frames.
                LinearGradient(colors: [.black.opacity(0.55), .clear],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea(edges: .top)
                    .allowsHitTesting(false)
            }

            Spacer()

            Button { model.togglePause() } label: {
                Image(systemName: model.isPaused ? "play.fill" : "pause.fill")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(.black.opacity(0.35), in: Circle())
            }
            .accessibilityLabel(model.isPaused ? "Play" : "Pause")
            .padding(.bottom, 32)
        }
    }

    private func chromeButton(_ systemImage: String, label: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(.black.opacity(0.35), in: Circle())
        }
        .accessibilityLabel(label)
    }

    private var standaloneCloseButton: some View {
        VStack {
            HStack {
                chromeButton("xmark", label: "Close") { dismiss() }
                Spacer()
            }
            Spacer()
        }
        .padding(12)
    }

    private var subtitle: String {
        var parts = ["\(min(model.currentIndex, hits.count - 1) + 1) of \(hits.count)"]
        if model.currentIndex < hits.count,
           let date = hits[model.currentIndex].createdAt {
            parts.append(String(Calendar.current.component(.year, from: date)))
        }
        return parts.joined(separator: " • ")
    }
}

// MARK: - Segmented progress bar

/// One thin segment per hit; segments before the current one are full, the
/// current one fills as its 5 s window elapses.
private struct SegmentedProgressBar: View {
    let count: Int
    let current: Int
    let progress: Double

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<count, id: \.self) { i in
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.3))
                        Capsule().fill(.white)
                            .frame(width: geo.size.width * fillFraction(i))
                    }
                }
            }
        }
        .frame(height: 3)
    }

    private func fillFraction(_ i: Int) -> CGFloat {
        if i < current { return 1 }
        if i == current { return CGFloat(min(max(progress, 0), 1)) }
        return 0
    }
}

// MARK: - Reel playback model

/// Drives the single shared AVPlayer through the hit list: load → seek to
/// max(0, hit.time − 2.5 s) → play 5 s → advance (looping). Exactly one
/// AVPlayer stays alive; the next hit's AVAsset is prefetched while the
/// current one plays so advances feel instant.
@MainActor
final class ReelPlayerModel: ObservableObject {
    let hits: [MomentHit]
    let player = AVPlayer()

    @Published private(set) var currentIndex = 0
    @Published private(set) var segmentProgress: Double = 0   // 0…1 of the 5 s window
    @Published private(set) var isLoading = true
    @Published private(set) var isPaused = false
    @Published private(set) var exhausted = false             // every hit failed → stop looping

    static let windowSeconds = 5.0
    static let leadInSeconds = 2.5

    /// Bumped on every segment change/teardown so late async completions
    /// (asset fetch, seek, watchdog) from a superseded segment are ignored.
    private var generation = 0
    private var segmentStartSeconds: Double = 0
    /// Last time playback measurably moved forward — the watchdog's stall
    /// clock. Reset on segment start, unpause, and foreground-resume.
    private var lastProgressAt = Date()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var loadTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var prefetched: (index: Int, task: Task<AVAsset?, Never>)?
    private var consecutiveFailures = 0
    private var started = false

    init(hits: [MomentHit]) {
        self.hits = hits
    }

    func start() {
        guard !started, !hits.isEmpty else { return }
        started = true
        // .playback keeps reel audio audible even with the silent switch on —
        // the user explicitly tapped into a video experience.
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        installTimeObserver()
        playSegment(at: 0)
    }

    /// Full cleanup. Called from onDisappear — leaked AVPlayer observers crash
    /// on dealloc, so removal is unconditional and idempotent.
    func teardown() {
        generation += 1
        loadTask?.cancel(); loadTask = nil
        watchdogTask?.cancel(); watchdogTask = nil
        prefetched?.task.cancel(); prefetched = nil
        player.pause()
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        player.replaceCurrentItem(with: nil)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: Controls

    func togglePause() { setPaused(!isPaused) }

    func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        isPaused = paused
        if paused {
            player.pause()
        } else if !isLoading {
            // Mid-load: beginPlayback() starts playing once ready.
            // Reset the stall clock — time spent paused must not read as a
            // stall the moment playback resumes.
            lastProgressAt = Date()
            player.play()
        }
    }

    /// iOS pauses the AVPlayer when the app resigns active and never resumes
    /// it; isPaused still reads false, so the chrome shows a playing state
    /// over a frozen frame and no tick/end event ever arrives. Called when
    /// the scene returns to .active: re-kick playback (and the stall clock,
    /// so the watchdog doesn't count the backgrounded time as a stall).
    func resumeIfNeeded() {
        guard started, !isPaused, !isLoading, !exhausted else { return }
        lastProgressAt = Date()
        player.play()
    }

    func skipForward() { advance() }

    func skipBack() {
        // Story-standard: a late tap restarts the current moment, an early
        // tap goes to the previous one.
        if segmentProgress > 0.3 || currentIndex == 0 {
            playSegment(at: currentIndex)
        } else {
            playSegment(at: currentIndex - 1)
        }
    }

    // MARK: Segment lifecycle

    private func advance() {
        guard !hits.isEmpty else { return }
        // Loop back to the first hit after the last.
        playSegment(at: (currentIndex + 1) % hits.count)
    }

    private func playSegment(at index: Int) {
        guard !hits.isEmpty, index < hits.count else { return }
        generation += 1
        let gen = generation
        loadTask?.cancel()
        watchdogTask?.cancel()
        currentIndex = index
        segmentProgress = 0
        isLoading = true
        player.pause()

        let hit = hits[index]
        loadTask = Task { [weak self] in
            guard let self else { return }
            let asset: AVAsset?
            if let prefetched = self.prefetched, prefetched.index == index {
                asset = await prefetched.task.value
            } else {
                asset = await ReelAssetLoader.avAsset(for: hit.assetID)
            }
            guard !Task.isCancelled, gen == self.generation else { return }
            self.prefetched = nil
            guard let asset else {
                await self.handleLoadFailure(gen: gen)
                return
            }
            self.consecutiveFailures = 0
            await self.beginPlayback(of: asset, hit: hit, gen: gen)
        }
    }

    private func beginPlayback(of asset: AVAsset, hit: MomentHit, gen: Int) async {
        let item = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: item)
        let start = max(0, hit.time - Self.leadInSeconds)
        segmentStartSeconds = start
        // ±0.5 s tolerance lands on a nearby keyframe so the seek is fast;
        // frame-exactness matters less than the reel never stalling.
        let tolerance = CMTime(seconds: 0.5, preferredTimescale: 600)
        await player.seek(to: CMTime(seconds: start, preferredTimescale: 600),
                          toleranceBefore: tolerance, toleranceAfter: tolerance)
        guard gen == generation else { return }   // user skipped during the seek
        installEndObserver(for: item)
        isLoading = false
        if !isPaused { player.play() }
        prefetchNext()
        startWatchdog(gen: gen)
    }

    private func handleLoadFailure(gen: Int) async {
        consecutiveFailures += 1
        if consecutiveFailures >= hits.count {
            // Everything failed (e.g. fully offline) — show the terminal
            // state instead of skip-looping forever.
            exhausted = true
            isLoading = false
            return
        }
        // Brief beat so the spinner reads as "this one didn't load" rather
        // than a flicker, then move on. Never hang on one bad asset.
        try? await Task.sleep(nanoseconds: 600_000_000)
        guard gen == generation else { return }
        advance()
    }

    // MARK: Observers

    private func installTimeObserver() {
        // 50 ms ticks keep the progress segment visually smooth.
        let interval = CMTime(value: 1, timescale: 20)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(seconds: time.seconds) }
        }
    }

    private func tick(seconds: Double) {
        guard !isLoading, seconds.isFinite else { return }
        let elapsed = seconds - segmentStartSeconds
        let newProgress = min(max(elapsed / Self.windowSeconds, 0), 1)
        if newProgress != segmentProgress { lastProgressAt = Date() }
        segmentProgress = newProgress
        if elapsed >= Self.windowSeconds { advance() }
    }

    private func installEndObserver(for item: AVPlayerItem) {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        // The clip can end before the 5 s window does (moment near the end of
        // a short video) — advance instead of sitting on a frozen last frame.
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.advance() }
        }
    }

    /// A failed AVPlayerItem or a stalled buffer produces no ticks and no
    /// end notification — without a watchdog the reel would hang there.
    /// The stall clock makes it cover MID-segment stalls too: an iCloud
    /// stream that plays 1–2 s and then buffers forever (the typical
    /// slow-network case) stops producing progress, and a one-shot
    /// start-of-segment check would never notice. Poll the clock and
    /// advance after 10 s without progress while unpaused.
    private func startWatchdog(gen: Int) {
        watchdogTask?.cancel()
        lastProgressAt = Date()
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                guard let self, !Task.isCancelled, gen == self.generation else { return }
                if !self.isPaused,
                   Date().timeIntervalSince(self.lastProgressAt) >= 10 {
                    self.advance()
                    return
                }
            }
        }
    }

    // MARK: Prefetch

    /// Fetch the next hit's AVAsset while the current one plays so the
    /// auto-advance doesn't show a loading beat (single-AVPlayer constraint:
    /// we prefetch the asset, not a second player).
    private func prefetchNext() {
        guard hits.count > 1 else { return }
        let next = (currentIndex + 1) % hits.count
        guard prefetched?.index != next else { return }
        prefetched?.task.cancel()
        let assetID = hits[next].assetID
        prefetched = (next, Task { await ReelAssetLoader.avAsset(for: assetID) })
    }
}

// MARK: - Asset loading

/// PHImageManager.requestAVAsset with a hard timeout — an iCloud-offline fetch
/// can otherwise stall indefinitely, and the reel must skip, never hang.
/// Shared with ReelExporter.
enum ReelAssetLoader {
    static func avAsset(for assetID: String,
                        deliveryMode: PHVideoRequestOptionsDeliveryMode = .automatic,
                        timeout: TimeInterval = 10) async -> AVAsset? {
        guard let phAsset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil)
            .firstObject else { return nil }
        let opts = PHVideoRequestOptions()
        opts.isNetworkAccessAllowed = true
        opts.deliveryMode = deliveryMode
        let state = ReelRequestState()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<AVAsset?, Never>) in
                let id = PHImageManager.default().requestAVAsset(forVideo: phAsset, options: opts) { av, _, _ in
                    if state.takeResume() { cont.resume(returning: av) }
                }
                state.register(id)
                // Timeout backstop. The one-shot flag keeps the continuation
                // single-resume; the losing request is then CANCELLED, not
                // abandoned — an orphaned iCloud video download would keep
                // grinding for a result the reel already moved past.
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if state.takeResume() {
                        cont.resume(returning: nil)
                        state.cancelRequest()
                    }
                }
            }
        } onCancel: {
            // Skip/dismiss cancels the Swift Task; propagate that to the
            // PHImageManager request so its network fetch stops too.
            // PHImageManager still calls the result handler (with nil) for
            // cancelled requests, so the continuation resumes there.
            state.cancelRequest()
        }
    }
}

/// Lock-guarded bridge between the in-flight requestAVAsset call, the timeout
/// backstop, and Swift task cancellation. Completion, timeout, and cancel all
/// fire on different queues: the flag guarantees the continuation resumes
/// exactly once, and the stored request ID lets the losing paths cancel the
/// underlying PHImageManager work (mirrors PHRequestCancellationState in
/// PhotoLibraryModel).
private final class ReelRequestState: @unchecked Sendable {
    private let lock = NSLock()
    private var requestID: PHImageRequestID?
    private var cancelled = false
    private var resumed = false

    /// Records the in-flight request, cancelling immediately if cancellation
    /// arrived before the request call returned its ID.
    func register(_ id: PHImageRequestID) {
        lock.lock()
        requestID = id
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel { PHImageManager.default().cancelImageRequest(id) }
    }

    /// Returns true exactly once — the winner resumes the continuation.
    func takeResume() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if resumed { return false }
        resumed = true
        return true
    }

    func cancelRequest() {
        lock.lock()
        cancelled = true
        let id = requestID
        lock.unlock()
        if let id { PHImageManager.default().cancelImageRequest(id) }
    }
}

// MARK: - Player layer host

/// Raw AVPlayerLayer host — VideoPlayer would draw its own transport controls
/// over the story chrome.
private struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerHostUIView {
        let view = PlayerHostUIView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ uiView: PlayerHostUIView, context: Context) {
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
    }

    final class PlayerHostUIView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
