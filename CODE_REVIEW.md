# Triangulography — code review

**Date:** 2026-09-03
**Scope:** All 3,062 lines of Swift in `TriangleAlgorithm/` (`ContentView.swift`, `Palettes.swift`, `IterateSchemes.swift`, `SoundEngine.swift`, `HelpOverlay.swift`).

**Method:** Static review only. Xcode was not available on the review machine (`xcodebuild` was pointed at CommandLineTools), so nothing here was compiled or run. No compile-blockers or crashes were found — the index arithmetic and `%` guards all hold up. Everything below is a correctness, concurrency, or performance defect.

**Fix first:** issues 1 and 2. Together they are the difference between the app answering the convex-hull membership question correctly and confidently drawing a false proof.

---

## Correctness

### 1. `trace` reports "witness" when it merely runs out of iterations

`TriangleAlgorithm/ContentView.swift:155`

```swift
for _ in 0..<maxIterations { ... }
return (path, pivots, distance(x, p) <= epsilon)   // false after 500 steps
```

`converged == false` has exactly one meaning downstream: *witness, proof p is outside*. But it is also what you get after exhausting `maxIterations: 500`. The triangle algorithm's gap decays like `O(R/√k)`, so for a target near the hull boundary (R ≈ 300 px, ε = 1 px) 500 iterations is nowhere near enough.

Consequences: the app draws an ✕ at `ContentView.swift:2207`, reports **outside**, and — with `showBisector` on — draws a "separating line" that separates nothing.

**Fix:** make the two exit conditions distinguishable, e.g. `enum Outcome { case converged, witness, exhausted }`, and render/aggregate `exhausted` differently from `witness`.

### 2. The membership verdict aggregates on the unreliable side

`TriangleAlgorithm/ContentView.swift:514`

```swift
// A single witness proves non-membership; otherwise all trajectories converged.
return trajectories.allSatisfy(\.converged)
```

The comment and the code disagree about which evidence is decisive. A single *convergence* is a constructive proof that p ∈ conv(S); a single non-convergence is only a proof if it is a genuine witness (see issue 1). With `allSatisfy`, one iterate stalling at the iteration cap overrides seven others that actually reached p.

**Fix:** `trajectories.contains(where: \.converged)` is the robust reading, and it is what the ✕ markers already imply visually.

### 3. Dragging the start square in Basic mode silently destroys the Paths/Regions layouts

`TriangleAlgorithm/ContentView.swift:1375`

The `.start` drag case sets `iterateScheme = .custom` on every frame. In Basic mode there is exactly one start square and it is always draggable, so nudging it flips the scheme permanently. Then `ContentView.swift:688` — `if iterateScheme != .custom` — declines to restore `.border`/`.pointsOfS` on the next mode switch, and `syncIteratesToHull` keeps the single point.

Switching Basic → Paths after touching the start square gives you **one** trajectory instead of eight, with no way to tell why.

**Fix:** Basic mode should not touch `iterateScheme` at all; its single start is already managed separately by `syncIteratesToHull`.

### 4. Cancelled field builds can resurrect themselves

`TriangleAlgorithm/ContentView.swift:1527` and `TriangleAlgorithm/ContentView.swift:1612`

`Task.isCancelled` is checked *before* `await MainActor.run { partitionField = partial; … }`, and `MainActor.run` is not a cancellation point. A task cancelled during that suspension still lands one write.

So `cancelFieldBuild()` + `partitionField = nil` in `.onChange(of: mode)` (`ContentView.swift:670`) can be immediately undone by the task it just cancelled, leaving a stale field alive in the new mode.

**Fix:** re-check `Task.isCancelled` *inside* the `MainActor.run` body, or stamp each build with a generation counter and drop writes from stale generations.

### 5. Collinear points read as a valid hull in the status chip

`TriangleAlgorithm/ContentView.swift:1013`

`pointCountStatus` tests `hullPoints.count`, but everything else tests `convexHull(of:).count`. Three collinear taps produce "Triangle ready — … then Run" while the Run button is disabled, because `startPoints` is empty (`syncIteratesToHull` bails at `ContentView.swift:1444`). Dead end with no explanation.

---

## Concurrency & performance

### 6. The audio score is synthesized on the main actor

`TriangleAlgorithm/SoundEngine.swift:113`

`renderScore` is documented as rendering "offline", but `SoundEngine` is `@MainActor` and `playRunScore` calls it straight from `recompute` (`ContentView.swift:1654`). Each tone is a ~3,970-iteration sine loop; 24 voices × a few hundred steps is tens of millions of float ops blocking the run loop at the exact moment the Run animation should start.

### 7. Long runs desynchronize from their audio

`TriangleAlgorithm/SoundEngine.swift:21`

`maxScoreDuration = 30` truncates the buffer, but nothing truncates the animation. A 500-step trace at 7 steps/sec animates for **71 seconds** with 30 seconds of audio — and in Basic mode (1.6 steps/sec) the same trace runs over five minutes. Both symptoms trace back to issue 1.

### 8. Partition mode re-encodes a 10 MB bitmap ~57 times per build

`TriangleAlgorithm/ContentView.swift:1580`

`cellSize = 0.75` on an iPad Pro canvas gives ~2.5M cells. Every 24-row batch copies the whole `pixels` array and makes a fresh `CGImage`, so a single build churns roughly half a gigabyte of allocations — and it reruns on every drag-end.

**Fix:** publish partials far less often, or write into a persistent `CGContext` instead of rebuilding the buffer per batch.

### 9. 8× poster export fails silently

`TriangleAlgorithm/ContentView.swift:1889`

```swift
guard let uiImage = renderer.uiImage else { return }
```

At 8× a 430×932-pt canvas is ~124 megapixels (~500 MB RGBA). When `ImageRenderer` gives up, the sheet keeps showing the previous image and its old pixel-size label, with no error surfaced.

**Fix:** cap the render size and add a visible failure path.

---

## Lower severity

- **Gesture state leaks on cancellation** — `ContentView.swift:1391`: `activeDrag`/`dragResolved` are only cleared in `.onEnded`. If the drag is cancelled (system edge swipe), the next drag skips hit-testing and keeps moving the previously grabbed point.
- **Painting mode does not lock the canvas** — `pointDragGesture` ignores `isPaintingWedges`, so a hull vertex can be dragged while painting, which re-traces and invalidates every wedge index already painted.
- **`wedgeOverrides` keys go stale** — `ContentView.swift:489`: keyed by wedge index and deliberately never cleared, so changing the scheme or iterate count re-applies hand-painted colors to unrelated wedges.
- **"Tracing…" overruns by one step** — `ContentView.swift:571`: should be `Double(maxSteps - 1)`; the picture completes ~1 s before the chip clears in Basic mode.
- **Ambient mode is broken in Partition** — `ContentView.swift:575`: the hold time is derived from `trajectories`, which is always empty in partition mode, so it re-randomizes every ~3.9 s and cancels each full-res build long before it finishes.
- **`CustomPaletteData.background` is stored, persisted, and ignored** — `Palettes.swift:154` hardcodes `.white`, and the editor's "Canvas" section has no background row.
- **`stepCount`'s cap (150) differs from `trace`'s (500)** — `ContentView.swift:165`: the intensity field saturates well before the traces do, and it returns the same count for "converged at k" and "witness at k".
- **README is stale** — it claims "Everything lives in a single file" (there are five), describes a fixed eight-iterate launch (now a scheme system), and its controls table lists 🎲/↩︎/🗑 buttons that were replaced by the shape and ⋯ menus.
