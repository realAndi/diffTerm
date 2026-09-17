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
    /// The row `markDirtyRow` inserted last, so a run of prints on one row
    /// costs one set insertion rather than one per character.
    private var lastDirtyRow = -1

    var scrollbackLimit: Int

    /// The cursor shape the user picked. A program that sets its own shape
    /// wins until it asks for the default back (`CSI 0 q`) or the terminal is
    /// reset — both of which mean this shape, not a hard-coded block.
    var defaultCursorShape: CursorShape = .block {
        didSet { if !cursorShapeSetByProgram { modes.cursorShape = defaultCursorShape } }
    }
    /// Whether the shape in `modes` came from DECSCUSR rather than the user.
    var cursorShapeSetByProgram = false

    /// Bumped by every reflow, with the stable-row mapping it used, so state
    /// kept outside the emulator in stable rows (a collapsed block) can move
    /// along with the text: compare the generation, then map through it.
    private(set) var reflowGeneration = 0
    private(set) var lastReflowMap: ((Int) -> Int)?

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
        let absolute = buffer.scrollbackCount + row
        // Printing marks the same row once per character; hashing into the
        // set every time is wasted work after the first.
        guard absolute != lastDirtyRow else { return }
        lastDirtyRow = absolute
        dirtyRows.insert(absolute)
    }

    func markAll() {
        allDirty = true
        lastDirtyRow = -1
        dirtyRows.removeAll(keepingCapacity: true)
    }

    func markRegionDirty(from: Int, to: Int) {
        guard !allDirty else { return }
        for r in from...max(from, to) { dirtyRows.insert(buffer.scrollbackCount + r) }
    }

    func clearDirty() {
        dirtyRows.removeAll(keepingCapacity: true)
        lastDirtyRow = -1
        allDirty = false
    }

    var needsRender: Bool { allDirty || !dirtyRows.isEmpty }

    // MARK: - Resize

    func resize(cols: Int, rows: Int) {
        guard cols != self.cols || rows != self.rows else { return }

        // A new width re-wraps the normal buffer, which moves text to other
        // rows. The command marks and pictures anchored to that text have to
        // move with it, and a command's start moves column as well as row.
        let evictedBefore = normal.scrollbackEvicted
        let starts = shellIntegration.blocks.compactMap { block -> Buffer.Position? in
            guard let start = block.commandStart else { return nil }
            return Buffer.Position(row: start.row - evictedBefore, col: start.col)
        }
        if let reflow = normal.resize(cols: cols, rows: rows, blank: currentBlank(), tracking: starts) {
            let moved = reflow.rows
            func stable(_ row: Int) -> Int {
                let old = row - evictedBefore
                guard old >= 0, !moved.isEmpty else { return row }
                // A mark can sit one past the last row: D is recorded where
                // the next prompt will go.
                guard old < moved.count else { return evictedBefore + moved[moved.count - 1] + (old - moved.count + 1) }
                return evictedBefore + moved[old]
            }
            var startsMoved: [Buffer.Position: Buffer.Position] = [:]
            for (before, after) in zip(starts, reflow.positions) { startsMoved[before] = after }
            shellIntegration.remap(row: stable) { row, col in
                guard let after = startsMoved[Buffer.Position(row: row - evictedBefore, col: col)] else {
                    return (stable(row), col)
                }
                return (evictedBefore + after.row, after.col)
            }
            images.remap(row: stable)
            reflowGeneration += 1
            lastReflowMap = stable
            shellIntegration.discard(before: oldestStableRow)
            images.discard(before: oldestStableRow)
        }
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

    func parserPrintASCII(_ byte: UInt8) {
        let set = activeCharsetForNextCharacter()
        let ch = Emulator.asciiCharacters[Int(byte & 0x7F)]
        if set.isPassthrough {
            place(ch, width: 1)
        } else {
            let translated = set.translate(ch)
            place(translated, width: CharWidth.width(of: translated))
        }
    }

    func parserPrintASCIIRun(_ run: UnsafeBufferPointer<UInt8>) {
        // Charset translation, a single shift and insert mode each change
        // what a character does; those take the per-character path.
        guard singleShift == nil, charsets[gl].isPassthrough, !modes.insertMode else {
            for byte in run { parserPrintASCII(byte) }
            return
        }
        var cellAttrs = attrs
        cellAttrs.linkID = currentLinkID
        var i = 0
        while i < run.count {
            let x = buffer.cursorX, y = buffer.cursorY
            // The last column is where autowrap is decided. A pending wrap,
            // or a cursor already there, goes through `place` so that logic
            // lives in one place; everything short of it is filled directly.
            let room = buffer.cols - 1 - x
            guard !buffer.wrapPending, room > 0, y < buffer.lines.count else {
                parserPrintASCII(run[i])
                i += 1
                continue
            }
            let n = min(room, run.count - i)
            buffer.lines[y].cells.withUnsafeMutableBufferPointer { cells in
                for k in 0..<n {
                    cells[x + k] = Cell(ch: Emulator.asciiCharacters[Int(run[i + k] & 0x7F)],
                                        attrs: cellAttrs)
                }
            }
            buffer.cursorX = x + n
            markDirtyRow(y)
            i += n
        }
    }

    /// Building a `Character` from a byte goes through String's UTF-8
    /// validation every time; the 128 possible results are made once.
    private static let asciiCharacters: [Character] =
        (0..<128).map { Character(Unicode.Scalar(UInt8($0))) }

    func parserPrint(_ ch: Character) {
        let set = activeCharsetForNextCharacter()
        let ch = set.isPassthrough ? ch : set.translate(ch)
        place(ch, width: CharWidth.width(of: ch))
    }

    func parserPrintScalar(_ scalar: Unicode.Scalar, width: Int) {
        // The 94-character sets only translate ASCII, so there is nothing to
        // look up, but a single shift is still used up by this character.
        singleShift = nil
        place(Character(scalar), width: width)
    }

    func parserPrintTextRun(_ run: UnsafeBufferPointer<UInt8>) {
        // The same conditions as the ASCII run: anything that changes what a
        // character does takes the per-character path.
        guard singleShift == nil, charsets[gl].isPassthrough, !modes.insertMode else {
            var i = 0
            while i < run.count { i += printCharacter(in: run, at: i) }
            return
        }
        var cellAttrs = attrs
        cellAttrs.linkID = currentLinkID
        var trailerAttrs = cellAttrs
        trailerAttrs.flags.insert(.wideTrailer)
        var i = 0
        while i < run.count {
            let x = buffer.cursorX, y = buffer.cursorY, cols = buffer.cols
            // Characters that end short of the last column are filled
            // directly; the one that would reach it, or any character while
            // a wrap is pending, goes through `place`, as in the ASCII run.
            if !buffer.wrapPending, y < buffer.lines.count {
                var next = x
                buffer.lines[y].cells.withUnsafeMutableBufferPointer { cells in
                    while i < run.count {
                        let byte = run[i]
                        if byte < 0x80 {
                            guard next + 1 < cols else { break }
                            cells[next] = Cell(ch: Emulator.asciiCharacters[Int(byte)], attrs: cellAttrs)
                            next += 1
                            i += 1
                        } else {
                            let (value, length) = Parser.decodeUTF8Sequence(run, at: i)
                            let width = CharWidth.standaloneWidth(value)
                            guard next + width < cols else { break }
                            cells[next] = Cell(ch: Character(Unicode.Scalar(value).unsafelyUnwrapped),
                                               attrs: cellAttrs)
                            if width == 2 { cells[next + 1] = Cell(ch: " ", attrs: trailerAttrs) }
                            next += width
                            i += length
                        }
                    }
                }
                if next != x {
                    buffer.cursorX = next
                    markDirtyRow(y)
                }
            }
            if i < run.count { i += printCharacter(in: run, at: i) }
        }
    }

    /// Prints the character of a text run that starts at `i` through the
    /// per-character path, and returns how many bytes it took.
    private func printCharacter(in run: UnsafeBufferPointer<UInt8>, at i: Int) -> Int {
        let byte = run[i]
        if byte < 0x80 {
            parserPrintASCII(byte)
            return 1
        }
        let (value, length) = Parser.decodeUTF8Sequence(run, at: i)
        parserPrintScalar(Unicode.Scalar(value).unsafelyUnwrapped, width: CharWidth.standaloneWidth(value))
        return length
    }

    /// GL's charset, unless SS2/SS3 picked one for exactly this character.
    @inline(__always)
    private func activeCharsetForNextCharacter() -> CharacterSet94 {
        if let ss = singleShift {
            singleShift = nil
            return charsets[ss]
        }
        return charsets[gl]
    }

    /// The common case of `place`: a character that ends short of the last
    /// column, with no wrap pending and insert mode off, needs none of its
    /// edge handling. Reading each property once and writing the cells
    /// through one buffer access, as the ASCII run does, saves most of the
    /// exclusivity and uniqueness checks the full path pays for. Returns
    /// false, having changed nothing, when the character needs all of it.
    @inline(__always)
    private func placeShortOfMargin(_ ch: Character, width: Int) -> Bool {
        let x = buffer.cursorX, y = buffer.cursorY
        guard width > 0, x + width < buffer.cols, !buffer.wrapPending, !modes.insertMode,
              y < buffer.lines.count else { return false }
        var cellAttrs = attrs
        cellAttrs.linkID = currentLinkID
        buffer.lines[y].cells.withUnsafeMutableBufferPointer { cells in
            cells[x] = Cell(ch: ch, attrs: cellAttrs)
            if width == 2 {
                var trailer = cellAttrs
                trailer.flags.insert(.wideTrailer)
                cells[x + 1] = Cell(ch: " ", attrs: trailer)
            }
        }
        buffer.cursorX = x + width
        markDirtyRow(y)
        return true
    }

    private func place(_ ch: Character, width: Int) {
        if placeShortOfMargin(ch, width: width) { return }

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
                var padding = currentBlank()
                padding.attrs.flags.insert(.wrapPadding)
                buffer.lines[buffer.cursorY][buffer.cursorX] = padding
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
            buffer.scrollUp(1, blank: currentBlank())
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
