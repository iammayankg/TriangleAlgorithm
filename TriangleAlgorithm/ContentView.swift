import SwiftUI

@main struct TriangleTraceApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

// MARK: - Geometry helpers

func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
    hypot(a.x - b.x, a.y - b.y)
}

/// The point on segment [a, b] closest to `target`.
func closestPointOnSegment(from a: CGPoint, to b: CGPoint, target: CGPoint) -> CGPoint {
    let dx = b.x - a.x
    let dy = b.y - a.y
    let lengthSquared = dx * dx + dy * dy
    guard lengthSquared > 0 else { return a }
    let t = ((target.x - a.x) * dx + (target.y - a.y) * dy) / lengthSquared
    let clamped = min(max(t, 0), 1)
    return CGPoint(x: a.x + clamped * dx, y: a.y + clamped * dy)
}

/// Convex hull via Andrew's monotone chain, for drawing the hull outline.
func convexHull(of points: [CGPoint]) -> [CGPoint] {
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

// MARK: - Triangle Algorithm (Kalantari)

struct Trajectory: Identifiable {
    let id = UUID()
    let points: [CGPoint]
    /// True if the iterate got within epsilon of the query point;
    /// false means the final point is a witness (proof of non-membership).
    let converged: Bool
}

enum TriangleAlgorithm {
    /// Traces iterates from `start` toward query point `p` over the vertex set.
    /// Each step pivots on a vertex v with d(x, v) >= d(p, v) and moves to the
    /// point on segment [x, v] nearest to p. Stops with a witness if no pivot exists.
    static func trace(
        from start: CGPoint,
        vertices: [CGPoint],
        target p: CGPoint,
        epsilon: CGFloat = 1.0,
        maxIterations: Int = 500
    ) -> (points: [CGPoint], converged: Bool) {
        var x = start
        var path = [x]
        guard !vertices.isEmpty else { return (path, false) }

        for _ in 0..<maxIterations {
            let currentGap = distance(x, p)
            if currentGap <= epsilon { return (path, true) }

            // Among all valid pivots, greedily take the one whose segment
            // projection lands nearest to p.
            var bestNext: CGPoint? = nil
            var bestGap = CGFloat.greatestFiniteMagnitude
            for v in vertices where distance(x, v) >= distance(p, v) {
                let candidate = closestPointOnSegment(from: x, to: v, target: p)
                let gap = distance(candidate, p)
                if gap < bestGap {
                    bestGap = gap
                    bestNext = candidate
                }
            }

            // No pivot (or no progress possible): x is a witness.
            guard let next = bestNext, bestGap < currentGap else {
                return (path, false)
            }
            x = next
            path.append(x)
        }
        return (path, distance(x, p) <= epsilon)
    }
}

// MARK: - Content view

struct ContentView: View {
    enum DragTarget: Hashable {
        case query
        case hull(Int)
    }

    /// A rendered poster ready for previewing and the share sheet.
    struct PosterImage: Identifiable {
        let id = UUID()
        let image: Image
    }

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
    @State private var palette: Palette = .mondrian
    @State private var soundOn = true
    @State private var isAmbient = false
    @State private var poster: PosterImage? = nil
    @State private var soundEngine = SoundEngine()

    private let stepsPerSecond: Double = 7
    private let borderInset: CGFloat = 18
    private let grabRadius: CGFloat = 30

    private var hasRun: Bool { !trajectories.isEmpty }

    private var membershipResult: Bool? {
        guard hasRun else { return nil }
        // A single witness proves non-membership; otherwise all trajectories converged.
        return trajectories.allSatisfy(\.converged)
    }

    var body: some View {
        ZStack {
            canvas

            if hullPoints.isEmpty && !isAmbient {
                emptyStateHint
            }

            if isAmbient {
                ambientHint
                    .transition(.opacity)
            } else {
                VStack(spacing: 12) {
                    topOverlay
                    Spacer()
                    controlBar
                }
                .padding()
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: isAmbient)
        .sensoryFeedback(trigger: isAnimating) { oldValue, newValue in
            guard oldValue && !newValue, let inside = membershipResult else { return nil }
            return inside ? .success : .error
        }
        .task(id: runStart) {
            // Stop the timeline once the longest trajectory has fully traced.
            guard runStart != nil, isAnimating else { return }
            let maxSteps = trajectories.map(\.points.count).max() ?? 0
            let duration = Double(maxSteps) / stepsPerSecond + 0.4
            try? await Task.sleep(for: .seconds(duration))
            withAnimation(.spring(duration: 0.4)) { isAnimating = false }
        }
        .task(id: isAmbient) {
            // Ambient wallpaper mode: keep composing until the user taps out.
            guard isAmbient else { return }
            while isAmbient && !Task.isCancelled {
                randomExample()
                let maxSteps = trajectories.map(\.points.count).max() ?? 0
                let traceDuration = Double(maxSteps) / stepsPerSecond + 0.4
                // Let the finished composition hang on screen before repainting.
                try? await Task.sleep(for: .seconds(traceDuration + 3.5))
            }
        }
        .sheet(item: $poster) { poster in
            posterSheet(for: poster)
        }
    }

    // MARK: Overlays

    private var emptyStateHint: some View {
        VStack(spacing: 10) {
            Image(systemName: "hand.tap")
                .font(.system(size: 44))
            Text("Tap anywhere to add hull points")
                .font(.headline)
            Text("Drag the target ring to move it, then press Run")
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
            HStack(alignment: .top, spacing: 10) {
                themeMenu
                Spacer()
                statusChip
                Spacer()
                shareButton
                infoButton
            }
            if hasRun && !isAnimating {
                legend
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.spring(duration: 0.4), value: isAnimating)
        .animation(.spring(duration: 0.4), value: hasRun)
    }

    @ViewBuilder
    private var statusChip: some View {
        if let inside = membershipResult, !isAnimating {
            Label(
                inside ? "Inside the convex hull" : "Outside — witness found",
                systemImage: inside ? "checkmark.seal.fill" : "xmark.seal.fill"
            )
            .font(.headline)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glassEffect(.regular.tint(inside ? Color.green.opacity(0.45) : Color.red.opacity(0.45)))
        } else if isAnimating {
            Label("Tracing 8 trajectories…", systemImage: "point.bottomleft.forward.to.point.topright.scurvepath")
                .font(.subheadline)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .glassEffect()
        } else if !hullPoints.isEmpty {
            Text(hullPoints.count < 3
                 ? "\(hullPoints.count) point\(hullPoints.count == 1 ? "" : "s") — add more, or press Run"
                 : "\(hullPoints.count) points — press Run")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .glassEffect()
        }
    }

    private var themeMenu: some View {
        Menu {
            Picker("Theme", selection: $palette) {
                ForEach(Palette.all) { palette in
                    Text(palette.name).tag(palette)
                }
            }
        } label: {
            Image(systemName: "paintpalette")
        }
        .buttonStyle(.glass)
        .accessibilityLabel("Color theme")
    }

    private var shareButton: some View {
        Button(action: sharePoster) {
            Image(systemName: "square.and.arrow.up")
        }
        .buttonStyle(.glass)
        .disabled(!hasRun || isAnimating)
        .accessibilityLabel("Export poster")
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
                .presentationCompactAdaptation(.popover)
        }
    }

    private var infoContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Kalantari's Triangle Algorithm")
                .font(.headline)
            Text("Eight iterates start from the corners and edge midpoints of the screen. Each step finds a pivot vertex v with d(x, v) ≥ d(p, v) and jumps to the point on the segment [x, v] closest to the target p.")
            Text("If an iterate gets within ε of the target, the point is in the hull. If no pivot exists, the iterate is a witness — proof the point is outside.")
            Divider()
            legendRows
        }
        .font(.callout)
        .padding()
        .frame(idealWidth: 320)
    }

    private var legend: some View {
        HStack(spacing: 14) {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(palette.line)
                    .frame(width: 9, height: 9)
                Text("Start")
            }
            HStack(spacing: 5) {
                Circle()
                    .strokeBorder(palette.target, lineWidth: 2)
                    .frame(width: 11, height: 11)
                Text("Target")
            }
            HStack(spacing: 5) {
                Image(systemName: "xmark")
                    .font(.caption.bold())
                    .foregroundStyle(palette.line)
                Text("Witness")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .glassEffect()
    }

    private var legendRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Dots — hull vertices (tap to add, drag to move)", systemImage: "circle.fill")
                .foregroundStyle(palette.vertex)
            Label("Ring — target point (drag to move)", systemImage: "circlebadge")
                .foregroundStyle(palette.target)
            Label("Squares — the 8 starting iterates", systemImage: "square.fill")
                .foregroundStyle(.secondary)
            Label("✕ — witness: the point is outside", systemImage: "xmark")
                .foregroundStyle(palette.line)
        }
        .font(.footnote)
    }

    // MARK: Control bar

    private var controlBar: some View {
        GlassEffectContainer(spacing: 14) {
            HStack(spacing: 14) {
                Button {
                    recompute(animated: true)
                } label: {
                    Label(hasRun ? "Replay" : "Run", systemImage: hasRun ? "arrow.clockwise" : "play.fill")
                        .frame(minWidth: 90)
                }
                .buttonStyle(.glassProminent)
                .disabled(hullPoints.isEmpty || queryPoint == nil || isAnimating)

                Button(action: randomExample) {
                    Image(systemName: "die.face.5")
                }
                .buttonStyle(.glass)
                .accessibilityLabel("Random example")

                Button {
                    isAmbient = true
                } label: {
                    Image(systemName: "sparkles")
                }
                .buttonStyle(.glass)
                .accessibilityLabel("Ambient mode")

                Button {
                    soundOn.toggle()
                    if !soundOn { soundEngine.stop() }
                } label: {
                    Image(systemName: soundOn ? "speaker.wave.2" : "speaker.slash")
                }
                .buttonStyle(.glass)
                .accessibilityLabel(soundOn ? "Mute sound" : "Enable sound")

                Button(action: undo) {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.glass)
                .disabled(hullPoints.isEmpty)
                .accessibilityLabel("Undo last point")

                Button(role: .destructive, action: clearAll) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.glass)
                .disabled(hullPoints.isEmpty && !hasRun)
                .accessibilityLabel("Clear all points")
            }
        }
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
        }
        .onTapGesture { location in
            if isAmbient {
                isAmbient = false
                return
            }
            guard target(near: location) == nil else { return }
            hullPoints.append(location)
            if hasRun { recompute(animated: false) }
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
                default:
                    break
                }
                if hasRun { recompute(animated: false) }
            }
            .onEnded { _ in
                activeDrag = nil
                dragResolved = false
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
        return best?.target
    }

    // MARK: Actions

    private func recompute(animated: Bool) {
        guard let p = queryPoint, !hullPoints.isEmpty, canvasSize != .zero else { return }
        trajectories = borderStartPoints(in: canvasSize).map { start in
            let result = TriangleAlgorithm.trace(from: start, vertices: hullPoints, target: p)
            return Trajectory(points: result.points, converged: result.converged)
        }
        if animated {
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

    private func undo() {
        guard !hullPoints.isEmpty else { return }
        hullPoints.removeLast()
        if hullPoints.isEmpty {
            trajectories = []
            runStart = nil
            isAnimating = false
        } else if hasRun {
            recompute(animated: false)
        }
    }

    private func clearAll() {
        hullPoints = []
        trajectories = []
        runStart = nil
        isAnimating = false
        soundEngine.stop()
        if canvasSize != .zero {
            queryPoint = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        }
    }

    private func randomExample() {
        guard canvasSize != .zero else { return }
        let w = canvasSize.width
        let h = canvasSize.height
        hullPoints = (0..<Int.random(in: 5...8)).map { _ in
            CGPoint(
                x: CGFloat.random(in: 0.15 * w...0.85 * w),
                y: CGFloat.random(in: 0.2 * h...0.72 * h)
            )
        }
        queryPoint = CGPoint(
            x: CGFloat.random(in: 0.1 * w...0.9 * w),
            y: CGFloat.random(in: 0.15 * h...0.78 * h)
        )
        recompute(animated: true)
    }

    /// The 8 starting iterates: 4 corners and 4 edge midpoints of the canvas.
    private func borderStartPoints(in size: CGSize) -> [CGPoint] {
        let minX = borderInset
        let minY = borderInset
        let maxX = size.width - borderInset
        let maxY = size.height - borderInset
        let midX = size.width / 2
        let midY = size.height / 2
        return [
            CGPoint(x: minX, y: minY), CGPoint(x: midX, y: minY), CGPoint(x: maxX, y: minY),
            CGPoint(x: maxX, y: midY), CGPoint(x: maxX, y: maxY), CGPoint(x: midX, y: maxY),
            CGPoint(x: minX, y: maxY), CGPoint(x: minX, y: midY)
        ]
    }

    // MARK: Poster export

    private func sharePoster() {
        guard hasRun, !isAnimating, canvasSize != .zero else { return }
        let renderer = ImageRenderer(content: posterContent)
        renderer.scale = 3
        guard let uiImage = renderer.uiImage else { return }
        poster = PosterImage(image: Image(uiImage: uiImage))
    }

    /// The finished composition matted and captioned like a gallery print.
    private var posterContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Canvas { context, size in
                draw(in: &context, size: size, at: .now)
            }
            .frame(width: canvasSize.width, height: canvasSize.height)
            .background(palette.background)
            .border(palette.line, width: 3)

            HStack(alignment: .firstTextBaseline) {
                Text("TriangleTrace")
                    .font(.system(.headline, design: .serif))
                Spacer()
                Text("\(palette.name) · \(membershipResult == true ? "inside the hull" : "witness found")")
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

            ShareLink(
                item: poster.image,
                preview: SharePreview("TriangleTrace — \(palette.name)", image: poster.image)
            ) {
                Label("Share poster", systemImage: "square.and.arrow.up")
                    .frame(minWidth: 160)
            }
            .buttonStyle(.glassProminent)
        }
        .padding(.vertical, 28)
        .presentationDetents([.medium, .large])
    }

    // MARK: Drawing

    private func draw(in context: inout GraphicsContext, size: CGSize, at date: Date) {
        let progress: Double
        if isAnimating, let start = runStart {
            progress = max(0, date.timeIntervalSince(start)) * stepsPerSecond
        } else {
            progress = .infinity
        }
        drawMondrianRegions(in: &context, size: size, upTo: progress)
        drawHull(in: &context)
        drawTrajectories(in: &context, upTo: progress)
        drawHullPoints(in: &context)
        drawQueryPoint(in: &context)
    }

    private func drawHull(in context: inout GraphicsContext) {
        let hull = convexHull(of: hullPoints)
        guard hull.count >= 2 else { return }
        var path = Path()
        path.move(to: hull[0])
        for point in hull.dropFirst() { path.addLine(to: point) }
        path.closeSubpath()
        context.stroke(path, with: .color(palette.line), lineWidth: 3)
    }

    private func drawHullPoints(in context: inout GraphicsContext) {
        for (index, point) in hullPoints.enumerated() {
            let radius: CGFloat = activeDrag == .hull(index) ? 9 : 6
            let rect = CGRect(x: point.x - radius, y: point.y - radius,
                              width: radius * 2, height: radius * 2)
            context.fill(Path(ellipseIn: rect), with: .color(palette.vertex))
            context.stroke(Path(ellipseIn: rect), with: .color(palette.background), lineWidth: 2)
        }
    }

    private func drawQueryPoint(in context: inout GraphicsContext) {
        guard let p = queryPoint else { return }
        let radius: CGFloat = activeDrag == .query ? 13 : 10
        let outer = CGRect(x: p.x - radius, y: p.y - radius,
                           width: radius * 2, height: radius * 2)
        context.fill(Path(ellipseIn: outer), with: .color(palette.background.opacity(0.85)))
        context.stroke(Path(ellipseIn: outer), with: .color(palette.target), lineWidth: 3)
        let inner = CGRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7)
        context.fill(Path(ellipseIn: inner), with: .color(palette.target))
    }

    private func drawTrajectories(in context: inout GraphicsContext, upTo progress: Double) {
        guard hasRun else { return }

        for trajectory in trajectories {
            let points = trajectory.points
            guard let first = points.first else { continue }

            // Starting iterate marker (square).
            let square = CGRect(x: first.x - 5, y: first.y - 5, width: 10, height: 10)
            context.fill(Path(roundedRect: square, cornerRadius: 1), with: .color(palette.line))

            // Angular bars, in the manner of the painter's grid lines.
            let (path, tip) = partialPolyline(points, upTo: progress)
            context.stroke(
                path,
                with: .color(palette.line),
                style: StrokeStyle(lineWidth: 4, lineCap: .butt, lineJoin: .miter)
            )

            let fullyRevealed = progress >= Double(points.count - 1)

            // Glowing tip while the trace is still moving.
            if !fullyRevealed, let tip {
                let halo = CGRect(x: tip.x - 6, y: tip.y - 6, width: 12, height: 12)
                context.fill(Path(ellipseIn: halo), with: .color(palette.line.opacity(0.3)))
                let head = CGRect(x: tip.x - 3.5, y: tip.y - 3.5, width: 7, height: 7)
                context.fill(Path(ellipseIn: head), with: .color(palette.line))
            }

            // Witness marker: an ✕ at the final iterate of a non-converged trajectory.
            if fullyRevealed && !trajectory.converged, let last = points.last {
                var cross = Path()
                cross.move(to: CGPoint(x: last.x - 6, y: last.y - 6))
                cross.addLine(to: CGPoint(x: last.x + 6, y: last.y + 6))
                cross.move(to: CGPoint(x: last.x + 6, y: last.y - 6))
                cross.addLine(to: CGPoint(x: last.x - 6, y: last.y + 6))
                context.stroke(cross, with: .color(palette.line), lineWidth: 3)
            }
        }
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
        func slice(_ i: Int) -> PaletteSlice {
            palette.slices[i % palette.slices.count]
        }
        let order = trajectories.indices.sorted { slice($0).isNeutral && !slice($1).isNeutral }

        for i in order {
            let a = revealedPoints(trajectories[i].points, upTo: progress)
            let b = revealedPoints(trajectories[(i + 1) % n].points, upTo: progress)
            guard let aStart = a.first, !b.isEmpty else { continue }
            var path = Path()
            path.move(to: aStart)
            for point in a.dropFirst() { path.addLine(to: point) }
            for point in b.reversed() { path.addLine(to: point) }
            path.closeSubpath()
            context.fill(path, with: .color(slice(i).color))
        }

        // Frame on the inset rect the traces start from, like a canvas edge.
        let frame = CGRect(x: borderInset, y: borderInset,
                           width: size.width - 2 * borderInset,
                           height: size.height - 2 * borderInset)
        context.stroke(Path(frame), with: .color(palette.line), lineWidth: 3)
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
