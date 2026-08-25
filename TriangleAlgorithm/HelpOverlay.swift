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
                        row(icon: "circlebadge", title: "Place the target",
                            detail: "Drag the ring anywhere on the canvas. The app tests whether that point lies inside the hull.")
                        row(icon: "play.fill", title: "Run",
                            detail: "Trajectories trace toward the target with sound. Converging paths mean the point is inside; a ✕ marks a witness proving it's outside. Stop skips to the result.")
                        row(icon: "paintpalette", title: "Style it",
                            detail: "Pick an art theme, then choose the coloring: painted slices between trajectories, or a gradient showing how many steps each point of the hull needs.")
                        row(icon: "square.grid.3x3.topleft.filled", title: "Shape the iterates",
                            detail: "In slice mode, choose how the starting iterates are laid out — border, ring, spiral, random — or edit them by hand. They always live inside the hull.")
                        row(icon: "sparkles", title: "And more",
                            detail: "The dice paints a random example, ambient mode composes endlessly until you tap, and the share button exports your run as a poster.")
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
