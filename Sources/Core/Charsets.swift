import Foundation

/// The 94-character sets a VT can designate into G0-G3. Only the ones that
/// still matter in practice are modelled: DEC Special Graphics is what draws
/// box-drawing output from ncurses when a program has not switched to UTF-8.
enum CharacterSet94 {
    case ascii
    case decSpecialGraphics
    case ukNational

    static func from(final: UInt8) -> CharacterSet94? {
        switch final {
        case UInt8(ascii: "0"): return .decSpecialGraphics
        case UInt8(ascii: "A"): return .ukNational
        case UInt8(ascii: "B"), UInt8(ascii: "<"), UInt8(ascii: "~"): return .ascii
        default: return nil
        }
    }

    /// DEC Special Graphics maps 0x5F-0x7E onto line-drawing glyphs.
    private static let graphics: [Character] = [
        "\u{00A0}", // _ blank
        "\u{25C6}", // ` diamond
        "\u{2592}", // a checker board
        "\u{2409}", // b HT
        "\u{240C}", // c FF
        "\u{240D}", // d CR
        "\u{240A}", // e LF
        "\u{00B0}", // f degree
        "\u{00B1}", // g plus/minus
        "\u{2424}", // h NL
        "\u{240B}", // i VT
        "\u{2518}", // j lower-right corner
        "\u{2510}", // k upper-right corner
        "\u{250C}", // l upper-left corner
        "\u{2514}", // m lower-left corner
        "\u{253C}", // n crossing lines
        "\u{23BA}", // o horizontal line scan 1
        "\u{23BB}", // p scan 3
        "\u{2500}", // q scan 5 (horizontal line)
        "\u{23BC}", // r scan 7
        "\u{23BD}", // s scan 9
        "\u{251C}", // t left tee
        "\u{2524}", // u right tee
        "\u{2534}", // v bottom tee
        "\u{252C}", // w top tee
        "\u{2502}", // x vertical line
        "\u{2264}", // y less than or equal
        "\u{2265}", // z greater than or equal
        "\u{03C0}", // { pi
        "\u{2260}", // | not equal
        "\u{00A3}", // } sterling
        "\u{00B7}", // ~ centered dot
    ]

    /// Translates a printable ASCII character through this set.
    func translate(_ ch: Character) -> Character {
        switch self {
        case .ascii:
            return ch
        case .ukNational:
            return ch == "#" ? "\u{00A3}" : ch
        case .decSpecialGraphics:
            guard let a = ch.asciiValue, a >= 0x5F, a <= 0x7E else { return ch }
            return CharacterSet94.graphics[Int(a - 0x5F)]
        }
    }

    var isPassthrough: Bool { self == .ascii }
}
