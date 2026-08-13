import AVFoundation
import Foundation

/// Generative background music for slideshows — synthesized on the fly with
/// AVAudioEngine, so the app ships ZERO audio assets and owes no licensing.
///
/// The sound: a slow four-chord ambient pad (three softly-detuned sine
/// partials per voice + a sine bass an octave down), a gentle pentatonic
/// "sparkle" note every couple of beats, and a big reverb over everything.
/// Three moods pick the key, progression, and tempo.
///
/// Real-time safety: the render closure runs on the audio thread — it only
/// reads the immutable `Score` and its own sample counter; no locks, no
/// allocation, no Swift concurrency. Start/stop happen on the main actor.
final class SlideshowMusic {
    enum Mood: String, CaseIterable, Codable {
        case calm, warm, bright

        /// Chord progression as MIDI roots + chord intervals, and pacing.
        fileprivate var score: Score {
            switch self {
            case .calm:   // C major: C  Am  F  G, dreamy and slow
                return Score(roots: [48, 45, 41, 43],
                             chordIntervals: [[0, 7, 12, 16], [0, 7, 12, 15], [0, 7, 12, 16], [0, 7, 12, 16]],
                             pentatonic: [60, 62, 64, 67, 69, 72, 74],
                             chordSeconds: 6.4, sparkleEvery: 1.6)
            case .warm:   // A minor: Am F C G, tender
                return Score(roots: [45, 41, 48, 43],
                             chordIntervals: [[0, 7, 12, 15], [0, 7, 12, 16], [0, 7, 12, 16], [0, 7, 12, 16]],
                             pentatonic: [57, 60, 62, 64, 67, 69, 72],
                             chordSeconds: 7.0, sparkleEvery: 1.75)
            case .bright: // G major: G Em C D, a little quicker
                return Score(roots: [43, 40, 48, 50],
                             chordIntervals: [[0, 7, 12, 16], [0, 7, 12, 15], [0, 7, 12, 16], [0, 7, 12, 16]],
                             pentatonic: [67, 69, 71, 74, 76, 79, 81],
                             chordSeconds: 5.6, sparkleEvery: 1.4)
            }
        }
    }

    fileprivate struct Score {
        var roots: [Int]                  // MIDI note per chord (bass root)
        var chordIntervals: [[Int]]       // semitone offsets per chord
        var pentatonic: [Int]             // sparkle note pool (MIDI)
        var chordSeconds: Double
        var sparkleEvery: Double          // seconds between sparkle notes
    }

    private var engine: AVAudioEngine?
    private(set) var isPlaying = false

    /// Start (or restart) playing a mood, with a soft fade-in.
    func start(mood: Mood) {
        stop()
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)

        let engine = AVAudioEngine()
        let sampleRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let render = RenderState(score: mood.score, sampleRate: sampleRate)

        let source = AVAudioSourceNode { _, _, frameCount, audioBufferList -> OSStatus in
            render.render(into: audioBufferList, frameCount: frameCount)
            return noErr
        }
        engine.attach(source)

        let reverb = AVAudioUnitReverb()
        reverb.loadFactoryPreset(.largeHall)
        reverb.wetDryMix = 45
        engine.attach(reverb)

        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)
        engine.connect(source, to: reverb, format: format)
        engine.connect(reverb, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0

        do {
            try engine.start()
        } catch {
            return   // no music is a graceful degradation
        }
        self.engine = engine
        isPlaying = true

        // Soft fade-in (~1.5s) off the audio thread.
        Task { [weak engine] in
            for step in 1...15 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                engine?.mainMixerNode.outputVolume = Float(step) / 15
            }
        }
    }

    /// Fade out briefly, then tear the engine down and release the session.
    func stop() {
        guard let engine else { return }
        isPlaying = false
        self.engine = nil
        Task {
            for step in stride(from: 9, through: 0, by: -1) {
                try? await Task.sleep(nanoseconds: 60_000_000)
                engine.mainMixerNode.outputVolume = Float(step) / 10
            }
            engine.stop()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    // MARK: - Audio-thread renderer

    /// Everything the render callback touches. Value-configured up front;
    /// mutable state is just sample counters + the sparkle PRNG — owned solely
    /// by the audio thread after start.
    private final class RenderState {
        private let score: Score
        private let sampleRate: Double
        private var sampleIndex: UInt64 = 0
        private var rng: UInt64 = 0x9E3779B97F4A7C15
        private var sparkleFreq = 0.0
        private var sparkleStart = 0.0     // seconds
        private let padAmp: Float = 0.10
        private let bassAmp: Float = 0.07
        private let sparkleAmp: Float = 0.05

        init(score: Score, sampleRate: Double) {
            self.score = score
            self.sampleRate = sampleRate
        }

        private static func hz(_ midi: Int) -> Double {
            440 * pow(2, (Double(midi) - 69) / 12)
        }

        private func nextRandom() -> UInt64 {
            rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17
            return rng
        }

        func render(into list: UnsafeMutablePointer<AudioBufferList>, frameCount: AVAudioFrameCount) {
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            let chordDur = score.chordSeconds
            let cycle = chordDur * Double(score.roots.count)

            for frame in 0..<Int(frameCount) {
                let t = Double(sampleIndex) / sampleRate
                let cyclePos = t.truncatingRemainder(dividingBy: cycle)
                let chordIndex = min(Int(cyclePos / chordDur), score.roots.count - 1)
                let chordPos = cyclePos - Double(chordIndex) * chordDur

                // Pad: three detuned sine partials per chord tone, with a slow
                // raised-cosine envelope across the chord (soft in/out).
                let env = 0.5 - 0.5 * cos(2 * .pi * min(max(chordPos / chordDur, 0), 1))
                var sample = 0.0
                let root = score.roots[chordIndex]
                for interval in score.chordIntervals[chordIndex] {
                    let f = Self.hz(root + interval + 12)   // pad an octave up
                    sample += sin(2 * .pi * f * t)
                    sample += 0.5 * sin(2 * .pi * (f * 1.003) * t)   // detune shimmer
                }
                sample *= Double(padAmp) * env / Double(score.chordIntervals[chordIndex].count)

                // Bass: root, one octave down, same envelope.
                sample += Double(bassAmp) * env * sin(2 * .pi * Self.hz(root - 12) * t)

                // Sparkle: a pentatonic note every `sparkleEvery` seconds with
                // an exponential decay. Note chosen when its window starts.
                let window = score.sparkleEvery
                let windowStart = floor(t / window) * window
                if windowStart != sparkleStart {
                    sparkleStart = windowStart
                    let pool = score.pentatonic
                    let pick = pool[Int(nextRandom() % UInt64(pool.count))]
                    // Rest ~1 in 4 windows so it breathes.
                    sparkleFreq = (nextRandom() % 4 == 0) ? 0 : Self.hz(pick + 12)
                }
                if sparkleFreq > 0 {
                    let age = t - sparkleStart
                    let decay = exp(-age * 2.2)
                    sample += Double(sparkleAmp) * decay * sin(2 * .pi * sparkleFreq * t)
                }

                let value = Float(sample)
                for buffer in buffers {
                    let out = buffer.mData!.assumingMemoryBound(to: Float.self)
                    out[frame] = value
                }
                sampleIndex &+= 1
            }
        }
    }
}
