import Foundation

/// Column width of a grapheme cluster, following the same rules terminals and
/// ncurses agree on: zero for combining marks, two for East Asian Wide and
/// Fullwidth, two for emoji presentation, one otherwise.
enum CharWidth {

    /// Ranges that occupy two columns. Sorted; searched by bisection.
    private static let wideRanges: [(UInt32, UInt32)] = [
        (0x1100, 0x115F),   // Hangul Jamo init. consonants
        (0x2E80, 0x303E),   // CJK Radicals, Kangxi, CJK Symbols
        (0x3041, 0x33FF),   // Hiragana .. CJK Compatibility
        (0x3400, 0x4DBF),   // CJK Unified Ext A
        (0x4E00, 0x9FFF),   // CJK Unified
        (0xA000, 0xA4CF),   // Yi
        (0xA960, 0xA97F),   // Hangul Jamo Extended-A
        (0xAC00, 0xD7A3),   // Hangul Syllables
        (0xF900, 0xFAFF),   // CJK Compatibility Ideographs
        (0xFE10, 0xFE19),   // Vertical forms
        (0xFE30, 0xFE6F),   // CJK Compatibility Forms
        (0xFF00, 0xFF60),   // Fullwidth Forms
        (0xFFE0, 0xFFE6),
        (0x16FE0, 0x16FE4),
        (0x17000, 0x187F7), // Tangut
        (0x18800, 0x18CD5),
        (0x1B000, 0x1B152), // Kana supplement
        (0x1F004, 0x1F004), // mahjong red dragon
        (0x1F0CF, 0x1F0CF),
        (0x1F18E, 0x1F18E),
        (0x1F191, 0x1F19A),
        (0x1F200, 0x1F320),
        (0x1F32D, 0x1F335),
        (0x1F337, 0x1F37C),
        (0x1F37E, 0x1F393),
        (0x1F3A0, 0x1F3CA),
        (0x1F3CF, 0x1F3D3),
        (0x1F3E0, 0x1F3F0),
        (0x1F3F4, 0x1F3F4),
        (0x1F3F8, 0x1F43E),
        (0x1F440, 0x1F440),
        (0x1F442, 0x1F4FC),
        (0x1F4FF, 0x1F53D),
        (0x1F54B, 0x1F54E),
        (0x1F550, 0x1F567),
        (0x1F57A, 0x1F57A),
        (0x1F595, 0x1F596),
        (0x1F5A4, 0x1F5A4),
        (0x1F5FB, 0x1F64F),
        (0x1F680, 0x1F6C5),
        (0x1F6CC, 0x1F6CC),
        (0x1F6D0, 0x1F6D2),
        (0x1F6D5, 0x1F6D7),
        (0x1F6EB, 0x1F6EC),
        (0x1F6F4, 0x1F6FC),
        (0x1F7E0, 0x1F7EB),
        (0x1F90C, 0x1F93A),
        (0x1F93C, 0x1F945),
        (0x1F947, 0x1F978),
        (0x1F97A, 0x1F9CB),
        (0x1F9CD, 0x1F9FF),
        (0x1FA70, 0x1FA74),
        (0x1FA78, 0x1FA7A),
        (0x1FA80, 0x1FA86),
        (0x1FA90, 0x1FAA8),
        (0x1FAB0, 0x1FAB6),
        (0x1FAC0, 0x1FAC2),
        (0x1FAD0, 0x1FAD6),
        (0x20000, 0x2FFFD),
        (0x30000, 0x3FFFD),
    ]

    private static func inWideRange(_ v: UInt32) -> Bool {
        var lo = 0, hi = wideRanges.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let r = wideRanges[mid]
            if v < r.0 { hi = mid - 1 }
            else if v > r.1 { lo = mid + 1 }
            else { return true }
        }
        return false
    }

    static func width(of scalar: Unicode.Scalar) -> Int {
        let v = scalar.value
        if v == 0 { return 0 }
        if v < 0x20 || (v >= 0x7F && v < 0xA0) { return 0 }
        // Combining marks and other zero-width classes.
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .enclosingMark, .spacingMark, .format:
            // SPACING marks do advance in some scripts, but terminals
            // universally treat them as zero-width; matching that is what
            // keeps the grid aligned with what the shell believes.
            if v == 0x00AD { return 1 } // soft hyphen renders
            return 0
        default: break
        }
        if v == 0x200B || (v >= 0x200C && v <= 0x200F) { return 0 }
        if v >= 0xFE00 && v <= 0xFE0F { return 0 }   // variation selectors
        if v >= 0xE0100 && v <= 0xE01EF { return 0 }
        // Anything Unicode gives emoji presentation by default is drawn as a
        // colour emoji, and those are square: two columns, whatever the table
        // says. Measured on device, U+2705 comes out 17pt in a 7.8pt Menlo
        // cell. The property comes from the OS, so unlike the table below it
        // keeps up with Unicode releases on its own.
        if scalar.properties.isEmojiPresentation { return 2 }
        return inWideRange(v) ? 2 : 1
    }

    /// Width of a full grapheme cluster: the base scalar decides, except that
    /// an emoji-presentation selector or a ZWJ sequence forces two columns.
    static func width(of ch: Character) -> Int {
        var scalars = ch.unicodeScalars.makeIterator()
        guard let first = scalars.next() else { return 0 }
        var w = width(of: first)
        while let s = scalars.next() {
            if s.value == 0xFE0F { w = max(w, 2) }          // emoji presentation
            if s.value == 0x200D { w = max(w, 2) }          // ZWJ sequence
        }
        return w
    }
}
