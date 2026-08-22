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
    func points(inHull hull: [CGPoint]) -> [CGPoint]? {
        guard self != .custom else { return nil }
        guard hull.count >= 3 else { return [] }

        let xs = hull.map(\.x)
        let ys = hull.map(\.y)
        let bounds = CGRect(x: xs.min()!, y: ys.min()!,
                            width: xs.max()! - xs.min()!,
                            height: ys.max()! - ys.min()!)
        let centroid = CGPoint(x: xs.reduce(0, +) / CGFloat(hull.count),
                               y: ys.reduce(0, +) / CGFloat(hull.count))

        switch self {
        case .border:
            // The hull's vertices and edge midpoints.
            return hull.indices.flatMap { i -> [CGPoint] in
                let a = hull[i]
                let b = hull[(i + 1) % hull.count]
                return [a, CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)]
            }
        case .corners:
            return hull
        case .ring:
            // Ellipse inscribed in the hull's bounding box, clamped inside.
            return (0..<8).map { i in
                let angle = CGFloat(i) / 8 * 2 * .pi - .pi / 2
                let point = CGPoint(x: bounds.midX + bounds.width / 2 * cos(angle),
                                    y: bounds.midY + bounds.height / 2 * sin(angle))
                return clampToConvexHull(point, hull: hull)
            }
        case .grid:
            // 3×3 lattice over the hull's bounding box, clamped inside.
            return (0..<3).flatMap { row in
                (0..<3).map { column in
                    let point = CGPoint(x: bounds.minX + bounds.width * CGFloat(column) / 2,
                                        y: bounds.minY + bounds.height * CGFloat(row) / 2)
                    return clampToConvexHull(point, hull: hull)
                }
            }
        case .spiral:
            // 10 points along two turns of an Archimedean spiral growing
            // outward from the hull's centroid, clamped inside.
            let maxRadius = min(bounds.width, bounds.height) / 2
            return (1...10).map { i in
                let t = CGFloat(i) / 10
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
            while points.count < 8 && attempts < 400 {
                attempts += 1
                let candidate = CGPoint(x: .random(in: bounds.minX...bounds.maxX),
                                        y: .random(in: bounds.minY...bounds.maxY))
                if isInsideConvexHull(candidate, hull: hull) { points.append(candidate) }
            }
            while points.count < 8 { points.append(centroid) }
            return points
        case .custom:
            return nil
        }
    }
}
