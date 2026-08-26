import SwiftUI

/// Full-screen, dismissable overlay that walks the user through the app's
/// core loop. Shown automatically on first launch and on demand from the
/// info popover.
struct HelpOverlay: View {
    let dismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture(perform: dismiss)

            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("How to use")
                            .font(.title2.bold())
                            .frame(maxWidth: .infinity, alignment: .center)

                        row(icon: "hand.tap", title: "Build a hull",
                            detail: "Tap the canvas to drop points — you need at least three. Drag any dot to reshape the hull; the buttons below undo or clear.")
                        row(icon: "circlebadge.fill", title: "Place the target",
                            detail: "Drag the dot anywhere on the canvas. The app tests whether that point lies inside the hull.")
                        row(icon: "play.fill", title: "Run",
                            detail: "Trajectories trace toward the target with sound. Converging paths mean the point is inside; a ✕ marks a witness proving it's outside. Stop skips to the result.")
                        row(icon: "paintpalette", title: "Style it",
                            detail: "Settings (under ⋯) holds the art themes and a customizable palette — each sets the line and accent colors, and restyles the finished picture instantly, no re-run needed.")

                        paletteGallery
                            .padding(.leading, 46)

                        row(icon: "square.stack.3d.up", title: "How the paint is applied",
                            detail: "In Palette slices mode, the regions between neighboring trajectories are filled with the theme's colors — neutral tones first, accents layered on top where paths cross. In Iteration intensity mode, the hull becomes a gradient: the algorithm runs from thousands of interior points, and the theme's accent color deepens where more steps are needed.")
                        row(icon: "square.grid.3x3.topleft.filled", title: "Shape the iterates",
                            detail: "In slice mode, choose how the starting iterates are laid out — border, ring, spiral, random — or edit them by hand. They always live inside the hull.")
                        row(icon: "sparkles", title: "And more",
                            detail: "The shapes menu drops a square, circle, ellipse, or random example onto the canvas; ambient mode composes endlessly until you tap, and the share button exports your run as a poster.")
                    }
                    .padding(24)
                }

                Button(action: dismiss) {
                    Text("Got it")
                        .frame(minWidth: 160)
                }
                .buttonStyle(.glassProminent)
                .padding(.vertical, 18)
            }
            .frame(maxWidth: 440, maxHeight: 600)
            .glassEffect(in: .rect(cornerRadius: 28))
            .padding(24)
        }
    }

    /// One swatch strip per theme: canvas, line, then the accent colors.
    private var paletteGallery: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Palette.all) { palette in
                HStack(spacing: 10) {
                    HStack(spacing: 3) {
                        swatch(palette.background)
                        swatch(palette.line)
                        ForEach(Array(accentColors(of: palette).enumerated()), id: \.offset) { _, color in
                            swatch(color)
                        }
                    }
                    Text(palette.name)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func accentColors(of palette: Palette) -> [Color] {
        var seen: Set<Color> = []
        return palette.slices.filter { !$0.isNeutral && seen.insert($0.color).inserted }.map(\.color)
    }

    private func swatch(_ color: Color) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(color)
            .frame(width: 15, height: 15)
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.secondary.opacity(0.35), lineWidth: 0.5))
    }

    private func row(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    HelpOverlay(dismiss: {})
}
