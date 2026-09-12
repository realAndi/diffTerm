import UIKit

/// Resolves terminal colours into concrete RGB values, folding together the
/// user's theme, any palette the running program has overridden, and the
/// per-cell attributes.
struct TerminalPalette {

    private(set) var theme: Theme
    /// 256 entries: the theme's ANSI colours, then the xterm cube and greys,
    /// with OSC 4 overrides applied on top.
    private(set) var colors: [Theme.RGB]

    private(set) var defaultForeground: Theme.RGB
    private(set) var defaultBackground: Theme.RGB
    private(set) var cursorColor: Theme.RGB

    init(theme: Theme,
         paletteOverrides: [Int: (UInt8, UInt8, UInt8)] = [:],
         foregroundOverride: (UInt8, UInt8, UInt8)? = nil,
         backgroundOverride: (UInt8, UInt8, UInt8)? = nil,
         cursorOverride: (UInt8, UInt8, UInt8)? = nil) {
        self.theme = theme
        var table = Theme.extendedPalette(ansi: theme.ansi)
        for (index, rgb) in paletteOverrides where index >= 0 && index < table.count {
            table[index] = Theme.RGB(rgb.0, rgb.1, rgb.2)
        }
        colors = table
        defaultForeground = foregroundOverride.map { Theme.RGB($0.0, $0.1, $0.2) } ?? theme.foreground
        defaultBackground = backgroundOverride.map { Theme.RGB($0.0, $0.1, $0.2) } ?? theme.background
        cursorColor = cursorOverride.map { Theme.RGB($0.0, $0.1, $0.2) } ?? theme.cursor
    }

    @inline(__always)
    func rgb(for color: TermColor, fallback: Theme.RGB) -> Theme.RGB {
        switch color {
        case .default:
            return fallback
        case .indexed(let i):
            let idx = Int(i)
            return idx < colors.count ? colors[idx] : fallback
        case .rgb(let r, let g, let b):
            return Theme.RGB(r, g, b)
        }
    }

    /// The pair of colours a cell should actually be painted with.
    func resolve(_ attrs: CellAttributes,
                 reverseVideo: Bool,
                 boldIsBright: Bool,
                 selected: Bool) -> (fg: Theme.RGB, bg: Theme.RGB) {

        var fgSpec = attrs.fg
        // SGR 1 traditionally also brightens the 8 base colours. It is a
        // preference because it is wrong often enough to annoy people.
        if boldIsBright, attrs.flags.contains(.bold), case .indexed(let i) = fgSpec, i < 8 {
            fgSpec = .indexed(i + 8)
        }

        var fg = rgb(for: fgSpec, fallback: defaultForeground)
        var bg = rgb(for: attrs.bg, fallback: defaultBackground)

        if attrs.flags.contains(.faint) {
            fg = fg.blended(with: bg, amount: 0.55)
        }

        if attrs.flags.contains(.inverse) != reverseVideo {
            swap(&fg, &bg)
        }

        if attrs.flags.contains(.invisible) {
            fg = bg
        }

        if selected {
            bg = theme.selection
            if let st = theme.selectionText {
                fg = st
            } else if abs(fg.luminance - bg.luminance) < 0.25 {
                // Keep selected text legible when the theme's selection colour
                // happens to sit close to the text colour.
                fg = bg.luminance > 0.5 ? Theme.RGB(0, 0, 0) : Theme.RGB(255, 255, 255)
            }
        }

        return (fg, bg)
    }

    /// A secondary foreground — ghost text, block rails — that is as close to
    /// the background as it can get while still clearing `minimumContrast`.
    ///
    /// Blending a fixed fraction toward the background does not work across
    /// themes: the same 55% that leaves diffTerm Dark at a readable 3.5:1
    /// drops Solarized Light to 1.74:1, which is invisible. Themes start from
    /// very different foreground contrasts, so the fraction has to be solved
    /// for rather than picked.
    ///
    /// Walks from dim to bright and takes the first value that clears the
    /// floor, so the result is the *most* subtle version that is still
    /// legible. Falls back to the plain foreground for a theme whose own text
    /// does not reach the floor — dimming that further would be worse.
    func secondaryForeground(minimumContrast: CGFloat = 4.0) -> Theme.RGB {
        let bg = defaultBackground
        let fg = defaultForeground
        guard fg.contrastRatio(with: bg) >= minimumContrast else { return fg }

        var amount: CGFloat = 0.70
        while amount > 0 {
            let candidate = fg.blended(with: bg, amount: amount)
            if candidate.contrastRatio(with: bg) >= minimumContrast { return candidate }
            amount -= 0.02
        }
        return fg
    }

    /// Colour for text drawn under the cursor block.
    func cursorTextColor() -> Theme.RGB {
        if let c = theme.cursorText { return c }
        return cursorColor.luminance > 0.55 ? Theme.RGB(0, 0, 0) : Theme.RGB(255, 255, 255)
    }
}
