import SwiftUI
import UIKit

// MARK: - Palettes

/// One of the eight fills painted between consecutive trajectories.
/// Neutral slices are painted first so the accent colors stay on top
/// where trajectories cross each other. Every slice is a visible color —
/// never white or the canvas color — so no wedge looks unpainted.
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

    /// Piet Mondrian — primaries and grays behind a black grid.
    static let mondrian = Palette(
        name: "Mondrian",
        background: .white,
        line: Color(red: 0.1, green: 0.1, blue: 0.1),
        vertex: .blue,
        target: .red,
        slices: [
            neutral(Color(red: 0.84, green: 0.83, blue: 0.79)),
            accent(Color(red: 0.87, green: 0.0, blue: 0.0)),
            neutral(Color(red: 0.78, green: 0.77, blue: 0.73)),
            accent(Color(red: 0.98, green: 0.79, blue: 0.0)),
            neutral(Color(red: 0.87, green: 0.85, blue: 0.80)),
            accent(Color(red: 0.13, green: 0.31, blue: 0.58)),
            neutral(Color(red: 0.70, green: 0.69, blue: 0.65)),
            accent(Color(red: 0.13, green: 0.13, blue: 0.13))
        ]
    )

    /// Wassily Kandinsky — warm earth tones with orange, teal, and violet.
    static let kandinsky = Palette(
        name: "Kandinsky",
        background: .white,
        line: Color(red: 0.18, green: 0.13, blue: 0.10),
        vertex: Color(red: 0.10, green: 0.35, blue: 0.55),
        target: Color(red: 0.85, green: 0.30, blue: 0.10),
        slices: [
            neutral(Color(red: 0.87, green: 0.78, blue: 0.60)),
            accent(Color(red: 0.93, green: 0.45, blue: 0.10)),
            neutral(Color(red: 0.76, green: 0.74, blue: 0.58)),
            accent(Color(red: 0.10, green: 0.47, blue: 0.47)),
            accent(Color(red: 0.95, green: 0.77, blue: 0.20)),
            accent(Color(red: 0.42, green: 0.26, blue: 0.55)),
            neutral(Color(red: 0.66, green: 0.69, blue: 0.64)),
            accent(Color(red: 0.83, green: 0.36, blue: 0.42))
        ]
    )

    /// Kazimir Malevich — suprematist black and red over graphite grays.
    static let malevich = Palette(
        name: "Malevich",
        background: .white,
        line: Color(red: 0.06, green: 0.06, blue: 0.06),
        vertex: Color(red: 0.15, green: 0.15, blue: 0.15),
        target: Color(red: 0.76, green: 0.16, blue: 0.12),
        slices: [
            neutral(Color(red: 0.80, green: 0.78, blue: 0.74)),
            accent(Color(red: 0.10, green: 0.10, blue: 0.10)),
            neutral(Color(red: 0.68, green: 0.66, blue: 0.62)),
            accent(Color(red: 0.76, green: 0.16, blue: 0.12)),
            neutral(Color(red: 0.74, green: 0.72, blue: 0.68)),
            accent(Color(red: 0.45, green: 0.45, blue: 0.46)),
            neutral(Color(red: 0.60, green: 0.58, blue: 0.54)),
            accent(Color(red: 0.24, green: 0.24, blue: 0.25))
        ]
    )

    /// Bauhaus — muted brick, mustard, and steel blue on warm paper.
    static let bauhaus = Palette(
        name: "Bauhaus",
        background: .white,
        line: Color(red: 0.16, green: 0.14, blue: 0.13),
        vertex: Color(red: 0.20, green: 0.36, blue: 0.53),
        target: Color(red: 0.75, green: 0.22, blue: 0.17),
        slices: [
            neutral(Color(red: 0.84, green: 0.77, blue: 0.64)),
            accent(Color(red: 0.75, green: 0.22, blue: 0.17)),
            neutral(Color(red: 0.79, green: 0.72, blue: 0.59)),
            accent(Color(red: 0.85, green: 0.63, blue: 0.13)),
            accent(Color(red: 0.20, green: 0.36, blue: 0.53)),
            neutral(Color(red: 0.62, green: 0.58, blue: 0.42)),
            neutral(Color(red: 0.71, green: 0.65, blue: 0.52)),
            accent(Color(red: 0.27, green: 0.26, blue: 0.24))
        ]
    )

    /// Neon Blueprint — deep blues traced in dark cyan on the white canvas.
    static let blueprint = Palette(
        name: "Neon Blueprint",
        background: .white,
        line: Color(red: 0.0, green: 0.42, blue: 0.58),
        vertex: Color(red: 0.05, green: 0.52, blue: 0.72),
        target: Color(red: 1.0, green: 0.30, blue: 0.55),
        slices: [
            neutral(Color(red: 0.10, green: 0.14, blue: 0.30)),
            accent(Color(red: 0.14, green: 0.18, blue: 0.42)),
            neutral(Color(red: 0.06, green: 0.16, blue: 0.24)),
            accent(Color(red: 0.05, green: 0.32, blue: 0.38)),
            neutral(Color(red: 0.09, green: 0.12, blue: 0.26)),
            accent(Color(red: 0.42, green: 0.12, blue: 0.45)),
            neutral(Color(red: 0.12, green: 0.13, blue: 0.30)),
            accent(Color(red: 0.16, green: 0.22, blue: 0.48))
        ]
    )

    /// A palette built from the user's stored custom colors. Every slice is
    /// an accent so the wedges paint exactly in the order they were chosen.
    /// The canvas is always white, like the built-in palettes.
    static func custom(from data: CustomPaletteData) -> Palette {
        Palette(
            name: "Custom",
            background: .white,
            line: Color(hex: data.line),
            vertex: Color(hex: data.vertex),
            target: Color(hex: data.target),
            slices: data.slices.map { accent(Color(hex: $0)) }
        )
    }
}

// MARK: - Custom palette storage

/// The user's custom palette, stored as hex strings so it round-trips
/// through AppStorage as a single JSON blob.
struct CustomPaletteData: Codable, Equatable {
    var background: String
    var line: String
    var vertex: String
    var target: String
    var slices: [String]

    /// A pleasant starting point: warm paper, ink lines, and eight
    /// distinct, non-white wedge tones.
    static let initial = CustomPaletteData(
        background: "#F2EEE3",
        line: "#26221C",
        vertex: "#33597F",
        target: "#C0392B",
        slices: ["#C0392B", "#D9A21B", "#1F7A72", "#6B4FA1",
                 "#7A7F3B", "#C96A2D", "#8E3B5C", "#3D5A80"]
    )
}

extension CustomPaletteData {
    init?(json: String) {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(CustomPaletteData.self, from: data),
              decoded.slices.count == 8 else { return nil }
        self = decoded
    }

    var jsonString: String {
        guard let data = try? JSONEncoder().encode(self) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

extension Color {
    /// Parses "#RRGGBB" (leading # optional). Falls back to black.
    init(hex: String) {
        var value: UInt64 = 0
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        Scanner(string: cleaned).scanHexInt64(&value)
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    var hexString: String {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(self).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        func byte(_ component: CGFloat) -> Int { Int((max(0, min(1, component)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }
}

// MARK: - Custom palette editor

/// Color pickers for every part of the custom palette. Edits write through
/// the binding immediately, so the canvas behind the sheet previews live.
struct CustomPaletteEditor: View {
    @Binding var data: CustomPaletteData
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Canvas") {
                    colorRow("Lines", \.line)
                    colorRow("Hull points", \.vertex)
                    colorRow("Target", \.target)
                }
                Section("Wedges") {
                    ForEach(data.slices.indices, id: \.self) { index in
                        ColorPicker("Wedge \(index + 1)", selection: sliceBinding(index), supportsOpacity: false)
                    }
                }
                Section {
                    Button("Reset to defaults", role: .destructive) {
                        data = .initial
                    }
                }
            }
            .navigationTitle("Custom palette")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func colorRow(_ title: String, _ keyPath: WritableKeyPath<CustomPaletteData, String>) -> some View {
        ColorPicker(title, selection: Binding(
            get: { Color(hex: data[keyPath: keyPath]) },
            set: { data[keyPath: keyPath] = $0.hexString }
        ), supportsOpacity: false)
    }

    private func sliceBinding(_ index: Int) -> Binding<Color> {
        Binding(
            get: { Color(hex: data.slices[index]) },
            set: { data.slices[index] = $0.hexString }
        )
    }
}
