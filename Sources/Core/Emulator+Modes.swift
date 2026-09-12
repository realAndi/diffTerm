import Foundation

enum DiffTermVersion {
    static let short = "1.0"
    static let full  = "diffTerm 1.0"
}

extension Emulator {

    // MARK: - Reported geometry
    //
    // Programs that ask for pixel dimensions (sixel probes, image protocols,
    // some TUI layout code) get real numbers from the view; until the view has
    // measured, plausible defaults keep them from dividing by zero.

    var reportedCellWidth: CGFloat {
        get { cellSize.width } set { cellSize.width = newValue }
    }
    var reportedCellHeight: CGFloat {
        get { cellSize.height } set { cellSize.height = newValue }
    }
    var reportedPixelWidth: CGFloat { cellSize.width * CGFloat(cols) }
    var reportedPixelHeight: CGFloat { cellSize.height * CGFloat(rows) }

    // MARK: - Title stack

    func pushTitle() {
        guard titleStack.count < 16 else { return }
        titleStack.append(title)
    }

    func popTitle() {
        guard let t = titleStack.popLast() else { return }
        title = t
        delegate?.emulator(self, didSetTitle: t)
    }

    // MARK: - ANSI modes (SM / RM)

    func setANSIMode(_ params: ParamList, enabled: Bool) {
        for i in 0..<params.count {
            switch params.at(i) {
            case 4:  modes.insertMode = enabled          // IRM
            case 20: modes.newlineMode = enabled         // LNM
            default: break
            }
        }
    }

    // MARK: - DEC private modes

    func handlePrivateCSI(params: ParamList, final: UInt8) {
        switch final {
        case UInt8(ascii: "h"): setDECMode(params, enabled: true)
        case UInt8(ascii: "l"): setDECMode(params, enabled: false)
        case UInt8(ascii: "s"): saveDECModes(params)
        case UInt8(ascii: "r"): restoreDECModes(params)
        case UInt8(ascii: "J"): parserCSI(private: 0, params: params, intermediates: [], final: UInt8(ascii: "J"))
        case UInt8(ascii: "K"): parserCSI(private: 0, params: params, intermediates: [], final: UInt8(ascii: "K"))
        case UInt8(ascii: "n"): privateDeviceStatusReport(params.at(0))
        case UInt8(ascii: "c"): reply("\u{1B}[?62;1;6;9;15;22c")
        default: break
        }
    }

    private func privateDeviceStatusReport(_ code: Int) {
        switch code {
        case 6:
            let row = modes.originMode ? buffer.cursorY - buffer.scrollTop + 1 : buffer.cursorY + 1
            reply("\u{1B}[?\(row);\(buffer.cursorX + 1);1R")
        case 15: reply("\u{1B}[?13n")     // no printer
        case 25: reply("\u{1B}[?20n")     // UDKs locked
        case 26: reply("\u{1B}[?27;1;0;0n")
        case 996:
            // DEC 2031 query: report the current colour scheme. 1 dark, 2 light.
            reply("\u{1B}[?997;\(appearanceIsDark ? 1 : 2)n")
        default: break
        }
    }

    func setDECMode(_ params: ParamList, enabled: Bool) {
        for i in 0..<params.count {
            apply(decMode: params.at(i), enabled: enabled)
        }
    }

    private func apply(decMode code: Int, enabled: Bool) {
        switch code {
        case 1:    modes.applicationCursorKeys = enabled
        case 3:
            // DECCOLM: switching column count clears the screen, and most
            // programs that set it expect exactly that side effect.
            eraseWholeScreen()
            buffer.scrollTop = 0
            buffer.scrollBottom = buffer.rows - 1
            setCursorHome()
        case 5:    modes.reverseVideo = enabled; markAll()
        case 6:
            modes.originMode = enabled
            buffer.cursorX = 0
            buffer.cursorY = enabled ? buffer.scrollTop : 0
        case 7:    modes.autoWrap = enabled
        case 9:    modes.mouseTracking = enabled ? .x10 : .none
        case 12:   modes.cursorBlink = enabled
        case 25:   modes.cursorVisible = enabled
        case 45:   modes.reverseWrapAround = enabled
        case 47:   switchScreen(alternate: enabled, saveCursor: false, clearOnEnter: false)
        case 66:   modes.applicationKeypad = enabled
        case 1000: modes.mouseTracking = enabled ? .normal : .none
        case 1002: modes.mouseTracking = enabled ? .buttonEvent : .none
        case 1003: modes.mouseTracking = enabled ? .anyEvent : .none
        case 1004: modes.focusReporting = enabled
        case 1005: modes.mouseEncoding = enabled ? .utf8 : .x10
        case 1006: modes.mouseEncoding = enabled ? .sgr : .x10
        case 1015: modes.mouseEncoding = enabled ? .urxvt : .x10
        case 1047: switchScreen(alternate: enabled, saveCursor: false, clearOnEnter: true)
        case 1048:
            if enabled { performSaveCursor() } else { performRestoreCursor() }
        case 1049: switchScreen(alternate: enabled, saveCursor: true, clearOnEnter: true)
        case 2004: modes.bracketedPaste = enabled
        case 2026: modes.synchronizedUpdate = enabled
        case 2031:
            modes.reportColorScheme = enabled
            // A program that just asked to be told usually wants to know the
            // state it is starting from, but the convention is to answer only
            // the explicit ?996n query, so nothing is sent here.
        default:   break
        }
    }

    /// DECRQM — report whether a mode is set. Programs use this to detect
    /// support before committing to a protocol, so an honest answer here is
    /// what keeps them on a code path we actually implement.
    func reportMode(_ code: Int, isPrivate: Bool) {
        let state: Int
        if isPrivate {
            switch code {
            case 1:    state = modes.applicationCursorKeys ? 1 : 2
            case 5:    state = modes.reverseVideo ? 1 : 2
            case 6:    state = modes.originMode ? 1 : 2
            case 7:    state = modes.autoWrap ? 1 : 2
            case 12:   state = modes.cursorBlink ? 1 : 2
            case 25:   state = modes.cursorVisible ? 1 : 2
            case 45:   state = modes.reverseWrapAround ? 1 : 2
            case 9:    state = modes.mouseTracking == .x10 ? 1 : 2
            case 1000: state = modes.mouseTracking == .normal ? 1 : 2
            case 1002: state = modes.mouseTracking == .buttonEvent ? 1 : 2
            case 1003: state = modes.mouseTracking == .anyEvent ? 1 : 2
            case 1004: state = modes.focusReporting ? 1 : 2
            case 1006: state = modes.mouseEncoding == .sgr ? 1 : 2
            case 47, 1047, 1049: state = modes.altScreen ? 1 : 2
            case 2004: state = modes.bracketedPaste ? 1 : 2
            case 2026: state = modes.synchronizedUpdate ? 1 : 2
            case 2031: state = modes.reportColorScheme ? 1 : 2
            default:   state = 0
            }
            reply("\u{1B}[?\(code);\(state)$y")
        } else {
            switch code {
            case 4:  state = modes.insertMode ? 1 : 2
            case 20: state = modes.newlineMode ? 1 : 2
            default: state = 0
            }
            reply("\u{1B}[\(code);\(state)$y")
        }
    }

    func saveDECModes(_ params: ParamList) {
        for i in 0..<params.count {
            let code = params.at(i)
            savedDECModes[code] = isDECModeSet(code)
        }
    }

    func restoreDECModes(_ params: ParamList) {
        for i in 0..<params.count {
            let code = params.at(i)
            if let v = savedDECModes[code] { apply(decMode: code, enabled: v) }
        }
    }

    private func isDECModeSet(_ code: Int) -> Bool {
        switch code {
        case 1: return modes.applicationCursorKeys
        case 5: return modes.reverseVideo
        case 6: return modes.originMode
        case 7: return modes.autoWrap
        case 12: return modes.cursorBlink
        case 25: return modes.cursorVisible
        case 45: return modes.reverseWrapAround
        case 1000: return modes.mouseTracking == .normal
        case 1002: return modes.mouseTracking == .buttonEvent
        case 1003: return modes.mouseTracking == .anyEvent
        case 1004: return modes.focusReporting
        case 1006: return modes.mouseEncoding == .sgr
        case 47, 1047, 1049: return modes.altScreen
        case 2004: return modes.bracketedPaste
        case 2031: return modes.reportColorScheme
        default: return false
        }
    }

    // MARK: - Alternate screen

    private func switchScreen(alternate wantAlt: Bool, saveCursor: Bool, clearOnEnter: Bool) {
        guard wantAlt != modes.altScreen else { return }
        if wantAlt {
            if saveCursor { performSaveCursor() }
            // The alternate screen always starts empty; carrying pixels over
            // from the normal buffer is what produces the classic "ghost of
            // the last screen" artefact.
            let alt = self.alternate
            alt.lines = (0..<alt.rows).map { _ in Line(width: alt.cols, template: currentBlank()) }
            alt.cursorX = buffer.cursorX
            alt.cursorY = buffer.cursorY
            alt.scrollTop = 0
            alt.scrollBottom = alt.rows - 1
            alt.wrapPending = false
            buffer = alt
            modes.altScreen = true
            if clearOnEnter { buffer.cursorX = 0; buffer.cursorY = 0 }
        } else {
            buffer = normal
            modes.altScreen = false
            if saveCursor { performRestoreCursor() }
        }
        markAll()
    }

    private func eraseWholeScreen() {
        for y in 0..<buffer.rows {
            buffer.lines[y] = Line(width: buffer.cols, template: currentBlank())
        }
        markAll()
    }

    private func setCursorHome() {
        buffer.cursorX = 0
        buffer.cursorY = 0
        buffer.wrapPending = false
    }

    // MARK: - Resets

    /// DECSTR. Leaves the screen contents and scrollback alone.
    func softReset() {
        modes.insertMode = false
        modes.originMode = false
        modes.autoWrap = true
        modes.applicationCursorKeys = false
        modes.applicationKeypad = false
        modes.cursorVisible = true
        modes.reverseWrapAround = false
        attrs = .blank
        currentLinkID = 0
        charsets = [.ascii, .ascii, .ascii, .ascii]
        gl = 0; gr = 2; singleShift = nil
        buffer.scrollTop = 0
        buffer.scrollBottom = buffer.rows - 1
        buffer.saved = Buffer.SavedCursor()
        buffer.wrapPending = false
    }

    /// RIS. Everything goes back to how the terminal started.
    func hardReset() {
        if modes.altScreen { switchScreen(alternate: false, saveCursor: false, clearOnEnter: false) }
        modes = TerminalModes()
        attrs = .blank
        currentLinkID = 0
        hyperlinks.removeAll()
        nextLinkID = 1
        charsets = [.ascii, .ascii, .ascii, .ascii]
        gl = 0; gr = 2; singleShift = nil
        savedDECModes.removeAll()
        paletteOverrides.removeAll()
        overrideForeground = nil
        overrideBackground = nil
        overrideCursorColor = nil
        titleStack.removeAll()
        title = ""
        shellIntegration.removeAll()
        images.removeAll()
        normal.clearScrollback()
        for buf in [normal, alternate] {
            buf.lines = (0..<buf.rows).map { _ in Line(width: buf.cols) }
            buf.cursorX = 0; buf.cursorY = 0
            buf.scrollTop = 0; buf.scrollBottom = buf.rows - 1
            buf.tabStops = Buffer.defaultTabStops(cols: buf.cols)
            buf.saved = Buffer.SavedCursor()
            buf.wrapPending = false
        }
        buffer = normal
        parser.reset()
        delegate?.emulatorPaletteDidChange(self)
        delegate?.emulator(self, didSetTitle: "")
        markAll()
    }
}
