# TriangleTrace

An interactive SwiftUI visualization of **Kalantari's Triangle Algorithm** — a simple iterative method for deciding whether a point lies inside the convex hull of a set of points — rendered in the style of a Mondrian composition.

## What it does

Tap the canvas to place hull vertices and drag the red ring to position a query point. Press **Run** and eight iterates launch from the corners and edge midpoints of the screen, each tracing a path toward the target:

- If an iterate gets within ε of the query point, the point is **inside** the convex hull.
- If an iterate reaches a state where no valid pivot exists, that iterate is a **witness** (marked with an ✕) — a proof that the point is **outside**.

As the trajectories animate, the regions between them fill with a Mondrian palette of white, red, blue, yellow, and gray, framed by black grid lines.

## The algorithm

At each step, the current iterate `x` looks for a *pivot*: a hull vertex `v` satisfying `d(x, v) ≥ d(p, v)`, where `p` is the query point. Among all valid pivots, the implementation greedily picks the one whose segment projection lands nearest to `p`, then moves `x` to the point on segment `[x, v]` closest to `p`. If no pivot exists (or no progress is possible), `x` is a witness certifying that `p` is outside the hull.

See Bahman Kalantari, *A characterization theorem and an algorithm for a convex hull problem* (2015) for the theory.

## Controls

| Control | Action |
|---|---|
| Tap canvas | Add a hull vertex |
| Drag a blue dot | Move a hull vertex |
| Drag the red ring | Move the query point |
| Run / Replay | Trace the eight trajectories |
| 🎲 | Generate a random example |
| ↩︎ | Undo the last vertex |
| 🗑 | Clear everything |

Moving a point after a run recomputes the result live, without replaying the animation.

## Project structure

Everything lives in a single file, `TriangleAlgorithm/ContentView.swift`:

- **Geometry helpers** — distance, closest point on a segment, and Andrew's monotone chain convex hull (used only to draw the hull outline).
- **`TriangleAlgorithm.trace`** — the core algorithm: pure, testable, and independent of the UI.
- **`ContentView`** — the `Canvas`/`TimelineView`-driven drawing, gestures, and Liquid Glass controls.

## Requirements

- Xcode 26 or later
- iOS 26 or later (uses Liquid Glass APIs such as `glassEffect` and `GlassEffectContainer`)

## Building

Open `TriangleAlgorithm.xcodeproj` in Xcode, select the TriangleAlgorithm scheme, and run.
