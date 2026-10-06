import AVFoundation

/// Synthesizes and plays a short generative score for one run of the
/// algorithm: a soft tick per pivot step whose pitch rises as the iterate
/// closes in on the target, then a consonant chord when a trajectory
/// converges or a dissonant cluster when it ends at a witness.
@MainActor
final class SoundEngine {
    /// The audible shape of one trajectory.
    struct Voice {
        /// Gap to the target at each step, normalized so 1 is the starting
        /// gap and 0 is on top of the target.
        let gaps: [Double]
        let converged: Bool
        /// Whether the voice ends on its chord. Manual stepping plays one
        /// tick at a time and only resolves on the run's final step.
        var playsCadence = true
    }

    /// AVAudioPCMBuffer isn't Sendable; the background render task builds
    /// the buffer privately and hands it to the main actor exactly once.
    private struct RenderedScore: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
    }

    /// AVAudioEngine and its nodes aren't Sendable either. The graph is
    /// built and started on a background task and only touched from the
    /// main actor once that has finished, never concurrently.
    private struct AudioGraph: @unchecked Sendable {
        let engine: AVAudioEngine
        let player: AVAudioPlayerNode
    }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    nonisolated private static let sampleRate: Double = 44_100
    /// Never synthesize more than this much audio for one run. The run
    /// animation clamps to the same bound so picture and score end together.
    nonisolated static let maxScoreDuration: Double = 30
    /// Invalidates in-flight background renders when a newer run (or a stop)
    /// supersedes them.
    private var renderGeneration = 0
    private var isReady = false
    private var isPreparing = false
    /// Score waiting for the session to finish activating; the first run's
    /// audio starts as soon as preparation completes.
    private var pendingBuffer: AVAudioPCMBuffer?

    /// Plays a run on its timeline's schedule, so every tick lands exactly
    /// when the canvas draws that step — through the accelerated tail too.
    func play(voices: [Voice], timeline: RunTimeline) {
        play(voices: voices, onsets: timeline.onsets)
    }

    /// Plays at a constant pace: manual stepping's quick-succession ticks.
    func play(voices: [Voice], stepsPerSecond: Double) {
        let maxSteps = voices.map(\.gaps.count).max() ?? 0
        play(voices: voices, onsets: (0..<maxSteps).map { Double($0) / stepsPerSecond })
    }

    /// `onsets[i]` is when the i-th point of every voice sounds.
    private func play(voices: [Voice], onsets: [Double]) {
#if targetEnvironment(simulator)
        // The simulator's audio stack intermittently times out inside
        // AVAudioEngine.start() and aborts the process (an uncatchable
        // AudioToolbox RPC failure), sometimes taking the whole simulator
        // down. Sound is a device-only feature.
        return
#else
        playRendered(voices: voices, onsets: onsets)
#endif
    }

    private func playRendered(voices: [Voice], onsets: [Double]) {
        renderGeneration += 1
        let generation = renderGeneration
        // Synthesis is tens of millions of float ops for a busy run — far
        // too much for the main actor at the exact moment the run animation
        // starts, so it renders on a background task.
        Task {
            let score = await Task.detached(priority: .userInitiated) {
                Self.renderScore(voices: voices, onsets: onsets).map(RenderedScore.init)
            }.value
            guard generation == renderGeneration, let score else { return }
            if isReady {
                playNow(score.buffer)
            } else {
                pendingBuffer = score.buffer
                prepareIfNeeded()
            }
        }
    }

    func stop() {
        renderGeneration += 1
        pendingBuffer = nil
        guard isReady else { return }
        player.stop()
    }

    private func playNow(_ buffer: AVAudioPCMBuffer) {
        player.stop()
        player.scheduleBuffer(buffer, at: nil, options: .interrupts)
        player.play()
    }

    /// Starts the audio engine lazily so the app makes no sound at all until
    /// the first audible run. Activating the session and starting the
    /// engine can each block for a second or more (while a Bluetooth route
    /// settles, say), so both happen off the main thread; the first run's
    /// score plays as soon as they finish.
    private func prepareIfNeeded() {
        guard !isReady, !isPreparing else { return }
        isPreparing = true
        let graph = AudioGraph(engine: engine, player: player)
        Task {
            let started = await Task.detached(priority: .userInitiated) {
                Self.start(graph)
            }.value
            finishPreparing(started: started)
        }
    }

    /// Configures the session, wires the player into the engine, and starts
    /// it. Pure setup with no engine state of its own, so it runs on a
    /// background task.
    nonisolated private static func start(_ graph: AudioGraph) -> Bool {
#if os(iOS)
        do {
            try AVAudioSession.sharedInstance().setCategory(.ambient, options: .mixWithOthers)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            return false
        }
#endif
        do {
            graph.engine.attach(graph.player)
            graph.engine.connect(
                graph.player,
                to: graph.engine.mainMixerNode,
                format: AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
            )
            try graph.engine.start()
            return true
        } catch {
            return false
        }
    }

    private func finishPreparing(started: Bool) {
        isPreparing = false
        isReady = started
        let buffer = pendingBuffer
        pendingBuffer = nil
        if started, let buffer {
            playNow(buffer)
        }
    }

    /// Renders the whole run into a single PCM buffer, offline, so playback
    /// stays perfectly in step with the on-screen animation timing.
    /// Pure computation with no engine state, so it runs off the main actor.
    nonisolated private static func renderScore(voices: [Voice], onsets: [Double]) -> AVAudioPCMBuffer? {
        let maxSteps = voices.map(\.gaps.count).max() ?? 0
        guard maxSteps > 0, let lastOnset = onsets.last else { return nil }
        // When a voice's point `step` sounds; voices never outrun the
        // schedule, but clamp rather than trap if one did.
        func onset(_ step: Int) -> Double { onsets[min(step, onsets.count - 1)] }

        let duration = min(lastOnset + 1.4, maxScoreDuration)
        let frameCount = AVAudioFrameCount(duration * sampleRate)
        guard frameCount > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let samples = buffer.floatChannelData?[0]
        else { return nil }
        buffer.frameLength = frameCount
        let totalFrames = Int(frameCount)

        // Mixes a decaying sine tone into the buffer at the given time.
        func addTone(at time: Double, frequency: Double, duration toneDuration: Double, amplitude: Double) {
            let start = Int(time * sampleRate)
            guard start >= 0, start < totalFrames else { return }
            let length = min(Int(toneDuration * sampleRate), totalFrames - start)
            let decay = 5.0 / toneDuration
            for i in 0..<length {
                let t = Double(i) / sampleRate
                samples[start + i] += Float(sin(2 * .pi * frequency * t) * exp(-decay * t) * amplitude)
            }
        }

        for (voiceIndex, voice) in voices.enumerated() {
            // Slight per-voice offset so simultaneous steps read as texture
            // rather than one loud click.
            let offset = Double(voiceIndex) * 0.014

            for (step, gap) in voice.gaps.enumerated() {
                let time = onset(step) + offset
                // Pitch climbs a bit over an octave as the gap closes.
                let frequency = 262 * pow(2, (1 - gap) * 1.4)
                addTone(at: time, frequency: frequency, duration: 0.09, amplitude: 0.035)
            }

            guard voice.playsCadence else { continue }
            let endTime = onset(voice.gaps.count - 1) + offset
            if voice.converged {
                for frequency in [523.25, 659.25, 784.0] {   // C–E–G: resolved
                    addTone(at: endTime, frequency: frequency, duration: 1.1, amplitude: 0.05)
                }
            } else {
                for frequency in [220.0, 233.08, 311.13] {   // A–B♭–E♭: a sour cluster
                    addTone(at: endTime, frequency: frequency, duration: 1.1, amplitude: 0.055)
                }
            }
        }

        // Hard-limit the mix so overlapping voices can never clip.
        for i in 0..<totalFrames {
            samples[i] = max(-1, min(1, samples[i]))
        }
        return buffer
    }
}
