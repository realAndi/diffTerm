import Foundation

enum MouseTracking: Equatable {
    case none
    case x10          // 9  — press only
    case normal       // 1000 — press/release
    case buttonEvent  // 1002 — plus drag while pressed
    case anyEvent     // 1003 — plus all motion
}

enum MouseEncoding: Equatable {
    case x10          // default, byte-clamped
    case utf8         // 1005
    case sgr          // 1006
    case urxvt        // 1015
}

enum CursorShape: Int {
    case block = 0, underline = 1, bar = 2
}

struct TerminalModes {
    var autoWrap = true
    var reverseWrapAround = false
    var originMode = false
    var applicationCursorKeys = false
    var applicationKeypad = false
    var insertMode = false
    var newlineMode = false
    var reverseVideo = false
    var cursorVisible = true
    var bracketedPaste = false
    var focusReporting = false
    var mouseTracking: MouseTracking = .none
    var mouseEncoding: MouseEncoding = .x10
    var altScreen = false
    var cursorBlink = true
    var cursorShape: CursorShape = .block
    var synchronizedUpdate = false     // DECSET 2026
    var reportColorScheme = false      // DECSET 2031: tell me when it changes
}

protocol EmulatorDelegate: AnyObject {
    /// Bytes the terminal wants to send back to the program (replies, mouse).
    func emulatorWrite(_ emulator: Emulator, data: [UInt8])
    func emulatorRing(_ emulator: Emulator)
    func emulator(_ emulator: Emulator, didSetTitle title: String)
    func emulator(_ emulator: Emulator, didSetWorkingDirectory path: String)
    func emulator(_ emulator: Emulator, didRequestClipboardWrite text: String)
    func emulator(_ emulator: Emulator, didPostNotification title: String, body: String)
    /// Fired when scrollback gained lines, so the view can hold its position.
    func emulator(_ emulator: Emulator, didScrollBy lines: Int)
    func emulatorPaletteDidChange(_ emulator: Emulator)
    /// A shell integration mark arrived: a command started, or finished.
    func emulatorShellIntegrationDidChange(_ emulator: Emulator)
}

/// An xterm-compatible terminal emulator: consumes bytes, maintains the
/// screen, and produces replies. It knows nothing about drawing or about the
/// pty — both sit behind the delegate — which keeps it straightforward to
/// reason about and to exercise in isolation.
final class Emulator: ParserDelegate {

    weak var delegate: EmulatorDelegate?

    var normal: Buffer
    var alternate: Buffer
    var buffer: Buffer      // whichever is active

    lazy var parser = Parser(delegate: self)

    var modes = TerminalModes()
    var attrs = CellAttributes.blank

    /// Colours overridden by the program via OSC 4/10/11/12. `nil` means the
    /// user's theme decides.
    var paletteOverrides: [Int: (UInt8, UInt8, UInt8)] = [:]
    var overrideForeground: (UInt8, UInt8, UInt8)?
    var overrideBackground: (UInt8, UInt8, UInt8)?
    var overrideCursorColor: (UInt8, UInt8, UInt8)?

    var title: String = ""
    var titleStack: [String] = []

    /// OSC 8 hyperlink targets, referenced by `CellAttributes.linkID`.
    var hyperlinks: [UInt32: String] = [:]
    var nextLinkID: UInt32 = 1
    var currentLinkID: UInt32 = 0

    // Charset designation: G0-G3 plus the GL/GR mappings.
    var charsets: [CharacterSet94] = [.ascii, .ascii, .ascii, .ascii]
    var gl = 0
    var gr = 2
    /// Set by SS2/SS3 — applies to exactly one character.
    var singleShift: Int?

    /// Rows touched since the last render pass, as absolute buffer indices.
    var dirtyRows = Set<Int>()
    var allDirty = true

    var scrollbackLimit: Int

    /// Pixel size of one cell, pushed down by the view so that programs
    /// querying window geometry get truthful answers.
    var cellSize = CGSize(width: 8, height: 16)

    /// Whether the active theme reads as dark, pushed down by the UI. Programs
    /// ask for it with DEC 2031 / the `?996n` query, and are told when it
    /// changes if they enabled 2031.
    var appearanceIsDark = true

    /// DEC private modes stashed by `CSI ? Pm s`.
    var savedDECModes: [Int: Bool] = [:]

    /// Command boundaries reported by the shell through OSC 133. Only the
    /// normal buffer records them: a full-screen program on the alternate
    /// screen has no prompts, and marks from before it started must survive it.
    var shellIntegration = ShellIntegration()

    /// Pictures placed in the grid, anchored to the same stable rows the marks
    /// use. Only the normal buffer has them, for the same reason.
    var images = InlineImageStore()

    /// In-flight DCS request, if any.
    var dcsKind: DCSKind = .none
    var dcsBuffer: [UInt8] = []
    /// Whether the Sixel being read asked for unset pixels to be left alone.
    var sixelBackgroundTransparent = true

    /// Set while the program has asked us to hold rendering (DECSET 2026).
    var suppressRender: Bool { modes.synchronizedUpdate }

    /// Suppresses redraw while a program brackets an update (DECSET 2026).
    var deferredRenderDepth = 0

    init(cols: Int, rows: Int, scrollbackLimit: Int = 10_000) {
        self.scrollbackLimit = scrollbackLimit
        normal = Buffer(cols: cols, rows: rows, scrollbackLimit: scrollbackLimit, allowsScrollback: true)
        alternate = Buffer(cols: cols, rows: rows, scrollbackLimit: 0, allowsScrollback: false)
        buffer = normal
    }

    var cols: Int { buffer.cols }
    var rows: Int { buffer.rows }

    // MARK: - Stable row coordinates
    //
    // Absolute row indices shift every time a line falls out of scrollback.
    // Adding the eviction count gives a number that never moves, which is what
    // a recorded command boundary needs.

    /// Where the cursor is, in coordinates that survive scrollback churn.
    var stableCursorRow: Int {
        normal.scrollbackEvicted + normal.scrollbackCount + normal.cursorY
    }

    /// The oldest row still held in scrollback, in the same coordinates.
    var oldestStableRow: Int { normal.scrollbackEvicted }

    /// Converts a stable row back to an index for `Buffer.row(at:)`.
    /// Returns nil once the row has aged out.
    func absoluteRow(for stable: Int) -> Int? {
        let index = stable - normal.scrollbackEvicted
        guard index >= 0, index < normal.totalRows else { return nil }
        return index
    }

    /// A blank cell carrying the current background — erases must paint the
    /// active background colour, not the default one (that is what makes a
    /// coloured `clear` fill the screen rather than leave stripes).
    func currentBlank() -> Cell {
        Cell(ch: " ", attrs: CellAttributes(fg: .default, bg: attrs.bg,
                                            underlineColor: .default, flags: [], linkID: 0))
    }

    // MARK: - Feeding

    func feed(_ bytes: UnsafeBufferPointer<UInt8>) {
        parser.parse(bytes)
    }

    func feed(_ bytes: [UInt8]) {
        bytes.withUnsafeBufferPointer { parser.parse($0) }
    }

    func feed(_ string: String) {
        feed(Array(string.utf8))
    }

    // MARK: - Dirty tracking

    func markDirtyRow(_ row: Int) {
        guard !allDirty else { return }
        dirtyRows.insert(buffer.scrollbackCount + row)
    }

    func markAll() {
        allDirty = true
        dirtyRows.removeAll(keepingCapacity: true)
    }

    func markRegionDirty(from: Int, to: Int) {
        guard !allDirty else { return }
        for r in from...max(from, to) { dirtyRows.insert(buffer.scrollbackCount + r) }
    }

    func clearDirty() {
        dirtyRows.removeAll(keepingCapacity: true)
        allDirty = false
    }

    var needsRender: Bool { allDirty || !dirtyRows.isEmpty }

    // MARK: - Resize

    func resize(cols: Int, rows: Int) {
        guard cols != self.cols || rows != self.rows else { return }
        normal.resize(cols: cols, rows: rows, blank: currentBlank())
        alternate.resize(cols: cols, rows: rows, blank: currentBlank())
        markAll()
    }

    func setScrollbackLimit(_ limit: Int) {
        scrollbackLimit = limit
        normal.setScrollbackLimit(limit)
    }

    func clearScrollback() {
        normal.clearScrollback()
        // The lines those marks pointed at are gone. `clearScrollback` counts
        // them as evicted, so this only has to sweep up what fell behind.
        shellIntegration.discard(before: oldestStableRow)
        images.discard(before: oldestStableRow)
        markAll()
    }

    // MARK: - Reply helper

    /// Called by the UI when the theme's light/dark polarity changes. Emits
    /// the DEC 2031 unsolicited report so a program that opted in — Claude
    /// Code sets `?2031h` at startup — can re-theme itself live, the moment
    /// diffTerm is switched between a light and a dark theme.
    func colorSchemeChanged(isDark: Bool) {
        guard appearanceIsDark != isDark else { return }
        appearanceIsDark = isDark
        guard modes.reportColorScheme else { return }
        reply("\u{1B}[?997;\(isDark ? 1 : 2)n")
    }

    func reply(_ s: String) {
        delegate?.emulatorWrite(self, data: Array(s.utf8))
    }

    func reply(_ b: [UInt8]) {
        delegate?.emulatorWrite(self, data: b)
    }

    // MARK: - ParserDelegate: printing

    func parserPrint(_ ch: Character) {
        var ch = ch
        let set: CharacterSet94
        if let ss = singleShift {
            set = charsets[ss]
            singleShift = nil
        } else {
            set = charsets[gl]
        }
        if !set.isPassthrough { ch = set.translate(ch) }

        let width = CharWidth.width(of: ch)

        // A zero-width mark belongs to the previous cell, not a new one.
        if width == 0 {
            appendCombining(ch)
            return
        }

        if buffer.wrapPending && modes.autoWrap {
            buffer.lines[buffer.cursorY].wrapped = true
            markDirtyRow(buffer.cursorY)
            lineFeed(resetColumn: true, isWrap: true)
            buffer.wrapPending = false
        }

        // A double-width glyph that will not fit is pushed to the next line
        // rather than split across the edge.
        if width == 2 && buffer.cursorX == buffer.cols - 1 {
            if modes.autoWrap {
                buffer.lines[buffer.cursorY][buffer.cursorX] = currentBlank()
                buffer.lines[buffer.cursorY].wrapped = true
                markDirtyRow(buffer.cursorY)
                lineFeed(resetColumn: true, isWrap: true)
            } else {
                return
            }
        }

        if modes.insertMode {
            insertBlanks(width, at: buffer.cursorX)
        }

        var cellAttrs = attrs
        cellAttrs.linkID = currentLinkID

        let y = buffer.cursorY
        guard y < buffer.lines.count, buffer.cursorX < buffer.cols else { return }

        buffer.lines[y][buffer.cursorX] = Cell(ch: ch, attrs: cellAttrs)
        if width == 2, buffer.cursorX + 1 < buffer.cols {
            var trailer = cellAttrs
            trailer.flags.insert(.wideTrailer)
            buffer.lines[y][buffer.cursorX + 1] = Cell(ch: " ", attrs: trailer)
        }
        markDirtyRow(y)

        let next = buffer.cursorX + width
        if next >= buffer.cols {
            buffer.cursorX = buffer.cols - 1
            buffer.wrapPending = true
        } else {
            buffer.cursorX = next
            buffer.wrapPending = false
        }
    }

    /// Attaches a combining scalar to the cell the cursor just left.
    private func appendCombining(_ ch: Character) {
        var x = buffer.cursorX
        let y = buffer.cursorY
        if !buffer.wrapPending { x -= 1 }
        while x > 0, buffer.lines[y][x].attrs.flags.contains(.wideTrailer) { x -= 1 }
        guard x >= 0, y < buffer.lines.count else { return }
        var cell = buffer.lines[y][x]
        var s = String(cell.ch)
        s.append(ch)
        if let combined = s.first, s.count == 1 {
            cell.ch = combined
            buffer.lines[y][x] = cell
            markDirtyRow(y)
        }
    }

    // MARK: - ParserDelegate: C0 controls

    func parserExecute(_ byte: UInt8) {
        switch byte {
        case 0x07:                       // BEL
            delegate?.emulatorRing(self)
        case 0x08:                       // BS
            backspace()
        case 0x09:                       // HT
            cursorForwardTab(1)
        case 0x0A, 0x0B, 0x0C:           // LF, VT, FF
            lineFeed(resetColumn: modes.newlineMode)
        case 0x0D:                       // CR
            buffer.cursorX = 0
            buffer.wrapPending = false
        case 0x0E:                       // SO — invoke G1 into GL
            gl = 1
        case 0x0F:                       // SI — invoke G0 into GL
            gl = 0
        case 0x84:                       // IND
            lineFeed(resetColumn: false)
        case 0x85:                       // NEL
            lineFeed(resetColumn: true)
        case 0x88:                       // HTS
            if buffer.cursorX < buffer.tabStops.count { buffer.tabStops[buffer.cursorX] = true }
        case 0x8D:                       // RI
            reverseIndex()
        default:
            break
        }
    }

    private func backspace() {
        if buffer.wrapPending {
            buffer.wrapPending = false
            return
        }
        if buffer.cursorX > 0 {
            buffer.cursorX -= 1
        } else if modes.reverseWrapAround, buffer.cursorY > buffer.scrollTop {
            buffer.cursorY -= 1
            buffer.cursorX = buffer.cols - 1
        }
    }

    /// One line feed on behalf of a picture being placed, so the rows it
    /// covers are real rows. Internal only because `Emulator+Image` needs it;
    /// nothing else should be feeding lines from outside the parser.
    func feedLineForImage() { lineFeed(resetColumn: true) }

    private func lineFeed(resetColumn: Bool, isWrap: Bool = false) {
        if resetColumn { buffer.cursorX = 0 }
        buffer.wrapPending = false
        if buffer.cursorY == buffer.scrollBottom {
            let before = buffer.scrollbackCount
            buffer.scrollUp(1, blank: currentBlank())
            let gained = buffer.scrollbackCount - before
            if gained > 0 { delegate?.emulator(self, didScrollBy: gained) }
            markAll()
        } else if buffer.cursorY < buffer.rows - 1 {
            buffer.cursorY += 1
        }
        if !isWrap, buffer.cursorY < buffer.lines.count {
            buffer.lines[buffer.cursorY].wrapped = false
        }
    }

    private func reverseIndex() {
        buffer.wrapPending = false
        if buffer.cursorY == buffer.scrollTop {
            buffer.scrollDown(1, blank: currentBlank())
            markAll()
        } else if buffer.cursorY > 0 {
            buffer.cursorY -= 1
        }
    }

    private func cursorForwardTab(_ n: Int) {
        var remaining = n
        var x = buffer.cursorX
        while remaining > 0 {
            x += 1
            while x < buffer.cols && !buffer.tabStops[x] { x += 1 }
            if x >= buffer.cols { x = buffer.cols - 1; break }
            remaining -= 1
        }
        buffer.cursorX = x
        buffer.wrapPending = false
    }

    private func cursorBackwardTab(_ n: Int) {
        var remaining = n
        var x = buffer.cursorX
        while remaining > 0, x > 0 {
            x -= 1
            while x > 0 && !buffer.tabStops[x] { x -= 1 }
            remaining -= 1
        }
        buffer.cursorX = max(0, x)
    }

    // MARK: - ParserDelegate: ESC

    func parserEscape(intermediates: [UInt8], final: UInt8) {
        if let first = intermediates.first {
            switch first {
            case UInt8(ascii: "("), UInt8(ascii: ")"),
                 UInt8(ascii: "*"), UInt8(ascii: "+"):
                let slot = Int(first - UInt8(ascii: "("))
                if let cs = CharacterSet94.from(final: final) { charsets[slot] = cs }
                return
            case UInt8(ascii: "#"):
                if final == UInt8(ascii: "8") { decalnFill() }
                return
            case UInt8(ascii: "%"):
                return                      // UTF-8 designation; we are always UTF-8
            case UInt8(ascii: " "):
                return                      // S7C1T / S8C1T
            default:
                return
            }
        }

        switch final {
        case UInt8(ascii: "7"): performSaveCursor()
        case UInt8(ascii: "8"): performRestoreCursor()
        case UInt8(ascii: "="): modes.applicationKeypad = true
        case UInt8(ascii: ">"): modes.applicationKeypad = false
        case UInt8(ascii: "D"): lineFeed(resetColumn: false)
        case UInt8(ascii: "E"): lineFeed(resetColumn: true)
        case UInt8(ascii: "H"):
            if buffer.cursorX < buffer.tabStops.count { buffer.tabStops[buffer.cursorX] = true }
        case UInt8(ascii: "M"): reverseIndex()
        case UInt8(ascii: "N"): singleShift = 2      // SS2
        case UInt8(ascii: "O"): singleShift = 3      // SS3
        case UInt8(ascii: "c"): hardReset()
        case UInt8(ascii: "n"): gl = 2               // LS2
        case UInt8(ascii: "o"): gl = 3               // LS3
        case UInt8(ascii: "|"): gr = 3               // LS3R
        case UInt8(ascii: "}"): gr = 2               // LS2R
        case UInt8(ascii: "~"): gr = 1               // LS1R
        case UInt8(ascii: "Z"):                      // DECID
            reply("\u{1B}[?62;1;6;22c")
        default:
            break
        }
    }

    /// DECALN — fill the screen with 'E'. Only ever used by test suites, but
    /// vttest is the cheapest way to sanity-check an emulator, so support it.
    private func decalnFill() {
        let cell = Cell(ch: "E", attrs: .blank)
        for y in 0..<buffer.rows {
            buffer.lines[y] = Line(width: buffer.cols, template: cell)
        }
        buffer.cursorX = 0; buffer.cursorY = 0
        buffer.scrollTop = 0; buffer.scrollBottom = buffer.rows - 1
        markAll()
    }

    func performSaveCursor() {
        buffer.saved = Buffer.SavedCursor(
            x: buffer.cursorX, y: buffer.cursorY, attrs: attrs,
            originMode: modes.originMode, wrapPending: buffer.wrapPending,
            charsets: charsets, gl: gl, gr: gr)
    }

    func performRestoreCursor() {
        let s = buffer.saved
        buffer.cursorX = s.x
        buffer.cursorY = s.y
        attrs = s.attrs
        modes.originMode = s.originMode
        buffer.wrapPending = s.wrapPending
        charsets = s.charsets
        gl = s.gl
        gr = s.gr
        buffer.clampCursor()
    }
}
