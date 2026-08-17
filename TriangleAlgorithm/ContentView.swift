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
    let color: Color
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

    private let trajectoryColors: [Color] = [
        .blue, .green, .orange, .purple, .pink, .teal, .indigo, .brown
    ]
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

            if hullPoints.isEmpty {
                emptyStateHint
            }

            VStack(spacing: 12) {
                topOverlay
                Spacer()
                controlBar
            }
            .padding()
        }
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
    }

    // MARK: Overlays

    private var emptyStateHint: some View {
        VStack(spacing: 10) {
            Image(systemName: "hand.tap")
                .font(.system(size: 44))
            Text("Tap anywhere to add hull points")
                .font(.headline)
            Text("Drag the red target to move it, then press Run")
                .font(.subheadline)
        }
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 40)
        .allowsHitTesting(false)
    }

    private var topOverlay: some View {
        VStack(spacing: 10) {
            HStack(alignment: .top) {
                Spacer()
                statusChip
                Spacer()
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
                RoundedRectangle(cornerRadius: 2)
                    .fill(.blue)
                    .frame(width: 9, height: 9)
                Text("Start")
            }
            HStack(spacing: 5) {
                Circle()
                    .strokeBorder(.red, lineWidth: 2)
                    .frame(width: 11, height: 11)
                Text("Target")
            }
            HStack(spacing: 5) {
                Image(systemName: "xmark")
                    .font(.caption.bold())
                    .foregroundStyle(.red)
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
            Label("Blue dots — hull vertices (tap to add, drag to move)", systemImage: "circle.fill")
                .foregroundStyle(.blue)
            Label("Red ring — target point (drag to move)", systemImage: "circlebadge")
                .foregroundStyle(.red)
            Label("Squares — the 8 starting iterates", systemImage: "square.fill")
                .foregroundStyle(.secondary)
            Label("✕ — witness: the point is outside", systemImage: "xmark")
                .foregroundStyle(.red)
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
        .background(Color.gray.opacity(0.08))
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { newSize in
            canvasSize = newSize
            if queryPoint == nil, newSize != .zero {
                queryPoint = CGPoint(x: newSize.width / 2, y: newSize.height / 2)
            }
        }
        .onTapGesture { location in
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
        trajectories = borderStartPoints(in: canvasSize).enumerated().map { index, start in
            let result = TriangleAlgorithm.trace(from: start, vertices: hullPoints, target: p)
            return Trajectory(
                points: result.points,
                converged: result.converged,
                color: trajectoryColors[index % trajectoryColors.count]
            )
        }
        if animated {
            runStart = Date()
            isAnimating = true
        } else {
            runStart = nil
            isAnimating = false
        }
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

    // MARK: Drawing

    private func draw(in context: inout GraphicsContext, size: CGSize, at date: Date) {
        drawHull(in: &context)
        drawTrajectories(in: &context, at: date)
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
        context.fill(path, with: .color(.blue.opacity(0.08)))
        context.stroke(path, with: .color(.blue.opacity(0.45)), lineWidth: 1.5)
    }

    private func drawHullPoints(in context: inout GraphicsContext) {
        for (index, point) in hullPoints.enumerated() {
            let radius: CGFloat = activeDrag == .hull(index) ? 9 : 6
            let rect = CGRect(x: point.x - radius, y: point.y - radius,
                              width: radius * 2, height: radius * 2)
            context.fill(Path(ellipseIn: rect), with: .color(.blue))
            context.stroke(Path(ellipseIn: rect), with: .color(.white), lineWidth: 2)
        }
    }

    private func drawQueryPoint(in context: inout GraphicsContext) {
        guard let p = queryPoint else { return }
        let radius: CGFloat = activeDrag == .query ? 13 : 10
        let outer = CGRect(x: p.x - radius, y: p.y - radius,
                           width: radius * 2, height: radius * 2)
        context.fill(Path(ellipseIn: outer), with: .color(.white.opacity(0.85)))
        context.stroke(Path(ellipseIn: outer), with: .color(.red), lineWidth: 3)
        let inner = CGRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7)
        context.fill(Path(ellipseIn: inner), with: .color(.red))
    }

    private func drawTrajectories(in context: inout GraphicsContext, at date: Date) {
        guard hasRun else { return }
        let progress: Double
        if isAnimating, let start = runStart {
            progress = max(0, date.timeIntervalSince(start)) * stepsPerSecond
        } else {
            progress = .infinity
        }

        for trajectory in trajectories {
            let points = trajectory.points
            guard let first = points.first else { continue }

            // Starting iterate marker (square).
            let square = CGRect(x: first.x - 5, y: first.y - 5, width: 10, height: 10)
            context.fill(Path(roundedRect: square, cornerRadius: 2), with: .color(trajectory.color))

            let (path, tip) = partialPolyline(points, upTo: progress)
            context.stroke(
                path,
                with: .color(trajectory.color.opacity(0.75)),
                style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
            )

            // Dots at each revealed iterate.
            let revealedCount = progress.isFinite ? min(points.count, Int(progress) + 1) : points.count
            for point in points.prefix(revealedCount) {
                let dot = CGRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4)
                context.fill(Path(ellipseIn: dot), with: .color(trajectory.color))
            }

            let fullyRevealed = progress >= Double(points.count - 1)

            // Glowing tip while the trace is still moving.
            if !fullyRevealed, let tip {
                let halo = CGRect(x: tip.x - 6, y: tip.y - 6, width: 12, height: 12)
                context.fill(Path(ellipseIn: halo), with: .color(trajectory.color.opacity(0.35)))
                let head = CGRect(x: tip.x - 3.5, y: tip.y - 3.5, width: 7, height: 7)
                context.fill(Path(ellipseIn: head), with: .color(trajectory.color))
            }

            // Witness marker: an ✕ at the final iterate of a non-converged trajectory.
            if fullyRevealed && !trajectory.converged, let last = points.last {
                var cross = Path()
                cross.move(to: CGPoint(x: last.x - 6, y: last.y - 6))
                cross.addLine(to: CGPoint(x: last.x + 6, y: last.y + 6))
                cross.move(to: CGPoint(x: last.x + 6, y: last.y - 6))
                cross.addLine(to: CGPoint(x: last.x - 6, y: last.y + 6))
                context.stroke(cross, with: .color(trajectory.color), lineWidth: 3)
            }
        }
    }

    /// Polyline through the first `progress` steps, with the tip interpolated
    /// partway along the current segment for smooth animation.
    /// Returns the path and the current tip position.
    private func partialPolyline(_ points: [CGPoint], upTo progress: Double) -> (Path, CGPoint?) {
        var path = Path()
        guard points.count >= 2 else { return (path, points.first) }
        let t = min(progress, Double(points.count - 1))
        let whole = Int(t)
        var tip = points[0]
        path.move(to: points[0])
        if whole >= 1 {
            for i in 1...whole { path.addLine(to: points[i]) }
            tip = points[whole]
        }
        let fraction = t - Double(whole)
        if whole < points.count - 1 && fraction > 0 {
            let a = points[whole]
            let b = points[whole + 1]
            tip = CGPoint(x: a.x + (b.x - a.x) * fraction,
                          y: a.y + (b.y - a.y) * fraction)
            path.addLine(to: tip)
        }
        return (path, tip)
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
