import Foundation

/// Maps a run's wall-clock time to the trace progress drawn on the canvas,
/// and gives the sound engine the same schedule so picture and score stay
/// in step.
///
/// Steps play at the mode's pace — slow enough in Learn to follow each
/// pivot. A run that zig-zags to the iteration cap would take minutes at
/// that pace and look frozen, so after a slow opening phase the remaining
/// steps accelerate to land the whole trace within a bounded window.
/// Short runs never reach the fast phase and play at the base pace
/// throughout.
nonisolated struct RunTimeline {
    /// Steps in the run: `points.count - 1` of the longest trajectory.
    let stepCount: Int
    /// The base pace, used for the whole of the slow phase.
    let stepsPerSecond: Double
    /// Steps played at the base pace before accelerating.
    let slowSteps: Int
    /// Seconds the accelerated remainder takes; zero when nothing remains.
    let fastDuration: Double

    /// How long the opening phase may run at the base pace.
    static let slowPhaseDuration = 10.0
    /// The most time the accelerated remainder may take.
    static let fastPhaseMaxDuration = 8.0

    init(stepCount: Int, stepsPerSecond: Double) {
        self.stepCount = max(stepCount, 0)
        self.stepsPerSecond = stepsPerSecond
        slowSteps = min(self.stepCount, Int(Self.slowPhaseDuration * stepsPerSecond))
        let remaining = Double(self.stepCount - slowSteps)
        // A remainder that fits the budget at the base pace just continues
        // at that pace; only a long tail is compressed.
        fastDuration = min(remaining / stepsPerSecond, Self.fastPhaseMaxDuration)
    }

    var slowDuration: Double { Double(slowSteps) / stepsPerSecond }

    /// Total playing time of the run.
    var duration: Double { slowDuration + fastDuration }

    /// Steps completed `elapsed` seconds into the run, fractional while a
    /// step is in flight, clamped to the run's length.
    func progress(at elapsed: Double) -> Double {
        let t = max(0, elapsed)
        let remaining = Double(stepCount - slowSteps)
        if t <= slowDuration || remaining == 0 || fastDuration == 0 {
            return min(t * stepsPerSecond, Double(stepCount))
        }
        let fastProgress = (t - slowDuration) / fastDuration * remaining
        return min(Double(slowSteps) + fastProgress, Double(stepCount))
    }

    /// When the iterate arrives at `points[index]`: zero for the start,
    /// `duration` for the final point.
    func onset(ofPoint index: Int) -> Double {
        if index <= slowSteps { return Double(index) / stepsPerSecond }
        let remaining = Double(stepCount - slowSteps)
        return slowDuration + Double(index - slowSteps) / remaining * fastDuration
    }

    /// Arrival times for every point of the longest trajectory.
    var onsets: [Double] { (0...stepCount).map(onset) }
}
