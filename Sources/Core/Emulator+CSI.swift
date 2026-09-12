import Foundation

extension Emulator {

    func parserCSI(private prefix: UInt8, params: ParamList, intermediates: [UInt8], final: UInt8) {
        let inter = intermediates.first ?? 0

        // Sequences distinguished by an intermediate byte are handled first so
        // that e.g. `CSI SP q` (cursor style) is not mistaken for `CSI q`.
        if inter != 0 {
            handleIntermediateCSI(prefix: prefix, params: params, inter: inter, final: final)
            return
        }

        if prefix == UInt8(ascii: "?") {
            handlePrivateCSI(params: params, final: final)
            return
        }
        if prefix == UInt8(ascii: ">") || prefix == UInt8(ascii: "<") || prefix == UInt8(ascii: "=") {
            handleSecondaryCSI(prefix: prefix, params: params, final: final)
            return
        }

        switch final {
        case UInt8(ascii: "@"): insertBlanks(params.atNonZero(0), at: buffer.cursorX)
        case UInt8(ascii: "A"): moveCursor(dy: -params.atNonZero(0))
        case UInt8(ascii: "B"): moveCursor(dy:  params.atNonZero(0))
        case UInt8(ascii: "C"): moveCursor(dx:  params.atNonZero(0))
        case UInt8(ascii: "D"): moveCursor(dx: -params.atNonZero(0))
        case UInt8(ascii: "E"):
            moveCursor(dy: params.atNonZero(0)); buffer.cursorX = 0
        case UInt8(ascii: "F"):
            moveCursor(dy: -params.atNonZero(0)); buffer.cursorX = 0
        case UInt8(ascii: "G"), UInt8(ascii: "`"):
            setCursor(x: params.atNonZero(0) - 1, y: nil)
        case UInt8(ascii: "H"), UInt8(ascii: "f"):
            setCursor(x: params.atNonZero(1) - 1, y: params.atNonZero(0) - 1, respectOrigin: true)
        case UInt8(ascii: "I"): cursorTab(forward: params.atNonZero(0))
        case UInt8(ascii: "J"): eraseInDisplay(params.at(0))
        case UInt8(ascii: "K"): eraseInLine(params.at(0))
        case UInt8(ascii: "L"): insertLines(params.atNonZero(0))
        case UInt8(ascii: "M"): deleteLines(params.atNonZero(0))
        case UInt8(ascii: "P"): deleteChars(params.atNonZero(0))
        case UInt8(ascii: "S"): scrollRegionUp(params.atNonZero(0))
        case UInt8(ascii: "T"): scrollRegionDown(params.atNonZero(0))
        case UInt8(ascii: "X"): eraseChars(params.atNonZero(0))
        case UInt8(ascii: "Z"): cursorTab(backward: params.atNonZero(0))
        case UInt8(ascii: "a"): moveCursor(dx: params.atNonZero(0))
        case UInt8(ascii: "b"): repeatLastCharacter(params.atNonZero(0))
        // VT220 + colour, and 4 for Sixel. Advertising 4 is not decoration:
        // img2sixel and chafa ask before they draw, and a terminal that
        // decodes Sixel without claiming it is never sent any.
        case UInt8(ascii: "c"): reply("\u{1B}[?62;1;4;6;9;15;22c")
        case UInt8(ascii: "d"): setCursor(x: nil, y: params.atNonZero(0) - 1, respectOrigin: true)
        case UInt8(ascii: "e"): moveCursor(dy: params.atNonZero(0))
        case UInt8(ascii: "g"): clearTabStop(params.at(0))
        case UInt8(ascii: "h"): setANSIMode(params, enabled: true)
        case UInt8(ascii: "l"): setANSIMode(params, enabled: false)
        case UInt8(ascii: "m"): applySGR(params)
        case UInt8(ascii: "n"): deviceStatusReport(params.at(0))
        case UInt8(ascii: "r"): setScrollRegion(top: params.at(0), bottom: params.at(1))
        case UInt8(ascii: "s"): saveCursorPublic()
        case UInt8(ascii: "u"): restoreCursorPublic()
        case UInt8(ascii: "t"): windowOperation(params)
        default:
            break
        }
    }

    // MARK: - CSI with intermediates

    private func handleIntermediateCSI(prefix: UInt8, params: ParamList, inter: UInt8, final: UInt8) {
        switch (inter, final) {
        case (UInt8(ascii: " "), UInt8(ascii: "q")):        // DECSCUSR
            applyCursorStyle(params.at(0))
        case (UInt8(ascii: "!"), UInt8(ascii: "p")):        // DECSTR soft reset
            softReset()
        case (UInt8(ascii: "$"), UInt8(ascii: "p")):        // DECRQM
            reportMode(params.at(0), isPrivate: prefix == UInt8(ascii: "?"))
        case (UInt8(ascii: "\""), UInt8(ascii: "q")):       // DECSCA — accepted, no-op
            break
        case (UInt8(ascii: "\""), UInt8(ascii: "p")):       // DECSCL
            break
        default:
            break
        }
    }

    private func applyCursorStyle(_ value: Int) {
        // 0/1 blinking block, 2 steady block, 3 blinking underline,
        // 4 steady underline, 5 blinking bar, 6 steady bar.
        switch value {
        case 0, 1: modes.cursorShape = .block;     modes.cursorBlink = true
        case 2:    modes.cursorShape = .block;     modes.cursorBlink = false
        case 3:    modes.cursorShape = .underline; modes.cursorBlink = true
        case 4:    modes.cursorShape = .underline; modes.cursorBlink = false
        case 5:    modes.cursorShape = .bar;       modes.cursorBlink = true
        case 6:    modes.cursorShape = .bar;       modes.cursorBlink = false
        default:   break
        }
    }

    // MARK: - Secondary / tertiary device attributes

    private func handleSecondaryCSI(prefix: UInt8, params: ParamList, final: UInt8) {
        switch (prefix, final) {
        case (UInt8(ascii: ">"), UInt8(ascii: "c")):
            // Firmware version reported as 0; terminal type 41 = VT420 class.
            reply("\u{1B}[>41;1;0c")
        case (UInt8(ascii: ">"), UInt8(ascii: "q")):        // XTVERSION
            reply("\u{1B}P>|diffTerm(\(DiffTermVersion.short))\u{1B}\\")
        case (UInt8(ascii: "?"), UInt8(ascii: "u")),
             (UInt8(ascii: ">"), UInt8(ascii: "u")),
             (UInt8(ascii: "<"), UInt8(ascii: "u")),
             (UInt8(ascii: "="), UInt8(ascii: "u")):
            // Kitty keyboard protocol: report "no flags set" so that programs
            // fall back to legacy encodings instead of assuming support.
            if final == UInt8(ascii: "u"), prefix == UInt8(ascii: "?") { reply("\u{1B}[?0u") }
        default:
            break
        }
    }

    // MARK: - Cursor movement

    private func moveCursor(dx: Int = 0, dy: Int = 0) {
        buffer.wrapPending = false
        if dx != 0 {
            buffer.cursorX = min(max(buffer.cursorX + dx, 0), buffer.cols - 1)
        }
        if dy != 0 {
            // Vertical movement stops at the scroll region edges when the
            // cursor starts inside it — matching xterm, and what keeps
            // full-screen apps from walking out of their pane.
            let insideRegion = buffer.cursorY >= buffer.scrollTop && buffer.cursorY <= buffer.scrollBottom
            var y = buffer.cursorY + dy
            if insideRegion {
                y = min(max(y, buffer.scrollTop), buffer.scrollBottom)
            } else {
                y = min(max(y, 0), buffer.rows - 1)
            }
            buffer.cursorY = y
        }
    }

    private func setCursor(x: Int?, y: Int?, respectOrigin: Bool = false) {
        buffer.wrapPending = false
        if let x { buffer.cursorX = min(max(x, 0), buffer.cols - 1) }
        if let y {
            if respectOrigin && modes.originMode {
                buffer.cursorY = min(max(buffer.scrollTop + y, buffer.scrollTop), buffer.scrollBottom)
            } else {
                buffer.cursorY = min(max(y, 0), buffer.rows - 1)
            }
        }
    }

    private func cursorTab(forward n: Int) {
        var remaining = n, x = buffer.cursorX
        while remaining > 0 {
            x += 1
            while x < buffer.cols && !buffer.tabStops[x] { x += 1 }
            if x >= buffer.cols { x = buffer.cols - 1; break }
            remaining -= 1
        }
        buffer.cursorX = x
        buffer.wrapPending = false
    }

    private func cursorTab(backward n: Int) {
        var remaining = n, x = buffer.cursorX
        while remaining > 0, x > 0 {
            x -= 1
            while x > 0 && !buffer.tabStops[x] { x -= 1 }
            remaining -= 1
        }
        buffer.cursorX = max(0, x)
        buffer.wrapPending = false
    }

    private func clearTabStop(_ mode: Int) {
        switch mode {
        case 0:
            if buffer.cursorX < buffer.tabStops.count { buffer.tabStops[buffer.cursorX] = false }
        case 3:
            buffer.tabStops = Array(repeating: false, count: buffer.cols)
        default:
            break
        }
    }

    func saveCursorPublic() { performSaveCursor() }
    func restoreCursorPublic() { performRestoreCursor() }

    // MARK: - Editing

    func insertBlanks(_ n: Int, at x: Int) {
        let y = buffer.cursorY
        guard y < buffer.lines.count, x < buffer.cols else { return }
        let count = min(n, buffer.cols - x)
        guard count > 0 else { return }
        var line = buffer.lines[y]
        line.cells.removeLast(count)
        line.cells.insert(contentsOf: Array(repeating: currentBlank(), count: count), at: x)
        buffer.lines[y] = line
        markDirtyRow(y)
    }

    private func deleteChars(_ n: Int) {
        let y = buffer.cursorY, x = buffer.cursorX
        guard y < buffer.lines.count, x < buffer.cols else { return }
        let count = min(n, buffer.cols - x)
        guard count > 0 else { return }
        var line = buffer.lines[y]
        line.cells.removeSubrange(x..<(x + count))
        line.cells.append(contentsOf: Array(repeating: currentBlank(), count: count))
        buffer.lines[y] = line
        markDirtyRow(y)
    }

    private func eraseChars(_ n: Int) {
        let y = buffer.cursorY, x = buffer.cursorX
        guard y < buffer.lines.count else { return }
        let end = min(x + n, buffer.cols)
        guard x < end else { return }
        for i in x..<end { buffer.lines[y][i] = currentBlank() }
        markDirtyRow(y)
    }

    private func insertLines(_ n: Int) {
        let y = buffer.cursorY
        guard y >= buffer.scrollTop, y <= buffer.scrollBottom else { return }
        let count = min(n, buffer.scrollBottom - y + 1)
        guard count > 0 else { return }
        for _ in 0..<count {
            buffer.lines.remove(at: buffer.scrollBottom)
            buffer.lines.insert(Line(width: buffer.cols, template: currentBlank()), at: y)
        }
        buffer.cursorX = 0
        markAll()
    }

    private func deleteLines(_ n: Int) {
        let y = buffer.cursorY
        guard y >= buffer.scrollTop, y <= buffer.scrollBottom else { return }
        let count = min(n, buffer.scrollBottom - y + 1)
        guard count > 0 else { return }
        for _ in 0..<count {
            buffer.lines.remove(at: y)
            buffer.lines.insert(Line(width: buffer.cols, template: currentBlank()), at: buffer.scrollBottom)
        }
        buffer.cursorX = 0
        markAll()
    }

    private func scrollRegionUp(_ n: Int) {
        buffer.scrollUp(n, blank: currentBlank())
        markAll()
    }

    private func scrollRegionDown(_ n: Int) {
        buffer.scrollDown(n, blank: currentBlank())
        markAll()
    }

    private func repeatLastCharacter(_ n: Int) {
        // REP repeats the last printed character; the cell just behind the
        // cursor is the only place it is still recorded.
        let y = buffer.cursorY
        var x = buffer.cursorX - (buffer.wrapPending ? 0 : 1)
        guard y < buffer.lines.count, x >= 0, x < buffer.cols else { return }
        while x > 0, buffer.lines[y][x].attrs.flags.contains(.wideTrailer) { x -= 1 }
        let ch = buffer.lines[y][x].ch
        for _ in 0..<min(n, buffer.cols * buffer.rows) { parserPrint(ch) }
    }

    // MARK: - Erasing

    private func eraseInDisplay(_ mode: Int) {
        let blank = currentBlank()
        switch mode {
        case 0:
            eraseLineRange(row: buffer.cursorY, from: buffer.cursorX, to: buffer.cols)
            if buffer.cursorY + 1 < buffer.rows {
                for y in (buffer.cursorY + 1)..<buffer.rows {
                    buffer.lines[y] = Line(width: buffer.cols, template: blank)
                }
            }
        case 1:
            eraseLineRange(row: buffer.cursorY, from: 0, to: buffer.cursorX + 1)
            if buffer.cursorY > 0 {
                for y in 0..<buffer.cursorY {
                    buffer.lines[y] = Line(width: buffer.cols, template: blank)
                }
            }
        case 2:
            for y in 0..<buffer.rows {
                buffer.lines[y] = Line(width: buffer.cols, template: blank)
            }
            // The pictures drawn on those rows go with them; otherwise `clear`
            // leaves every image on screen floating over a fresh prompt.
            discardImages(visibleRowsOf: buffer)
        case 3:
            // xterm extension: also drop the scrollback. `clear` relies on it.
            // Through the emulator rather than the buffer, so the shell
            // integration marks pointing into those lines go with them.
            clearScrollback()
        default:
            return
        }
        markAll()
    }

    private func eraseInLine(_ mode: Int) {
        switch mode {
        case 0: eraseLineRange(row: buffer.cursorY, from: buffer.cursorX, to: buffer.cols)
        case 1: eraseLineRange(row: buffer.cursorY, from: 0, to: buffer.cursorX + 1)
        case 2: eraseLineRange(row: buffer.cursorY, from: 0, to: buffer.cols)
        default: return
        }
        markDirtyRow(buffer.cursorY)
    }

    private func eraseLineRange(row: Int, from: Int, to: Int) {
        guard row < buffer.lines.count else { return }
        let lo = max(0, from), hi = min(to, buffer.cols)
        guard lo < hi else { return }
        let blank = currentBlank()
        for i in lo..<hi { buffer.lines[row][i] = blank }
        if hi >= buffer.cols { buffer.lines[row].wrapped = false }
    }

    // MARK: - Scroll region

    private func setScrollRegion(top: Int, bottom: Int) {
        let t = top == 0 ? 1 : top
        let b = bottom == 0 ? buffer.rows : bottom
        guard t < b else { return }
        buffer.scrollTop = min(max(t - 1, 0), buffer.rows - 1)
        buffer.scrollBottom = min(max(b - 1, 0), buffer.rows - 1)
        // DECSTBM homes the cursor, honouring origin mode.
        buffer.cursorX = 0
        buffer.cursorY = modes.originMode ? buffer.scrollTop : 0
        buffer.wrapPending = false
    }

    // MARK: - Reports

    private func deviceStatusReport(_ code: Int) {
        switch code {
        case 5:
            reply("\u{1B}[0n")
        case 6:
            let row = modes.originMode ? buffer.cursorY - buffer.scrollTop + 1 : buffer.cursorY + 1
            reply("\u{1B}[\(row);\(buffer.cursorX + 1)R")
        default:
            break
        }
    }

    private func windowOperation(_ params: ParamList) {
        switch params.at(0) {
        case 11: reply("\u{1B}[1t")                                    // window is open
        case 13: reply("\u{1B}[3;0;0t")                                // position
        case 14: reply("\u{1B}[4;\(Int(reportedPixelHeight));\(Int(reportedPixelWidth))t")
        case 16: reply("\u{1B}[6;\(Int(reportedCellHeight));\(Int(reportedCellWidth))t")
        case 18: reply("\u{1B}[8;\(buffer.rows);\(buffer.cols)t")
        case 19: reply("\u{1B}[9;\(buffer.rows);\(buffer.cols)t")
        case 20: reply("\u{1B}]L\(title)\u{1B}\\")
        case 21: reply("\u{1B}]l\(title)\u{1B}\\")
        case 22: pushTitle()
        case 23: popTitle()
        default: break
        }
    }
}
