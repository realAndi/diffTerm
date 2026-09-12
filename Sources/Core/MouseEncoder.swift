import Foundation

/// Encodes pointer events for programs that have asked to receive them
/// (`DECSET 1000` and friends). Touch is mapped onto a single left button,
/// which is what tmux, vim and less actually use.
enum MouseEncoder {

    enum Button: Int {
        case left = 0
        case middle = 1
        case right = 2
        case release = 3
        case scrollUp = 64
        case scrollDown = 65
    }

    enum Kind {
        case press
        case release
        case drag
        case scroll
    }

    static func bytes(button: Button,
                      kind: Kind,
                      col: Int,
                      row: Int,
                      modifiers: KeyModifiers,
                      encoding: MouseEncoding) -> [UInt8] {
        // Coordinates are 1-based.
        let c = max(1, col + 1)
        let r = max(1, row + 1)

        var code = button.rawValue
        if kind == .drag { code += 32 }
        if modifiers.contains(.shift)   { code += 4 }
        if modifiers.contains(.alt)     { code += 8 }
        if modifiers.contains(.control) { code += 16 }

        switch encoding {
        case .sgr:
            let final = (kind == .release) ? "m" : "M"
            return Array("\u{1B}[<\(code);\(c);\(r)\(final)".utf8)

        case .urxvt:
            let released = (kind == .release) ? Button.release.rawValue : code
            return Array("\u{1B}[\(released + 32);\(c);\(r)M".utf8)

        case .utf8:
            var out = Array("\u{1B}[M".utf8)
            let value = (kind == .release ? Button.release.rawValue : code) + 32
            out.append(contentsOf: Array(String(UnicodeScalar(UInt32(value)) ?? " ").utf8))
            out.append(contentsOf: Array(String(UnicodeScalar(UInt32(c + 32)) ?? " ").utf8))
            out.append(contentsOf: Array(String(UnicodeScalar(UInt32(r + 32)) ?? " ").utf8))
            return out

        case .x10:
            // The original encoding packs coordinates into single bytes, so
            // anything past column 223 simply cannot be represented.
            guard c <= 223, r <= 223 else { return [] }
            let value = (kind == .release ? Button.release.rawValue : code) + 32
            return [0x1B, UInt8(ascii: "["), UInt8(ascii: "M"),
                    UInt8(value & 0xFF), UInt8(c + 32), UInt8(r + 32)]
        }
    }

    /// Whether a given tracking mode wants to hear about this kind of event.
    static func shouldReport(kind: Kind, tracking: MouseTracking) -> Bool {
        switch tracking {
        case .none:        return false
        case .x10:         return kind == .press
        case .normal:      return kind == .press || kind == .release || kind == .scroll
        case .buttonEvent: return true
        case .anyEvent:    return true
        }
    }
}
