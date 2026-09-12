import Foundation

struct KeyModifiers: OptionSet {
    let rawValue: Int
    static let shift   = KeyModifiers(rawValue: 1 << 0)
    static let alt     = KeyModifiers(rawValue: 1 << 1)
    static let control = KeyModifiers(rawValue: 1 << 2)
    static let command = KeyModifiers(rawValue: 1 << 3)

    /// xterm's modifier parameter: 1 + a bitmask of shift/alt/ctrl/meta.
    var xtermParameter: Int {
        var m = 0
        if contains(.shift)   { m |= 1 }
        if contains(.alt)     { m |= 2 }
        if contains(.control) { m |= 4 }
        if contains(.command) { m |= 8 }
        return m + 1
    }

    var isEmpty2: Bool { xtermParameter == 1 }
}

enum SpecialKey {
    case up, down, right, left
    case home, end, pageUp, pageDown
    case insert, delete
    case backspace, enter, tab, escape
    case f(Int)
    case keypadEnter
}

/// Turns key events into the byte sequences a Unix program expects.
///
/// The rules here are xterm's, because that is what `TERM=xterm-256color`
/// promises and what every terminfo entry on the device describes.
enum KeyEncoder {

    static func bytes(for key: SpecialKey,
                      modifiers: KeyModifiers,
                      applicationCursorKeys: Bool,
                      applicationKeypad: Bool,
                      backspaceSendsDelete: Bool = true) -> [UInt8] {
        let mod = modifiers.xtermParameter

        switch key {
        case .up:    return cursorKey("A", mod: mod, app: applicationCursorKeys)
        case .down:  return cursorKey("B", mod: mod, app: applicationCursorKeys)
        case .right: return cursorKey("C", mod: mod, app: applicationCursorKeys)
        case .left:  return cursorKey("D", mod: mod, app: applicationCursorKeys)
        case .home:  return cursorKey("H", mod: mod, app: applicationCursorKeys)
        case .end:   return cursorKey("F", mod: mod, app: applicationCursorKeys)

        case .insert:   return tildeKey(2, mod: mod)
        case .delete:   return tildeKey(3, mod: mod)
        case .pageUp:   return tildeKey(5, mod: mod)
        case .pageDown: return tildeKey(6, mod: mod)

        case .backspace:
            // The tty is configured with VERASE = DEL, so backspace sends
            // 0x7F; Ctrl-Backspace conventionally sends 0x08 instead.
            var out: [UInt8] = []
            if modifiers.contains(.alt) { out.append(0x1B) }
            if modifiers.contains(.control) {
                out.append(backspaceSendsDelete ? 0x08 : 0x7F)
            } else {
                out.append(backspaceSendsDelete ? 0x7F : 0x08)
            }
            return out

        case .enter:
            var out: [UInt8] = []
            if modifiers.contains(.alt) { out.append(0x1B) }
            out.append(0x0D)
            return out

        case .keypadEnter:
            if applicationKeypad { return Array("\u{1B}OM".utf8) }
            return [0x0D]

        case .tab:
            if modifiers.contains(.shift) { return Array("\u{1B}[Z".utf8) }
            var out: [UInt8] = []
            if modifiers.contains(.alt) { out.append(0x1B) }
            out.append(0x09)
            return out

        case .escape:
            var out: [UInt8] = []
            if modifiers.contains(.alt) { out.append(0x1B) }
            out.append(0x1B)
            return out

        case .f(let n):
            return functionKey(n, mod: mod)
        }
    }

    private static func cursorKey(_ letter: Character, mod: Int, app: Bool) -> [UInt8] {
        if mod != 1 {
            // Modified cursor keys always use the CSI form, even in
            // application mode — this trips up naive implementations.
            return Array("\u{1B}[1;\(mod)\(letter)".utf8)
        }
        return Array((app ? "\u{1B}O\(letter)" : "\u{1B}[\(letter)").utf8)
    }

    private static func tildeKey(_ n: Int, mod: Int) -> [UInt8] {
        if mod != 1 { return Array("\u{1B}[\(n);\(mod)~".utf8) }
        return Array("\u{1B}[\(n)~".utf8)
    }

    private static func functionKey(_ n: Int, mod: Int) -> [UInt8] {
        switch n {
        case 1...4:
            let letter = ["P", "Q", "R", "S"][n - 1]
            if mod != 1 { return Array("\u{1B}[1;\(mod)\(letter)".utf8) }
            return Array("\u{1B}O\(letter)".utf8)
        default:
            // F5-F20 use the tilde form with a lookup table that intentionally
            // skips a few numbers, matching xterm.
            let codes: [Int: Int] = [
                5: 15, 6: 17, 7: 18, 8: 19, 9: 20, 10: 21, 11: 23, 12: 24,
                13: 25, 14: 26, 15: 28, 16: 29, 17: 31, 18: 32, 19: 33, 20: 34,
            ]
            guard let code = codes[n] else { return [] }
            return tildeKey(code, mod: mod)
        }
    }

    /// Encodes a printable character together with its modifiers.
    static func bytes(for text: String, modifiers: KeyModifiers) -> [UInt8] {
        guard !text.isEmpty else { return [] }

        if modifiers.contains(.control) {
            if let ctrl = controlByte(for: text) {
                var out: [UInt8] = []
                if modifiers.contains(.alt) { out.append(0x1B) }
                out.append(ctrl)
                return out
            }
        }

        var out: [UInt8] = []
        if modifiers.contains(.alt) { out.append(0x1B) }
        out.append(contentsOf: Array(text.utf8))
        return out
    }

    /// Ctrl-<key> for the keys that have a C0 equivalent.
    static func controlByte(for text: String) -> UInt8? {
        guard let scalar = text.unicodeScalars.first, text.unicodeScalars.count == 1 else { return nil }
        let v = scalar.value
        switch v {
        case 0x40...0x5F:                       // @ A-Z [ \ ] ^ _
            return UInt8(v - 0x40)
        case 0x61...0x7A:                       // a-z
            return UInt8(v - 0x60)
        case 0x20:                              // space -> NUL
            return 0
        case 0x3F:                              // ? -> DEL
            return 0x7F
        case 0x32:                              // 2 -> NUL
            return 0
        case 0x33...0x37:                       // 3-7 -> ESC FS GS RS US
            return UInt8(v - 0x33 + 0x1B)
        case 0x38:                              // 8 -> DEL
            return 0x7F
        case 0x2F:                              // / -> US
            return 0x1F
        default:
            return nil
        }
    }

    /// Wraps pasted text for bracketed-paste mode and strips anything that
    /// could be mistaken for a control sequence.
    static func paste(_ text: String, bracketed: Bool) -> [UInt8] {
        // A paste must never be able to inject an escape sequence, and in
        // bracketed mode it must not contain the end marker either.
        var cleaned = String()
        cleaned.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x1B, 0x9B, 0x90, 0x9D, 0x9E, 0x9F:
                continue                        // drop escape introducers
            case 0x00...0x08, 0x0B, 0x0C, 0x0E...0x1A, 0x1C...0x1F, 0x7F:
                continue                        // drop other controls
            case 0x0D:
                cleaned.unicodeScalars.append("\r")
            case 0x0A:
                // Newlines in a paste are submitted as carriage returns,
                // which is what a terminal line discipline expects.
                cleaned.unicodeScalars.append("\r")
            default:
                cleaned.unicodeScalars.append(scalar)
            }
        }
        guard bracketed else { return Array(cleaned.utf8) }
        var out = Array("\u{1B}[200~".utf8)
        out.append(contentsOf: Array(cleaned.utf8))
        out.append(contentsOf: Array("\u{1B}[201~".utf8))
        return out
    }
}
