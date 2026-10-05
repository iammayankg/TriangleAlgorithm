import SwiftUI
import Photos

@main struct TriangleTraceApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

// MARK: - Geometry helpers

nonisolated func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
    hypot(a.x - b.x, a.y - b.y)
}

/// The point on segment [a, b] closest to `target`.
nonisolated func closestPointOnSegment(from a: CGPoint, to b: CGPoint, target: CGPoint) -> CGPoint {
    let dx = b.x - a.x
    let dy = b.y - a.y
    let lengthSquared = dx * dx + dy * dy
    guard lengthSquared > 0 else { return a }
    let t = ((target.x - a.x) * dx + (target.y - a.y) * dy) / lengthSquared
    let clamped = min(max(t, 0), 1)
    return CGPoint(x: a.x + clamped * dx, y: a.y + clamped * dy)
}

/// Convex hull via Andrew's monotone chain, for drawing the hull outline.
nonisolated func convexHull(of points: [CGPoint]) -> [CGPoint] {
    guard points.count >= 3 else { return points }
    let sorted = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
    func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
    }
    var lower: [CGPoint] = []
    for p in sorted {
        while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 {
            lower.removeLast()
        }
        lower.append(p)
    }
    var upper: [CGPoint] = []
    for p in sorted.reversed() {
        while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 {
            upper.removeLast()
        }
        upper.append(p)
    }
    return lower.dropLast() + upper.dropLast()
}

/// True if `point` lies inside or on the boundary of the convex polygon `hull`.
nonisolated func isInsideConvexHull(_ point: CGPoint, hull: [CGPoint]) -> Bool {
    guard hull.count >= 3 else { return false }
    var sign: CGFloat = 0
    for i in hull.indices {
        let a = hull[i]
        let b = hull[(i + 1) % hull.count]
        let cross = (b.x - a.x) * (point.y - a.y) - (b.y - a.y) * (point.x - a.x)
        if cross != 0 {
            if sign == 0 {
                sign = cross > 0 ? 1 : -1
            } else if (cross > 0 ? 1 : -1) != sign {
                return false
            }
        }
    }
    return true
}

/// `point` unchanged if it's inside `hull`; otherwise the nearest point on
/// the hull's boundary.
nonisolated func clampToConvexHull(_ point: CGPoint, hull: [CGPoint]) -> CGPoint {
    guard hull.count >= 3 else { return hull.first ?? point }
    if isInsideConvexHull(point, hull: hull) { return point }
    var best = hull[0]
    var bestGap = CGFloat.greatestFiniteMagnitude
    for i in hull.indices {
        let candidate = closestPointOnSegment(from: hull[i], to: hull[(i + 1) % hull.count], target: point)
        let gap = distance(candidate, point)
        if gap < bestGap {
            bestGap = gap
            best = candidate
        }
    }
    return best
}

// MARK: - Triangle Algorithm (Kalantari)

/// How a trace ended. The three cases carry different evidentiary weight:
/// a convergence proves p is inside the hull, a witness proves it is
/// outside, and an exhausted run proves nothing either way.
enum TraceOutcome {
    /// The iterate got within epsilon of the query point.
    case converged
    /// No valid pivot remained (or no progress was possible), so the final
    /// iterate is a witness.
    case witness
    /// The iteration budget ran out before either proof.
    case exhausted
}

struct Trajectory: Identifiable {
    let id = UUID()
    let points: [CGPoint]
    /// What each step did: `steps[i]` carried the iterate from `points[i]`
    /// to `points[i + 1]`, naming the vertices it moved toward or away from.
    let steps: [TraceStep]
    let outcome: TraceOutcome
    var converged: Bool { outcome == .converged }
    /// The vertex called out as each step's pivot.
    var pivots: [CGPoint] { steps.map(\.pivot) }
}

enum TriangleAlgorithm {
    /// Traces iterates from `start` toward query point `p` over the vertex set.
    /// Each step pivots on a vertex v with d(x, v) >= d(p, v) and moves to the
    /// point on segment [x, v] nearest to p. Stops with a witness if no pivot exists.
    /// One iteration from `x`: the best valid pivot and the point on
    /// segment [x, pivot] nearest to p. Nil when no pivot exists (x is a
    /// witness) — the shared kernel of `trace` and `stepCount`.
    nonisolated static func step(
        from x: CGPoint,
        vertices: [CGPoint],
        target p: CGPoint
    ) -> (next: CGPoint, pivotIndex: Int, gap: CGFloat)? {
        var best: (next: CGPoint, pivotIndex: Int, gap: CGFloat)? = nil
        for (index, v) in vertices.enumerated() where distance(x, v) >= distance(p, v) {
            let candidate = closestPointOnSegment(from: x, to: v, target: p)
            let gap = distance(candidate, p)
            if gap < (best?.gap ?? .greatestFiniteMagnitude) {
                best = (candidate, index, gap)
            }
        }
        return best
    }

    /// Traces iterates under the chosen step strategy. Every strategy stops
    /// the same way: converged within epsilon of p, a witness once no valid
    /// pivot (or no progress) remains, or exhausted at the iteration cap.
    nonisolated static func trace(
        from start: CGPoint,
        vertices: [CGPoint],
        target p: CGPoint,
        strategy: StepStrategy = .toward,
        blockSize: Int = 4,
        epsilon: CGFloat = 1.0,
        maxIterations: Int = 500
    ) -> (points: [CGPoint], steps: [TraceStep], outcome: TraceOutcome) {
        var solver = StepSolver(start: start, vertices: vertices, target: p,
                                strategy: strategy, blockSize: blockSize)
        var path = [start]
        var steps: [TraceStep] = []
        guard !vertices.isEmpty else { return (path, steps, .witness) }

        for _ in 0..<maxIterations {
            if solver.gap <= epsilon { return (path, steps, .converged) }
            // No pivot (or no progress possible): x is a witness.
            guard let step = solver.advance() else { return (path, steps, .witness) }
            path.append(solver.x)
            steps.append(step)
        }
        return (path, steps, solver.gap <= epsilon ? .converged : .exhausted)
    }

    /// Like `trace`, but only counts steps — cheap enough to sample many
    /// starting points, as the iteration-intensity field does.
    nonisolated static func stepCount(
        from start: CGPoint,
        vertices: [CGPoint],
        target p: CGPoint,
        strategy: StepStrategy = .toward,
        blockSize: Int = 4,
        epsilon: CGFloat = 1.0,
        maxIterations: Int = 150
    ) -> Int {
        guard !vertices.isEmpty else { return 0 }
        var solver = StepSolver(start: start, vertices: vertices, target: p,
                                strategy: strategy, blockSize: blockSize)
        for iteration in 0..<maxIterations {
            if solver.gap <= epsilon { return iteration }
            guard solver.advance() != nil else { return iteration }
        }
        return maxIterations
    }
}

/// A grid of triangle-algorithm step counts sampled across the canvas,
/// backing the iteration-intensity coloring mode and the partition mode.
struct IterationField {
    let cellSize: CGFloat
    let columns: Int
    let rows: Int
    let counts: [Int]
    let maxCount: Int

    /// Renders the sampled counts into a bitmap with one pixel per cell.
    /// Drawing it scaled up with interpolation smooths the gradient far
    /// beyond the sampling resolution. Unsampled cells stay transparent.
    func makeImage(baseColor: PlatformColor) -> CGImage? {
        let (red, green, blue, baseAlpha) = baseColor.rgbaComponents
        var pixels = [UInt8](repeating: 0, count: columns * rows * 4)
        for index in counts.indices {
            let steps = counts[index]
            guard steps >= 0 else { continue }
            let alpha = (0.05 + 0.95 * Double(steps) / Double(maxCount)) * baseAlpha
            func component(_ value: CGFloat) -> UInt8 {
                UInt8(max(0, min(255, value * alpha * 255)))
            }
            let offset = index * 4
            pixels[offset] = component(red)
            pixels[offset + 1] = component(green)
            pixels[offset + 2] = component(blue)
            pixels[offset + 3] = UInt8(max(0, min(255, alpha * 255)))
        }
        return pixels.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: columns, height: rows,
                      bitsPerComponent: 8, bytesPerRow: columns * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
                .makeImage()
        }
    }
}

// MARK: - Content view

struct ContentView: View {
    /// The app's feature tiers, from a single demonstrated path up to the
    /// full generative canvas. Each mode reveals only the controls it needs.
    enum AppMode: String, CaseIterable, Identifiable {
        /// One triangle, one target, one start iterate — the algorithm
        /// itself, traced slowly with each pivot pointed out.
        case basic = "Basic"
        /// Many starting iterates at once. The coloring button picks how the
        /// run is shown: plain paths, palette-filled regions between them,
        /// or the iteration-intensity field.
        case paths = "Paths"
        /// Every point of the hull shaded in one color, its intensity set
        /// by how many iterations the algorithm needs from there.
        case partition = "Partition"

        var id: String { rawValue }
    }

    enum DragTarget: Hashable {
        case query
        case hull(Int)
        case start(Int)
    }

    /// Preset outlines the vertex set S can be sampled from: random points
    /// scattered along the shape's boundary.
    enum ShapePreset: String, CaseIterable, Identifiable {
        case square = "Square"
        case circle = "Circle"
        case ellipse = "Ellipse"
        case diamond = "Diamond"
        case pentagon = "Pentagon"
        case hexagon = "Hexagon"
        case star = "Star"

        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .square: "square"
            case .circle: "circle"
            case .ellipse: "oval"
            case .diamond: "diamond"
            case .pentagon: "pentagon"
            case .hexagon: "hexagon"
            case .star: "star"
            }
        }
    }

    /// The interactive walkthroughs, one flow per mode. Each step drives
    /// the real canvas and, where possible, advances on the user's own
    /// action — placing the third triangle point, a trace finishing, a
    /// wedge getting painted — with a Next button as the manual fallback.
    enum TutorialStep: Int, CaseIterable {
        // Basic: the algorithm itself, one slow trace at a time.
        case placeTriangle
        case dragTarget
        case runIt
        case watchTrace
        case readResult
        case tryOtherSide
        case explore
        // Paths: a whole set of starting iterates at once, then the
        // coloring button turns the paths into a painting.
        case pathsLoadShape
        case pathsWatch
        case pathsSchemes
        case pathsColoring
        case regionsWatch
        case regionsPaint
        case regionsThemes
        // Partition: the hull shaded by how many iterations each point needs.
        case partitionRun
        case partitionRead
        case partitionLive

        /// The mode whose walkthrough this step belongs to.
        var flow: AppMode {
            switch self {
            case .placeTriangle, .dragTarget, .runIt, .watchTrace,
                 .readResult, .tryOtherSide, .explore: .basic
            case .pathsLoadShape, .pathsWatch, .pathsSchemes, .pathsColoring,
                 .regionsWatch, .regionsPaint, .regionsThemes: .paths
            case .partitionRun, .partitionRead, .partitionLive: .partition
            }
        }

        static func first(for mode: AppMode) -> TutorialStep {
            switch mode {
            case .basic: .placeTriangle
            case .paths: .pathsLoadShape
            case .partition: .partitionRun
            }
        }

        /// The next step within the same flow; nil at the flow's end.
        var next: TutorialStep? {
            guard let candidate = TutorialStep(rawValue: rawValue + 1),
                  candidate.flow == flow else { return nil }
            return candidate
        }

        var indexInFlow: Int { rawValue - Self.first(for: flow).rawValue }
        var flowLength: Int { Self.allCases.filter { $0.flow == flow }.count }

        /// The step's instruction; result-dependent steps read the current
        /// membership verdict so the text matches what's on screen.
        func instruction(inside: Bool?) -> String {
            switch self {
            case .placeTriangle:
                "Tap three spots on the canvas. They become S — the corner points of a triangle."
            case .dragTarget:
                "The round dot is the target p. Drag it anywhere — the algorithm will test whether p lies inside the triangle."
            case .runIt:
                "The small square is the starting iterate. The algorithm will walk it toward p, one pivot at a time. Press Run."
            case .watchTrace:
                "Watch each step: the ring marks the pivot — a corner at least as far from the iterate as from p — and the iterate slides along the dashed direction to the spot nearest p."
            case .readResult:
                inside == false
                    ? "The iterate stopped at a ✕ — a witness. No valid pivot was left, which proves p is outside the triangle; the red dot up top says the same."
                    : "The iterate reached p, so p is inside the triangle — the green dot up top confirms it."
            case .tryOtherSide:
                inside == false
                    ? "Now drag p inside the triangle and press Run again — this time the iterate should reach it."
                    : "Now drag p outside the triangle and press Run again — with no valid pivot left, the iterate stops as a ✕ witness."
            case .explore:
                "That's the whole algorithm! Explore the modes up top: Paths traces many starts at once, with a coloring button that paints the areas between them, and Partition shades the hull by how many iterations each point needs. Each has its own tutorial under the ⋯ menu."
            case .pathsLoadShape:
                "Paths traces a whole set of starting iterates at once. Load a point set from the shape menu below — Circle is a good start — or tap points by hand and press Run."
            case .pathsWatch:
                "Every small square is a starting iterate. They all walk toward p at the same time, each picking its own pivots along the way."
            case .pathsSchemes:
                "Each path either reached p or stopped at a ✕ witness. The grid button at the top left lays the starts out differently — Border, Corners, Points of S, Ring, Spiral, or your own custom set. Pick one and Run again."
            case .pathsColoring:
                "Everything is live: drag p or any point of S and the paths re-trace as you move. Now turn them into a painting — tap the coloring button next to the grid button and choose Palette slices."
            case .regionsWatch:
                "The area between neighboring paths now fills with the palette's colors. Press Run to watch each wedge fill in as the paths sweep toward p."
            case .regionsPaint:
                "Now paint by hand: tap the paintbrush at the top left, pick a color from the wheel, then tap any wedge to recolor it."
            case .regionsThemes:
                "Nice! The coloring button also offers Iteration intensity, a gradient over the hull. Themes and a custom palette live under ⋯ → Settings, and the share button exports the picture as a poster. Last stop: the Partition tutorial, under ⋯."
            case .partitionRun:
                "Partition answers one question: starting from each point inside the hull, how many iterations does the algorithm need to reach p? Load a shape from the menu below or tap your own points, then press Run."
            case .partitionRead:
                "One color, many shades: the deeper the tint, the more iterations the algorithm takes from that point. Pale regions converge almost at once."
            case .partitionLive:
                "Drag p and watch the shading reshape around it. That's the full tour — replay any tutorial from the ⋯ menu."
            }
        }
    }

    /// A rendered poster ready for previewing and the share sheet.
    /// The identity is stable so re-rendering at a new resolution updates
    /// the presented sheet in place instead of dismissing and re-presenting.
    struct PosterImage: Identifiable {
        var id: String { "poster" }
        let image: Image
        let platformImage: PlatformImage
        let pixelSize: CGSize
    }

    /// Render scale for poster export, as a multiple of the on-screen size.
    enum ExportResolution: String, CaseIterable, Identifiable {
        case standard = "2×"
        case high = "4×"
        case ultra = "8×"

        var id: String { rawValue }

        var scale: CGFloat {
            switch self {
            case .standard: 2
            case .high: 4
            case .ultra: 8
            }
        }
    }

    @AppStorage("appMode") private var mode: AppMode = .basic
    @State private var hullPoints: [CGPoint] = []
    @State private var queryPoint: CGPoint? = nil

    init(seedHullPoints: [CGPoint] = [], seedQueryPoint: CGPoint? = nil) {
        _hullPoints = State(initialValue: seedHullPoints)
        _queryPoint = State(initialValue: seedQueryPoint)
    }
    @State private var trajectories: [Trajectory] = []
    @State private var runStart: Date? = nil
    @State private var isAnimating = false
    @State private var canvasSize: CGSize = .zero
    @State private var activeDrag: DragTarget? = nil
    @State private var dragResolved = false
    @State private var showInfo = false
    @State private var showHelp = false
    @State private var tutorialStep: TutorialStep? = nil
    /// The verdict of the run the tutorial is narrating, captured when the
    /// trace finishes so the step text doesn't flip while the user drags
    /// p around for the next step.
    @State private var tutorialVerdict: Bool? = nil
    @AppStorage("hasSeenHelpOverlay") private var hasSeenHelpOverlay = false
    @State private var palette: Palette = .mondrian
    @State private var showPaletteEditor = false
    @AppStorage("customPalette") private var customPaletteJSON = ""
    /// The informational chips a tap on × can hide. Dismissals clear on the
    /// next run (or mode switch), so a fresh result shows up again.
    enum Chip: Hashable {
        case status, result, fieldProgress, tracing
    }
    @State private var dismissedChips: Set<Chip> = []
    /// Master switch for the informational chips, under Settings → Trace;
    /// off by default so the canvas stays uncluttered. The painting and
    /// iterate-editing chips carry their own controls and stay regardless.
    @AppStorage("showChips") private var showChips = false

    /// The iterate layout a coloring opens with — the single source for the
    /// launch, mode-switch, and coloring-switch paths. Palette slices start
    /// from the points of S so every wedge is anchored at a vertex; plain
    /// paths spread along the border. Intensity ignores iterates, so nil.
    private func defaultScheme(for coloring: ColoringMode) -> IterateScheme? {
        switch coloring {
        case .paths: .border
        case .palette: .pointsOfS
        case .intensity: nil
        }
    }

    /// Whether a given informational chip should be on screen. The
    /// tutorials narrate the chips ("the green dot up top"), so they show
    /// during a walkthrough even when the setting is off.
    private func chipVisible(_ chip: Chip) -> Bool {
        (showChips || tutorialStep != nil) && !dismissedChips.contains(chip)
    }

    /// How a Paths run is shown; chosen with the coloring button and
    /// remembered across launches like the mode itself.
    @AppStorage("coloringMode") private var coloringMode: ColoringMode = .paths
    @State private var iterationField: IterationField? = nil
    @State private var fieldImage: CGImage? = nil
    @State private var fieldTask: Task<Void, Never>? = nil
    @State private var isBuildingField = false
    @State private var fieldProgress: Double = 0
    @State private var partitionField: IterationField? = nil
    @State private var partitionImage: CGImage? = nil
    @State private var iterateScheme: IterateScheme = .border
    /// The step rule every trace (and the intensity field) runs under.
    @AppStorage("stepStrategy") private var stepStrategy: StepStrategy = .toward
    /// Pairs per scan for the guarded block strategy.
    @AppStorage("blockSize") private var blockSize = 4
    @AppStorage("iterateCount") private var iterateCount = 8
    @AppStorage("trajectoryLineWidth") private var trajectoryLineWidth = 4.0
    @AppStorage("hullLineWidth") private var hullLineWidth = 3.0
    @AppStorage("pointMarkerSize") private var pointMarkerSize = 6.0
    @State private var showSettings = false
    /// Basic mode's "why this pivot" card; dismissed per run, back on the next.
    @State private var showPivotExplanation = true
    /// Basic mode: reveal the trace one step per tap instead of on a timer.
    @AppStorage("basicManualStepping") private var manualStepping = false
    /// How many steps of a manual run have been taken so far.
    @State private var revealedSteps = 0
    /// The step the card (and the pivot demo) is showing once a run has
    /// finished and the user is paging through it.
    @State private var reviewedStep = 0
    @State private var startPoints: [CGPoint] = []
    @State private var isEditingIterates = false
    @State private var isPaintingWedges = false
    @State private var paintColor: Color = .orange
    /// User-picked wedge fills, keyed by wedge index. Painted on top of the
    /// palette's own coloring, and never cleared by theme or run changes —
    /// the user works on top of the existing canvas.
    @State private var wedgeOverrides: [Int: Color] = [:]
    @State private var showAddHullPointsAlert = false
    @State private var showOutsideHullWarning = false
    @State private var outsideHullWarningNonce = 0
    @State private var soundOn = true
    @State private var showBisector = false
    @State private var isAmbient = false
    @State private var poster: PosterImage? = nil
    @State private var exportResolution: ExportResolution = .high
    @State private var isRenderingPoster = false
    @State private var isSavingToPhotos = false
    @State private var didSaveToPhotos = false
    @State private var showSaveFailedAlert = false
    @State private var showPosterRenderFailedAlert = false
    @State private var soundEngine = SoundEngine()

    /// Basic mode traces slowly enough to follow each pivot; the other
    /// modes favor a lively composition.
    private var stepsPerSecond: Double { mode == .basic ? 1.6 : 7 }
    private let grabRadius: CGFloat = 30

    private var hasRun: Bool { !trajectories.isEmpty }

    /// Steps in Basic mode's single trace.
    private var totalSteps: Int { trajectories.first?.steps.count ?? 0 }

    /// A Basic-mode run being revealed by hand rather than on the timer.
    private var isManualRun: Bool { mode == .basic && manualStepping && hasRun }

    /// A manual run with steps still to take: the picture and verdict are
    /// incomplete, exactly as during an animated trace.
    private var isManualStepping: Bool { isManualRun && revealedSteps < totalSteps }

    /// Whether the current mode has a finished picture worth exporting.
    private var hasResult: Bool { mode == .partition ? partitionField != nil : hasRun }

    /// The membership verdict: true (inside), false (outside), or nil when
    /// there is no result — or when every trajectory merely ran out of
    /// iterations, which proves nothing.
    private var membershipResult: Bool? {
        guard hasResult else { return nil }
        if mode == .partition {
            // The partition samples every point of the hull instead of
            // tracing from chosen starts, so the verdict is read straight
            // from the geometry.
            guard let p = queryPoint else { return nil }
            return isInsideConvexHull(p, hull: convexHull(of: hullPoints))
        }
        // One converged trajectory is a constructive proof that p is in the
        // hull; failing that, one genuine witness proves it is outside.
        if trajectories.contains(where: { $0.outcome == .converged }) { return true }
        if trajectories.contains(where: { $0.outcome == .witness }) { return false }
        return nil
    }

    /// The iterations the result took: the longest trace in Basic and Paths
    /// (the picture is finished once it settles), and the most demanding
    /// sampled point in Partition.
    private var resultIterations: Int? {
        guard hasResult else { return nil }
        if mode == .partition { return partitionField?.maxCount }
        return trajectories.map(\.steps.count).max()
    }

    var body: some View {
        ZStack {
            canvas

            if hullPoints.isEmpty && !isAmbient && !isEditingIterates && tutorialStep == nil {
                emptyStateHint
            }

            if isAmbient {
                ambientHint
                    .transition(.opacity)
            } else {
                VStack(spacing: 12) {
                    topOverlay
                    Spacer()
                    if let step = tutorialStep {
                        tutorialCard(step)
                    }
                    pivotExplanationCard
                    controlBar
                }
                .padding()
                .transition(.opacity)
            }

            if showHelp {
                HelpOverlay(dismiss: {
                    hasSeenHelpOverlay = true
                    showHelp = false
                }, startTutorial: {
                    startTutorial()
                })
                .transition(.opacity)
                .zIndex(1)
            }
        }
        .onAppear {
            if !hasSeenHelpOverlay { showHelp = true }
            // The Regions tab folded into Paths with the palette coloring;
            // carry a saved Regions preference over instead of dropping it.
            if UserDefaults.standard.string(forKey: "appMode") == "Regions" {
                mode = .paths
                coloringMode = .palette
            }
            // The mode and coloring persist across launches but the scheme
            // doesn't: restore the coloring's default when launching into Paths.
            if mode == .paths, let scheme = defaultScheme(for: coloringMode) {
                iterateScheme = scheme
            }
        }
        .animation(.easeInOut(duration: 0.25), value: showHelp)
        .animation(.easeInOut(duration: 0.3), value: isAmbient)
        .sensoryFeedback(trigger: isAnimating) { oldValue, newValue in
            guard oldValue && !newValue, let inside = membershipResult else { return nil }
            return inside ? .success : .error
        }
        .task(id: runStart) {
            // Stop the timeline once the longest trajectory has fully traced.
            // Clamped to the score's cap so a run that hit the iteration
            // limit jumps to its finished picture when the audio ends
            // instead of animating for minutes past it.
            guard runStart != nil, isAnimating else { return }
            let maxSteps = trajectories.map(\.points.count).max() ?? 0
            let duration = min(Double(max(maxSteps - 1, 0)) / stepsPerSecond + 0.4,
                               SoundEngine.maxScoreDuration)
            try? await Task.sleep(for: .seconds(duration))
            withAnimation(.spring(duration: 0.4)) { isAnimating = false }
        }
        .task(id: isAmbient) {
            // Ambient wallpaper mode: keep composing until the user taps out.
            guard isAmbient else { return }
            while isAmbient && !Task.isCancelled {
                randomExample()
                let maxSteps = trajectories.map(\.points.count).max() ?? 0
                let traceDuration = min(Double(max(maxSteps - 1, 0)) / stepsPerSecond + 0.4,
                                        SoundEngine.maxScoreDuration)
                // Let the finished composition hang on screen before repainting.
                try? await Task.sleep(for: .seconds(traceDuration + 3.5))
            }
        }
        .sensoryFeedback(.warning, trigger: outsideHullWarningNonce)
        .task(id: outsideHullWarningNonce) {
            // Auto-dismiss the outside-the-hull warning; the nonce restarts
            // the timer when the user keeps tapping outside.
            guard showOutsideHullWarning else { return }
            try? await Task.sleep(for: .seconds(2))
            withAnimation(.easeInOut(duration: 0.3)) { showOutsideHullWarning = false }
        }
        .onChange(of: soundOn) { _, isOn in
            if !isOn { soundEngine.stop() }
        }
        .onChange(of: isAnimating) { _, animating in
            // The tutorials follow the user's own runs: starting a trace
            // moves to the commentary step, a finished trace moves on to
            // reading the result.
            guard let step = tutorialStep else { return }
            let advanced: TutorialStep?
            if animating {
                switch step {
                case .dragTarget, .runIt: advanced = .watchTrace
                case .pathsLoadShape: advanced = .pathsWatch
                default: advanced = nil
                }
            } else {
                switch step {
                case .watchTrace:
                    tutorialVerdict = membershipResult
                    advanced = .readResult
                case .tryOtherSide where hasRun: advanced = .explore
                case .pathsWatch: advanced = .pathsSchemes
                case .regionsWatch: advanced = .regionsPaint
                default: advanced = nil
                }
            }
            if let advanced {
                withAnimation(.spring(duration: 0.35)) { tutorialStep = advanced }
            }
        }
        .onChange(of: isBuildingField) { _, building in
            // Partition tutorial: move on once the first partition renders.
            if !building, tutorialStep == .partitionRun, partitionField != nil {
                withAnimation(.spring(duration: 0.35)) { tutorialStep = .partitionRead }
            }
        }
        .onChange(of: wedgeOverrides) { _, overrides in
            // Paths tutorial: painting the first wedge completes the step.
            if !overrides.isEmpty, tutorialStep == .regionsPaint {
                withAnimation(.spring(duration: 0.35)) { tutorialStep = .regionsThemes }
            }
        }
        .onChange(of: coloringMode) { _, newMode in
            if newMode == .intensity {
                // The plot doesn't use the iterate set or the wedge fills;
                // leave both editing modes.
                isEditingIterates = false
                isPaintingWedges = false
                // A cleared custom set would leave Run disabled with the
                // iterate controls hidden — fall back to the default scheme.
                if startPoints.isEmpty { iterateScheme = .border }
            } else if newMode == .paths {
                // Plain paths have no wedges to paint.
                isPaintingWedges = false
            }
            // Each coloring opens with its own default iterate layout; a
            // hand-placed custom set is the user's own and stays.
            if mode == .paths, iterateScheme != .custom, let scheme = defaultScheme(for: newMode) {
                iterateScheme = scheme
            }
            rebuildIterationField()
            // Paths tutorial: choosing the palette coloring completes the step.
            if newMode == .palette, tutorialStep == .pathsColoring {
                withAnimation(.spring(duration: 0.35)) { tutorialStep = .regionsWatch }
            }
        }
        .onChange(of: palette) { _, newPalette in
            // The fields' data survives a theme change; only re-tint the bitmaps.
            if let field = iterationField {
                fieldImage = field.makeImage(baseColor: PlatformColor(newPalette.intensityBase))
            }
            if let field = partitionField {
                partitionImage = field.makeImage(baseColor: PlatformColor(newPalette.intensityBase))
            }
        }
        .onChange(of: mode) { _, newMode in
            // A tutorial narrates one specific mode; switching away from
            // it mid-flow ends the walkthrough.
            if let step = tutorialStep, step.flow != newMode {
                tutorialStep = nil
            }
            // A mode switch keeps the placed points but clears the finished
            // picture — each tier composes its own kind of result.
            dismissedChips = []
            trajectories = []
            runStart = nil
            isAnimating = false
            soundEngine.stop()
            cancelFieldBuild()
            iterationField = nil
            fieldImage = nil
            partitionField = nil
            partitionImage = nil
            isEditingIterates = false
            isPaintingWedges = false
            if newMode == .basic {
                // Basic works on a single triangle: keep three well-spread
                // hull vertices when arriving from a many-point set.
                let hull = convexHull(of: hullPoints)
                if hullPoints.count > 3 && hull.count >= 3 {
                    hullPoints = [hull[0], hull[hull.count / 3], hull[2 * hull.count / 3]]
                }
                startPoints = Array(startPoints.prefix(1))
            }
            // Paths opens with a default iterate layout suited to its
            // coloring; a hand-placed custom set is the user's own and stays.
            if iterateScheme != .custom, newMode == .paths,
               let scheme = defaultScheme(for: coloringMode) {
                iterateScheme = scheme
            }
            syncIteratesToHull()
        }
        .onChange(of: iterateScheme) { _, newScheme in
            guard mode != .basic,
                  let points = newScheme.points(inHull: convexHull(of: hullPoints), vertices: hullPoints, count: iterateCount) else { return }
            startPoints = points
            if hasRun { recompute(animated: false) }
        }
        .onChange(of: iterateCount) { _, newCount in
            // Regenerate the current scheme at the new size; custom sets
            // are the user's own and stay untouched, as is basic mode's
            // single start.
            guard mode != .basic,
                  let points = iterateScheme.points(inHull: convexHull(of: hullPoints), vertices: hullPoints, count: newCount) else { return }
            startPoints = points
            if hasRun { recompute(animated: false) }
        }
        .onChange(of: manualStepping) { _, _ in
            // Switching the stepping style mid-run keeps the finished
            // picture on screen; the next Run starts in the new style.
            guard mode == .basic else { return }
            stopTrace()
            revealedSteps = totalSteps
        }
        .onChange(of: revealedSteps) { _, taken in
            // Manual runs drive the Basic tutorial the way an animation
            // ending does: the last step taken moves on to the verdict.
            guard isManualRun, taken >= totalSteps, let step = tutorialStep else { return }
            let advanced: TutorialStep?
            switch step {
            case .watchTrace:
                tutorialVerdict = membershipResult
                advanced = .readResult
            case .tryOtherSide: advanced = .explore
            default: advanced = nil
            }
            if let advanced {
                withAnimation(.spring(duration: 0.35)) { tutorialStep = advanced }
            }
        }
        .sensoryFeedback(trigger: revealedSteps) { _, taken in
            guard isManualRun else { return nil }
            if taken >= totalSteps, let inside = membershipResult { return inside ? .success : .error }
            return .selection
        }
        .onChange(of: stepStrategy) { _, _ in
            // A finished picture re-traces under the new rule in place, so
            // the strategies can be compared on the same hull and target.
            if hasResult { recompute(animated: false) }
        }
        .onChange(of: blockSize) { _, _ in
            if hasResult, stepStrategy == .block { recompute(animated: false) }
        }
        .alert("Add hull points first", isPresented: $showAddHullPointsAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Place at least three points to form a hull, then edit the iterates inside it.")
        }
        .sheet(item: $poster) { poster in
            posterSheet(for: poster)
        }
        .alert("Couldn't render the poster", isPresented: $showPosterRenderFailedAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("There wasn't enough memory to render at this size. Try a lower export resolution.")
        }
        .sheet(isPresented: $showSettings) {
            settingsSheet
        }
    }

    /// App settings. Edits apply immediately, so the canvas behind the
    /// sheet previews new colors and iterate layouts live.
    private var settingsSheet: some View {
        NavigationStack {
            Form {
                Section("Appearance") {
                    Picker("Theme", selection: $palette) {
                        ForEach(Palette.all) { palette in
                            Text(palette.name).tag(palette)
                        }
                        Text("Custom").tag(Palette.custom(from: customPaletteData))
                    }
                    Button {
                        // Switch to the custom palette so edits preview live
                        // behind the editor.
                        palette = .custom(from: customPaletteData)
                        showPaletteEditor = true
                    } label: {
                        Label("Customize palette…", systemImage: "slider.horizontal.3")
                    }
                    // The coloring only applies to Paths; offering it elsewhere
                    // would silently change the next Paths visit.
                    if mode == .paths {
                        Picker("Coloring", selection: $coloringMode) {
                            ForEach(ColoringMode.allCases) { coloring in
                                Label(coloring.rawValue, systemImage: coloring.symbol).tag(coloring)
                            }
                        }
                    }
                }
                Section {
                    Picker("Step strategy", selection: $stepStrategy) {
                        ForEach(StepStrategy.allCases) { strategy in
                            Label(strategy.name, systemImage: strategy.symbol).tag(strategy)
                        }
                    }
                    if stepStrategy == .block {
                        Stepper(value: $blockSize, in: 1...16) {
                            LabeledContent("Block size k", value: "\(blockSize)")
                        }
                    }
                } header: {
                    Text("Algorithm")
                } footer: {
                    Text(stepStrategy.summary)
                }
                Section {
                    Toggle(isOn: $showBisector) {
                        Label("Witness bisector", systemImage: "line.diagonal")
                    }
                    Toggle(isOn: $soundOn) {
                        Label("Sound", systemImage: soundOn ? "speaker.wave.2" : "speaker.slash")
                    }
                    Toggle(isOn: $showChips) {
                        Label("Status chips", systemImage: "capsule")
                    }
                } header: {
                    Text("Trace")
                } footer: {
                    Text("Status chips show the membership verdict with its iteration count, Basic mode's step summary, and progress while tracing or building a field. Each can also be hidden with its ×.")
                }
                Section {
                    VStack(alignment: .leading) {
                        LabeledContent("Trajectories", value: trajectoryLineWidth.formatted())
                        Slider(value: $trajectoryLineWidth, in: 0...10, step: 0.5)
                    }
                    VStack(alignment: .leading) {
                        LabeledContent("Convex hull", value: hullLineWidth.formatted())
                        Slider(value: $hullLineWidth, in: 0...10, step: 0.5)
                    }
                    VStack(alignment: .leading) {
                        LabeledContent("Point markers", value: pointMarkerSize.formatted())
                        Slider(value: $pointMarkerSize, in: 0.5...20, step: 0.5)
                    }
                } header: {
                    Text("Line & marker size")
                } footer: {
                    Text("A line width of 0 hides that line entirely.")
                }
                Section {
                    Stepper(value: $iterateCount, in: 4...24) {
                        LabeledContent("Iterates", value: "\(iterateCount)")
                    }
                } header: {
                    Text("Auto-generated iterates")
                } footer: {
                    Text("How many starting iterates the schemes generate. Corners uses fewer when the hull has fewer vertices; Points of S ignores this and starts from every point of S.")
                }
            }
            .navigationTitle("Settings")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showSettings = false }
                }
            }
            .sheet(isPresented: $showPaletteEditor) {
                CustomPaletteEditor(data: customPaletteBinding)
            }
        }
        .mediumOrLargeDetents()
    }

    /// The stored custom palette, falling back to the starter set.
    private var customPaletteData: CustomPaletteData {
        CustomPaletteData(json: customPaletteJSON) ?? .initial
    }

    /// Writes edits back to storage and, when the custom palette is the one
    /// on screen, applies them immediately so the canvas previews live.
    private var customPaletteBinding: Binding<CustomPaletteData> {
        Binding(
            get: { customPaletteData },
            set: { newValue in
                customPaletteJSON = newValue.jsonString
                if palette.id == "Custom" {
                    palette = .custom(from: newValue)
                }
            }
        )
    }

    // MARK: Overlays

    private var emptyStateHint: some View {
        VStack(spacing: 10) {
            Image(systemName: "hand.tap")
                .font(.system(size: 44))
            Text(mode == .basic
                 ? "Tap 3 points to make the triangle S"
                 : "Tap anywhere to add points of S")
                .font(.headline)
            Text(mode == .basic
                 ? "Then drag the target p and the start square, and press Run"
                 : "Drag the target dot to move it, then press Run")
                .font(.subheadline)
        }
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 40)
        .allowsHitTesting(false)
    }

    private var ambientHint: some View {
        VStack {
            Spacer()
            Text("Ambient mode — tap anywhere to exit")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .glassEffect()
                .padding(.bottom, 30)
        }
        .allowsHitTesting(false)
    }

    private var topOverlay: some View {
        VStack(spacing: 10) {
            modePicker
            HStack(alignment: .top, spacing: 10) {
                // The iterate set only matters where many paths are traced:
                // basic has a single fixed start, partition ignores starts,
                // and the intensity plot samples its own grid.
                if mode == .paths && coloringMode != .intensity {
                    iterateMenu
                }
                // The coloring button toggles how a Paths run is shown.
                if mode == .paths {
                    coloringMenu
                }
                // The step rule shapes every trace, including the iteration
                // counts behind the partition shading.
                strategyMenu
                if mode == .paths && coloringMode == .palette && hasRun {
                    paintButton
                }
                Spacer()
                resultDot
                shareButton
                infoButton
            }
            // The chip gets its own row so its text never fights the
            // buttons for width on small screens.
            statusChip
            if isBuildingField, chipVisible(.fieldProgress) {
                fieldProgressChip
                    .transition(.opacity)
            }
        }
        .animation(.spring(duration: 0.4), value: isAnimating)
        .animation(.spring(duration: 0.4), value: hasRun)
        .animation(.spring(duration: 0.3), value: isBuildingField)
        .animation(.spring(duration: 0.3), value: coloringMode)
        .animation(.spring(duration: 0.3), value: dismissedChips)
        .animation(.spring(duration: 0.3), value: showChips)
    }

    /// The × that hides a chip until the next run brings it back.
    private func dismissButton(for chip: Chip) -> some View {
        Button {
            dismissedChips.insert(chip)
        } label: {
            Image(systemName: "xmark")
                .font(.caption2.bold())
                .foregroundStyle(.secondary)
                .padding(4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Hide")
    }

    /// The feature tiers, from the single demonstrated path to the full
    /// canvas. Switching keeps the points but clears the finished picture.
    private var modePicker: some View {
        Picker("Mode", selection: $mode) {
            ForEach(AppMode.allCases) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 420)
        .padding(4)
        .glassEffect(in: .rect(cornerRadius: 12))
    }

    private var fieldProgressChip: some View {
        HStack(spacing: 10) {
            ProgressView(value: fieldProgress)
                .frame(width: 90)
            Text("\(mode == .partition ? "Partition" : "Intensity") \(Int(fieldProgress * 100))%")
                .monospacedDigit()
            Button("Stop") {
                cancelFieldBuild()
            }
            .font(.caption.bold())
            dismissButton(for: .fieldProgress)
        }
        .font(.caption)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect()
        // Contain rather than combine so Stop and × stay reachable.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Computing \(mode == .partition ? "partition" : "intensity plot")")
    }

    /// Membership verdict as a dot beside the menu buttons — green for
    /// inside the hull, red for outside, orange when every trace hit the
    /// iteration cap and the run proved nothing — with the number of
    /// iterations the result took alongside. Shown in every mode once a
    /// result exists.
    @ViewBuilder
    private var resultDot: some View {
        // Partition waits for the fine field to finish (and the drag to end)
        // the way Paths waits for the animation, so the count doesn't tick
        // upward batch by batch or jump between coarse and fine values.
        let partitionSettled = mode != .partition || (!isBuildingField && activeDrag == nil)
        if hasResult, !isAnimating, !isManualStepping, partitionSettled, chipVisible(.result) {
            let inside = membershipResult
            let iterations = resultIterations ?? 0
            HStack(spacing: 8) {
                Circle()
                    .fill(inside == true ? Color.green : inside == false ? Color.red : Color.orange)
                    .frame(width: 12, height: 12)
                Text("\(iterations)")
                    .font(.subheadline.monospacedDigit().bold())
                dismissButton(for: .result)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .glassEffect()
            .transition(.opacity)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(
                (inside == true ? "Inside the convex hull"
                 : inside == false ? (mode == .partition ? "Outside the convex hull" : "Outside — witness found")
                 : "Inconclusive — iteration limit reached")
                + ", \(iterations) iteration\(iterations == 1 ? "" : "s")"
            )
        }
    }

    /// Enters wedge-painting mode, where a tap fills the wedge under the
    /// finger with the chosen color, layered over the palette's coloring.
    private var paintButton: some View {
        Button {
            isPaintingWedges.toggle()
            if isPaintingWedges { isEditingIterates = false }
        } label: {
            Image(systemName: isPaintingWedges ? "paintbrush.fill" : "paintbrush")
        }
        .buttonStyle(.glass)
        .accessibilityLabel(isPaintingWedges ? "Stop painting wedges" : "Paint wedges")
    }

    @ViewBuilder
    private var statusChip: some View {
        if isPaintingWedges && !isAnimating {
            HStack(spacing: 12) {
                ColorPicker("Wedge color", selection: $paintColor, supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 32)
                Label("Tap a wedge to paint it", systemImage: "hand.tap")
                Button("Clear", role: .destructive) {
                    wedgeOverrides = [:]
                }
                .disabled(wedgeOverrides.isEmpty)
                Button("Done") {
                    isPaintingWedges = false
                }
                .font(.subheadline.bold())
            }
            .font(.subheadline)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassEffect()
        } else if isEditingIterates && !isAnimating {
            HStack(spacing: 12) {
                if showOutsideHullWarning {
                    Label("Place iterates inside the hull", systemImage: "exclamationmark.triangle.fill")
                } else {
                    Label("Iterates: tap to add, drag to move", systemImage: "square.and.pencil")
                    Button("Clear", role: .destructive) {
                        clearIterates()
                    }
                    .disabled(startPoints.isEmpty)
                    Button("Done") {
                        isEditingIterates = false
                    }
                    .font(.subheadline.bold())
                }
            }
            .font(.subheadline)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassEffect(showOutsideHullWarning
                         ? .regular.tint(Color.orange.opacity(0.45))
                         : .regular)
        } else if isAnimating, chipVisible(.tracing) {
            HStack(spacing: 12) {
                Label("Tracing \(trajectories.count) trajector\(trajectories.count == 1 ? "y" : "ies")…", systemImage: "point.bottomleft.forward.to.point.topright.scurvepath")
                Button("Stop") {
                    stopTrace()
                }
                .font(.subheadline.bold())
                dismissButton(for: .tracing)
            }
            .font(.subheadline)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassEffect()
        } else if let hint = hullHint, !dismissedChips.contains(.status) {
            // A greyed Run button needs explaining, so this hint ignores the
            // chip setting; it disappears on its own once the hull is valid.
            statusText(hint)
        } else if mode == .basic, !hullPoints.isEmpty, !isAnimating, chipVisible(.status) {
            // Only Basic narrates its idle state; the other modes let the
            // picture and the result pill speak for themselves.
            statusText(basicStatus)
        }
    }

    private func statusText(_ text: String) -> some View {
        HStack(spacing: 10) {
            Text(text)
                .foregroundStyle(.secondary)
            dismissButton(for: .status)
        }
        .font(.subheadline)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect()
    }

    /// Why Run is disabled when the hull is the reason: too few points, or
    /// points all on one line. Nil once a real hull exists.
    private var hullHint: String? {
        guard !hullPoints.isEmpty else { return nil }
        let n = hullPoints.count
        if mode == .basic {
            if n < 3 { return "\(n) of 3 triangle points" }
            // Everything downstream tests the convex hull, not the raw
            // count — collinear points have no interior, so the chip must
            // not announce a triangle that doesn't exist.
            if convexHull(of: hullPoints).count < 3 {
                return "Corners are on one line — drag one to open the triangle"
            }
            return nil
        }
        if n < 3 { return "\(n) point\(n == 1 ? "" : "s") — add at least 3" }
        if convexHull(of: hullPoints).count < 3 { return "\(n) points on one line — add one off it" }
        return nil
    }

    /// Basic mode's idle status once the triangle exists: the run summary,
    /// or a nudge to Run.
    private var basicStatus: String {
        // After a run, account for the steps so the strategies can be
        // compared by eye: how many steps, and of which kinds.
        if hasRun, !isManualStepping, let summary = stepSummary {
            return summary
        }
        return "Triangle ready — drag the corners, target, or start square, then Run"
    }

    /// The step the pivot demo and explanation card are focused on: the
    /// one being traced while animating, else the one the user paged to.
    private func focusedStepIndex(at date: Date, stepCount: Int) -> Int {
        guard stepCount > 0 else { return 0 }
        if isAnimating, let start = runStart {
            let progress = max(0, date.timeIntervalSince(start)) * stepsPerSecond
            return min(max(Int(progress), 0), stepCount - 1)
        }
        return min(max(reviewedStep, 0), stepCount - 1)
    }

    /// Basic mode's small "why this pivot" card. While the trace animates it
    /// narrates the step being drawn; afterwards it pages through the run,
    /// and the pivot demo highlights whichever step is showing.
    ///
    /// In manual stepping the card is also the controller: Next takes the
    /// step it is describing, Back undoes it, and the trace on the canvas
    /// grows one segment at a time.
    @ViewBuilder
    private var pivotExplanationCard: some View {
        if mode == .basic, showPivotExplanation || isManualRun, tutorialStep == nil,
           let trajectory = trajectories.first, !trajectory.steps.isEmpty {
            TimelineView(.animation(minimumInterval: 0.1, paused: !isAnimating)) { timeline in
                let steps = trajectory.steps
                let manual = isManualRun
                let taken = min(revealedSteps, steps.count)
                let index = manual ? min(taken, steps.count - 1)
                                   : focusedStepIndex(at: timeline.date, stepCount: steps.count)
                let step = steps[index]
                let pending = manual && taken < steps.count
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 14) {
                        Text(pending ? "Next: step \(index + 1) of \(steps.count) · \(step.kind.label)"
                                     : "Step \(index + 1) of \(steps.count) · \(step.kind.label)")
                            .font(.subheadline.bold())
                            .monospacedDigit()
                        Spacer()
                        if manual {
                            Button {
                                revealManualSteps(taken - 1)
                            } label: {
                                Image(systemName: "chevron.left")
                            }
                            .disabled(taken == 0)
                            .accessibilityLabel("Back one step")
                            Button {
                                revealManualSteps(taken + 1)
                            } label: {
                                Label("Next", systemImage: "chevron.right")
                                    .labelStyle(.titleAndIcon)
                            }
                            .buttonStyle(.borderedProminent)
                            .buttonBorderShape(.capsule)
                            .controlSize(.small)
                            .disabled(!pending)
                            .accessibilityLabel("Take the next step")
                            if pending {
                                Button("Skip to end") {
                                    revealManualSteps(steps.count)
                                }
                                .font(.caption)
                            }
                        } else {
                            if !isAnimating {
                                Button {
                                    reviewedStep = index - 1
                                } label: {
                                    Image(systemName: "chevron.left")
                                }
                                .disabled(index == 0)
                                .accessibilityLabel("Previous step")
                                Button {
                                    reviewedStep = index + 1
                                } label: {
                                    Image(systemName: "chevron.right")
                                }
                                .disabled(index == steps.count - 1)
                                .accessibilityLabel("Next step")
                            }
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) { showPivotExplanation = false }
                            } label: {
                                Image(systemName: "xmark")
                            }
                            .accessibilityLabel("Hide pivot explanation")
                        }
                    }
                    .font(.subheadline)
                    Text(step.reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if manual, !pending {
                        Text(trajectory.outcome == .converged
                             ? "The iterate reached p: p is inside the triangle."
                             : trajectory.outcome == .witness
                                ? "No valid pivot is left: the iterate is a witness, so p is outside."
                                : "The iteration cap was reached without a verdict.")
                            .font(.caption.bold())
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: 440)
                .glassEffect(in: .rect(cornerRadius: 16))
                .accessibilityElement(children: .combine)
            }
            .transition(.opacity)
        }
    }

    /// Reveals a manual run up to `count` steps, with a tick for each step
    /// newly taken (and the run's cadence when the last one lands).
    private func revealManualSteps(_ count: Int) {
        let target = min(max(count, 0), totalSteps)
        let previous = revealedSteps
        revealedSteps = target
        guard target > previous, soundOn, let trajectory = trajectories.first,
              let first = trajectory.points.first, let p = queryPoint else { return }
        let initialGap = max(distance(first, p), 1)
        // Skipping ahead plays the remaining ticks in quick succession.
        let gaps = trajectory.points[(previous + 1)...target].map { min(1, Double(distance($0, p) / initialGap)) }
        soundEngine.play(voices: [SoundEngine.Voice(gaps: gaps, converged: trajectory.converged,
                                                     playsCadence: target == totalSteps)],
                         stepsPerSecond: 12)
    }

    /// Basic mode's run summary: step count under the current strategy and
    /// a breakdown by step kind when more than one kind occurred.
    private var stepSummary: String? {
        guard let trajectory = trajectories.first, !trajectory.steps.isEmpty else { return nil }
        let steps = trajectory.steps
        let counts = StepKind.allCases.compactMap { kind -> String? in
            let n = steps.filter { $0.kind == kind }.count
            return n > 0 ? "\(n) \(kind.label)" : nil
        }
        let head = "\(steps.count) step\(steps.count == 1 ? "" : "s") · \(stepStrategy.name)"
        return counts.count > 1 ? "\(head): \(counts.joined(separator: ", "))" : head
    }

    private var iterateMenu: some View {
        Menu {
            Picker("Iterates", selection: $iterateScheme) {
                Section("Deterministic") {
                    Text(IterateScheme.border.name).tag(IterateScheme.border)
                    Text(IterateScheme.corners.name).tag(IterateScheme.corners)
                    Text(IterateScheme.pointsOfS.name).tag(IterateScheme.pointsOfS)
                }
                Section("Patterned") {
                    Text(IterateScheme.ring.name).tag(IterateScheme.ring)
                    Text(IterateScheme.grid.name).tag(IterateScheme.grid)
                    Text(IterateScheme.spiral.name).tag(IterateScheme.spiral)
                }
                Section {
                    Text(IterateScheme.random.name).tag(IterateScheme.random)
                    Text(IterateScheme.custom.name).tag(IterateScheme.custom)
                }
            }
            Divider()
            Toggle("Edit iterates", isOn: editIteratesBinding)
        } label: {
            Image(systemName: "square.grid.3x3.topleft.filled")
        }
        .buttonStyle(.glass)
        .accessibilityLabel("Iterate scheme")
    }

    /// Picks how a finished Paths run is shown: the bare trajectories, the
    /// palette-filled regions between them, or the iteration-intensity
    /// field. The same choice lives under Settings.
    private var coloringMenu: some View {
        Menu {
            Picker("Coloring", selection: $coloringMode) {
                ForEach(ColoringMode.allCases) { coloring in
                    Label(coloring.rawValue, systemImage: coloring.symbol).tag(coloring)
                }
            }
        } label: {
            Image(systemName: coloringMode.symbol)
        }
        .buttonStyle(.glass)
        .accessibilityLabel("Coloring: \(coloringMode.rawValue)")
    }

    /// Quick access to the anti-zig-zag step strategies from the paper; the
    /// same choice, with a fuller description, lives under Settings.
    private var strategyMenu: some View {
        Menu {
            Picker("Step strategy", selection: $stepStrategy) {
                ForEach(StepStrategy.allCases) { strategy in
                    Label(strategy.name, systemImage: strategy.symbol).tag(strategy)
                }
            }
            if stepStrategy == .block {
                Divider()
                Picker("Block size", selection: $blockSize) {
                    ForEach(StepStrategy.blockSizes, id: \.self) { k in
                        Text("k = \(k)").tag(k)
                    }
                }
                .pickerStyle(.menu)
            }
        } label: {
            Image(systemName: stepStrategy.symbol)
        }
        .buttonStyle(.glass)
        .accessibilityLabel("Step strategy: \(stepStrategy.name)")
    }

    /// Gates edit mode behind having a hull to edit inside: without at least
    /// three hull points there is no interior for the iterates to live in.
    private var editIteratesBinding: Binding<Bool> {
        Binding(
            get: { isEditingIterates },
            set: { wantsOn in
                if wantsOn && convexHull(of: hullPoints).count < 3 {
                    showAddHullPointsAlert = true
                } else {
                    isEditingIterates = wantsOn
                    if wantsOn { isPaintingWedges = false }
                }
            }
        )
    }

    private var shareButton: some View {
        Button(action: sharePoster) {
            if isRenderingPoster {
                ProgressView()
            } else {
                Image(systemName: "square.and.arrow.up")
            }
        }
        .buttonStyle(.glass)
        .disabled(!hasResult || isAnimating || isRenderingPoster)
        .accessibilityLabel(isRenderingPoster ? "Rendering poster" : "Export poster")
    }

    private var infoButton: some View {
        Button {
            showInfo.toggle()
        } label: {
            Image(systemName: "info")
        }
        .buttonStyle(.glass)
        .accessibilityLabel("About the Triangle Algorithm")
        .popover(isPresented: $showInfo) {
            infoContent
                .keepPopoverCompact()
        }
    }

    private var infoContent: some View {
        ScrollView {
            infoText
        }
        .frame(idealWidth: 340, maxHeight: 460)
    }

    private var infoText: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Kalantari's Triangle Algorithm")
                .font(.headline)
            Text("Iterates start from a configurable set of points inside the convex hull — evenly spaced along its border by default. Each step finds a pivot vertex v with d(x, v) ≥ d(p, v) and jumps to the point on the segment [x, v] closest to the target p.")
            Text("If an iterate gets within ε of the target, the point is in the hull. If no pivot exists, the iterate is a witness — proof the point is outside.")
            Divider()
            Text("Intensity plot")
                .font(.headline)
            Text("The Iteration intensity coloring ignores the visible iterates and instead samples a fine grid of thousands of points across the hull's interior, running the algorithm from every one. The more steps a point needs to converge or reach a witness, the deeper it is painted in the theme's accent color.")
            Text("The plot is computed in batches in the background and sweeps in as it builds — you can stop it at any time and keep the partial result. It recomputes coarsely while you drag, then refines when you let go.")
            Divider()
            legendRows
            Divider()
            Button {
                showInfo = false
                showHelp = true
            } label: {
                Label("Show quick guide", systemImage: "questionmark.circle")
            }
        }
        .font(.callout)
        .padding()
    }

    private var legendRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Dots — hull vertices (tap to add, drag to move)", systemImage: "circle.fill")
                .foregroundStyle(palette.vertex)
            Label("Dot — target point (drag to move)", systemImage: "circlebadge.fill")
                .foregroundStyle(palette.target)
            Label("Squares — the starting iterates (pick a scheme or edit them)", systemImage: "square.fill")
                .foregroundStyle(.secondary)
            Label("✕ — witness: the point is outside", systemImage: "xmark")
                .foregroundStyle(palette.line)
            Label("Gradient — deeper color, more iterations (intensity mode)", systemImage: "circle.lefthalf.filled")
                .foregroundStyle(palette.intensityBase)
        }
        .font(.footnote)
    }

    // MARK: Tutorial

    /// Switches to the chosen mode on a blank canvas and begins that
    /// mode's walkthrough.
    private func startTutorial(for flowMode: AppMode = .basic) {
        showHelp = false
        hasSeenHelpOverlay = true
        showSettings = false
        isAmbient = false
        mode = flowMode
        // The Paths walkthrough starts with bare paths and introduces the
        // coloring button partway through.
        if flowMode == .paths { coloringMode = .paths }
        clearAll()
        withAnimation(.spring(duration: 0.35)) { tutorialStep = .first(for: flowMode) }
    }

    /// One step of the walkthrough, pinned above the control bar so the
    /// canvas stays fully visible and interactive.
    private func tutorialCard(_ step: TutorialStep) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("\(step.flow.rawValue) tutorial", systemImage: "graduationcap.fill")
                    .font(.caption.bold())
                Spacer()
                Text("\(step.indexInFlow + 1) of \(step.flowLength)")
                    .font(.caption)
                    .monospacedDigit()
            }
            .foregroundStyle(.secondary)
            Text(step.instruction(inside: tutorialVerdict))
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("End tutorial") {
                    withAnimation(.spring(duration: 0.35)) { tutorialStep = nil }
                }
                Spacer()
                Button(step.next == nil ? "Done" : "Next") {
                    withAnimation(.spring(duration: 0.35)) { tutorialStep = step.next }
                }
                .font(.subheadline.bold())
            }
            .font(.subheadline)
        }
        .padding(16)
        .frame(maxWidth: 460)
        .glassEffect(in: .rect(cornerRadius: 20))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: Control bar

    private var runDisabled: Bool {
        guard !isAnimating, queryPoint != nil else { return true }
        switch mode {
        case .basic:
            return hullPoints.count < 3 || startPoints.isEmpty
        case .paths:
            return hullPoints.isEmpty || startPoints.isEmpty
        case .partition:
            return convexHull(of: hullPoints).count < 3
        }
    }

    private var controlBar: some View {
        GlassEffectContainer(spacing: 14) {
            HStack(spacing: 14) {
                // While a trace animates or a field builds, Run becomes
                // Stop, so a long run can always be interrupted even with
                // the status chips hidden.
                let busy = isAnimating || isBuildingField
                Button {
                    if isAnimating {
                        stopTrace()
                    } else if isBuildingField {
                        cancelFieldBuild()
                    } else {
                        recompute(animated: true)
                    }
                } label: {
                    Label(busy ? "Stop" : hasResult ? "Replay" : "Run",
                          systemImage: busy ? "stop.fill" : hasResult ? "arrow.clockwise" : "play.fill")
                        .frame(minWidth: 90)
                }
                .buttonStyle(.glassProminent)
                .disabled(!busy && runDisabled)

                // Basic mode is the hand-placed triangle; the sampled shapes
                // belong to the richer tiers. It gets the stepping style
                // instead: let the trace play, or take it one step per tap.
                if mode == .basic {
                    Picker("Stepping", selection: $manualStepping) {
                        Text("Auto").tag(false)
                        Text("Step").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 130)
                    .accessibilityLabel("Stepping style")
                } else {
                    shapeMenu
                }

                Button(action: undo) {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.glass)
                .disabled(isEditingIterates ? startPoints.isEmpty : hullPoints.isEmpty)
                .accessibilityLabel(isEditingIterates ? "Undo last iterate" : "Undo last point")

                moreMenu
            }
        }
    }

    /// Replaces the vertex set S: random points on the boundary of a preset
    /// shape, or a fully random example composition.
    private var shapeMenu: some View {
        Menu {
            ForEach(ShapePreset.allCases) { shape in
                Button {
                    applyShapePreset(shape)
                } label: {
                    Label(shape.rawValue, systemImage: shape.symbol)
                }
            }
            Divider()
            Button(action: randomExample) {
                Label("Random", systemImage: "die.face.5")
            }
        } label: {
            Image(systemName: "square.on.circle")
        }
        .buttonStyle(.glass)
        .accessibilityLabel("Shape presets")
    }

    /// Secondary actions folded into one overflow button so the bar stays
    /// uncrowded on small screens.
    private var moreMenu: some View {
        Menu {
            Button {
                // Ambient takes over the whole canvas; a tutorial in
                // progress can't continue underneath it.
                tutorialStep = nil
                isAmbient = true
            } label: {
                Label("Ambient mode", systemImage: "sparkles")
            }
            Divider()
            Menu {
                ForEach(AppMode.allCases) { flowMode in
                    Button(flowMode.rawValue) {
                        startTutorial(for: flowMode)
                    }
                }
            } label: {
                Label("Tutorials", systemImage: "graduationcap")
            }
            Button {
                showSettings = true
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            Divider()
            Button(role: .destructive, action: clearAll) {
                Label("Clear all points", systemImage: "trash")
            }
            .disabled(hullPoints.isEmpty && !hasRun)
        } label: {
            Image(systemName: "ellipsis")
        }
        .buttonStyle(.glass)
        .accessibilityLabel("More options")
    }

    // MARK: Canvas & gestures

    private var canvas: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !isAnimating)) { timeline in
            Canvas { context, size in
                draw(in: &context, size: size, at: timeline.date)
            }
        }
        .background(palette.background)
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { newSize in
            canvasSize = newSize
            if queryPoint == nil, newSize != .zero {
                queryPoint = CGPoint(x: newSize.width / 2, y: newSize.height / 2)
            }
            // Iterates are hull-relative, so a size change only matters for
            // seeding them once a hull exists (e.g. in seeded previews).
            if newSize != .zero, startPoints.isEmpty {
                syncIteratesToHull()
            }
        }
        .onTapGesture { location in
            if isAmbient {
                isAmbient = false
                return
            }
            if isPaintingWedges {
                if let index = wedgeIndex(at: location) {
                    wedgeOverrides[index] = paintColor
                }
                return
            }
            guard target(near: location) == nil else { return }
            if isEditingIterates {
                let hull = convexHull(of: hullPoints)
                guard hull.count >= 3 else { return }
                // Iterates live inside the hull; a tap outside is rejected
                // with a transient warning rather than silently moved.
                guard isInsideConvexHull(location, hull: hull) else {
                    withAnimation(.spring(duration: 0.3)) { showOutsideHullWarning = true }
                    outsideHullWarningNonce += 1
                    return
                }
                startPoints.append(location)
                iterateScheme = .custom
            } else {
                // Basic mode is exactly one triangle; extra taps do nothing
                // (the status chip explains the corners are draggable).
                guard mode != .basic || hullPoints.count < 3 else { return }
                hullPoints.append(location)
                syncIteratesToHull()
                if tutorialStep == .placeTriangle && convexHull(of: hullPoints).count >= 3 {
                    withAnimation(.spring(duration: 0.35)) { tutorialStep = .dragTarget }
                }
            }
            if hasResult { recompute(animated: false) }
        }
        .gesture(pointDragGesture)
        .ignoresSafeArea(edges: .bottom)
    }

    private var pointDragGesture: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                guard !isAmbient else { return }
                if !dragResolved {
                    activeDrag = target(near: value.startLocation)
                    dragResolved = true
                }
                guard let activeDrag else { return }
                switch activeDrag {
                case .query:
                    queryPoint = value.location
                case .hull(let index) where hullPoints.indices.contains(index):
                    hullPoints[index] = value.location
                    syncIteratesToHull()
                case .start(let index) where startPoints.indices.contains(index):
                    startPoints[index] = clampToConvexHull(value.location, hull: convexHull(of: hullPoints))
                    // Basic mode's single start is managed by syncIteratesToHull,
                    // not the scheme; flipping to .custom here would silently
                    // replace the other modes' default layouts with this one
                    // point on the next mode switch.
                    if mode != .basic { iterateScheme = .custom }
                default:
                    break
                }
                if tutorialStep == .tryOtherSide {
                    // The teaching moment here is pressing Run and watching
                    // the outcome; live-recomputing during the drag would
                    // reveal the answer early. Clear the old run instead.
                    trajectories = []
                    runStart = nil
                } else if hasResult {
                    recompute(animated: false)
                }
            }
            .onEnded { _ in
                let wasDragging = activeDrag != nil
                if tutorialStep == .dragTarget && activeDrag == .query {
                    withAnimation(.spring(duration: 0.35)) { tutorialStep = .runIt }
                }
                activeDrag = nil
                dragResolved = false
                // Refine the coarse drag-time fields back to full resolution.
                guard wasDragging else { return }
                if mode == .partition, partitionField != nil {
                    rebuildPartition()
                } else if hasRun && mode == .paths && coloringMode == .intensity {
                    rebuildIterationField()
                }
            }
    }

    /// The draggable point nearest to `location` within the grab radius, if any.
    private func target(near location: CGPoint) -> DragTarget? {
        var best: (target: DragTarget, gap: CGFloat)? = nil
        if let q = queryPoint {
            let gap = distance(q, location)
            if gap <= grabRadius { best = (.query, gap) }
        }
        for (index, point) in hullPoints.enumerated() {
            let gap = distance(point, location)
            if gap <= grabRadius && gap < (best?.gap ?? .greatestFiniteMagnitude) {
                best = (.hull(index), gap)
            }
        }
        // Start points only participate while the user is editing iterates —
        // so the border squares never hijack hull or target drags — except
        // in basic mode, where the single start square is always live.
        if isEditingIterates || mode == .basic {
            for (index, point) in startPoints.enumerated() {
                let gap = distance(point, location)
                if gap <= grabRadius && gap < (best?.gap ?? .greatestFiniteMagnitude) {
                    best = (.start(index), gap)
                }
            }
        }
        return best?.target
    }

    // MARK: Actions

    /// Keeps the iterate set consistent with the current hull: scheme-based
    /// sets regenerate from the hull's geometry, while custom and random
    /// layouts keep their shape and just get strays clamped back inside.
    /// With fewer than three hull points there is no interior, so the set
    /// empties until a hull exists.
    private func syncIteratesToHull() {
        let hull = convexHull(of: hullPoints)
        guard hull.count >= 3 else {
            startPoints = []
            return
        }
        if mode == .basic {
            // A single start iterate, defaulting to the triangle's centroid;
            // the user drags it anywhere inside.
            if let existing = startPoints.first {
                startPoints = [clampToConvexHull(existing, hull: hull)]
            } else {
                let centroid = CGPoint(x: hull.map(\.x).reduce(0, +) / CGFloat(hull.count),
                                       y: hull.map(\.y).reduce(0, +) / CGFloat(hull.count))
                startPoints = [centroid]
            }
            return
        }
        if iterateScheme == .custom || iterateScheme.isRandom {
            if startPoints.isEmpty, let generated = iterateScheme.points(inHull: hull, vertices: hullPoints, count: iterateCount) {
                startPoints = generated
            } else {
                startPoints = startPoints.map { clampToConvexHull($0, hull: hull) }
            }
        } else if let generated = iterateScheme.points(inHull: hull, vertices: hullPoints, count: iterateCount) {
            startPoints = generated
        }
    }

    /// Samples the hull's interior on a fine grid and records how many steps
    /// the algorithm needs from each cell, so the intensity mode paints a
    /// smooth gradient independent of the visible iterate set. Cells outside
    /// the hull are marked unsampled and stay unpainted — like the iterates
    /// themselves, the field only starts from inside the hull.
    ///
    /// The sampling runs in a cancellable background task, publishing a
    /// partial field after each batch of rows so the gradient sweeps in
    /// progressively and the user can stop a long build partway.
    ///
    /// While the user is dragging, `coarse` builds a quick low-resolution
    /// field for live feedback (no progress chip); the fine grid is rebuilt
    /// when the drag ends.
    private func rebuildIterationField(coarse: Bool = false) {
        fieldTask?.cancel()
        let hull = convexHull(of: hullPoints)
        guard mode == .paths, coloringMode == .intensity, hasRun,
              let p = queryPoint, hull.count >= 3, canvasSize != .zero else {
            iterationField = nil
            fieldImage = nil
            isBuildingField = false
            return
        }
        let cellSize: CGFloat = coarse ? 12 : 3
        let columns = Int(ceil(canvasSize.width / cellSize))
        let rows = Int(ceil(canvasSize.height / cellSize))
        guard columns > 0, rows > 0 else {
            iterationField = nil
            fieldImage = nil
            isBuildingField = false
            return
        }
        let vertices = hullPoints
        let strategy = stepStrategy
        let blockSize = blockSize
        isBuildingField = !coarse
        fieldProgress = 0
        fieldTask = Task.detached(priority: .userInitiated) {
            var counts = [Int](repeating: -1, count: columns * rows)
            var maxCount = 1
            let batchRows = 6
            for batchStart in stride(from: 0, to: rows, by: batchRows) {
                let batchEnd = min(batchStart + batchRows, rows)
                for row in batchStart..<batchEnd {
                    if Task.isCancelled { return }
                    for column in 0..<columns {
                        let start = CGPoint(x: (CGFloat(column) + 0.5) * cellSize,
                                            y: (CGFloat(row) + 0.5) * cellSize)
                        guard isInsideConvexHull(start, hull: hull) else { continue }
                        let steps = TriangleAlgorithm.stepCount(from: start, vertices: vertices, target: p,
                                                                strategy: strategy, blockSize: blockSize)
                        counts[row * columns + column] = steps
                        maxCount = max(maxCount, steps)
                    }
                }
                if Task.isCancelled { return }
                let partial = IterationField(cellSize: cellSize, columns: columns,
                                             rows: rows, counts: counts, maxCount: maxCount)
                let progress = Double(batchEnd) / Double(rows)
                await MainActor.run {
                    // Re-check inside the main-actor hop: MainActor.run is not
                    // a cancellation point, so a build cancelled during the
                    // suspension must not resurrect a field the cancel cleared.
                    guard !Task.isCancelled else { return }
                    iterationField = partial
                    fieldImage = partial.makeImage(baseColor: PlatformColor(palette.intensityBase))
                    if !coarse {
                        fieldProgress = progress
                        if batchEnd == rows { isBuildingField = false }
                    }
                }
            }
        }
    }

    /// Stops an in-flight intensity-field build, keeping whatever batches
    /// have already been painted.
    private func cancelFieldBuild() {
        fieldTask?.cancel()
        fieldTask = nil
        isBuildingField = false
    }

    /// Samples the hull's interior and counts how many iterations the
    /// algorithm needs from each cell to reach the target, shading the hull
    /// in a single color whose intensity grows with the count.
    ///
    /// Runs in the same cancellable background pipeline as the intensity
    /// field; `coarse` gives quick low-resolution feedback during drags.
    private func rebuildPartition(coarse: Bool = false) {
        fieldTask?.cancel()
        let hull = convexHull(of: hullPoints)
        guard mode == .partition, let p = queryPoint,
              hull.count >= 3, canvasSize != .zero else {
            partitionField = nil
            partitionImage = nil
            isBuildingField = false
            return
        }
        let vertices = hullPoints
        let strategy = stepStrategy
        let blockSize = blockSize
        // Every cell runs a full trace, so the grid is a little denser than
        // the intensity field's but nowhere near per-pixel.
        let cellSize: CGFloat = coarse ? 10 : 2
        let columns = Int(ceil(canvasSize.width / cellSize))
        let rows = Int(ceil(canvasSize.height / cellSize))
        guard columns > 0, rows > 0 else {
            partitionField = nil
            partitionImage = nil
            isBuildingField = false
            return
        }
        let baseColor = PlatformColor(palette.intensityBase)
        isBuildingField = !coarse
        fieldProgress = 0
        fieldTask = Task.detached(priority: .userInitiated) {
            var counts = [Int](repeating: -1, count: columns * rows)
            var maxCount = 1
            let batchRows = max(6, rows / 12 + 1)
            for batchStart in stride(from: 0, to: rows, by: batchRows) {
                let batchEnd = min(batchStart + batchRows, rows)
                for row in batchStart..<batchEnd {
                    if Task.isCancelled { return }
                    for column in 0..<columns {
                        let start = CGPoint(x: (CGFloat(column) + 0.5) * cellSize,
                                            y: (CGFloat(row) + 0.5) * cellSize)
                        guard isInsideConvexHull(start, hull: hull) else { continue }
                        let steps = TriangleAlgorithm.stepCount(from: start, vertices: vertices, target: p,
                                                                strategy: strategy, blockSize: blockSize)
                        counts[row * columns + column] = steps
                        maxCount = max(maxCount, steps)
                    }
                }
                if Task.isCancelled { return }
                let partial = IterationField(cellSize: cellSize, columns: columns,
                                             rows: rows, counts: counts, maxCount: maxCount)
                let progress = Double(batchEnd) / Double(rows)
                await MainActor.run {
                    // Same re-check as the intensity field: don't let a
                    // cancelled build land one last write after the fact.
                    guard !Task.isCancelled else { return }
                    partitionField = partial
                    partitionImage = partial.makeImage(baseColor: baseColor)
                    if !coarse {
                        fieldProgress = progress
                        if batchEnd == rows { isBuildingField = false }
                    }
                }
            }
        }
    }



    private func recompute(animated: Bool) {
        guard let p = queryPoint, !hullPoints.isEmpty, canvasSize != .zero else { return }
        // A deliberate Run brings back any chips the user had hidden; the
        // silent recomputes behind drags and setting changes leave them be.
        if animated { dismissedChips = [] }
        // Partition mode has no trajectories: Run builds the iteration-count
        // shading over the hull instead.
        if mode == .partition {
            rebuildPartition(coarse: activeDrag != nil)
            runStart = nil
            isAnimating = false
            soundEngine.stop()
            return
        }
        // A random scheme samples a fresh set on every animated run, so each
        // Run/Replay composes a new picture. Basic mode's single start stays
        // where the user put it.
        if animated, mode != .basic, iterateScheme.isRandom,
           let fresh = iterateScheme.points(inHull: convexHull(of: hullPoints), vertices: hullPoints, count: iterateCount),
           !fresh.isEmpty {
            startPoints = fresh
        }
        guard !startPoints.isEmpty else { return }
        trajectories = startPoints.map { start in
            let result = TriangleAlgorithm.trace(from: start, vertices: hullPoints, target: p,
                                                 strategy: stepStrategy, blockSize: blockSize)
            return Trajectory(points: result.points, steps: result.steps, outcome: result.outcome)
        }
        rebuildIterationField(coarse: activeDrag != nil)
        if animated, mode == .basic, manualStepping {
            // Manual stepping: nothing moves until the user asks for the
            // first step. The card takes over from the timeline and score.
            showPivotExplanation = true
            revealedSteps = 0
            reviewedStep = 0
            runStart = nil
            isAnimating = false
            soundEngine.stop()
            if tutorialStep == .dragTarget || tutorialStep == .runIt {
                withAnimation(.spring(duration: 0.35)) { tutorialStep = .watchTrace }
            }
        } else if animated {
            // A fresh run brings the explanation back and parks the review
            // on the final step, where the trace ends up.
            showPivotExplanation = true
            reviewedStep = max((trajectories.first?.steps.count ?? 1) - 1, 0)
            runStart = Date()
            isAnimating = true
            playRunScore(target: p)
        } else {
            runStart = nil
            isAnimating = false
            soundEngine.stop()
        }
    }

    /// Turns the freshly computed trajectories into voices for the sound
    /// engine: one tick per step, pitched by how close the iterate is.
    private func playRunScore(target p: CGPoint) {
        guard soundOn else { return }
        let voices = trajectories.compactMap { trajectory -> SoundEngine.Voice? in
            guard let first = trajectory.points.first else { return nil }
            let initialGap = max(distance(first, p), 1)
            let gaps = trajectory.points.map { min(1, Double(distance($0, p) / initialGap)) }
            return SoundEngine.Voice(gaps: gaps, converged: trajectory.converged)
        }
        soundEngine.play(voices: voices, stepsPerSecond: stepsPerSecond)
    }

    /// Ends the trace playback early: the fully traced composition and the
    /// membership verdict appear immediately instead of step by step.
    private func stopTrace() {
        withAnimation(.spring(duration: 0.4)) { isAnimating = false }
        soundEngine.stop()
    }

    private func undo() {
        if isEditingIterates {
            guard !startPoints.isEmpty else { return }
            startPoints.removeLast()
            iterateScheme = .custom
            if startPoints.isEmpty {
                trajectories = []
                runStart = nil
                isAnimating = false
            } else if hasRun {
                recompute(animated: false)
            }
            return
        }
        guard !hullPoints.isEmpty else { return }
        hullPoints.removeLast()
        syncIteratesToHull()
        if hullPoints.isEmpty || startPoints.isEmpty {
            trajectories = []
            runStart = nil
            isAnimating = false
        } else if hasRun {
            recompute(animated: false)
        }
    }

    /// Empties the iterate set so the user can place a fresh one by hand.
    /// The trajectories go with it — they were traced from the old starts.
    private func clearIterates() {
        startPoints = []
        iterateScheme = .custom
        trajectories = []
        runStart = nil
        isAnimating = false
        soundEngine.stop()
    }

    private func clearAll() {
        dismissedChips = []
        hullPoints = []
        trajectories = []
        runStart = nil
        isAnimating = false
        isEditingIterates = false
        isPaintingWedges = false
        wedgeOverrides = [:]
        syncIteratesToHull()
        cancelFieldBuild()
        iterationField = nil
        fieldImage = nil
        partitionField = nil
        partitionImage = nil
        soundEngine.stop()
        if canvasSize != .zero {
            queryPoint = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        }
    }

    private func randomExample() {
        guard canvasSize != .zero else { return }
        let w = canvasSize.width
        let h = canvasSize.height
        hullPoints = (0..<(mode == .basic ? 3 : Int.random(in: 5...8))).map { _ in
            CGPoint(
                x: CGFloat.random(in: 0.15 * w...0.85 * w),
                y: CGFloat.random(in: 0.2 * h...0.72 * h)
            )
        }
        queryPoint = CGPoint(
            x: CGFloat.random(in: 0.1 * w...0.9 * w),
            y: CGFloat.random(in: 0.15 * h...0.78 * h)
        )
        syncIteratesToHull()
        recompute(animated: true)
    }

    /// Replaces the hull's vertex set with random points on the boundary of
    /// the chosen shape, centered in the same canvas region the random
    /// example uses so the overlays don't cover it.
    ///
    /// Sampling is stratified: the boundary is split into as many equal
    /// segments as there are points and each point lands at a random spot
    /// within its own segment. That keeps the placement random while
    /// guaranteeing the whole outline is covered, so the hull actually
    /// reads as the chosen shape instead of an irregular polygon.
    private func applyShapePreset(_ shape: ShapePreset) {
        guard canvasSize != .zero else { return }
        let center = CGPoint(x: canvasSize.width / 2, y: 0.46 * canvasSize.height)
        let maxRadiusX = 0.35 * canvasSize.width
        let maxRadiusY = 0.26 * canvasSize.height

        // A deliberately small vertex set — 10 to 20 points — so each dot of
        // S stays individually readable instead of dissolving into an outline.
        func sampleCount(forPerimeter perimeter: CGFloat) -> Int {
            max(10, min(20, Int(perimeter / 60)))
        }

        /// The shape's own corners pinned exactly, with whatever remains of
        /// the point budget scattered stratified along the outline's edges.
        /// Everything comes back in perimeter order — downstream features
        /// like the Points of S iterates and the wedge fills between
        /// consecutive trajectories rely on neighbors in the array being
        /// neighbors on the outline.
        func sampledOutline(_ corners: [CGPoint]) -> [CGPoint] {
            let edges = corners.indices.map { (start: corners[$0], end: corners[($0 + 1) % corners.count]) }
            let lengths = edges.map { distance($0.start, $0.end) }
            let perimeter = lengths.reduce(0, +)
            let extra = max(0, sampleCount(forPerimeter: perimeter) - corners.count)
            guard extra > 0, perimeter > 0 else { return corners }
            // Arc-length position of every point, corner and extra alike.
            var positioned: [(position: CGFloat, point: CGPoint)] = []
            var walked: CGFloat = 0
            for (index, corner) in corners.enumerated() {
                positioned.append((walked, corner))
                walked += lengths[index]
            }
            for i in 0..<extra {
                let position = perimeter * (CGFloat(i) + .random(in: 0..<1)) / CGFloat(extra)
                var remaining = position
                for (index, edge) in edges.enumerated() where lengths[index] > 0 {
                    if remaining <= lengths[index] {
                        let t = remaining / lengths[index]
                        positioned.append((position, CGPoint(x: edge.start.x + (edge.end.x - edge.start.x) * t,
                                                             y: edge.start.y + (edge.end.y - edge.start.y) * t)))
                        break
                    }
                    remaining -= lengths[index]
                }
            }
            return positioned.sorted { $0.position < $1.position }.map(\.point)
        }

        func regularPolygon(sides: Int) -> [CGPoint] {
            let radius = min(maxRadiusX, maxRadiusY)
            return (0..<sides).map { i in
                let angle = -CGFloat.pi / 2 + CGFloat(i) * 2 * .pi / CGFloat(sides)
                return CGPoint(x: center.x + radius * cos(angle),
                               y: center.y + radius * sin(angle))
            }
        }

        let points: [CGPoint]
        switch shape {
        case .circle:
            let radius = min(maxRadiusX, maxRadiusY)
            let count = sampleCount(forPerimeter: 2 * .pi * radius)
            points = (0..<count).map { i in
                let angle = (Double(i) + .random(in: 0..<1)) * 2 * .pi / Double(count)
                return CGPoint(x: center.x + radius * cos(angle),
                               y: center.y + radius * sin(angle))
            }
        case .ellipse:
            // Ramanujan's perimeter approximation.
            let a = maxRadiusX, b = maxRadiusY
            let perimeter = CGFloat.pi * (3 * (a + b) - sqrt((3 * a + b) * (a + 3 * b)))
            let count = sampleCount(forPerimeter: perimeter)
            points = (0..<count).map { i in
                let angle = (Double(i) + .random(in: 0..<1)) * 2 * .pi / Double(count)
                return CGPoint(x: center.x + a * cos(angle),
                               y: center.y + b * sin(angle))
            }
        case .square:
            let half = min(maxRadiusX, maxRadiusY)
            points = sampledOutline([CGPoint(x: center.x - half, y: center.y - half),
                                     CGPoint(x: center.x + half, y: center.y - half),
                                     CGPoint(x: center.x + half, y: center.y + half),
                                     CGPoint(x: center.x - half, y: center.y + half)])
        case .diamond:
            points = sampledOutline([CGPoint(x: center.x, y: center.y - maxRadiusY),
                                     CGPoint(x: center.x + maxRadiusX, y: center.y),
                                     CGPoint(x: center.x, y: center.y + maxRadiusY),
                                     CGPoint(x: center.x - maxRadiusX, y: center.y)])
        case .pentagon:
            points = sampledOutline(regularPolygon(sides: 5))
        case .hexagon:
            points = sampledOutline(regularPolygon(sides: 6))
        case .star:
            // A five-pointed star, alternating outer and inner corners.
            // The five inner corners are points of S that lie strictly
            // inside the convex hull — S itself is not convex.
            let outer = min(maxRadiusX, maxRadiusY)
            let inner = outer * 0.45
            points = sampledOutline((0..<10).map { i in
                let radius = i.isMultiple(of: 2) ? outer : inner
                let angle = -CGFloat.pi / 2 + CGFloat(i) * .pi / 5
                return CGPoint(x: center.x + radius * cos(angle),
                               y: center.y + radius * sin(angle))
            })
        }

        hullPoints = points
        syncIteratesToHull()
        recompute(animated: true)
    }

    // MARK: Poster export

    /// ImageRenderer silently returns nil once the bitmap runs to hundreds
    /// of megapixels (8× on an iPad canvas). Cap the poster's pixel count so
    /// a big canvas renders at the largest workable scale instead of failing.
    private func posterScale(for resolution: ExportResolution) -> CGFloat {
        // Approximates posterContent's size: canvas plus matte and caption.
        let contentSize = CGSize(width: canvasSize.width + 56, height: canvasSize.height + 100)
        let maxPixels: CGFloat = 64_000_000
        let maxScale = sqrt(maxPixels / max(contentSize.width * contentSize.height, 1))
        return min(resolution.scale, maxScale)
    }

    private func sharePoster() {
        guard hasResult, !isAnimating, canvasSize != .zero, !isRenderingPoster else { return }
        isRenderingPoster = true
        Task { @MainActor in
            // ImageRenderer is main-actor bound, so the rasterization itself
            // briefly blocks the run loop; sleep one frame first so the
            // progress indicator is on screen before that happens.
            try? await Task.sleep(for: .milliseconds(50))
            defer { isRenderingPoster = false }
            let renderer = ImageRenderer(content: posterContent)
            renderer.scale = posterScale(for: exportResolution)
#if canImport(UIKit)
            guard let platformImage = renderer.uiImage else {
                showPosterRenderFailedAlert = true
                return
            }
            let image = Image(uiImage: platformImage)
            let pixelSize = CGSize(width: platformImage.size.width * platformImage.scale,
                                   height: platformImage.size.height * platformImage.scale)
#else
            guard let platformImage = renderer.nsImage else {
                showPosterRenderFailedAlert = true
                return
            }
            let image = Image(nsImage: platformImage)
            // NSImage reports points; the renderer's scale gives the pixel count.
            let pixelSize = CGSize(width: platformImage.size.width * renderer.scale,
                                   height: platformImage.size.height * renderer.scale)
#endif
            didSaveToPhotos = false
            poster = PosterImage(
                image: image,
                platformImage: platformImage,
                pixelSize: pixelSize
            )
        }
    }

    private var posterCaption: String {
        if mode == .partition { return "\(stepStrategy.captionName(blockSize: blockSize)) · iteration partition" }
        let steps = stepStrategy.captionName(blockSize: blockSize)
        guard let inside = membershipResult else { return "\(steps) · iteration limit reached" }
        return "\(steps) · \(inside ? "inside the hull" : "witness found")"
    }

    /// The finished composition matted and captioned like a gallery print.
    private var posterContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Canvas { context, size in
                draw(in: &context, size: size, at: .now)
            }
            .frame(width: canvasSize.width, height: canvasSize.height)
            .background(palette.background)

            HStack(alignment: .firstTextBaseline) {
                Text("Triangle Algorithm")
                    .font(.system(.headline, design: .serif))
                Spacer()
                Text("\(palette.name) · \(posterCaption)")
                    .font(.system(.caption, design: .serif))
                    .opacity(0.7)
            }
            .foregroundStyle(palette.line)
        }
        .padding(28)
        .background(palette.background)
    }

    private func posterSheet(for poster: PosterImage) -> some View {
        VStack(spacing: 24) {
            poster.image
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
                .padding(.horizontal, 24)
                .opacity(isRenderingPoster ? 0.4 : 1)
                .overlay {
                    if isRenderingPoster {
                        ProgressView("Rendering \(exportResolution.rawValue)…")
                            .padding(16)
                            .glassEffect()
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: isRenderingPoster)

            VStack(spacing: 8) {
                Picker("Resolution", selection: $exportResolution) {
                    ForEach(ExportResolution.allCases) { resolution in
                        Text(resolution.rawValue).tag(resolution)
                    }
                }
                .pickerStyle(.segmented)
                Text("\(Int(poster.pixelSize.width)) × \(Int(poster.pixelSize.height)) px")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            .padding(.horizontal, 24)
            .disabled(isRenderingPoster)

            ShareLink(
                item: poster.image,
                preview: SharePreview("TriangleTrace — \(palette.name)", image: poster.image)
            ) {
                Label("Share poster", systemImage: "square.and.arrow.up")
                    .frame(minWidth: 160)
            }
            .buttonStyle(.glassProminent)
            .disabled(isRenderingPoster)

            Button {
                saveToPhotos(poster)
            } label: {
                if isSavingToPhotos {
                    ProgressView()
                        .frame(minWidth: 160)
                } else {
                    Label(didSaveToPhotos ? "Saved" : "Save to Photos",
                          systemImage: didSaveToPhotos ? "checkmark" : "square.and.arrow.down")
                        .frame(minWidth: 160)
                }
            }
            .buttonStyle(.glass)
            .disabled(isRenderingPoster || isSavingToPhotos || didSaveToPhotos)
        }
        .padding(.vertical, 28)
        .mediumOrLargeDetents()
        .onChange(of: exportResolution) { _, _ in
            // Re-render the poster at the newly chosen scale.
            sharePoster()
        }
        .alert("Couldn't save to Photos", isPresented: $showSaveFailedAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Allow photo library access for TriangleTrace in Settings and try again.")
        }
    }

    /// Writes the rendered poster straight to the photo library, requesting
    /// add-only access the first time.
    private func saveToPhotos(_ poster: PosterImage) {
        guard !isSavingToPhotos else { return }
        isSavingToPhotos = true
        Task {
            defer { isSavingToPhotos = false }
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                showSaveFailedAlert = true
                return
            }
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAsset(from: poster.platformImage)
                }
                withAnimation(.easeInOut(duration: 0.2)) { didSaveToPhotos = true }
            } catch {
                showSaveFailedAlert = true
            }
        }
    }

    // MARK: Drawing

    private func draw(in context: inout GraphicsContext, size: CGSize, at date: Date) {
        let progress: Double
        if isAnimating, let start = runStart {
            progress = max(0, date.timeIntervalSince(start)) * stepsPerSecond
        } else if isManualRun {
            progress = Double(min(revealedSteps, totalSteps))
        } else {
            progress = .infinity
        }
        switch mode {
        case .paths:
            switch coloringMode {
            case .paths:
                break
            case .palette:
                drawMondrianRegions(in: &context, size: size, upTo: progress)
            case .intensity:
                drawIterationField(in: &context, size: size)
            }
        case .partition:
            drawPartitionField(in: &context)
        case .basic:
            break
        }
        drawHull(in: &context)
        switch mode {
        case .basic:
            drawTrajectories(in: &context, upTo: progress)
            drawPivotDemo(in: &context, upTo: progress)
        case .paths:
            // The intensity field speaks for itself; trajectory polylines
            // would just cover it, so they stay off in that coloring.
            if coloringMode != .intensity {
                drawTrajectories(in: &context, upTo: progress)
            }
        case .partition:
            // The partition coloring stands alone — no paths on top.
            break
        }
        drawStartPoints(in: &context)
        drawHullPoints(in: &context)
        drawQueryPoint(in: &context)
    }

    /// Basic mode's pivot demonstration. While the trace animates, a dashed
    /// line runs from the current iterate to the vertex chosen as pivot,
    /// with a ring calling the pivot out; once finished, every step's pivot
    /// line stays faintly visible so the whole run can be read back.
    ///
    /// Under the anti-zig-zag strategies a step can also involve vertices
    /// the iterate moves *away* from (weight donors) and a search direction
    /// that points at no vertex at all (a pairwise or block transfer), so
    /// the demo draws the search segment itself, rings the receivers, and
    /// marks donors with a struck-through ring.
    private func drawPivotDemo(in context: inout GraphicsContext, upTo progress: Double) {
        guard let trajectory = trajectories.first, !trajectory.steps.isEmpty else { return }
        let points = trajectory.points
        let steps = trajectory.steps
        let finished = progress >= Double(points.count - 1)
        if finished {
            for (index, step) in steps.enumerated() {
                drawStepGuides(step, from: points[index], in: &context, opacity: 0.3, lineWidth: 1.5)
            }
        }
        // While tracing, call out the step being drawn; once finished, the
        // step the explanation card is paged to (if the card is showing).
        if !finished || showPivotExplanation || isManualRun {
            // A manual run's focus is the step just taken (or about to be);
            // an auto run's is the one the card has been paged to.
            let reviewed = isManualRun ? revealedSteps : reviewedStep
            let index = finished
                ? min(max(reviewed, 0), steps.count - 1)
                : min(max(Int(progress), 0), steps.count - 1)
            let step = steps[index]
            drawStepGuides(step, from: points[index], in: &context, opacity: 0.8, lineWidth: 2)
            if finished {
                // Where the iterate stood when this step was taken.
                let origin = points[index]
                let halo = CGRect(x: origin.x - 7, y: origin.y - 7, width: 14, height: 14)
                context.stroke(Path(ellipseIn: halo), with: .color(palette.target), lineWidth: 2)
            }
            let ringRadius = pointMarkerSize + 7
            for receiver in step.receivers {
                let ring = CGRect(x: receiver.x - ringRadius, y: receiver.y - ringRadius,
                                  width: ringRadius * 2, height: ringRadius * 2)
                context.stroke(Path(ellipseIn: ring), with: .color(palette.target), lineWidth: 3)
            }
            for donor in step.donors {
                let ring = CGRect(x: donor.x - ringRadius, y: donor.y - ringRadius,
                                  width: ringRadius * 2, height: ringRadius * 2)
                context.stroke(Path(ellipseIn: ring), with: .color(palette.line), lineWidth: 3)
                // A bar through the ring: this vertex is giving weight up.
                var bar = Path()
                bar.move(to: CGPoint(x: donor.x - ringRadius, y: donor.y))
                bar.addLine(to: CGPoint(x: donor.x + ringRadius, y: donor.y))
                context.stroke(bar, with: .color(palette.line), lineWidth: 3)
            }
            if step.kind == .midpoint {
                // The virtual pivot: the midpoint the two best pivots blend into.
                let r: CGFloat = pointMarkerSize * 0.7
                var diamond = Path()
                diamond.move(to: CGPoint(x: step.endpoint.x, y: step.endpoint.y - r))
                diamond.addLine(to: CGPoint(x: step.endpoint.x + r, y: step.endpoint.y))
                diamond.addLine(to: CGPoint(x: step.endpoint.x, y: step.endpoint.y + r))
                diamond.addLine(to: CGPoint(x: step.endpoint.x - r, y: step.endpoint.y))
                diamond.closeSubpath()
                context.fill(diamond, with: .color(palette.target))
            }
        }
    }

    /// The dashed search segment of one step plus thin guides to the
    /// vertices it involved: dashed in the target color toward receivers,
    /// dotted in the line color toward donors.
    private func drawStepGuides(_ step: TraceStep, from origin: CGPoint,
                                in context: inout GraphicsContext,
                                opacity: Double, lineWidth: CGFloat) {
        var search = Path()
        search.move(to: origin)
        search.addLine(to: step.endpoint)
        context.stroke(search, with: .color(palette.target.opacity(opacity)),
                       style: StrokeStyle(lineWidth: lineWidth, dash: [6, 4]))
        // A toward step's segment already ends at its receiver.
        let guidedReceivers = step.kind == .toward ? [] : step.receivers
        for receiver in guidedReceivers {
            var guide = Path()
            guide.move(to: origin)
            guide.addLine(to: receiver)
            context.stroke(guide, with: .color(palette.target.opacity(opacity * 0.6)),
                           style: StrokeStyle(lineWidth: max(1, lineWidth - 1), dash: [3, 4]))
        }
        for donor in step.donors {
            var guide = Path()
            guide.move(to: origin)
            guide.addLine(to: donor)
            context.stroke(guide, with: .color(palette.line.opacity(opacity * 0.6)),
                           style: StrokeStyle(lineWidth: max(1, lineWidth - 1), dash: [1, 4]))
        }
    }

    /// The iteration-count shading as a bitmap under the hull: one color,
    /// deepening with the number of steps needed from each point.
    private func drawPartitionField(in context: inout GraphicsContext) {
        guard let field = partitionField, let bitmap = partitionImage else { return }
        let rect = CGRect(x: 0, y: 0,
                          width: CGFloat(field.columns) * field.cellSize,
                          height: CGFloat(field.rows) * field.cellSize)
        // Interpolation smooths the sampled grid into a continuous gradient.
        let image = Image(decorative: bitmap, scale: 1).interpolation(.medium)
        context.draw(image, in: rect)
    }


    /// Starting iterate markers (squares), visible once a run exists or while
    /// the user is editing the iterate set.
    private func drawStartPoints(in context: inout GraphicsContext) {
        switch mode {
        case .basic:
            // The single start square is always live and draggable.
            break
        case .partition:
            // Partition mode has no starting iterates at all.
            return
        case .paths:
            // In the intensity coloring the squares belong to the hidden
            // trajectories, so they only appear while editing the iterate set.
            guard isEditingIterates || (hasRun && coloringMode != .intensity) else { return }
        }
        for (index, point) in startPoints.enumerated() {
            let base = pointMarkerSize * 0.8
            let half: CGFloat = activeDrag == .start(index) ? base + 3 : base
            let square = CGRect(x: point.x - half, y: point.y - half,
                                width: half * 2, height: half * 2)
            context.fill(Path(roundedRect: square, cornerRadius: 1), with: .color(palette.line))
            if mode == .basic {
                // Name the iterate so the explanations can refer to it,
                // lettered like the corners.
                let label = Text("I")
                    .font(.footnote.bold())
                    .foregroundStyle(palette.line)
                context.draw(label, at: CGPoint(x: point.x + half + 9, y: point.y - half - 6))
            }
            if isEditingIterates {
                context.stroke(
                    Path(roundedRect: square.insetBy(dx: -4, dy: -4), cornerRadius: 2),
                    with: .color(palette.line.opacity(0.35)),
                    lineWidth: 2
                )
            }
        }
    }

    private func drawHull(in context: inout GraphicsContext) {
        let hull = convexHull(of: hullPoints)
        guard hull.count >= 2 else { return }
        var path = Path()
        path.move(to: hull[0])
        for point in hull.dropFirst() { path.addLine(to: point) }
        path.closeSubpath()
        guard hullLineWidth > 0 else { return }
        context.stroke(path, with: .color(palette.line), lineWidth: hullLineWidth)
    }

    private func drawHullPoints(in context: inout GraphicsContext) {
        for (index, point) in hullPoints.enumerated() {
            let radius: CGFloat = activeDrag == .hull(index) ? pointMarkerSize + 3 : pointMarkerSize
            let rect = CGRect(x: point.x - radius, y: point.y - radius,
                              width: radius * 2, height: radius * 2)
            context.fill(Path(ellipseIn: rect), with: .color(palette.vertex))
            context.stroke(Path(ellipseIn: rect), with: .color(palette.background), lineWidth: 2)
            if mode == .basic {
                // Letter the corners so the pivot explanation can name them.
                let label = Text(vertexName(index))
                    .font(.footnote.bold())
                    .foregroundStyle(palette.line)
                context.draw(label, at: CGPoint(x: point.x + radius + 9, y: point.y - radius - 6))
            }
        }
    }

    private func drawQueryPoint(in context: inout GraphicsContext) {
        guard let p = queryPoint else { return }
        let base = pointMarkerSize * 0.8
        let radius: CGFloat = activeDrag == .query ? base + 3 : base
        let rect = CGRect(x: p.x - radius, y: p.y - radius,
                          width: radius * 2, height: radius * 2)
        context.fill(Path(ellipseIn: rect), with: .color(palette.target))
        context.stroke(Path(ellipseIn: rect), with: .color(palette.background), lineWidth: 2)
        if mode == .basic {
            // Name the target the way the paper does.
            let label = Text("p")
                .font(.footnote.bold())
                .foregroundStyle(palette.line)
            context.draw(label, at: CGPoint(x: p.x + radius + 9, y: p.y - radius - 6))
        }
    }

    private func drawTrajectories(in context: inout GraphicsContext, upTo progress: Double) {
        guard hasRun else { return }

        for trajectory in trajectories {
            let points = trajectory.points
            guard !points.isEmpty else { continue }

            // Angular bars, in the manner of the painter's grid lines.
            // Width 0 hides the polylines and leaves just the markers.
            let (path, tip) = partialPolyline(points, upTo: progress)
            if trajectoryLineWidth > 0 {
                context.stroke(
                    path,
                    with: .color(palette.line),
                    style: StrokeStyle(lineWidth: trajectoryLineWidth, lineCap: .butt, lineJoin: .miter)
                )
            }

            let fullyRevealed = progress >= Double(points.count - 1)

            // Glowing tip while the trace is still moving.
            if !fullyRevealed, let tip {
                let halo = CGRect(x: tip.x - 6, y: tip.y - 6, width: 12, height: 12)
                context.fill(Path(ellipseIn: halo), with: .color(palette.line.opacity(0.3)))
                let head = CGRect(x: tip.x - 3.5, y: tip.y - 3.5, width: 7, height: 7)
                context.fill(Path(ellipseIn: head), with: .color(palette.line))
            }

            // Witness marker: an ✕ at the final iterate proving p is outside.
            // A trace that merely ran out of iterations proves nothing, so it
            // ends in an open ring instead — and never claims a bisector.
            if fullyRevealed, let last = points.last {
                switch trajectory.outcome {
                case .witness:
                    if showBisector, let p = queryPoint {
                        drawBisector(between: last, and: p, in: &context)
                    }
                    var cross = Path()
                    cross.move(to: CGPoint(x: last.x - 6, y: last.y - 6))
                    cross.addLine(to: CGPoint(x: last.x + 6, y: last.y + 6))
                    cross.move(to: CGPoint(x: last.x + 6, y: last.y - 6))
                    cross.addLine(to: CGPoint(x: last.x - 6, y: last.y + 6))
                    context.stroke(cross, with: .color(palette.line), lineWidth: 3)
                case .exhausted:
                    let ring = CGRect(x: last.x - 5, y: last.y - 5, width: 10, height: 10)
                    context.stroke(Path(ellipseIn: ring), with: .color(palette.line), lineWidth: 2.5)
                case .converged:
                    break
                }
            }
        }
    }

    /// The orthogonal bisector of the segment from a witness to the target:
    /// every hull vertex lies on the witness's side, so the dashed line
    /// visibly separates the target from the hull.
    private func drawBisector(between witness: CGPoint, and p: CGPoint, in context: inout GraphicsContext) {
        let dx = p.x - witness.x
        let dy = p.y - witness.y
        let gap = hypot(dx, dy)
        guard gap > 0 else { return }
        let mid = CGPoint(x: (witness.x + p.x) / 2, y: (witness.y + p.y) / 2)
        // Unit direction along the bisector, perpendicular to witness → target.
        let ux = -dy / gap
        let uy = dx / gap
        // Long enough to cross the whole canvas from any midpoint.
        let reach = canvasSize.width + canvasSize.height
        var line = Path()
        line.move(to: CGPoint(x: mid.x - ux * reach, y: mid.y - uy * reach))
        line.addLine(to: CGPoint(x: mid.x + ux * reach, y: mid.y + uy * reach))
        context.stroke(line, with: .color(palette.target),
                       style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
    }

    /// Fills the regions between consecutive trajectories with the palette's
    /// slice colors. Slice i is bounded by trajectory i traced inward, a
    /// bridge between the two tips, trajectory i+1 traced back outward, and
    /// the border segment between their start points (consecutive starts
    /// always share a screen edge, so closing the subpath runs straight
    /// along the border).
    private func drawMondrianRegions(in context: inout GraphicsContext, size: CGSize, upTo progress: Double) {
        let n = trajectories.count
        guard hasRun, n >= 2 else { return }

        // Neutral slices first so accents paint over them where trajectories
        // cross each other. Nonzero winding keeps self-overlapping slices solid.
        let order = trajectories.indices.sorted { paletteSlice($0).isNeutral && !paletteSlice($1).isNeutral }

        for i in order {
            guard let path = wedgePath(i, upTo: progress) else { continue }
            context.fill(path, with: .color(paletteSlice(i).color))
        }

        // The user's hand-painted fills go on top of the palette's coloring,
        // leaving every unpainted wedge exactly as it was.
        for i in trajectories.indices {
            guard let color = wedgeOverrides[i],
                  let path = wedgePath(i, upTo: progress) else { continue }
            context.fill(path, with: .color(color))
        }
    }

    private func paletteSlice(_ i: Int) -> PaletteSlice {
        palette.slices[i % palette.slices.count]
    }

    /// The region between trajectory `i` and its neighbor, as drawn by
    /// `drawMondrianRegions` — shared by drawing and wedge hit-testing.
    private func wedgePath(_ i: Int, upTo progress: Double = .infinity) -> Path? {
        let n = trajectories.count
        guard n >= 2 else { return nil }
        let a = revealedPoints(trajectories[i].points, upTo: progress)
        let b = revealedPoints(trajectories[(i + 1) % n].points, upTo: progress)
        guard let aStart = a.first, !b.isEmpty else { return nil }
        var path = Path()
        path.move(to: aStart)
        for point in a.dropFirst() { path.addLine(to: point) }
        for point in b.reversed() { path.addLine(to: point) }
        path.closeSubpath()
        return path
    }

    /// The wedge under `location`, checking the visually topmost first:
    /// painted wedges sit above accents, which sit above neutrals.
    private func wedgeIndex(at location: CGPoint) -> Int? {
        let n = trajectories.count
        guard n >= 2 else { return nil }
        let order = trajectories.indices.sorted { paletteSlice($0).isNeutral && !paletteSlice($1).isNeutral }
        let painted = trajectories.indices.filter { wedgeOverrides[$0] != nil }.sorted(by: >)
        let unpainted = order.reversed().filter { wedgeOverrides[$0] == nil }
        for i in painted + unpainted {
            if let path = wedgePath(i), path.contains(location) { return i }
        }
        return nil
    }

    /// Paints the iteration-count field sampled across the whole canvas:
    /// each cell's color deepens with the number of steps the algorithm
    /// needs from that point, regardless of the visible iterate set.
    private func drawIterationField(in context: inout GraphicsContext, size: CGSize) {
        guard hasRun, let field = iterationField, let bitmap = fieldImage else { return }
        // One pixel per sampled cell, stretched over the canvas with
        // interpolation — much smoother and cheaper than per-cell rects.
        let rect = CGRect(x: 0, y: 0,
                          width: CGFloat(field.columns) * field.cellSize,
                          height: CGFloat(field.rows) * field.cellSize)
        let image = Image(decorative: bitmap, scale: 1).interpolation(.medium)
        context.draw(image, in: rect)
    }

    /// The iterate points revealed at `progress`, with the tip interpolated
    /// partway along the current segment for smooth animation.
    private func revealedPoints(_ points: [CGPoint], upTo progress: Double) -> [CGPoint] {
        guard points.count >= 2, progress < Double(points.count - 1) else { return points }
        let whole = max(0, Int(progress))
        var revealed = Array(points.prefix(whole + 1))
        let fraction = progress - Double(whole)
        if fraction > 0 {
            let a = points[whole]
            let b = points[whole + 1]
            revealed.append(CGPoint(x: a.x + (b.x - a.x) * fraction,
                                    y: a.y + (b.y - a.y) * fraction))
        }
        return revealed
    }

    /// Polyline through the revealed points.
    /// Returns the path and the current tip position.
    private func partialPolyline(_ points: [CGPoint], upTo progress: Double) -> (Path, CGPoint?) {
        let revealed = revealedPoints(points, upTo: progress)
        var path = Path()
        guard let first = revealed.first else { return (path, nil) }
        path.move(to: first)
        for point in revealed.dropFirst() { path.addLine(to: point) }
        return (path, revealed.last)
    }
}

#Preview {
    ContentView()
}

#Preview("With points") {
    ContentView(
        seedHullPoints: [
            CGPoint(x: 110, y: 190), CGPoint(x: 250, y: 150), CGPoint(x: 330, y: 260),
            CGPoint(x: 280, y: 380), CGPoint(x: 120, y: 340), CGPoint(x: 210, y: 250)
        ],
        seedQueryPoint: CGPoint(x: 220, y: 280)
    )
}
