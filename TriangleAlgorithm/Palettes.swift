import SwiftUI

// MARK: - Palettes

/// One of the eight fills painted between consecutive trajectories.
/// Neutral slices are painted first so the accent colors stay on top
/// where trajectories cross each other.
struct PaletteSlice: Hashable {
    let color: Color
    let isNeutral: Bool
}

/// A painting style for the composition: canvas, grid-line, and point
/// colors plus the eight slice fills between trajectories.
struct Palette: Identifiable, Hashable {
    let name: String
    let background: Color
    let line: Color
    let vertex: Color
    let target: Color
    let slices: [PaletteSlice]

    var id: String { name }
}

/// How the regions between trajectories are colored: the palette's fixed
/// slice colors, or a single hue whose intensity reflects how many
/// iterations the bounding trajectories needed to converge or find a witness.
enum ColoringMode: String, CaseIterable, Identifiable {
    case palette = "Palette slices"
    case intensity = "Iteration intensity"

    var id: String { rawValue }
}

extension Palette {
    static let all: [Palette] = [.mondrian, .kandinsky, .malevich, .bauhaus, .blueprint]

    /// The hue the iteration-intensity coloring mode modulates.
    var intensityBase: Color {
        slices.first(where: { !$0.isNeutral })?.color ?? line
    }

    private static func neutral(_ color: Color) -> PaletteSlice {
        PaletteSlice(color: color, isNeutral: true)
    }

    private static func accent(_ color: Color) -> PaletteSlice {
        PaletteSlice(color: color, isNeutral: false)
    }

    /// Piet Mondrian — sparse primaries on off-white behind a black grid.
    static let mondrian: Palette = {
        let canvas = Color(red: 0.96, green: 0.95, blue: 0.92)
        return Palette(
            name: "Mondrian",
            background: canvas,
            line: Color(red: 0.1, green: 0.1, blue: 0.1),
            vertex: .blue,
            target: .red,
            slices: [
                neutral(canvas),
                accent(Color(red: 0.87, green: 0.0, blue: 0.0)),
                neutral(canvas),
                accent(Color(red: 0.98, green: 0.79, blue: 0.0)),
                neutral(canvas),
                accent(Color(red: 0.13, green: 0.31, blue: 0.58)),
                neutral(canvas),
                neutral(Color(red: 0.88, green: 0.87, blue: 0.84))
            ]
        )
    }()

    /// Wassily Kandinsky — warm cream with orange, teal, and violet.
    static let kandinsky: Palette = {
        let canvas = Color(red: 0.95, green: 0.91, blue: 0.82)
        return Palette(
            name: "Kandinsky",
            background: canvas,
            line: Color(red: 0.18, green: 0.13, blue: 0.10),
            vertex: Color(red: 0.10, green: 0.35, blue: 0.55),
            target: Color(red: 0.85, green: 0.30, blue: 0.10),
            slices: [
                neutral(canvas),
                accent(Color(red: 0.93, green: 0.45, blue: 0.10)),
                neutral(canvas),
                accent(Color(red: 0.10, green: 0.47, blue: 0.47)),
                accent(Color(red: 0.95, green: 0.77, blue: 0.20)),
                accent(Color(red: 0.42, green: 0.26, blue: 0.55)),
                neutral(canvas),
                accent(Color(red: 0.83, green: 0.36, blue: 0.42))
            ]
        )
    }()

    /// Kazimir Malevich — suprematist black and red floating on white.
    static let malevich: Palette = {
        let canvas = Color(red: 0.97, green: 0.96, blue: 0.94)
        return Palette(
            name: "Malevich",
            background: canvas,
            line: Color(red: 0.06, green: 0.06, blue: 0.06),
            vertex: Color(red: 0.15, green: 0.15, blue: 0.15),
            target: Color(red: 0.76, green: 0.16, blue: 0.12),
            slices: [
                neutral(canvas),
                accent(Color(red: 0.10, green: 0.10, blue: 0.10)),
                neutral(canvas),
                accent(Color(red: 0.76, green: 0.16, blue: 0.12)),
                neutral(canvas),
                neutral(Color(red: 0.86, green: 0.84, blue: 0.81)),
                neutral(canvas),
                accent(Color(red: 0.24, green: 0.24, blue: 0.25))
            ]
        )
    }()

    /// Bauhaus — muted brick, mustard, and steel blue on warm paper.
    static let bauhaus: Palette = {
        let canvas = Color(red: 0.93, green: 0.89, blue: 0.83)
        return Palette(
            name: "Bauhaus",
            background: canvas,
            line: Color(red: 0.16, green: 0.14, blue: 0.13),
            vertex: Color(red: 0.20, green: 0.36, blue: 0.53),
            target: Color(red: 0.75, green: 0.22, blue: 0.17),
            slices: [
                neutral(canvas),
                accent(Color(red: 0.75, green: 0.22, blue: 0.17)),
                neutral(canvas),
                accent(Color(red: 0.85, green: 0.63, blue: 0.13)),
                accent(Color(red: 0.20, green: 0.36, blue: 0.53)),
                neutral(canvas),
                neutral(Color(red: 0.87, green: 0.82, blue: 0.73)),
                accent(Color(red: 0.27, green: 0.26, blue: 0.24))
            ]
        )
    }()

    /// Neon Blueprint — electric cyan traces over deep midnight blues.
    static let blueprint: Palette = {
        let canvas = Color(red: 0.04, green: 0.07, blue: 0.15)
        return Palette(
            name: "Neon Blueprint",
            background: canvas,
            line: Color(red: 0.35, green: 0.90, blue: 1.0),
            vertex: Color(red: 0.45, green: 0.85, blue: 1.0),
            target: Color(red: 1.0, green: 0.30, blue: 0.55),
            slices: [
                neutral(canvas),
                accent(Color(red: 0.14, green: 0.18, blue: 0.42)),
                neutral(canvas),
                accent(Color(red: 0.05, green: 0.32, blue: 0.38)),
                neutral(Color(red: 0.07, green: 0.10, blue: 0.22)),
                accent(Color(red: 0.42, green: 0.12, blue: 0.45)),
                neutral(canvas),
                accent(Color(red: 0.09, green: 0.14, blue: 0.32))
            ]
        )
    }()
}
