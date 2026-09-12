import UIKit

/// Draws the app icon from a theme.
///
/// Written in Swift rather than the old Python rasteriser so it reads the real
/// `Theme` table — one source of truth for colours — and because CoreGraphics
/// does gradients and stroked joins properly in a fraction of the time.
enum IconRenderer {

    /// The mark: a shell prompt chevron and a cursor block. Geometry is in
    /// fractions of the canvas so every size is identical bar resolution.
    static func image(for theme: Theme, size: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let bounds = CGRect(x: 0, y: 0, width: size, height: size)

        let base = accentColor(for: theme)
        let accent = theme.isDark ? base : base.blended(with: Theme.RGB(0, 0, 0), amount: 0.10)
        let ground = theme.background

        return UIGraphicsImageRenderer(bounds: bounds, format: format).image { context in
            let ctx = context.cgContext

            // Background: a gentle vertical gradient around the theme's own
            // background, so the icon reads as that theme at a glance.
            let top: Theme.RGB
            let bottom: Theme.RGB
            if theme.isDark {
                top = ground.blended(with: Theme.RGB(255, 255, 255), amount: 0.10)
                bottom = ground.blended(with: Theme.RGB(0, 0, 0), amount: 0.25)
            } else {
                // A near-white square reads as a blank tile on the home
                // screen, so the foot of the gradient is tinted with the
                // theme's own accent instead of merely darkened.
                top = ground.blended(with: Theme.RGB(255, 255, 255), amount: 0.30)
                bottom = ground.blended(with: accent, amount: 0.14)
            }
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                         colors: [top.cgColor, bottom.cgColor] as CFArray,
                                         locations: [0, 1]) {
                ctx.drawLinearGradient(gradient,
                                       start: CGPoint(x: 0, y: 0),
                                       end: CGPoint(x: 0, y: size),
                                       options: [])
            } else {
                ctx.setFillColor(ground.cgColor)
                ctx.fill(bounds)
            }

            // A soft lift behind the mark; flat colour looks dead at 1024.
            let glowCentre = CGPoint(x: size * 0.42, y: size * 0.46)
            if let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                     colors: [accent.uiColor.withAlphaComponent(0.22).cgColor,
                                              accent.uiColor.withAlphaComponent(0).cgColor] as CFArray,
                                     locations: [0, 1]) {
                ctx.drawRadialGradient(glow,
                                       startCenter: glowCentre, startRadius: 0,
                                       endCenter: glowCentre, endRadius: size * 0.62,
                                       options: [])
            }

            let stroke = size * 0.072
            let cx = size * 0.40, cy = size * 0.50
            let arm = size * 0.135

            ctx.setStrokeColor(accent.cgColor)
            ctx.setLineWidth(stroke)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.beginPath()
            ctx.move(to: CGPoint(x: cx - arm, y: cy - arm * 1.30))
            ctx.addLine(to: CGPoint(x: cx + arm * 0.55, y: cy))
            ctx.addLine(to: CGPoint(x: cx - arm, y: cy + arm * 1.30))
            ctx.strokePath()

            // Cursor block on the prompt line.
            let barRect = CGRect(x: size * 0.545,
                                 y: cy + arm * 1.30 - stroke / 2,
                                 width: size * 0.23,
                                 height: stroke)
            ctx.setFillColor(theme.foreground.cgColor)
            ctx.addPath(UIBezierPath(roundedRect: barRect, cornerRadius: stroke * 0.28).cgPath)
            ctx.fillPath()
        }
    }

    /// Picks the colour the mark is drawn in: something with actual chroma
    /// that still stands off the background. A theme whose cursor is nearly
    /// grey (Nord, Dracula) falls through to its blues.
    static func accentColor(for theme: Theme) -> Theme.RGB {
        func chroma(_ c: Theme.RGB) -> CGFloat {
            let hi = CGFloat(max(c.r, max(c.g, c.b)))
            let lo = CGFloat(min(c.r, min(c.g, c.b)))
            return (hi - lo) / 255
        }
        var candidates = [theme.cursor]
        for index in [12, 4, 14, 6, 13, 5] where index < theme.ansi.count {
            candidates.append(theme.ansi[index])
        }
        // 3:1 is a rule for text and controls. This is a thick mark covering a
        // fifth of the canvas, and holding it to the text threshold rejects
        // colours that are perfectly legible — Sakura's pink misses by 0.01
        // and the icon comes out blue.
        let minimumContrast: CGFloat = 2.2
        for candidate in candidates
        where chroma(candidate) >= 0.15 && candidate.contrastRatio(with: theme.background) >= minimumContrast {
            return candidate
        }
        return candidates.first { $0.contrastRatio(with: theme.background) >= minimumContrast }
            ?? theme.foreground
    }

    // MARK: - Generation

    struct Output {
        var written: [String] = []
        var alternates: [String] = []
    }

    /// Writes the primary icon set plus one alternate per theme, and rewrites
    /// Info.plist's icon entries to match what was produced.
    @discardableResult
    static func generate(iconDirectory: String, infoPlistPath: String?) -> Output {
        var output = Output()
        let fm = FileManager.default
        try? fm.createDirectory(atPath: iconDirectory, withIntermediateDirectories: true)

        func write(_ image: UIImage, _ name: String) {
            guard let data = image.pngData() else { return }
            let path = (iconDirectory as NSString).appendingPathComponent(name)
            if (try? data.write(to: URL(fileURLWithPath: path))) != nil {
                output.written.append(name)
            }
        }

        // Primary icon: the app's own dark theme, at every size iOS asks for.
        let primary = Theme.theme(withID: "diffterm-dark")
        for (name, size) in [("AppIcon20x20@2x.png", 40), ("AppIcon20x20@3x.png", 60),
                             ("AppIcon29x29@2x.png", 58), ("AppIcon29x29@3x.png", 87),
                             ("AppIcon40x40@2x.png", 80), ("AppIcon40x40@3x.png", 120),
                             ("AppIcon60x60@2x.png", 120), ("AppIcon60x60@3x.png", 180),
                             ("AppIcon76x76@2x~ipad.png", 152),
                             ("AppIcon83.5x83.5@2x~ipad.png", 167)] {
            // No 1024 marketing icon: nothing in the bundle references it and
            // it alone was most of the icon payload.
            write(image(for: primary, size: CGFloat(size)), name)
        }

        // One alternate per theme. The primary already covers diffTerm Dark,
        // but it gets an alternate too so switching back is uniform.
        for theme in Theme.builtIn {
            let base = "AppIcon-\(theme.id)"
            write(image(for: theme, size: 120), "\(base)@2x.png")
            write(image(for: theme, size: 180), "\(base)@3x.png")
            write(image(for: theme, size: 152), "\(base)@2x~ipad.png")
            output.alternates.append(theme.id)
        }

        if let infoPlistPath {
            updateInfoPlist(at: infoPlistPath, alternates: output.alternates)
        }
        return output
    }

    private static func updateInfoPlist(at path: String, alternates: [String]) {
        guard let data = FileManager.default.contents(atPath: path),
              var plist = (try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil)) as? [String: Any] else {
            print("  ! could not read \(path)")
            return
        }

        var alternateEntries: [String: Any] = [:]
        for id in alternates {
            alternateEntries[id] = [
                "CFBundleIconFiles": ["AppIcon-\(id)"],
                "UIPrerenderedIcon": false,
            ] as [String: Any]
        }

        for key in ["CFBundleIcons", "CFBundleIcons~ipad"] {
            guard var icons = plist[key] as? [String: Any] else { continue }
            icons["CFBundleAlternateIcons"] = alternateEntries
            plist[key] = icons
        }

        guard let out = try? PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0) else { return }
        try? out.write(to: URL(fileURLWithPath: path))
        print("  updated \(path) with \(alternates.count) alternate icons")
    }
}
