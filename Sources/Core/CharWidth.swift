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
        // Printable ASCII and Latin-1 through Latin Extended/IPA/spacing
        // modifiers: one column, no property lookup. U+00AD is the only
        // format character below U+0300 and is drawn anyway; nothing here
        // has emoji presentation. This skips two Unicode table searches for
        // nearly every character a terminal prints.
        if (v >= 0x20 && v < 0x7F) || (v >= 0xA0 && v < 0x300) { return 1 }
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

    /// Width of a scalar from the ranges terminals print most after ASCII —
    /// Latin, Greek and Cyrillic letters, punctuation, symbols, box drawing,
    /// kana, CJK, Hangul syllables, private-use glyphs and emoji — or 0 for
    /// any other scalar.
    ///
    /// Every scalar with a non-zero answer is also a guarantee about grapheme
    /// clusters: its Grapheme_Cluster_Break class is Other, Control, LV or
    /// LVT (never Extend, ZWJ, SpacingMark, Prepend, a regional indicator or
    /// a Hangul jamo), so it cannot join into one cluster with printable
    /// ASCII or with another scalar this returns non-zero for. Older rules
    /// agree: the emoji classes of Unicode 9 and 10 only joined a skin-tone
    /// modifier or what follows a ZWJ, and neither is accepted here. That is
    /// what lets the parser skip String's segmentation for these without
    /// changing where it breaks.
    ///
    /// The uniform ranges hold no marks, format characters or
    /// emoji-presentation scalars, so their width is what `width(of:)` would
    /// work out from the Unicode tables; the mixed ones look it up in
    /// `mixedWidths`.
    @inline(__always)
    static func standaloneWidth(_ v: UInt32) -> Int {
        if v < 0x2000 {
            switch v {
            case 0x00A0...0x02FF: return 1  // Latin-1 .. spacing modifiers
            case 0x0370...0x0482,           // Greek, Cyrillic, minus the
                 0x048A...0x052F:           // Cyrillic combining marks
                return 1
            case 0x1E00...0x1EFF: return 1  // Latin Extended Additional
            default: return 0
            }
        }
        if v < 0x3000 {
            switch v {
            case 0x2500...0x25FC: return 1  // box drawing, blocks, shapes
            case 0x2010...0x2027,           // general punctuation, minus
                 0x2030...0x205E:           // the format controls
                return 1
            case 0x2070...0x20CF: return 1  // super/subscripts, currency
            case 0x2100...0x22FF: return 1  // letterlike, arrows, maths
            case 0x2400...0x24FF: return 1  // control pictures, enclosed
            case 0x2800...0x28FF: return 1  // braille
            case 0x2300...0x23FF,           // technical symbols, dingbats:
                 0x25FD...0x27BF:           // some have emoji presentation
                return Int(mixedWidths[Int(v - 0x2300)])
            default: return 0
            }
        }
        switch v {
        case 0x4E00...0x9FFF: return 2      // CJK Unified Ideographs
        case 0x3041...0x3096,               // hiragana and katakana, minus
             0x309B...0x30FF:               // the combining voicing marks
            return 2
        case 0x3000...0x3029: return 2      // CJK punctuation
        case 0xAC00...0xD7A3: return 2      // Hangul syllables
        case 0x3400...0x4DBF: return 2      // CJK Extension A
        case 0xE000...0xF8FF: return 1      // private use: Powerline, Nerd Fonts
        case 0xF900...0xFAFF: return 2      // CJK compatibility ideographs
        case 0xFF01...0xFF60: return 2      // fullwidth forms
        case 0x1F300...0x1F3FA,             // emoji, minus the skin-tone
             0x1F400...0x1F6FF,             // modifiers, which extend the
             0x1F900...0x1F9FF:             // emoji before them
            return Int(mixedWidths[Int(v - 0x1F300) + 0x500])
        default: return 0
        }
    }

    /// `width(of:)` for U+2300–U+27FF, then U+1F300–U+1F9FF, worked out once.
    /// Asking the Unicode tables costs two searches per character, where this
    /// costs an index; the answers come from the same function, so they
    /// cannot differ.
    private static let mixedWidths: [UInt8] =
        (UInt32(0x2300)...0x27FF).map { UInt8(width(of: Unicode.Scalar($0).unsafelyUnwrapped)) } +
        (UInt32(0x1F300)...0x1F9FF).map { UInt8(width(of: Unicode.Scalar($0).unsafelyUnwrapped)) }

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
