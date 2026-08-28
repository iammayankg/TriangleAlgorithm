import SwiftUI

// MARK: - Iterate schemes

/// How the starting iterates are generated, analogous to how `Palette`
/// picks the coloring. Every scheme yields points inside (or on) the convex
/// hull: deterministic schemes build on the hull's own vertices, patterned
/// schemes trace a figure clamped into the hull, `random` samples fresh
/// interior points on every run, and `custom` holds whatever the user has
/// placed by hand.
enum IterateScheme: String, CaseIterable, Identifiable {
    case border = "Border"
    case corners = "Corners"
    case pointsOfS = "Points of S"
    case ring = "Ring"
    case grid = "Grid"
    case spiral = "Spiral"
    case random = "Random"
    case custom = "Custom"

    var id: String { rawValue }
    var name: String { rawValue }

    /// True if the scheme should sample new points on every animated run.
    var isRandom: Bool { self == .random }

    /// Generates the starting iterates for the given convex hull. Returns
    /// nil for `.custom`, whose points are owned by the user and never
    /// regenerated, and an empty set when the hull has no interior yet.
    ///
    /// `count` sets how many iterates every scheme produces. Corners caps
    /// at the hull's own vertex count when the hull has fewer than `count`
    /// vertices. Points of S ignores `count` and starts one iterate at
    /// every point of `vertices` — the full set S, including any points
    /// interior to the hull.
    func points(inHull hull: [CGPoint], vertices: [CGPoint] = [], count: Int = 8) -> [CGPoint]? {
        guard self != .custom else { return nil }
        guard hull.count >= 3 else { return [] }
        let count = max(1, count)

        let xs = hull.map(\.x)
        let ys = hull.map(\.y)
        let bounds = CGRect(x: xs.min()!, y: ys.min()!,
                            width: xs.max()! - xs.min()!,
                            height: ys.max()! - ys.min()!)
        let centroid = CGPoint(x: xs.reduce(0, +) / CGFloat(hull.count),
                               y: ys.reduce(0, +) / CGFloat(hull.count))

        switch self {
        case .border:
            // `count` points evenly spaced along the hull's perimeter, so
            // the iterate count stays the configured size no matter how
            // many vertices the hull has (e.g. a sampled shape preset).
            let segments = hull.indices.map { i -> (start: CGPoint, end: CGPoint, length: CGFloat) in
                let a = hull[i]
                let b = hull[(i + 1) % hull.count]
                return (a, b, distance(a, b))
            }
            let perimeter = segments.reduce(0) { $0 + $1.length }
            guard perimeter > 0 else { return Array(repeating: hull[0], count: count) }
            return (0..<count).map { i in
                var remaining = perimeter * CGFloat(i) / CGFloat(count)
                for segment in segments {
                    if remaining <= segment.length, segment.length > 0 {
                        let t = remaining / segment.length
                        return CGPoint(x: segment.start.x + (segment.end.x - segment.start.x) * t,
                                       y: segment.start.y + (segment.end.y - segment.start.y) * t)
                    }
                    remaining -= segment.length
                }
                return hull[0]
            }
        case .corners:
            // Every hull vertex, or an evenly spaced subsample when the
            // hull has more vertices than the configured count.
            guard hull.count > count else { return hull }
            return (0..<count).map { hull[$0 * hull.count / count] }
        case .pointsOfS:
            // Every point of S exactly as placed, hull vertices and
            // interior points alike. Ordered by angle around the set's
            // centroid so consecutive trajectories are geometric neighbors
            // and the wedge fills between them nest instead of criss-
            // crossing when the points were placed out of order.
            let source = vertices.isEmpty ? hull : vertices
            let center = CGPoint(x: source.map(\.x).reduce(0, +) / CGFloat(source.count),
                                 y: source.map(\.y).reduce(0, +) / CGFloat(source.count))
            return source.sorted {
                atan2($0.y - center.y, $0.x - center.x) < atan2($1.y - center.y, $1.x - center.x)
            }
        case .ring:
            // Ellipse inscribed in the hull's bounding box, clamped inside.
            return (0..<count).map { i in
                let angle = CGFloat(i) / CGFloat(count) * 2 * .pi - .pi / 2
                let point = CGPoint(x: bounds.midX + bounds.width / 2 * cos(angle),
                                    y: bounds.midY + bounds.height / 2 * sin(angle))
                return clampToConvexHull(point, hull: hull)
            }
        case .grid:
            // A near-square lattice of about `count` points over the hull's
            // bounding box, clamped inside.
            let columns = max(2, Int(Double(count).squareRoot().rounded()))
            let rows = max(2, Int((Double(count) / Double(columns)).rounded(.up)))
            return (0..<rows).flatMap { row in
                (0..<columns).map { column in
                    let point = CGPoint(
                        x: bounds.minX + bounds.width * CGFloat(column) / CGFloat(columns - 1),
                        y: bounds.minY + bounds.height * CGFloat(row) / CGFloat(rows - 1)
                    )
                    return clampToConvexHull(point, hull: hull)
                }
            }
        case .spiral:
            // Points along two turns of an Archimedean spiral growing
            // outward from the hull's centroid, clamped inside.
            let maxRadius = min(bounds.width, bounds.height) / 2
            return (1...count).map { i in
                let t = CGFloat(i) / CGFloat(count)
                let angle = t * 4 * .pi
                let point = CGPoint(x: centroid.x + maxRadius * t * cos(angle),
                                    y: centroid.y + maxRadius * t * sin(angle))
                return clampToConvexHull(point, hull: hull)
            }
        case .random:
            // Rejection-sample the hull's interior; for degenerate, sliver-thin
            // hulls fall back to the centroid so the count always comes out.
            var points: [CGPoint] = []
            var attempts = 0
            while points.count < count && attempts < count * 50 {
                attempts += 1
                let candidate = CGPoint(x: .random(in: bounds.minX...bounds.maxX),
                                        y: .random(in: bounds.minY...bounds.maxY))
                if isInsideConvexHull(candidate, hull: hull) { points.append(candidate) }
            }
            while points.count < count { points.append(centroid) }
            return points
        case .custom:
            return nil
        }
    }
}
