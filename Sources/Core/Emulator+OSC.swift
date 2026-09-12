import Foundation

extension Emulator {

    func parserOSC(_ payload: [UInt8]) {
        // Split off the numeric command; everything after the first ';' is
        // the argument, which may itself contain semicolons.
        var idx = 0
        var command = 0
        var sawDigit = false
        while idx < payload.count, payload[idx] >= 0x30, payload[idx] <= 0x39 {
            command = command * 10 + Int(payload[idx] - 0x30)
            sawDigit = true
            idx += 1
            if idx > 5 { break }
        }
        guard sawDigit else { return }
        if idx < payload.count, payload[idx] == UInt8(ascii: ";") { idx += 1 }
        let argBytes = Array(payload[idx...])
        let arg = String(decoding: argBytes, as: UTF8.self)

        switch command {
        case 0:
            setTitle(arg)
        case 1:
            break                              // icon name only; nothing to show
        case 2:
            setTitle(arg)
        case 4:
            handlePaletteSet(arg)
        case 7:
            handleWorkingDirectory(arg)
        case 8:
            handleHyperlink(arg)
        case 9:
            delegate?.emulator(self, didPostNotification: "diffTerm", body: arg)
        case 10:
            handleDynamicColor(arg, slot: .foreground)
        case 11:
            handleDynamicColor(arg, slot: .background)
        case 12:
            handleDynamicColor(arg, slot: .cursor)
        case 52:
            handleClipboard(arg)
        case 104:
            handlePaletteReset(arg)
        case 110: overrideForeground = nil; delegate?.emulatorPaletteDidChange(self)
        case 111: overrideBackground = nil; delegate?.emulatorPaletteDidChange(self)
        case 112: overrideCursorColor = nil; delegate?.emulatorPaletteDidChange(self)
        case 133:
            handleShellIntegration(arg)
        case 1337:
            handleITermFile(arg)
        case 777:
            handleNotification(arg)
        default:
            break
        }
    }

    private func setTitle(_ t: String) {
        // Terminal titles are attacker-influenced text: strip controls so a
        // program cannot smuggle escape sequences into the UI chrome.
        let cleaned = String(t.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F })
        let trimmed = String(cleaned.prefix(256))
        title = trimmed
        delegate?.emulator(self, didSetTitle: trimmed)
    }

    // MARK: - OSC 8 hyperlinks

    /// `OSC 8 ; params ; URI ST`. An empty URI closes the current link.
    private func handleHyperlink(_ arg: String) {
        guard let sep = arg.firstIndex(of: ";") else {
            currentLinkID = 0
            return
        }
        let uri = String(arg[arg.index(after: sep)...])
        guard !uri.isEmpty else {
            currentLinkID = 0
            return
        }
        // Only schemes that are meaningful and safe to hand to the system.
        let lower = uri.lowercased()
        let allowed = ["http://", "https://", "file://", "mailto:", "ftp://"]
        guard allowed.contains(where: { lower.hasPrefix($0) }) else {
            currentLinkID = 0
            return
        }
        guard hyperlinks.count < 4096 else { return }
        let id = nextLinkID
        nextLinkID &+= 1
        if nextLinkID == 0 { nextLinkID = 1 }
        hyperlinks[id] = uri
        currentLinkID = id
    }

    // MARK: - OSC 7 working directory

    private func handleWorkingDirectory(_ arg: String) {
        guard let url = URL(string: arg), url.isFileURL else { return }
        delegate?.emulator(self, didSetWorkingDirectory: url.path)
    }

    // MARK: - OSC 4 / 104 palette

    private func handlePaletteSet(_ arg: String) {
        // `index;spec` pairs, possibly repeated.
        let parts = arg.components(separatedBy: ";")
        var i = 0
        while i + 1 < parts.count {
            guard let index = Int(parts[i]), index >= 0, index < 256 else { i += 2; continue }
            let spec = parts[i + 1]
            if spec == "?" {
                if let c = paletteOverrides[index] {
                    reply("\u{1B}]4;\(index);\(xtermColorString(c))\u{1B}\\")
                }
            } else if let c = parseColorSpec(spec) {
                paletteOverrides[index] = c
            }
            i += 2
        }
        delegate?.emulatorPaletteDidChange(self)
    }

    private func handlePaletteReset(_ arg: String) {
        if arg.isEmpty {
            paletteOverrides.removeAll()
        } else {
            for p in arg.components(separatedBy: ";") {
                if let i = Int(p) { paletteOverrides.removeValue(forKey: i) }
            }
        }
        delegate?.emulatorPaletteDidChange(self)
    }

    private enum DynamicColorSlot { case foreground, background, cursor }

    private func handleDynamicColor(_ arg: String, slot: DynamicColorSlot) {
        if arg == "?" {
            let current: (UInt8, UInt8, UInt8)?
            switch slot {
            case .foreground: current = overrideForeground
            case .background: current = overrideBackground
            case .cursor:     current = overrideCursorColor
            }
            if let c = current {
                let code = slot == .foreground ? 10 : (slot == .background ? 11 : 12)
                reply("\u{1B}]\(code);\(xtermColorString(c))\u{1B}\\")
            }
            return
        }
        guard let c = parseColorSpec(arg) else { return }
        switch slot {
        case .foreground: overrideForeground = c
        case .background: overrideBackground = c
        case .cursor:     overrideCursorColor = c
        }
        delegate?.emulatorPaletteDidChange(self)
    }

    private func xtermColorString(_ c: (UInt8, UInt8, UInt8)) -> String {
        String(format: "rgb:%04x/%04x/%04x",
               Int(c.0) << 8 | Int(c.0), Int(c.1) << 8 | Int(c.1), Int(c.2) << 8 | Int(c.2))
    }

    /// Accepts the X colour forms terminals actually receive: `#rgb`,
    /// `#rrggbb`, `rgb:r/g/b` with 1-4 hex digits per channel, and `rgbi:`.
    func parseColorSpec(_ spec: String) -> (UInt8, UInt8, UInt8)? {
        let s = spec.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") {
            let hex = String(s.dropFirst())
            guard hex.allSatisfy({ $0.isHexDigit }) else { return nil }
            let per = hex.count / 3
            guard per >= 1, per <= 4, hex.count % 3 == 0 else { return nil }
            var comps: [UInt8] = []
            var idx = hex.startIndex
            for _ in 0..<3 {
                let end = hex.index(idx, offsetBy: per)
                guard let v = UInt32(hex[idx..<end], radix: 16) else { return nil }
                comps.append(scaleHex(v, digits: per))
                idx = end
            }
            return (comps[0], comps[1], comps[2])
        }
        if s.lowercased().hasPrefix("rgb:") {
            let body = String(s.dropFirst(4))
            let parts = body.components(separatedBy: "/")
            guard parts.count == 3 else { return nil }
            var comps: [UInt8] = []
            for p in parts {
                guard !p.isEmpty, p.count <= 4, p.allSatisfy({ $0.isHexDigit }),
                      let v = UInt32(p, radix: 16) else { return nil }
                comps.append(scaleHex(v, digits: p.count))
            }
            return (comps[0], comps[1], comps[2])
        }
        if let named = Emulator.namedColors[s.lowercased()] { return named }
        return nil
    }

    /// Scales an n-hex-digit channel to 8 bits the way X11 does.
    private func scaleHex(_ v: UInt32, digits: Int) -> UInt8 {
        switch digits {
        case 1: return UInt8(v * 17)
        case 2: return UInt8(v & 0xFF)
        case 3: return UInt8((v >> 4) & 0xFF)
        default: return UInt8((v >> 8) & 0xFF)
        }
    }

    static let namedColors: [String: (UInt8, UInt8, UInt8)] = [
        "black": (0, 0, 0), "red": (255, 0, 0), "green": (0, 128, 0),
        "yellow": (255, 255, 0), "blue": (0, 0, 255), "magenta": (255, 0, 255),
        "cyan": (0, 255, 255), "white": (255, 255, 255), "gray": (190, 190, 190),
        "grey": (190, 190, 190), "orange": (255, 165, 0), "purple": (160, 32, 240),
    ]

    // MARK: - OSC 52 clipboard

    private func handleClipboard(_ arg: String) {
        // `Pc ; Pd` — we honour writes to the primary/clipboard selections and
        // deliberately never answer reads, so that a program (or something
        // running over ssh) cannot exfiltrate the user's clipboard.
        guard let sep = arg.firstIndex(of: ";") else { return }
        let data = String(arg[arg.index(after: sep)...])
        guard data != "?" else { return }
        guard let decoded = Data(base64Encoded: padded(data)),
              decoded.count <= 1 << 20,
              let text = String(data: decoded, encoding: .utf8) else { return }
        delegate?.emulator(self, didRequestClipboardWrite: text)
    }

    /// Restores the `=` padding some emitters leave off. `Data(base64Encoded:)`
    /// rejects an unpadded string outright, which turned a cosmetic difference
    /// between senders into a copy that silently did nothing.
    private func padded(_ s: String) -> String {
        let remainder = s.count % 4
        guard remainder != 0 else { return s }
        return s + String(repeating: "=", count: 4 - remainder)
    }

    // MARK: - OSC 133 shell integration

    /// `A` prompt start, `B` command start, `C` output start, `D[;exit]` done.
    /// FinalTerm defined these and every shell integration worth having emits
    /// them; they are the only way to know where a command's output begins
    /// without guessing from the text.
    private func handleShellIntegration(_ arg: String) {
        // A full-screen program on the alternate screen has no prompts, and
        // anything it emits would land on rows that vanish when it exits.
        guard !modes.altScreen else { return }

        var fields = arg.components(separatedBy: ";")
        guard let kind = fields.first?.first else { return }
        fields.removeFirst()

        let row = stableCursorRow
        switch kind {
        case "A":
            shellIntegration.beginPrompt(at: row)
        case "B":
            shellIntegration.beginCommand(at: row, col: buffer.cursorX)
        case "C":
            shellIntegration.beginOutput(at: row)
        case "D":
            // `D;1` and `D;aborted=1` both appear in the wild; take the first
            // field that is a plain integer and ignore the rest.
            let exit = fields.first.flatMap { Int($0) }
                ?? fields.compactMap { $0.split(separator: "=").last.flatMap { Int($0) } }.first
            shellIntegration.endCommand(at: row, exitCode: exit)
        default:
            break
        }
        shellIntegration.discard(before: oldestStableRow)
        images.discard(before: oldestStableRow)
        delegate?.emulatorShellIntegrationDidChange(self)
    }

    // MARK: - OSC 777 notifications

    private func handleNotification(_ arg: String) {
        // `notify;title;body`
        let parts = arg.components(separatedBy: ";")
        guard parts.first == "notify" else { return }
        let title = parts.count > 1 ? parts[1] : "diffTerm"
        let body = parts.count > 2 ? parts[2...].joined(separator: ";") : ""
        delegate?.emulator(self, didPostNotification: title, body: body)
    }

    // MARK: - DCS

    func parserDCSHook(private prefix: UInt8, params: ParamList, intermediates: [UInt8], final: UInt8) {
        dcsKind = .none
        guard prefix == 0 else { return }
        if final == UInt8(ascii: "q") {
            // Both of these end in `q` and are told apart by the intermediate:
            // DECRQSS is `DCS $ q`, a Sixel is `DCS Pn;Pn;Pn q` with none at
            // all. This used to claim the empty case for DECRQSS, which meant
            // DECRQSS never matched a real request and a Sixel was answered as
            // if it were one.
            if intermediates == [UInt8(ascii: "$")] {
                dcsKind = .decrqss
            } else if intermediates.isEmpty {
                dcsKind = .sixel
                // P2 = 1 asks for unset pixels to be left alone rather than
                // painted; we leave them transparent either way, which is the
                // same thing against a terminal background.
                sixelBackgroundTransparent = params.at(1) == 1
            }
            dcsBuffer.removeAll(keepingCapacity: true)
        } else if final == UInt8(ascii: "|"), prefix == UInt8(ascii: "+") {
            // XTGETTCAP — answer "unknown" for everything rather than lie.
            dcsKind = .xtgettcap
            dcsBuffer.removeAll(keepingCapacity: true)
        }
    }

    func parserDCSPut(_ byte: UInt8) {
        guard dcsKind != .none else { return }
        // A Sixel is a whole picture and needs room a status request never
        // does. Capping them the same way would truncate every Sixel worth
        // looking at, which is the mistake OSC 52 already made once.
        let ceiling = dcsKind == .sixel ? SixelDecoder.maximumPayload : 1024
        guard dcsBuffer.count < ceiling else { return }
        dcsBuffer.append(byte)
    }

    func parserDCSUnhook() {
        defer { dcsKind = .none; dcsBuffer.removeAll(keepingCapacity: true) }
        switch dcsKind {
        case .decrqss:
            answerDECRQSS(String(decoding: dcsBuffer, as: UTF8.self))
        case .xtgettcap:
            reply("\u{1B}P0+r\u{1B}\\")
        case .sixel:
            placeSixel(dcsBuffer)
        case .none:
            break
        }
    }

    private func answerDECRQSS(_ request: String) {
        switch request {
        case "m":                        // current SGR
            reply("\u{1B}P1$r\(currentSGRString())m\u{1B}\\")
        case "r":                        // scroll region
            reply("\u{1B}P1$r\(buffer.scrollTop + 1);\(buffer.scrollBottom + 1)r\u{1B}\\")
        case " q":                       // cursor style
            let base: Int
            switch modes.cursorShape {
            case .block: base = 1
            case .underline: base = 3
            case .bar: base = 5
            }
            reply("\u{1B}P1$r\(base + (modes.cursorBlink ? 0 : 1)) q\u{1B}\\")
        default:
            reply("\u{1B}P0$r\u{1B}\\")
        }
    }

    private func currentSGRString() -> String {
        var parts = ["0"]
        let f = attrs.flags
        if f.contains(.bold) { parts.append("1") }
        if f.contains(.faint) { parts.append("2") }
        if f.contains(.italic) { parts.append("3") }
        if f.contains(.underline) { parts.append("4") }
        if f.contains(.blink) { parts.append("5") }
        if f.contains(.inverse) { parts.append("7") }
        if f.contains(.invisible) { parts.append("8") }
        if f.contains(.strikethrough) { parts.append("9") }
        switch attrs.fg {
        case .default: break
        case .indexed(let i) where i < 8: parts.append("\(30 + Int(i))")
        case .indexed(let i) where i < 16: parts.append("\(90 + Int(i) - 8)")
        case .indexed(let i): parts.append("38;5;\(i)")
        case .rgb(let r, let g, let b): parts.append("38;2;\(r);\(g);\(b)")
        }
        switch attrs.bg {
        case .default: break
        case .indexed(let i) where i < 8: parts.append("\(40 + Int(i))")
        case .indexed(let i) where i < 16: parts.append("\(100 + Int(i) - 8)")
        case .indexed(let i): parts.append("48;5;\(i)")
        case .rgb(let r, let g, let b): parts.append("48;2;\(r);\(g);\(b)")
        }
        return parts.joined(separator: ";")
    }
}

enum DCSKind {
    case none, decrqss, xtgettcap, sixel
}
