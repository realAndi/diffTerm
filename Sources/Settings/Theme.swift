import UIKit

struct Theme: Equatable {
    var id: String
    var name: String
    var isDark: Bool

    var background: RGB
    var foreground: RGB
    var cursor: RGB
    var cursorText: RGB?
    var selection: RGB
    var selectionText: RGB?
    /// The 16 ANSI colours: 0-7 normal, 8-15 bright.
    var ansi: [RGB]

    struct RGB: Equatable, Hashable {
        var r: UInt8, g: UInt8, b: UInt8

        init(_ r: UInt8, _ g: UInt8, _ b: UInt8) { self.r = r; self.g = g; self.b = b }

        /// `#rrggbb`.
        init?(hex: String) {
            var s = hex
            if s.hasPrefix("#") { s.removeFirst() }
            guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
            self.init(UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF))
        }

        var uiColor: UIColor {
            UIColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
        }

        var cgColor: CGColor { uiColor.cgColor }

        var hex: String { String(format: "#%02x%02x%02x", r, g, b) }

        /// Perceived brightness. Cheap, and good enough for deciding which
        /// way to lean; use `contrastRatio` when the answer has to be right.
        var luminance: CGFloat {
            (0.2126 * CGFloat(r) + 0.7152 * CGFloat(g) + 0.0722 * CGFloat(b)) / 255
        }

        /// WCAG relative luminance — gamma-corrected, unlike `luminance`.
        var relativeLuminance: CGFloat {
            func channel(_ v: UInt8) -> CGFloat {
                let c = CGFloat(v) / 255
                return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
        }

        /// WCAG contrast ratio, 1 (identical) to 21 (black on white).
        func contrastRatio(with other: RGB) -> CGFloat {
            let a = relativeLuminance, b = other.relativeLuminance
            return (max(a, b) + 0.05) / (min(a, b) + 0.05)
        }

        func blended(with other: RGB, amount: CGFloat) -> RGB {
            let t = min(max(amount, 0), 1)
            func mix(_ a: UInt8, _ b: UInt8) -> UInt8 {
                UInt8(min(255, max(0, (CGFloat(a) * (1 - t) + CGFloat(b) * t).rounded())))
            }
            return RGB(mix(r, other.r), mix(g, other.g), mix(b, other.b))
        }
    }
}

extension Theme {

    /// Builds the full 256-entry xterm palette: 16 themed colours, a 6x6x6
    /// colour cube, then 24 greys.
    static func extendedPalette(ansi: [RGB]) -> [RGB] {
        var palette = [RGB]()
        palette.reserveCapacity(256)
        palette.append(contentsOf: ansi.prefix(16))
        while palette.count < 16 { palette.append(RGB(0, 0, 0)) }

        let levels: [UInt8] = [0, 95, 135, 175, 215, 255]
        for r in 0..<6 {
            for g in 0..<6 {
                for b in 0..<6 {
                    palette.append(RGB(levels[r], levels[g], levels[b]))
                }
            }
        }
        for i in 0..<24 {
            let v = UInt8(8 + i * 10)
            palette.append(RGB(v, v, v))
        }
        return palette
    }
}

// MARK: - Built-in themes

extension Theme {

    /// Literals here are checked by eye, not by the compiler, so a bad one
    /// degrades to magenta rather than trapping at launch.
    private static func rgb(_ hex: String) -> RGB { RGB(hex: hex) ?? RGB(255, 0, 255) }

    private static func make(_ id: String, _ name: String, dark: Bool,
                             bg: String, fg: String, cursor: String, selection: String,
                             _ colors: [String]) -> Theme {
        var ansi = colors.map(rgb)
        while ansi.count < 16 { ansi.append(rgb("#ff00ff")) }
        return Theme(id: id, name: name, isDark: dark,
                     background: rgb(bg), foreground: rgb(fg),
                     cursor: rgb(cursor), cursorText: nil,
                     selection: rgb(selection), selectionText: nil,
                     ansi: Array(ansi.prefix(16)))
    }

    static let builtIn: [Theme] = [
        make("diffterm-dark", "diffTerm Dark", dark: true,
             bg: "#11131a", fg: "#d5d8e2", cursor: "#5ac8fa", selection: "#2b4a6b",
             ["#1b1e26", "#ff5f6b", "#5ee08a", "#f5c451", "#5aa9fa", "#c586ff", "#4fd8d0", "#c6cad6",
              "#3c4150", "#ff8b93", "#8fefae", "#ffdb85", "#8ec7ff", "#ddb0ff", "#87efe6", "#eef1f7"]),

        make("diffterm-light", "diffTerm Light", dark: false,
             bg: "#fbfbfd", fg: "#22242c", cursor: "#0a84ff", selection: "#bcd9f7",
             ["#22242c", "#c4283a", "#1a7f43", "#9a6b00", "#0a5fd0", "#8a3fbf", "#0f7f86", "#b9bcc6",
              "#5b5f6c", "#e04a5c", "#2aa35c", "#a87c0c", "#2c7ff0", "#a862d8", "#1fa0a8", "#22242c"]),

        // Petals against paper. Bright variants are deepened rather than
        // lightened — on a pale background the usual "brighter" direction
        // walks straight off the readable end of the scale.
        make("sakura", "Sakura", dark: false,
             bg: "#fff5f7", fg: "#4a3640", cursor: "#e0679a", selection: "#ffd9e4",
             ["#4a3640", "#c2415f", "#5c8c53", "#a67c18", "#4a72b8", "#a8578f", "#3e8b8b", "#c9b8bf",
              "#8a7480", "#d94a6c", "#5b9b52", "#a8801f", "#5580d0", "#bd5fa4", "#3d9494", "#4a3640"]),

        make("sakura-night", "Sakura Night", dark: true,
             bg: "#1e1720", fg: "#f0dae2", cursor: "#ff9ec4", selection: "#4a2f3f",
             ["#2a2030", "#ff6b8a", "#9ed49a", "#f3c98b", "#8fb8e8", "#e59ad4", "#8fd8d0", "#e4d2da",
              "#5a4655", "#ff8fa8", "#b8e6b0", "#ffdfa8", "#aacff5", "#f5b8e4", "#a8ece4", "#fff2f6"]),

        make("solarized-dark", "Solarized Dark", dark: true,
             bg: "#002b36", fg: "#93a1a1", cursor: "#93a1a1", selection: "#073642",
             ["#073642", "#dc322f", "#859900", "#b58900", "#268bd2", "#d33682", "#2aa198", "#eee8d5",
              "#002b36", "#cb4b16", "#586e75", "#657b83", "#839496", "#6c71c4", "#93a1a1", "#fdf6e3"]),

        make("solarized-light", "Solarized Light", dark: false,
             bg: "#fdf6e3", fg: "#657b83", cursor: "#586e75", selection: "#eee8d5",
             ["#073642", "#dc322f", "#859900", "#b58900", "#268bd2", "#d33682", "#2aa198", "#eee8d5",
              "#002b36", "#cb4b16", "#586e75", "#657b83", "#839496", "#6c71c4", "#93a1a1", "#fdf6e3"]),

        make("nord", "Nord", dark: true,
             bg: "#2e3440", fg: "#d8dee9", cursor: "#d8dee9", selection: "#434c5e",
             ["#3b4252", "#bf616a", "#a3be8c", "#ebcb8b", "#81a1c1", "#b48ead", "#88c0d0", "#e5e9f0",
              "#4c566a", "#bf616a", "#a3be8c", "#ebcb8b", "#81a1c1", "#b48ead", "#8fbcbb", "#eceff4"]),

        make("dracula", "Dracula", dark: true,
             bg: "#282a36", fg: "#f8f8f2", cursor: "#f8f8f2", selection: "#44475a",
             ["#21222c", "#ff5555", "#50fa7b", "#f1fa8c", "#bd93f9", "#ff79c6", "#8be9fd", "#f8f8f2",
              "#6272a4", "#ff6e6e", "#69ff94", "#ffffa5", "#d6acff", "#ff92df", "#a4ffff", "#ffffff"]),

        make("gruvbox-dark", "Gruvbox Dark", dark: true,
             bg: "#282828", fg: "#ebdbb2", cursor: "#ebdbb2", selection: "#504945",
             ["#282828", "#cc241d", "#98971a", "#d79921", "#458588", "#b16286", "#689d6a", "#a89984",
              "#928374", "#fb4934", "#b8bb26", "#fabd2f", "#83a598", "#d3869b", "#8ec07c", "#ebdbb2"]),

        make("one-dark", "One Dark", dark: true,
             bg: "#282c34", fg: "#abb2bf", cursor: "#528bff", selection: "#3e4451",
             ["#282c34", "#e06c75", "#98c379", "#e5c07b", "#61afef", "#c678dd", "#56b6c2", "#abb2bf",
              "#5c6370", "#e06c75", "#98c379", "#e5c07b", "#61afef", "#c678dd", "#56b6c2", "#ffffff"]),

        make("tokyo-night", "Tokyo Night", dark: true,
             bg: "#1a1b26", fg: "#c0caf5", cursor: "#c0caf5", selection: "#33467c",
             ["#15161e", "#f7768e", "#9ece6a", "#e0af68", "#7aa2f7", "#bb9af7", "#7dcfff", "#a9b1d6",
              "#414868", "#f7768e", "#9ece6a", "#e0af68", "#7aa2f7", "#bb9af7", "#7dcfff", "#c0caf5"]),

        make("monokai", "Monokai", dark: true,
             bg: "#272822", fg: "#f8f8f2", cursor: "#f8f8f0", selection: "#49483e",
             ["#272822", "#f92672", "#a6e22e", "#f4bf75", "#66d9ef", "#ae81ff", "#a1efe4", "#f8f8f2",
              "#75715e", "#f92672", "#a6e22e", "#f4bf75", "#66d9ef", "#ae81ff", "#a1efe4", "#f9f8f5"]),

        make("catppuccin-mocha", "Catppuccin Mocha", dark: true,
             bg: "#1e1e2e", fg: "#cdd6f4", cursor: "#f5e0dc", selection: "#414356",
             ["#45475a", "#f38ba8", "#a6e3a1", "#f9e2af", "#89b4fa", "#f5c2e7", "#94e2d5", "#bac2de",
              "#585b70", "#f38ba8", "#a6e3a1", "#f9e2af", "#89b4fa", "#f5c2e7", "#94e2d5", "#a6adc8"]),

        make("basic-light", "Paper", dark: false,
             bg: "#ffffff", fg: "#1a1a1a", cursor: "#1a1a1a", selection: "#c8dcf0",
             ["#1a1a1a", "#c01c28", "#1c7a48", "#8a6800", "#1c5fc0", "#9c3fae", "#0e7c86", "#c7c7c7",
              "#6e6e6e", "#d3303f", "#228a52", "#96730a", "#2a6fd6", "#ad50bd", "#128c96", "#1a1a1a"]),
    ]

    static func theme(withID id: String) -> Theme {
        builtIn.first { $0.id == id } ?? builtIn[0]
    }
}
