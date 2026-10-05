import SwiftUI

// MARK: - Step strategies (anti-zig-zag)

/// The rule that moves the iterate on each step. The classic Triangle
/// Algorithm only ever steps *toward* a pivot vertex, which near a facet
/// makes the iterate bounce between two vertices in ever-smaller zig-zags.
/// The other strategies are the remedies compared in the step ablation of
/// "Guarded Block Transfers for Polytope Distance": each keeps the iterate
/// as an explicit convex combination of the vertices so weight can also be
/// taken *away* from a vertex, or moved between two vertices at once.
nonisolated enum StepStrategy: String, CaseIterable, Identifiable {
    /// Plain Triangle Algorithm: move toward the best valid pivot.
    case toward = "Toward"
    /// Pivot on the midpoint of the two best pivots when that lands nearer p.
    case midpoint = "Midpoint"
    /// Away-step Frank–Wolfe: a step straight away from the worst active
    /// vertex competes with the toward step.
    case away = "Away"
    /// Mitchell–Demyanov–Malozemov: shift weight from the worst active
    /// vertex to the best vertex in one pairwise transfer.
    case pairwise = "Pairwise"
    /// Guarded block transfers: aggregate k pairwise transfers into one
    /// line search, guarded by the single MDM step, with an away fallback.
    case block = "Block"

    var id: String { rawValue }

    var name: String {
        switch self {
        case .toward: "Toward (classic TA)"
        case .midpoint: "Midpoint heuristic"
        case .away: "Away steps"
        case .pairwise: "Pairwise (MDM)"
        case .block: "Guarded block"
        }
    }

    var symbol: String {
        switch self {
        case .toward: "arrow.up.right"
        case .midpoint: "arrow.triangle.merge"
        case .away: "arrow.uturn.backward"
        case .pairwise: "arrow.left.arrow.right"
        case .block: "square.stack.3d.forward.dottedline"
        }
    }

    /// One-paragraph explanation for the settings footer and help overlay.
    var summary: String {
        switch self {
        case .toward:
            "The plain Triangle Algorithm. Each step picks the vertex v with d(x, v) ≥ d(p, v) whose segment brings the iterate nearest to p and moves there. Near a facet this zig-zags between two vertices."
        case .midpoint:
            "The search heuristic of the enhanced TA: besides the best pivot, try pivoting on the midpoint of the two best pivots. Blending two vertices aims straight at a facet instead of bouncing between its corners."
        case .away:
            "Away-step Frank–Wolfe. The iterate is kept as a weighted blend of vertices; a step directly away from the worst-weighted vertex competes with the toward step. When the away step empties a vertex's weight it is a drop step."
        case .pairwise:
            "The MDM transfer, pairwise Frank–Wolfe on the hull. Each step moves weight from the worst active vertex to the best vertex, so the iterate slides parallel to the facet instead of zig-zagging across it."
        case .block:
            "Guarded block transfers from the paper. The top-k vertices are paired with the worst-k active ones, all k transfers are aggregated into one exact line search, and the result is guarded against the single MDM step. When the leading transfer is capacity-clipped an away step takes over; if that empties a vertex it drops it."
        }
    }

    /// Short form for the poster caption.
    func captionName(blockSize: Int) -> String {
        switch self {
        case .toward: "toward steps"
        case .midpoint: "midpoint steps"
        case .away: "away steps"
        case .pairwise: "pairwise steps"
        case .block: "block steps, k = \(blockSize)"
        }
    }

    /// Whether the strategy needs the iterate's convex weights.
    var usesWeights: Bool {
        switch self {
        case .toward, .midpoint: false
        case .away, .pairwise, .block: true
        }
    }

    /// Preset block sizes offered in the quick menu.
    static let blockSizes = [2, 4, 8, 16]
}

/// What a single step did, for drawing and for the run summary.
nonisolated enum StepKind: String, CaseIterable {
    case toward, midpoint, away, drop, pairwise, block

    var label: String {
        switch self {
        case .toward: "toward"
        case .midpoint: "midpoint"
        case .away: "away"
        case .drop: "drop"
        case .pairwise: "pairwise"
        case .block: "block"
        }
    }
}

/// One step of a trace: the vertices that gained weight (the iterate moved
/// toward them), the vertices that lost weight (it moved away from them),
/// and the far end of the search segment the iterate slid along.
nonisolated struct TraceStep {
    let kind: StepKind
    let receivers: [CGPoint]
    let donors: [CGPoint]
    /// The point reached at the maximal step along the search direction;
    /// for a toward step this is the pivot vertex itself.
    let endpoint: CGPoint
    /// Why this step was chosen over the alternatives the strategy weighed,
    /// in a sentence or two naming vertices by `vertexName`.
    let reason: String

    /// The single vertex to call out as "the pivot" of the step.
    var pivot: CGPoint { receivers.first ?? donors.first ?? endpoint }
}

/// Short label for the vertex at `index`: A, B, C… then v27, v28….
/// Shared by the explanation text and the canvas labels.
nonisolated func vertexName(_ index: Int) -> String {
    index < 26 ? String(UnicodeScalar(UInt8(65 + index))) : "v\(index + 1)"
}

// MARK: - Line search

/// Exact minimisation of ‖x + γd − p‖² over γ ∈ [0, maxStep]. Nil when the
/// direction is not a descent direction (or is degenerate). `gain` is the
/// decrease of ½‖x − p‖², the objective every strategy competes on.
nonisolated func lineSearch(
    from x: CGPoint,
    direction d: CGPoint,
    target p: CGPoint,
    maxStep: CGFloat
) -> (gamma: CGFloat, next: CGPoint, gain: CGFloat, clipped: Bool)? {
    let dd = d.x * d.x + d.y * d.y
    guard dd > 0, maxStep > 0 else { return nil }
    let slope = (p.x - x.x) * d.x + (p.y - x.y) * d.y
    guard slope > 0 else { return nil }
    let unclipped = slope / dd
    let clipped = unclipped >= maxStep
    let gamma = clipped ? maxStep : unclipped
    let next = CGPoint(x: x.x + gamma * d.x, y: x.y + gamma * d.y)
    let gain = gamma * slope - 0.5 * gamma * gamma * dd
    return (gamma, next, gain, clipped)
}

/// Convex weights expressing `point` over `vertices`: one-hot when the point
/// is a vertex, otherwise barycentric coordinates in the fan triangle of the
/// hull that contains it. Points a hair outside the hull (float error after
/// clamping) get the nearest triangle with negatives clamped away.
nonisolated func convexWeights(of point: CGPoint, over vertices: [CGPoint]) -> [CGFloat] {
    var weights = [CGFloat](repeating: 0, count: vertices.count)
    guard !vertices.isEmpty else { return weights }
    if let exact = vertices.firstIndex(where: { distance($0, point) < 1e-6 }) {
        weights[exact] = 1
        return weights
    }
    func nearestOneHot() -> [CGFloat] {
        var nearest = 0
        for index in vertices.indices where distance(vertices[index], point) < distance(vertices[nearest], point) {
            nearest = index
        }
        weights[nearest] = 1
        return weights
    }
    let hull = convexHull(of: vertices)
    let hullIndices = hull.compactMap { h in vertices.firstIndex(where: { $0 == h }) }
    guard hull.count >= 3, hullIndices.count == hull.count else { return nearestOneHot() }

    let a = hull[0]
    var best: (score: CGFloat, indices: [Int], coords: [CGFloat])? = nil
    for i in 1..<(hull.count - 1) {
        let b = hull[i], c = hull[i + 1]
        let det = (b.x - a.x) * (c.y - a.y) - (c.x - a.x) * (b.y - a.y)
        guard abs(det) > 1e-12 else { continue }
        let l1 = ((point.x - a.x) * (c.y - a.y) - (c.x - a.x) * (point.y - a.y)) / det
        let l2 = ((b.x - a.x) * (point.y - a.y) - (point.x - a.x) * (b.y - a.y)) / det
        let l0 = 1 - l1 - l2
        let score = min(l0, l1, l2)
        if score > (best?.score ?? -.infinity) {
            best = (score, [hullIndices[0], hullIndices[i], hullIndices[i + 1]], [l0, l1, l2])
        }
    }
    guard let best else { return nearestOneHot() }
    let clamped = best.coords.map { max(0, $0) }
    let total = clamped.reduce(0, +)
    guard total > 0 else { return nearestOneHot() }
    for (index, weight) in zip(best.indices, clamped) {
        weights[index] += weight / total
    }
    return weights
}

// MARK: - Solver

/// Runs one trace step at a time under a chosen strategy, keeping the
/// iterate and (where needed) its convex weights over the vertex set.
/// Shared by the animated traces and the iteration-intensity field.
nonisolated struct StepSolver {
    let vertices: [CGPoint]
    let target: CGPoint
    let strategy: StepStrategy
    let blockSize: Int
    private(set) var x: CGPoint
    /// Convex weights with x = Σ αᵢvᵢ; empty for strategies that don't need them.
    private var weights: [CGFloat]

    /// Below this a weight counts as zero (the vertex has left the support).
    private static let supportThreshold: CGFloat = 1e-9

    init(start: CGPoint, vertices: [CGPoint], target: CGPoint, strategy: StepStrategy, blockSize: Int) {
        self.vertices = vertices
        self.target = target
        self.strategy = strategy
        self.blockSize = max(1, blockSize)
        self.x = start
        self.weights = strategy.usesWeights ? convexWeights(of: start, over: vertices) : []
    }

    var gap: CGFloat { distance(x, target) }

    /// A possible step: where it lands, what it gains, and the bookkeeping
    /// needed to keep the weights in step with the iterate.
    private struct Candidate {
        let kind: StepKind
        let next: CGPoint
        let gain: CGFloat
        let endpoint: CGPoint
        let receivers: [Int]
        let donors: [Int]
        let update: WeightUpdate
        /// Filled in wherever the decision between candidates is made.
        var reason = ""
    }

    private enum WeightUpdate {
        /// α ← (1 − γ)α + γ·Σ share·e_i (toward / midpoint).
        case blend(gamma: CGFloat, shares: [(index: Int, share: CGFloat)])
        /// α ← (1 + γ)α − γ·e_u (away); `drop` zeroes u exactly.
        case away(gamma: CGFloat, from: Int, drop: Bool)
        /// α_i += delta_i (pairwise and block transfers).
        case transfer([(index: Int, delta: CGFloat)])
    }

    /// Takes one step. Nil means the iterate is a witness: no vertex is a
    /// valid Triangle-Algorithm pivot, so p is provably outside the hull.
    mutating func advance() -> TraceStep? {
        let scan = towardScan()
        guard let toward = scan.best else { return nil }
        var chosen = toward
        let towardText = towardReason(toward, validCount: scan.validCount)
        switch strategy {
        case .toward:
            chosen.reason = towardText
        case .midpoint:
            if let midpoint = midpointCandidate() {
                let names = midpoint.receivers.map(vertexName)
                if midpoint.gain > toward.gain {
                    chosen = midpoint
                    chosen.reason = "Pivoting on the midpoint of \(names[0]) and \(names[1]), the two best pivots, lands nearer p than \(names[0]) alone: \(gapText(midpoint)) versus \(gapText(toward))."
                } else {
                    chosen.reason = "\(names[0]) alone lands nearer p than the midpoint of \(names[0]) and \(names[1]): \(gapText(toward)) versus \(gapText(midpoint))."
                }
            } else {
                chosen.reason = towardText + " With no second valid pivot there is no midpoint to try."
            }
        case .away:
            if let away = awayCandidate(), let donor = away.donors.first {
                let u = vertexName(donor)
                if away.gain > toward.gain {
                    chosen = away
                    chosen.reason = "\(u) has the lowest score of the active vertices (weight \(weightText(donor))). Stepping straight away from it gains more than the best toward step on \(vertexName(toward.receivers[0])): \(gapText(away)) versus \(gapText(toward))."
                    if away.kind == .drop {
                        chosen.reason += " The step used up \(u)'s whole weight, so \(u) leaves the support — a drop step."
                    }
                } else {
                    chosen.reason = towardText + " It beats stepping away from \(u), the lowest-scoring active vertex: \(gapText(toward)) versus \(gapText(away))."
                }
            } else {
                chosen.reason = towardText + " No away step is available: the iterate sits on a single vertex."
            }
        case .pairwise:
            if let pairwise = pairwiseCandidate(), pairwise.gain > 0 {
                chosen = pairwise
            } else {
                chosen.reason = towardText + " No pairwise transfer was available."
            }
        case .block:
            if let block = blockCandidate(), block.gain > 0 {
                chosen = block
            } else {
                chosen.reason = towardText + " No block pair survived, so the plain toward step was taken."
            }
        }
        guard chosen.gain > 0 else { return nil }
        apply(chosen)
        return TraceStep(kind: chosen.kind,
                         receivers: chosen.receivers.map { vertices[$0] },
                         donors: chosen.donors.map { vertices[$0] },
                         endpoint: chosen.endpoint,
                         reason: chosen.reason)
    }

    // MARK: Explanations

    private func lengthText(_ value: CGFloat) -> String {
        String(format: value < 10 ? "%.1f" : "%.0f", value)
    }
    private func weightText(_ index: Int) -> String { String(format: "%.2f", weights[index]) }

    /// "gap 120 → 45": the distance to p before and after a candidate step.
    private func gapText(_ candidate: Candidate) -> String {
        "gap \(lengthText(gap)) → \(lengthText(distance(candidate.next, target)))"
    }

    /// Why the greedy TA pivot qualifies and why it won the scan.
    private func towardReason(_ toward: Candidate, validCount: Int) -> String {
        let index = toward.receivers[0]
        let name = vertexName(index)
        let v = vertices[index]
        var text = "\(name) is a valid pivot: it is at least as far from the iterate (\(lengthText(distance(x, v)))) as from p (\(lengthText(distance(target, v))))."
        text += validCount > 1
            ? " Of \(validCount) valid pivots, sliding along the segment to \(name) lands nearest p: \(gapText(toward))."
            : " It is the only valid pivot: \(gapText(toward))."
        return text
    }

    private func pairText(receiver: Int, donor: Int) -> String {
        "\(vertexName(receiver))←\(vertexName(donor))"
    }

    // MARK: Candidates

    /// Score sᵢ = ⟨p − x, vᵢ⟩, the Frank–Wolfe linearisation: the best
    /// receiver maximises it and the worst donor minimises it.
    private func score(_ index: Int) -> CGFloat {
        let v = vertices[index]
        return (target.x - x.x) * v.x + (target.y - x.y) * v.y
    }

    private var support: [Int] {
        weights.indices.filter { weights[$0] > Self.supportThreshold }
    }

    /// The classic TA step toward vertex `index`, if it is a valid pivot.
    private func toward(_ index: Int) -> Candidate? {
        let v = vertices[index]
        guard distance(x, v) >= distance(target, v),
              let search = lineSearch(from: x, direction: CGPoint(x: v.x - x.x, y: v.y - x.y),
                                      target: target, maxStep: 1) else { return nil }
        return Candidate(kind: .toward, next: search.next, gain: search.gain, endpoint: v,
                         receivers: [index], donors: [],
                         update: .blend(gamma: search.gamma, shares: [(index, 1)]))
    }

    /// The greedy TA pivot: among valid pivots, the one whose segment
    /// projection lands nearest p (the largest gain), plus how many
    /// vertices qualified.
    private func towardScan() -> (best: Candidate?, validCount: Int) {
        var best: Candidate? = nil
        var validCount = 0
        for index in vertices.indices {
            guard let candidate = toward(index) else { continue }
            validCount += 1
            if candidate.gain > (best?.gain ?? 0) { best = candidate }
        }
        return (best, validCount)
    }

    /// Pivot on the midpoint of the two best valid pivots. The midpoint is
    /// a convex combination, so the segment to it stays inside the hull.
    private func midpointCandidate() -> Candidate? {
        var first: Candidate? = nil
        var second: Candidate? = nil
        for index in vertices.indices {
            guard let candidate = toward(index) else { continue }
            if candidate.gain > (first?.gain ?? 0) {
                second = first
                first = candidate
            } else if candidate.gain > (second?.gain ?? 0) {
                second = candidate
            }
        }
        guard let r1 = first?.receivers.first, let r2 = second?.receivers.first else { return nil }
        let a = vertices[r1], b = vertices[r2]
        let m = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        guard let search = lineSearch(from: x, direction: CGPoint(x: m.x - x.x, y: m.y - x.y),
                                      target: target, maxStep: 1) else { return nil }
        return Candidate(kind: .midpoint, next: search.next, gain: search.gain, endpoint: m,
                         receivers: [r1, r2], donors: [],
                         update: .blend(gamma: search.gamma, shares: [(r1, 0.5), (r2, 0.5)]))
    }

    /// Step straight away from `donor`: x + γ(x − u), γ ≤ α_u / (1 − α_u).
    private func away(from donor: Int) -> Candidate? {
        let alpha = weights[donor]
        guard alpha < 1 - Self.supportThreshold else { return nil }
        let u = vertices[donor]
        let maxStep = alpha / (1 - alpha)
        let direction = CGPoint(x: x.x - u.x, y: x.y - u.y)
        guard let search = lineSearch(from: x, direction: direction, target: target, maxStep: maxStep) else { return nil }
        let endpoint = CGPoint(x: x.x + maxStep * direction.x, y: x.y + maxStep * direction.y)
        return Candidate(kind: search.clipped ? .drop : .away, next: search.next, gain: search.gain,
                         endpoint: endpoint, receivers: [], donors: [donor],
                         update: .away(gamma: search.gamma, from: donor, drop: search.clipped))
    }

    /// The worst active vertex by score, excluding `excluded`.
    private func worstDonor(excluding excluded: Int? = nil) -> Int? {
        support.filter { $0 != excluded }.min { score($0) < score($1) }
    }

    private func awayCandidate() -> Candidate? {
        guard let donor = worstDonor() else { return nil }
        return away(from: donor)
    }

    /// Transfer weight from `donor` to `receiver` along vᵣ − vᵤ, γ ≤ α_u.
    private func transfer(from donor: Int, to receiver: Int, kind: StepKind = .pairwise) -> Candidate? {
        let r = vertices[receiver], u = vertices[donor]
        let capacity = weights[donor]
        let direction = CGPoint(x: r.x - u.x, y: r.y - u.y)
        guard let search = lineSearch(from: x, direction: direction, target: target, maxStep: capacity) else { return nil }
        let endpoint = CGPoint(x: x.x + capacity * direction.x, y: x.y + capacity * direction.y)
        var candidate = Candidate(kind: kind, next: search.next, gain: search.gain, endpoint: endpoint,
                                  receivers: [receiver], donors: [donor],
                                  update: .transfer([(receiver, search.gamma), (donor, -search.gamma)]))
        let rName = vertexName(receiver), uName = vertexName(donor)
        candidate.reason = "Weight moves from \(uName), the lowest-scoring active vertex (weight \(weightText(donor))), to \(rName), the highest-scoring vertex, so the iterate slides parallel to \(uName)\(rName) instead of zig-zagging across the facet: \(gapText(candidate))."
        if search.clipped {
            candidate.reason += " \(uName)'s whole weight was transferred, so the step is capacity-clipped and \(uName) leaves the support."
        }
        return candidate
    }

    /// The MDM step: best receiver by score, worst donor in the support.
    private func pairwiseCandidate() -> Candidate? {
        guard let receiver = vertices.indices.max(by: { score($0) < score($1) }),
              let donor = worstDonor(excluding: receiver) else { return nil }
        return transfer(from: donor, to: receiver)
    }

    /// Algorithm 1 of the paper: top-k receivers paired with the worst-k
    /// donors, one line search along the aggregated direction, guarded by
    /// the single MDM step, with the away fallback when pair 1 is capped.
    private func blockCandidate() -> Candidate? {
        let receivers = Array(vertices.indices.sorted { score($0) > score($1) }.prefix(blockSize))
        guard let leadReceiver = receivers.first else { return nil }
        // If r* is active it leaves the donor list, so pair 1 always survives.
        let donors = Array(support.filter { $0 != leadReceiver }.sorted { score($0) < score($1) }.prefix(blockSize))
        guard let leadDonor = donors.first else { return nil }
        let donorSet = Set(donors)

        struct Pair { let receiver: Int; let donor: Int; let direction: CGPoint; let gamma: CGFloat }
        var pairs: [Pair] = []
        for (receiver, donor) in zip(receivers, donors) {
            let gap = score(receiver) - score(donor)
            guard gap > 0, !donorSet.contains(receiver) else { continue }
            let r = vertices[receiver], u = vertices[donor]
            let direction = CGPoint(x: r.x - u.x, y: r.y - u.y)
            let dd = direction.x * direction.x + direction.y * direction.y
            guard dd > 0 else { continue }
            pairs.append(Pair(receiver: receiver, donor: donor, direction: direction,
                              gamma: min(gap / dd, weights[donor])))
        }
        guard let lead = pairs.first, lead.receiver == leadReceiver, lead.donor == leadDonor else {
            guard var fallback = pairwiseCandidate() else { return nil }
            fallback.reason = "No block pair survived the scan, so the single MDM transfer stands in. " + fallback.reason
            return fallback
        }
        let leadGap = score(leadReceiver) - score(leadDonor)
        let leadDD = lead.direction.x * lead.direction.x + lead.direction.y * lead.direction.y
        let leadCapped = leadGap / leadDD > weights[leadDonor]

        // The aggregated block direction d = Σ γⱼ dⱼ, searched over θ ∈ [0, 1].
        let blockDirection = pairs.reduce(CGPoint.zero) { partial, pair in
            CGPoint(x: partial.x + pair.gamma * pair.direction.x,
                    y: partial.y + pair.gamma * pair.direction.y)
        }
        let block: Candidate? = lineSearch(from: x, direction: blockDirection, target: target, maxStep: 1).map { search in
            var deltas: [(index: Int, delta: CGFloat)] = []
            for pair in pairs {
                deltas.append((pair.receiver, search.gamma * pair.gamma))
                deltas.append((pair.donor, -search.gamma * pair.gamma))
            }
            return Candidate(kind: .block, next: search.next, gain: search.gain,
                             endpoint: CGPoint(x: x.x + blockDirection.x, y: x.y + blockDirection.y),
                             receivers: pairs.map(\.receiver), donors: pairs.map(\.donor),
                             update: .transfer(deltas))
        }
        let mdm = transfer(from: leadDonor, to: leadReceiver)

        func best(of candidates: [Candidate?]) -> Candidate? {
            candidates.compactMap { $0 }.max { $0.gain < $1.gain }
        }
        let pair1 = pairText(receiver: leadReceiver, donor: leadDonor)
        let pairList = pairs.map { pairText(receiver: $0.receiver, donor: $0.donor) }.joined(separator: ", ")
        let blockText = "the \(pairs.count)-pair block (\(pairList))"

        // Case (a): pair 1 uncapped — the guard, block against MDM.
        guard leadCapped else {
            guard var winner = best(of: [block, mdm]) else { return nil }
            if pairs.count == 1 {
                winner.reason = "Pair 1 (\(pair1)) is uncapped and no other pair survived, so the block is the MDM transfer \(pair1) itself: weight moves from \(vertexName(leadDonor)) to \(vertexName(leadReceiver)) and the iterate slides parallel to the facet: \(gapText(winner))."
            } else if winner.kind == .block, let mdm {
                let verb = winner.gain > mdm.gain ? "gains more than" : "matches"
                winner.reason = "Pair 1 (\(pair1)) is uncapped, so the guard applies: one line search along the aggregated direction of \(blockText) \(verb) the single MDM transfer \(pair1): \(gapText(winner)) versus \(gapText(mdm))."
            } else if let block {
                winner.reason = "Pair 1 (\(pair1)) is uncapped. The guard keeps the single MDM transfer \(pair1), which gains more than \(blockText): \(gapText(winner)) versus \(gapText(block))."
            }
            return winner
        }
        // Case (b): a boundary-clipped away step on u* is a drop and is taken
        // outright; otherwise the best of the four candidates wins.
        let capped = "Pair 1 (\(pair1)) is capacity-clipped: \(vertexName(leadDonor))'s weight \(weightText(leadDonor)) can't fund the full transfer."
        let awayStep = away(from: leadDonor)
        if var awayStep, awayStep.kind == .drop {
            awayStep.reason = "\(capped) The away step from \(vertexName(leadDonor)) is boundary-clipped too, so it is taken outright as a drop step and \(vertexName(leadDonor)) leaves the support: \(gapText(awayStep))."
            return awayStep
        }
        guard var winner = best(of: [block, mdm, awayStep, toward(leadReceiver)]) else { return nil }
        let winnerName: String
        switch winner.kind {
        case .block: winnerName = "the block"
        case .pairwise: winnerName = "the MDM transfer"
        case .away, .drop: winnerName = "the away step"
        case .toward, .midpoint: winnerName = "the toward step"
        }
        winner.reason = "\(capped) Of \(blockText), the MDM transfer \(pair1), the away step from \(vertexName(leadDonor)) and the toward step on \(vertexName(leadReceiver)), \(winnerName) gains most: \(gapText(winner))."
        return winner
    }

    // MARK: Applying a step

    private mutating func apply(_ candidate: Candidate) {
        x = candidate.next
        guard strategy.usesWeights else { return }
        switch candidate.update {
        case .blend(let gamma, let shares):
            for index in weights.indices { weights[index] *= 1 - gamma }
            for (index, share) in shares { weights[index] += gamma * share }
        case .away(let gamma, let donor, let drop):
            for index in weights.indices { weights[index] *= 1 + gamma }
            weights[donor] = drop ? 0 : weights[donor] - gamma
        case .transfer(let deltas):
            for (index, delta) in deltas { weights[index] += delta }
        }
        for index in weights.indices where weights[index] < Self.supportThreshold {
            weights[index] = 0
        }
    }
}
