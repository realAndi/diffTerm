import UIKit
import CoreText

/// The four style variants a terminal needs, plus the cell metrics derived
/// from them. Metrics come from the regular face so that italic or bold text
/// can never shift the grid.
final class TerminalFont {

    enum Style: Int, CaseIterable {
        case regular = 0, bold, italic, boldItalic

        init(flags: CellFlags, allowBold: Bool) {
            let bold = allowBold && flags.contains(.bold)
            let italic = flags.contains(.italic)
            switch (bold, italic) {
            case (false, false): self = .regular
            case (true, false):  self = .bold
            case (false, true):  self = .italic
            case (true, true):   self = .boldItalic
            }
        }
    }

    let familyName: String
    let pointSize: CGFloat
    let fonts: [CTFont]          // indexed by Style.rawValue

    let cellSize: CGSize
    let ascent: CGFloat
    let descent: CGFloat
    let underlinePosition: CGFloat
    let underlineThickness: CGFloat

    /// The system monospaced face, which has no family name we can look up by
    /// string, gets this sentinel instead.
    static let systemMonospacedName = "__system_mono__"

    init(familyName: String, pointSize: CGFloat, lineHeightScale: CGFloat, scale: CGFloat) {
        self.familyName = familyName
        self.pointSize = pointSize

        let base: UIFont
        if familyName == TerminalFont.systemMonospacedName {
            base = UIFont.monospacedSystemFont(ofSize: pointSize, weight: .regular)
        } else {
            base = UIFont(name: familyName, size: pointSize)
                ?? UIFont.monospacedSystemFont(ofSize: pointSize, weight: .regular)
        }

        func variant(bold: Bool, italic: Bool) -> CTFont {
            var traits: UIFontDescriptor.SymbolicTraits = []
            if bold { traits.insert(.traitBold) }
            if italic { traits.insert(.traitItalic) }
            if traits.isEmpty { return base as CTFont }
            if let d = base.fontDescriptor.withSymbolicTraits(traits) {
                return UIFont(descriptor: d, size: pointSize) as CTFont
            }
            // Not every monospace family ships all four faces; synthesising a
            // slant is better than silently dropping the distinction.
            if italic {
                var slant = CGAffineTransform(a: 1, b: 0, c: 0.21, d: 1, tx: 0, ty: 0)
                return withUnsafePointer(to: &slant) { matrix in
                    CTFontCreateCopyWithAttributes(base as CTFont, pointSize, matrix, nil)
                }
            }
            return base as CTFont
        }

        fonts = [
            base as CTFont,
            variant(bold: true, italic: false),
            variant(bold: false, italic: true),
            variant(bold: true, italic: true),
        ]

        let regular = fonts[0]
        let a = CTFontGetAscent(regular)
        let d = CTFontGetDescent(regular)
        let l = CTFontGetLeading(regular)

        // Advance is measured from a real glyph rather than trusting the
        // family to be fixed-pitch; some "monospace" fonts are not.
        var advance: CGFloat = 0
        var glyph = CGGlyph(0)
        var ch: UniChar = UniChar(UnicodeScalar("M").value)
        if CTFontGetGlyphsForCharacters(regular, &ch, &glyph, 1) {
            var adv = CGSize.zero
            CTFontGetAdvancesForGlyphs(regular, .horizontal, &glyph, &adv, 1)
            advance = adv.width
        }
        if advance <= 0 { advance = pointSize * 0.6 }

        // Snap to whole device pixels so glyph edges stay crisp and columns
        // never accumulate rounding drift across a wide screen.
        let px = max(scale, 1)
        let w = (advance * px).rounded(.up) / px
        let rawHeight = (a + d + l) * lineHeightScale
        let h = max((rawHeight * px).rounded(.up) / px, 1)

        cellSize = CGSize(width: w, height: h)
        // Centre the text box vertically inside a scaled line height.
        let extra = max(0, h - (a + d))
        ascent = a + extra / 2
        descent = d + extra / 2

        underlineThickness = max(CTFontGetUnderlineThickness(regular), 1 / px)
        underlinePosition = CTFontGetUnderlinePosition(regular)
    }

    func font(for style: Style) -> CTFont { fonts[style.rawValue] }

    /// Fixed-pitch families installed on the device, for the settings picker.
    static func availableFamilies() -> [(displayName: String, familyName: String)] {
        var result: [(String, String)] = [("System Mono", systemMonospacedName)]
        let preferred = ["Menlo", "Courier New", "Courier", "American Typewriter"]
        var seen = Set<String>()
        for family in UIFont.familyNames.sorted() {
            guard let sample = UIFont(name: UIFont.fontNames(forFamilyName: family).first ?? family, size: 12)
            else { continue }
            let traits = sample.fontDescriptor.symbolicTraits
            guard traits.contains(.traitMonoSpace) || preferred.contains(family) else { continue }
            guard seen.insert(family).inserted else { continue }
            result.append((family, family))
        }
        return result
    }
}

/// Per-character glyph lookup, cached because the same few hundred characters
/// are drawn thousands of times a second.
final class GlyphCache {

    enum Entry {
        /// A glyph present in the requested face — the fast path.
        case glyph(CGGlyph)
        /// Needs font fallback or shaping; drawn as a laid-out line.
        case line(CTLine, width: CGFloat)
        case blank
    }

    private var storage: [Key: Entry] = [:]
    private let font: TerminalFont

    private struct Key: Hashable {
        let ch: Character
        let style: Int
    }

    init(font: TerminalFont) {
        self.font = font
        storage.reserveCapacity(1024)
    }

    func entry(for ch: Character, style: TerminalFont.Style, color: Theme.RGB) -> Entry {
        if ch == " " { return .blank }
        let key = Key(ch: ch, style: style.rawValue)
        if let cached = storage[key] {
            // Fallback lines bake in their colour, so they can't be shared
            // across colours; re-make those and cache only the common case.
            if case .line = cached {
                return makeEntry(ch: ch, style: style, color: color)
            }
            return cached
        }
        let made = makeEntry(ch: ch, style: style, color: color)
        if case .line = made {
            // Don't store colour-specific entries.
            return made
        }
        if storage.count > 4096 { storage.removeAll(keepingCapacity: true) }
        storage[key] = made
        return made
    }

    /// Unicode splits emoji-capable characters into those that default to a
    /// colour emoji (✅, ⭐) and those that default to a plain text glyph
    /// (⏺, ⚠, ✳). CoreText does not make that distinction when it goes
    /// looking for a missing glyph: its cascade reaches Apple Color Emoji long
    /// before any monochrome face, so a terminal font without ⏺ turns Claude
    /// Code's bullets into red record buttons — 17pt of emoji in a 7.8pt cell.
    /// Asking for text presentation explicitly with U+FE0E fixes both the
    /// colour and the width. Characters that really are emoji are left alone.
    static func presentationCorrected(_ ch: Character) -> String {
        let s = String(ch)
        guard let first = ch.unicodeScalars.first,
              first.properties.isEmoji,
              !first.properties.isEmojiPresentation,
              !ch.unicodeScalars.contains(where: { $0.value == 0xFE0F || $0.value == 0xFE0E })
        else { return s }
        return s + "\u{FE0E}"
    }

    private func makeEntry(ch: Character, style: TerminalFont.Style, color: Theme.RGB) -> Entry {
        let face = font.font(for: style)
        let utf16 = Array(String(ch).utf16)

        if utf16.count == 1 {
            var glyph = CGGlyph(0)
            var unit = utf16[0]
            if CTFontGetGlyphsForCharacters(face, &unit, &glyph, 1), glyph != 0 {
                return .glyph(glyph)
            }
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: face,
            .foregroundColor: color.uiColor,
        ]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: GlyphCache.presentationCorrected(ch), attributes: attrs))
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        return .line(line, width: width)
    }
}
