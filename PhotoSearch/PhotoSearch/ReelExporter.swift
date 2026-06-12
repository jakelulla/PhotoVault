import AVFoundation
import Photos
import SwiftUI

// MARK: - ReelExporter

/// Stitches every MomentHit's ~5 s window into one portrait (1080×1920) H.264
/// movie: AVMutableComposition for the cuts, AVMutableVideoComposition layer
/// instructions to aspect-fit each clip's natural size/rotation onto the
/// canvas, AVAssetExportSession to a temp .mp4 for the share sheet.
@MainActor
final class ReelExporter: ObservableObject {
    enum Phase: Equatable {
        case idle
        case preparing(done: Int, total: Int)
        case exporting
        case finished(URL)
        case failed(String)
        case cancelled
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var progress: Float = 0

    static let renderSize = CGSize(width: 1080, height: 1920)
    static let windowSeconds = 5.0
    static let leadInSeconds = 2.5

    private var session: AVAssetExportSession?
    private var progressTimer: Timer?
    private var buildTask: Task<Void, Never>?

    func start(hits: [MomentHit], title: String) {
        guard case .idle = phase, !hits.isEmpty else { return }
        buildTask = Task { await run(hits, title: title) }
    }

    func cancel() {
        if case .finished = phase { return }   // nothing left to cancel
        buildTask?.cancel()
        session?.cancelExport()
        stopProgressTimer()
        phase = .cancelled
    }

    // MARK: Pipeline

    private func run(_ hits: [MomentHit], title: String) async {
        do {
            let (composition, videoComposition) = try await buildComposition(hits)
            try Task.checkCancellation()
            try await export(composition, videoComposition, title: title)
        } catch is CancellationError {
            phase = .cancelled
        } catch {
            // Surface the failure — a silent dead-end here is undebuggable
            // for users ("the button does nothing").
            phase = .failed(error.localizedDescription)
        }
    }

    private enum ExportError: LocalizedError {
        case compositionFailed
        case nothingToExport
        case sessionFailed
        case exportFailed(String)

        var errorDescription: String? {
            switch self {
            case .compositionFailed: return "Couldn't create the video composition."
            case .nothingToExport: return "None of the videos could be loaded. They may be in iCloud and unavailable right now."
            case .sessionFailed: return "Couldn't start the video export."
            case .exportFailed(let why): return why
            }
        }
    }

    // MARK: Composition

    private func buildComposition(_ hits: [MomentHit]) async throws
        -> (AVMutableComposition, AVMutableVideoComposition) {
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw ExportError.compositionFailed }
        // Created lazily on the first clip that actually has audio — an
        // audio track containing nothing but empty ranges can fail export.
        var audioTrack: AVMutableCompositionTrack?

        // One layer instruction for the single video track; setTransform(_:at:)
        // re-aims the aspect-fit at each cut so per-clip rotation/size is
        // handled without juggling alternating tracks.
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        var cursor = CMTime.zero
        var inserted = 0

        for (i, hit) in hits.enumerated() {
            try Task.checkCancellation()
            phase = .preparing(done: i, total: hits.count)

            // Longer timeout than playback: an export is worth waiting for an
            // iCloud download. A clip that still fails is skipped, not fatal.
            guard let asset = await ReelAssetLoader.avAsset(
                for: hit.assetID, deliveryMode: .highQualityFormat, timeout: 30)
            else { continue }
            guard let srcVideo = try? await asset.loadTracks(withMediaType: .video).first
            else { continue }

            // Clamp the window against the *asset's* duration — PhotoKit
            // metadata (hit.duration) can disagree slightly with the file.
            let assetSeconds = ((try? await asset.load(.duration)) ?? .zero).seconds
            guard assetSeconds > 0.1 else { continue }
            let start = max(0, min(hit.time - Self.leadInSeconds, assetSeconds - 0.5))
            let clipSeconds = min(Self.windowSeconds, assetSeconds - start)
            guard clipSeconds > 0.1 else { continue }
            let range = CMTimeRange(
                start: CMTime(seconds: start, preferredTimescale: 600),
                duration: CMTime(seconds: clipSeconds, preferredTimescale: 600))

            do { try videoTrack.insertTimeRange(range, of: srcVideo, at: cursor) }
            catch { continue }   // unreadable track — skip the clip, keep the reel

            let naturalSize = (try? await srcVideo.load(.naturalSize)) ?? .zero
            let preferred = (try? await srcVideo.load(.preferredTransform)) ?? .identity
            layerInstruction.setTransform(
                Self.aspectFitTransform(naturalSize: naturalSize, preferredTransform: preferred),
                at: cursor)

            // Audio: keep the timeline aligned even when a clip is silent —
            // a missing span would pull every later clip's audio early.
            if let srcAudio = try? await asset.loadTracks(withMediaType: .audio).first {
                if audioTrack == nil {
                    audioTrack = composition.addMutableTrack(
                        withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                    if cursor > .zero {
                        // Pad silence for the clips inserted before audio existed.
                        audioTrack?.insertEmptyTimeRange(
                            CMTimeRange(start: .zero, duration: cursor))
                    }
                }
                do { try audioTrack?.insertTimeRange(range, of: srcAudio, at: cursor) }
                catch {
                    audioTrack?.insertEmptyTimeRange(
                        CMTimeRange(start: cursor, duration: range.duration))
                }
            } else if let audioTrack {
                audioTrack.insertEmptyTimeRange(
                    CMTimeRange(start: cursor, duration: range.duration))
            }

            cursor = CMTimeAdd(cursor, range.duration)
            inserted += 1
        }

        guard inserted > 0 else { throw ExportError.nothingToExport }

        let instruction = AVMutableVideoCompositionInstruction()
        // Cover the full composition duration (not our cursor arithmetic):
        // track inserts snap to sample boundaries, and an instruction gap of
        // even one frame fails the export with -11841.
        let totalDuration = try await composition.load(.duration)
        instruction.timeRange = CMTimeRange(start: .zero, duration: totalDuration)
        instruction.layerInstructions = [layerInstruction]

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = Self.renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.instructions = [instruction]
        return (composition, videoComposition)
    }

    /// Maps a source track onto the portrait canvas: apply the track's
    /// preferredTransform (rotation), re-anchor the resulting bounds at the
    /// origin, then scale-aspect-fit and center into 1080×1920.
    static func aspectFitTransform(naturalSize: CGSize,
                                   preferredTransform: CGAffineTransform) -> CGAffineTransform {
        guard naturalSize.width > 0, naturalSize.height > 0 else { return .identity }
        let bounds = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let displaySize = CGSize(width: abs(bounds.width), height: abs(bounds.height))
        guard displaySize.width > 0, displaySize.height > 0 else { return .identity }
        // Rotation transforms typically swing content into negative
        // coordinates; translate it back so (0,0) is the visible corner.
        var t = preferredTransform.concatenating(
            CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
        let scale = min(renderSize.width / displaySize.width,
                        renderSize.height / displaySize.height)
        t = t.concatenating(CGAffineTransform(scaleX: scale, y: scale))
        t = t.concatenating(CGAffineTransform(
            translationX: (renderSize.width - displaySize.width * scale) / 2,
            y: (renderSize.height - displaySize.height * scale) / 2))
        return t
    }

    // MARK: Export

    private func export(_ composition: AVMutableComposition,
                        _ videoComposition: AVMutableVideoComposition,
                        title: String) async throws {
        guard let session = AVAssetExportSession(
            asset: composition, presetName: AVAssetExportPresetHighestQuality)
        else { throw ExportError.sessionFailed }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(Self.fileName(for: title)).mp4")
        try? FileManager.default.removeItem(at: url)   // export fails if the file exists

        session.outputURL = url
        session.outputFileType = .mp4
        session.videoComposition = videoComposition
        session.shouldOptimizeForNetworkUse = true
        self.session = session

        phase = .exporting
        startProgressTimer()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { cont.resume() }
        }
        stopProgressTimer()
        self.session = nil

        switch session.status {
        case .completed:
            progress = 1
            phase = .finished(url)
        case .cancelled:
            phase = .cancelled
        default:
            throw ExportError.exportFailed(
                session.error?.localizedDescription ?? "The video export failed.")
        }
    }

    /// Share-sheet-friendly file name from the reel title, e.g.
    /// "dog at the beach" → "dog at the beach Reel-1718230000.mp4".
    private static func fileName(for title: String) -> String {
        let safe = title
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let base = safe.isEmpty ? "Moment Reel" : "\(safe) Reel"
        // Timestamp suffix keeps repeat exports from colliding in tmp.
        return "\(base)-\(Int(Date().timeIntervalSince1970))"
    }

    // MARK: Progress polling

    private func startProgressTimer() {
        progress = 0
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let session = self.session else { return }
                self.progress = session.progress
            }
        }
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }
}

// MARK: - Export sheet

/// Progress UI for the export: preparing (per-clip) → exporting (progress
/// bar) → share. Presented from MomentReelView; the reel pauses underneath.
struct ReelExportSheet: View {
    let hits: [MomentHit]
    let title: String

    @StateObject private var exporter = ReelExporter()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                switch exporter.phase {
                case .idle, .preparing:
                    VStack(spacing: 16) {
                        ProgressView()
                        Text(preparingLabel)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                case .exporting:
                    VStack(spacing: 16) {
                        ProgressView(value: exporter.progress)
                            .padding(.horizontal, 40)
                        Text("Exporting… \(Int(exporter.progress * 100))%")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                case .finished(let url):
                    VStack(spacing: 20) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(.green)
                        Text("Reel Ready")
                            .font(.headline)
                        ShareLink(item: url) {
                            Label("Share Video", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                case .failed:
                    // The alert below carries the message; this is just the
                    // resting state behind it.
                    ContentUnavailableView("Export Failed",
                                           systemImage: "exclamationmark.triangle")
                case .cancelled:
                    ContentUnavailableView("Export Cancelled", systemImage: "xmark.circle")
                }
            }
            .navigationTitle("Export Reel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(doneState ? "Done" : "Cancel") {
                        exporter.cancel()
                        dismiss()
                    }
                }
            }
            .task { exporter.start(hits: hits, title: title) }
            .alert("Export Failed", isPresented: failedBinding) {
                Button("OK") { dismiss() }
            } message: {
                Text(failureMessage)
            }
        }
        .presentationDetents([.medium])
        // Swiping the sheet away mid-export must stop the work, not leave a
        // detached export session grinding in the background.
        .onDisappear { exporter.cancel() }
    }

    private var preparingLabel: String {
        if case .preparing(let done, let total) = exporter.phase {
            return "Preparing clip \(done + 1) of \(total)…"
        }
        return "Preparing…"
    }

    private var doneState: Bool {
        switch exporter.phase {
        case .finished, .cancelled, .failed: return true
        default: return false
        }
    }

    private var failedBinding: Binding<Bool> {
        Binding(
            get: { if case .failed = exporter.phase { return true } else { return false } },
            set: { if !$0 { dismiss() } }
        )
    }

    private var failureMessage: String {
        if case .failed(let message) = exporter.phase { return message }
        return "The video export failed."
    }
}
