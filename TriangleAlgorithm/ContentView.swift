import SwiftUI
import UIKit

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
    nonisolated static func trace(
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

    /// Like `trace`, but only counts steps — cheap enough to sample many
    /// starting points, as the iteration-intensity field does.
    nonisolated static func stepCount(
        from start: CGPoint,
        vertices: [CGPoint],
        target p: CGPoint,
        epsilon: CGFloat = 1.0,
        maxIterations: Int = 150
    ) -> Int {
        var x = start
        guard !vertices.isEmpty else { return 0 }
        for iteration in 0..<maxIterations {
            let currentGap = distance(x, p)
            if currentGap <= epsilon { return iteration }
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
            guard let next = bestNext, bestGap < currentGap else { return iteration }
            x = next
        }
        return maxIterations
    }
}

/// A grid of triangle-algorithm step counts sampled across the canvas,
/// backing the iteration-intensity coloring mode.
struct IterationField {
    let cellSize: CGFloat
    let columns: Int
    let rows: Int
    let counts: [Int]
    let maxCount: Int

    /// Renders the sampled counts into a bitmap with one pixel per cell.
    /// Drawing it scaled up with interpolation smooths the gradient far
    /// beyond the sampling resolution. Unsampled cells stay transparent.
    func makeImage(baseColor: UIColor) -> CGImage? {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, baseAlpha: CGFloat = 0
        baseColor.getRed(&red, green: &green, blue: &blue, alpha: &baseAlpha)
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
    enum DragTarget: Hashable {
        case query
        case hull(Int)
        case start(Int)
    }

    /// A rendered poster ready for previewing and the share sheet.
    /// The identity is stable so re-rendering at a new resolution updates
    /// the presented sheet in place instead of dismissing and re-presenting.
    struct PosterImage: Identifiable {
        var id: String { "poster" }
        let image: Image
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
    @State private var coloringMode: ColoringMode = .palette
    @State private var iterationField: IterationField? = nil
    @State private var fieldImage: CGImage? = nil
    @State private var fieldTask: Task<Void, Never>? = nil
    @State private var isBuildingField = false
    @State private var fieldProgress: Double = 0
    @State private var iterateScheme: IterateScheme = .border
    @State private var startPoints: [CGPoint] = []
    @State private var isEditingIterates = false
    @State private var showAddHullPointsAlert = false
    @State private var showOutsideHullWarning = false
    @State private var outsideHullWarningNonce = 0
    @State private var soundOn = true
    @State private var isAmbient = false
    @State private var poster: PosterImage? = nil
    @State private var exportResolution: ExportResolution = .high
    @State private var isRenderingPoster = false
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

            if hullPoints.isEmpty && !isAmbient && !isEditingIterates {
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
        .onChange(of: coloringMode) { _, _ in
            rebuildIterationField()
        }
        .onChange(of: palette) { _, newPalette in
            // The field's data survives a theme change; only re-tint the bitmap.
            if let field = iterationField {
                fieldImage = field.makeImage(baseColor: UIColor(newPalette.intensityBase))
            }
        }
        .onChange(of: iterateScheme) { _, newScheme in
            guard let points = newScheme.points(inHull: convexHull(of: hullPoints)) else { return }
            startPoints = points
            if hasRun { recompute(animated: false) }
        }
        .alert("Add hull points first", isPresented: $showAddHullPointsAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Place at least three points to form a hull, then edit the iterates inside it.")
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
                iterateMenu
                Spacer()
                shareButton
                infoButton
            }
            // The chip gets its own row so its text never fights the
            // buttons for width on small screens.
            statusChip
            if isBuildingField {
                fieldProgressChip
                    .transition(.opacity)
            }
            if hasRun && !isAnimating {
                legend
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.spring(duration: 0.4), value: isAnimating)
        .animation(.spring(duration: 0.4), value: hasRun)
        .animation(.spring(duration: 0.3), value: isBuildingField)
    }

    private var fieldProgressChip: some View {
        HStack(spacing: 10) {
            ProgressView(value: fieldProgress)
                .frame(width: 90)
            Text("Intensity \(Int(fieldProgress * 100))%")
                .monospacedDigit()
            Button("Stop") {
                cancelFieldBuild()
            }
            .font(.caption.bold())
        }
        .font(.caption)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Computing intensity plot, \(Int(fieldProgress * 100)) percent. Stop.")
    }

    @ViewBuilder
    private var statusChip: some View {
        if isEditingIterates && !isAnimating {
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
        } else if let inside = membershipResult, !isAnimating {
            Label(
                inside ? "Inside the convex hull" : "Outside — witness found",
                systemImage: inside ? "checkmark.seal.fill" : "xmark.seal.fill"
            )
            .font(.headline)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glassEffect(.regular.tint(inside ? Color.green.opacity(0.45) : Color.red.opacity(0.45)))
        } else if isAnimating {
            HStack(spacing: 12) {
                Label("Tracing \(trajectories.count) trajectories…", systemImage: "point.bottomleft.forward.to.point.topright.scurvepath")
                Button("Stop") {
                    stopTrace()
                }
                .font(.subheadline.bold())
            }
            .font(.subheadline)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassEffect()
        } else if !hullPoints.isEmpty {
            Text(hullPoints.count < 3
                 ? "\(hullPoints.count) point\(hullPoints.count == 1 ? "" : "s") — add at least 3"
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
            Divider()
            Picker("Coloring", selection: $coloringMode) {
                ForEach(ColoringMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
        } label: {
            Image(systemName: "paintpalette")
        }
        .buttonStyle(.glass)
        .accessibilityLabel("Color theme")
    }

    private var iterateMenu: some View {
        Menu {
            Picker("Iterates", selection: $iterateScheme) {
                Section("Deterministic") {
                    Text(IterateScheme.border.name).tag(IterateScheme.border)
                    Text(IterateScheme.corners.name).tag(IterateScheme.corners)
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
        .disabled(!hasRun || isAnimating || isRenderingPoster)
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
                .presentationCompactAdaptation(.popover)
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
            Text("Iterates start from a configurable set of points inside the convex hull — its vertices and edge midpoints by default. Each step finds a pivot vertex v with d(x, v) ≥ d(p, v) and jumps to the point on the segment [x, v] closest to the target p.")
            Text("If an iterate gets within ε of the target, the point is in the hull. If no pivot exists, the iterate is a witness — proof the point is outside.")
            Divider()
            Text("Intensity plot")
                .font(.headline)
            Text("The Iteration intensity coloring ignores the visible iterates and instead samples a fine grid of thousands of points across the hull's interior, running the algorithm from every one. The more steps a point needs to converge or reach a witness, the deeper it is painted in the theme's accent color.")
            Text("The plot is computed in batches in the background and sweeps in as it builds — you can stop it at any time and keep the partial result. It recomputes coarsely while you drag, then refines when you let go.")
            Divider()
            legendRows
        }
        .font(.callout)
        .padding()
    }

    /// Compact key under the status chip, matched to the coloring mode:
    /// trajectory markers in palette mode, the step-count gradient in
    /// intensity mode.
    private var legend: some View {
        HStack(spacing: 14) {
            if coloringMode == .intensity {
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(LinearGradient(
                            colors: [palette.intensityBase.opacity(0.08), palette.intensityBase],
                            startPoint: .leading, endPoint: .trailing))
                        .frame(width: 46, height: 9)
                    Text("Fewer → more steps")
                }
            } else {
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(palette.line)
                        .frame(width: 9, height: 9)
                    Text("Start")
                }
                HStack(spacing: 5) {
                    Image(systemName: "xmark")
                        .font(.caption.bold())
                        .foregroundStyle(palette.line)
                    Text("Witness")
                }
            }
            HStack(spacing: 5) {
                Circle()
                    .strokeBorder(palette.target, lineWidth: 2)
                    .frame(width: 11, height: 11)
                Text("Target")
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
            Label("Squares — the starting iterates (pick a scheme or edit them)", systemImage: "square.fill")
                .foregroundStyle(.secondary)
            Label("✕ — witness: the point is outside", systemImage: "xmark")
                .foregroundStyle(palette.line)
            Label("Gradient — deeper color, more iterations (intensity mode)", systemImage: "circle.lefthalf.filled")
                .foregroundStyle(palette.intensityBase)
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
                .disabled(hullPoints.isEmpty || queryPoint == nil || startPoints.isEmpty || isAnimating)

                Button(action: randomExample) {
                    Image(systemName: "die.face.5")
                }
                .buttonStyle(.glass)
                .accessibilityLabel("Random example")

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

    /// Secondary actions folded into one overflow button so the bar stays
    /// uncrowded on small screens.
    private var moreMenu: some View {
        Menu {
            Button {
                isAmbient = true
            } label: {
                Label("Ambient mode", systemImage: "sparkles")
            }
            Toggle(isOn: $soundOn) {
                Label("Sound", systemImage: soundOn ? "speaker.wave.2" : "speaker.slash")
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
                hullPoints.append(location)
                syncIteratesToHull()
            }
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
                    syncIteratesToHull()
                case .start(let index) where startPoints.indices.contains(index):
                    startPoints[index] = clampToConvexHull(value.location, hull: convexHull(of: hullPoints))
                    iterateScheme = .custom
                default:
                    break
                }
                if hasRun { recompute(animated: false) }
            }
            .onEnded { _ in
                let wasDragging = activeDrag != nil
                activeDrag = nil
                dragResolved = false
                // Refine the coarse drag-time field back to full resolution.
                if wasDragging && hasRun && coloringMode == .intensity {
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
        // Start points only participate while the user is editing iterates,
        // so the border squares never hijack hull or target drags.
        if isEditingIterates {
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
        if iterateScheme == .custom || iterateScheme.isRandom {
            if startPoints.isEmpty, let generated = iterateScheme.points(inHull: hull) {
                startPoints = generated
            } else {
                startPoints = startPoints.map { clampToConvexHull($0, hull: hull) }
            }
        } else if let generated = iterateScheme.points(inHull: hull) {
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
        guard coloringMode == .intensity, hasRun,
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
                        let steps = TriangleAlgorithm.stepCount(from: start, vertices: vertices, target: p)
                        counts[row * columns + column] = steps
                        maxCount = max(maxCount, steps)
                    }
                }
                if Task.isCancelled { return }
                let partial = IterationField(cellSize: cellSize, columns: columns,
                                             rows: rows, counts: counts, maxCount: maxCount)
                let progress = Double(batchEnd) / Double(rows)
                await MainActor.run {
                    iterationField = partial
                    fieldImage = partial.makeImage(baseColor: UIColor(palette.intensityBase))
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

    private func recompute(animated: Bool) {
        guard let p = queryPoint, !hullPoints.isEmpty, canvasSize != .zero else { return }
        // A random scheme samples a fresh set on every animated run, so each
        // Run/Replay composes a new picture.
        if animated, iterateScheme.isRandom,
           let fresh = iterateScheme.points(inHull: convexHull(of: hullPoints)),
           !fresh.isEmpty {
            startPoints = fresh
        }
        guard !startPoints.isEmpty else { return }
        trajectories = startPoints.map { start in
            let result = TriangleAlgorithm.trace(from: start, vertices: hullPoints, target: p)
            return Trajectory(points: result.points, converged: result.converged)
        }
        rebuildIterationField(coarse: activeDrag != nil)
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
        hullPoints = []
        trajectories = []
        runStart = nil
        isAnimating = false
        isEditingIterates = false
        syncIteratesToHull()
        cancelFieldBuild()
        iterationField = nil
        fieldImage = nil
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
        syncIteratesToHull()
        recompute(animated: true)
    }

    // MARK: Poster export

    private func sharePoster() {
        guard hasRun, !isAnimating, canvasSize != .zero, !isRenderingPoster else { return }
        isRenderingPoster = true
        Task { @MainActor in
            // ImageRenderer is main-actor bound, so the rasterization itself
            // briefly blocks the run loop; sleep one frame first so the
            // progress indicator is on screen before that happens.
            try? await Task.sleep(for: .milliseconds(50))
            defer { isRenderingPoster = false }
            let renderer = ImageRenderer(content: posterContent)
            renderer.scale = exportResolution.scale
            guard let uiImage = renderer.uiImage else { return }
            poster = PosterImage(
                image: Image(uiImage: uiImage),
                pixelSize: CGSize(width: uiImage.size.width * uiImage.scale,
                                  height: uiImage.size.height * uiImage.scale)
            )
        }
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
        }
        .padding(.vertical, 28)
        .presentationDetents([.medium, .large])
        .onChange(of: exportResolution) { _, _ in
            // Re-render the poster at the newly chosen scale.
            sharePoster()
        }
    }

    // MARK: Drawing

    private func draw(in context: inout GraphicsContext, size: CGSize, at date: Date) {
        let progress: Double
        if isAnimating, let start = runStart {
            progress = max(0, date.timeIntervalSince(start)) * stepsPerSecond
        } else {
            progress = .infinity
        }
        switch coloringMode {
        case .palette:
            drawMondrianRegions(in: &context, size: size, upTo: progress)
        case .intensity:
            drawIterationField(in: &context, size: size)
        }
        drawHull(in: &context)
        // The intensity field speaks for itself; trajectory polylines would
        // just cover it, so they only render in palette mode.
        if coloringMode == .palette {
            drawTrajectories(in: &context, upTo: progress)
        }
        drawStartPoints(in: &context)
        drawHullPoints(in: &context)
        drawQueryPoint(in: &context)
    }

    /// Starting iterate markers (squares), visible once a run exists or while
    /// the user is editing the iterate set.
    private func drawStartPoints(in context: inout GraphicsContext) {
        // In intensity mode the squares belong to the hidden trajectories,
        // so they only appear while the user is editing the iterate set.
        guard isEditingIterates || (hasRun && coloringMode == .palette) else { return }
        for (index, point) in startPoints.enumerated() {
            let half: CGFloat = activeDrag == .start(index) ? 8 : 5
            let square = CGRect(x: point.x - half, y: point.y - half,
                                width: half * 2, height: half * 2)
            context.fill(Path(roundedRect: square, cornerRadius: 1), with: .color(palette.line))
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
            guard !points.isEmpty else { continue }

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
