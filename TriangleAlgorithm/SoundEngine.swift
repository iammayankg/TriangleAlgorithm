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
    }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let sampleRate: Double = 44_100
    /// Never synthesize more than this much audio for one run.
    private let maxScoreDuration: Double = 30
    private var isReady = false

    func play(voices: [Voice], stepsPerSecond: Double) {
        guard let buffer = renderScore(voices: voices, stepsPerSecond: stepsPerSecond) else { return }
        prepareIfNeeded()
        guard isReady else { return }
        player.stop()
        player.scheduleBuffer(buffer, at: nil, options: .interrupts)
        try? player.playAudio()
    }

    func stop() {
        guard isReady else { return }
        player.stop()
    }

    /// Starts the audio engine lazily so the app makes no sound at all
    /// until the first audible run.
    private func prepareIfNeeded() {
        guard !isReady else { return }
        do {
#if os(iOS)
            try AVAudioSession.sharedInstance().setCategory(.ambient, options: .mixWithOthers)
            try AVAudioSession.sharedInstance().setActive(true)
#endif
            engine.attach(player)
            try engine.connectNode(
                player,
                to: engine.mainMixerNode,
                format: AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
            )
            try engine.start()
            isReady = true
        } catch {
            isReady = false
        }
    }

    /// Renders the whole run into a single PCM buffer, offline, so playback
    /// stays perfectly in step with the on-screen animation timing.
    private func renderScore(voices: [Voice], stepsPerSecond: Double) -> AVAudioPCMBuffer? {
        let stepDuration = 1.0 / stepsPerSecond
        let maxSteps = voices.map(\.gaps.count).max() ?? 0
        guard maxSteps > 0 else { return nil }

        let duration = min(Double(maxSteps - 1) * stepDuration + 1.4, maxScoreDuration)
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
                let time = Double(step) * stepDuration + offset
                // Pitch climbs a bit over an octave as the gap closes.
                let frequency = 262 * pow(2, (1 - gap) * 1.4)
                addTone(at: time, frequency: frequency, duration: 0.09, amplitude: 0.035)
            }

            let endTime = Double(voice.gaps.count - 1) * stepDuration + offset
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
