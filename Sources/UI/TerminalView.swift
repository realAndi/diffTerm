import UIKit
import CoreText

protocol TerminalViewDelegate: AnyObject {
    func terminalViewDidChangeGeometry(_ view: TerminalView)
}

/// Draws the terminal grid.
///
/// The view is always exactly the size of the visible viewport; scrolling is
/// expressed as `scrollOffset` and driven from outside. Backing a 10,000-line
/// scrollback with a real 170,000-point-tall layer is not viable, and tiling
/// costs more than it saves for content that redraws this often.
final class TerminalView: UIView {

    weak var emulator: Emulator?
    weak var geometryDelegate: TerminalViewDelegate?

    private(set) var terminalFont: TerminalFont
    private var glyphCache: GlyphCache
    var palette: TerminalPalette

    /// Distance in points from the top of the whole buffer (scrollback + grid)
    /// to the top of the view.
    var scrollOffset: CGFloat = 0 {
        didSet { if scrollOffset != oldValue { setNeedsDisplay() } }
    }

    var selection: TerminalSelection? {
        didSet { if selection != oldValue { setNeedsDisplay() } }
    }

    /// Cleared and set by the blink timer; combined with the emulator's own
    /// DECTCEM state to decide whether the cursor is painted.
    var cursorBlinkOn = true {
        didSet { if cursorBlinkOn != oldValue { setNeedsDisplayForCursor() } }
    }

    var isInputFocused = false {
        didSet { if isInputFocused != oldValue { setNeedsDisplay() } }
    }

    var boldIsBright = true
    var useBoldFont = true
    var preferredCursorShape: CursorShape = .block

    /// Draws the per-command chrome and reserves the gutter it lives in.
    ///
    /// The gutter is reserved whether or not the alternate screen is up: a
    /// full-screen program that gained two columns the moment it launched and
    /// lost them again on exit would be resized twice for nothing.
    var blockMode = false {
        didSet {
            guard blockMode != oldValue else { return }
            invalidateLayout()
            recomputeGeometry()
            geometryDelegate?.terminalViewDidChangeGeometry(self)
            setNeedsDisplay()
        }
    }

    /// Width reserved at the left edge for the block status rail. Zero unless
    /// blocks are on, which is what keeps every coordinate below identical to
    /// what it was before this existed.
    var gutterWidth: CGFloat { blockMode ? TerminalView.gutter : 0 }

    static let gutter: CGFloat = 13

    /// Air above each block after the first — the space between Warp-style
    /// cards. Zero unless block mode is on.
    static let blockGap: CGFloat = 8

    /// Prompt rows whose block the user has collapsed, keyed by the block's
    /// stable prompt row so the choice survives scrollback churn. Toggled from
    /// the pane; changing it rebuilds the layout.
    var collapsedBlocks: Set<Int> = [] {
        didSet {
            guard collapsedBlocks != oldValue else { return }
            invalidateLayout()
            setNeedsDisplay()
            geometryDelegate?.terminalViewDidChangeGeometry(self)
        }
    }

    private var cachedLayout: BlockLayout?
    private var cachedLayoutSignature: Int = .min

    /// The vertical layout in force: piecewise when blocks add padding or a
    /// block is collapsed, the plain `row * cellHeight` identity otherwise.
    /// Cached and rebuilt only when its inputs change.
    var layout: BlockLayout {
        let signature = layoutSignature()
        if let cachedLayout, cachedLayoutSignature == signature { return cachedLayout }
        let built = buildLayout()
        cachedLayout = built
        cachedLayoutSignature = signature
        return built
    }

    func invalidateLayout() { cachedLayoutSignature = .min }

    private func layoutSignature() -> Int {
        var hasher = Hasher()
        hasher.combine(blockMode)
        hasher.combine(Int(cellSize.height * 100))
        if let e = emulator {
            hasher.combine(e.buffer.totalRows)
            hasher.combine(e.modes.altScreen)
            hasher.combine(e.shellIntegration.blocks.count)
            hasher.combine(e.shellIntegration.last?.promptStart ?? -1)
            hasher.combine(e.shellIntegration.last?.outputEnd ?? -1)
            hasher.combine(e.stableCursorRow)
        }
        hasher.combine(collapsedBlocks)
        return hasher.finalize()
    }

    private func buildLayout() -> BlockLayout {
        let cellH = cellSize.height
        guard let e = emulator, blockMode, !e.modes.altScreen else {
            return BlockLayout(rows: emulator?.buffer.totalRows ?? visibleRows, cellHeight: cellH)
        }
        let total = e.buffer.totalRows
        let evicted = e.oldestStableRow
        let liveEnd = e.stableCursorRow
        var spans: [BlockLayout.Span] = []
        for block in e.shellIntegration.blocks {
            let stable = block.stableRows(liveEnd: liveEnd)
            let prompt = stable.lowerBound - evicted
            let end = (stable.upperBound - evicted) + 1     // inclusive → exclusive
            guard end > 0, prompt < total else { continue }
            let output = block.outputStart.map { $0 - evicted }
            spans.append(BlockLayout.Span(
                promptRow: max(0, prompt),
                outputRow: output,
                endRow: min(end, total),
                collapsed: collapsedBlocks.contains(block.promptStart)))
        }
        return BlockLayout(rows: total, cellHeight: cellH,
                           gap: TerminalView.blockGap, summaryHeight: cellH, spans: spans)
    }

    /// The suggestion drawn after the cursor, if any. Set by the controller;
    /// the view only draws it and reports where it landed so a tap can be
    /// matched against it.
    var ghostText: String = "" {
        didSet { if ghostText != oldValue { setNeedsDisplay() } }
    }

    /// One rect per character of ghost text as last drawn, in view
    /// coordinates, so a tap can be matched to the word it landed on.
    private(set) var ghostRects: [CGRect] = []

    /// Rows visible in the viewport, derived from the view's height.
    private(set) var visibleRows = 0
    private(set) var visibleCols = 0

    var cellSize: CGSize { terminalFont.cellSize }

    /// Pictures decoded for drawing, by the image store's id. Swept against
    /// the store as it draws, so an erased picture stops costing memory.
    var imageCache: [Int: CGImage] = [:]

    private var lastCursorRect: CGRect = .zero
    /// Where the cursor was when it was last invalidated. Deliberately not
    /// where it was last drawn: a repaint that never reached the screen must
    /// not count as the caret having caught up.
    private var lastCursorState = (x: -1, y: -1, scrollback: -1, visible: false)

    init(font: TerminalFont, palette: TerminalPalette) {
        self.terminalFont = font
        self.glyphCache = GlyphCache(font: font)
        self.palette = palette
        super.init(frame: .zero)
        isOpaque = true
        contentMode = .redraw
        layer.drawsAsynchronously = false
        backgroundColor = palette.defaultBackground.uiColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func update(font: TerminalFont) {
        terminalFont = font
        glyphCache = GlyphCache(font: font)
        recomputeGeometry()
        setNeedsDisplay()
    }

    func update(palette: TerminalPalette) {
        self.palette = palette
        backgroundColor = palette.defaultBackground.uiColor
        setNeedsDisplay()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        recomputeGeometry()
    }

    private func recomputeGeometry() {
        let cols = max(1, Int(floor((bounds.width - gutterWidth) / cellSize.width)))
        let rows = max(1, Int(floor(bounds.height / cellSize.height)))
        guard cols != visibleCols || rows != visibleRows else { return }
        visibleCols = cols
        visibleRows = rows
        geometryDelegate?.terminalViewDidChangeGeometry(self)
    }

    // MARK: - Coordinate conversion

    /// Total height of everything the buffer holds.
    var contentHeight: CGFloat {
        guard emulator != nil else { return bounds.height }
        return layout.totalHeight
    }

    /// Absolute row index at a point in view coordinates.
    func row(at point: CGPoint) -> Int {
        layout.row(atY: point.y + scrollOffset)
    }

    func column(at point: CGPoint) -> Int {
        Int(floor((point.x - gutterWidth) / cellSize.width))
    }

    func gridPosition(at point: CGPoint, clampToBuffer: Bool = true) -> GridPosition {
        var r = row(at: point)
        var c = column(at: point)
        if clampToBuffer, let e = emulator {
            r = min(max(r, 0), max(0, e.buffer.totalRows - 1))
            c = min(max(c, 0), e.buffer.cols)
        }
        return GridPosition(row: r, col: c)
    }

    /// Rect of a cell in view coordinates.
    func rect(row: Int, col: Int) -> CGRect {
        CGRect(x: gutterWidth + CGFloat(col) * cellSize.width,
               y: layout.y(forRow: row) - scrollOffset,
               width: cellSize.width,
               height: cellSize.height)
    }

    // MARK: - Targeted invalidation

    func setNeedsDisplay(rows: Set<Int>) {
        guard !rows.isEmpty else { return }
        let layout = self.layout
        for r in rows {
            let y = layout.y(forRow: r) - scrollOffset
            guard y + cellSize.height > 0, y < bounds.height else { continue }
            setNeedsDisplay(CGRect(x: 0, y: y, width: bounds.width, height: cellSize.height))
        }
    }

    /// Repaints the cursor when it has moved and nothing else has changed.
    ///
    /// A bare cursor move dirties no rows, because no cell's contents changed
    /// — and yet the caret is somewhere else now. Without this the caret only
    /// catches up the next time the blink toggles, which every keystroke
    /// postpones by restarting the blink: hold an arrow down and the caret
    /// sits still until you let go, then jumps.
    @discardableResult
    func invalidateCursorIfMoved() -> Bool {
        guard let e = emulator else { return false }
        let state = (e.buffer.cursorX, e.buffer.cursorY,
                     e.buffer.scrollbackCount, e.modes.cursorVisible)
        guard state != lastCursorState else { return false }
        lastCursorState = state
        setNeedsDisplayForCursor()
        return true
    }

    private func setNeedsDisplayForCursor() {
        guard let e = emulator else { return }
        let absRow = e.buffer.scrollbackCount + e.buffer.cursorY
        let r = rect(row: absRow, col: e.buffer.cursorX)
            .insetBy(dx: -cellSize.width, dy: 0)
        setNeedsDisplay(r.union(lastCursorRect))
    }

    // MARK: - Drawing

    private struct GlyphBucketKey: Hashable {
        let style: Int
        let color: Theme.RGB
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext(), let emulator else { return }

        let cellW = cellSize.width
        let cellH = cellSize.height
        let reverse = emulator.modes.reverseVideo

        // Base fill. Under reverse video the whole screen inverts, including
        // the margins that no cell covers.
        let baseBG = reverse ? palette.defaultForeground : palette.defaultBackground
        ctx.setFillColor(baseBG.cgColor)
        ctx.fill(rect)

        let gutterX = gutterWidth
        let buffer = emulator.buffer
        let totalRows = buffer.totalRows

        let layout = self.layout
        let firstRow = max(0, layout.row(atY: rect.minY + scrollOffset))
        let lastRow = min(totalRows - 1, layout.row(atY: rect.maxY + scrollOffset))
        guard firstRow <= lastRow else { return }

        // Block chrome sits under everything: a cell that paints its own
        // background must cover the wash, not be tinted by it.
        drawBlocks(ctx, emulator: emulator, rows: firstRow...lastRow, clip: rect)

        // Pictures go over the chrome and under the text. The rows they cover
        // are blank, so the text pass draws nothing over them — but selection
        // highlighting still does, which is what makes selecting across an
        // image look right.
        drawInlineImages(ctx, emulator: emulator, layout: layout,
                         rows: firstRow...lastRow, clip: rect)

        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)
        ctx.setShouldSmoothFonts(false)

        // Glyph positions are collected in a y-up space and drawn later under
        // a flipped CTM. CTFontDrawGlyphs ignores the context's text matrix
        // (unlike CTLineDraw), so flipping the CTM is the only way to get
        // both paths to agree on where a baseline is.
        let flipHeight = bounds.height

        var buckets: [GlyphBucketKey: (glyphs: [CGGlyph], positions: [CGPoint])] = [:]
        var decorations: [(rect: CGRect, color: Theme.RGB, style: DecorationStyle)] = []
        var fallbacks: [(line: CTLine, point: CGPoint)] = []

        let cursorRow = buffer.scrollbackCount + buffer.cursorY
        let cursorCol = buffer.cursorX
        let drawCursorHere = shouldDrawCursor(emulator)

        for absRow in firstRow...lastRow {
            if layout.isHidden(row: absRow) { continue }
            let line = buffer.row(at: absRow)
            let y = layout.y(forRow: absRow) - scrollOffset
            let baseline = y + terminalFont.ascent

            let width = min(line.count, buffer.cols)
            guard width > 0 else { continue }

            // --- Backgrounds, coalesced into the longest possible runs ---
            var runStart = 0
            var runColor: Theme.RGB? = nil
            var col = 0
            while col <= width {
                let color: Theme.RGB?
                if col < width {
                    let selected = selection?.contains(row: absRow, col: col) ?? false
                    let resolved = palette.resolve(line[col].attrs,
                                                   reverseVideo: reverse,
                                                   boldIsBright: boldIsBright,
                                                   selected: selected)
                    color = resolved.bg == baseBG ? nil : resolved.bg
                } else {
                    color = nil
                }
                if color != runColor {
                    if let rc = runColor, col > runStart {
                        ctx.setFillColor(rc.cgColor)
                        ctx.fill(CGRect(x: gutterX + CGFloat(runStart) * cellW, y: y,
                                        width: CGFloat(col - runStart) * cellW, height: cellH))
                    }
                    runStart = col
                    runColor = color
                }
                col += 1
            }

            // --- Glyphs ---
            for col in 0..<width {
                let cell = line[col]
                if cell.attrs.flags.contains(.wideTrailer) { continue }
                if cell.ch == " " && !cell.attrs.flags.anyUnderline
                    && !cell.attrs.flags.contains(.strikethrough)
                    && !cell.attrs.flags.contains(.overline) { continue }

                let selected = selection?.contains(row: absRow, col: col) ?? false
                var (fg, _) = palette.resolve(cell.attrs,
                                              reverseVideo: reverse,
                                              boldIsBright: boldIsBright,
                                              selected: selected)

                // Text sitting under a block cursor is drawn in the cursor's
                // contrasting colour instead of its own.
                if drawCursorHere, absRow == cursorRow, col == cursorCol,
                   effectiveCursorShape(emulator) == .block {
                    fg = palette.cursorTextColor()
                }

                let x = gutterX + CGFloat(col) * cellW

                if cell.ch != " " {
                    let style = TerminalFont.Style(flags: cell.attrs.flags, allowBold: useBoldFont)
                    switch glyphCache.entry(for: cell.ch, style: style, color: fg) {
                    case .glyph(let g):
                        let key = GlyphBucketKey(style: style.rawValue, color: fg)
                        buckets[key, default: ([], [])].glyphs.append(g)
                        buckets[key]!.positions.append(CGPoint(x: x, y: flipHeight - baseline))
                    case .line(let ctLine, let lineWidth):
                        // Centre fallback glyphs (emoji, CJK) in their cells.
                        let cellSpan = CharWidth.width(of: cell.ch) == 2 ? cellW * 2 : cellW
                        let dx = max(0, (cellSpan - lineWidth) / 2)
                        fallbacks.append((ctLine, CGPoint(x: x + dx, y: flipHeight - baseline)))
                    case .blank:
                        break
                    }
                }

                let flags = cell.attrs.flags
                if flags.anyUnderline || flags.contains(.strikethrough) || flags.contains(.overline) {
                    let span = CharWidth.width(of: cell.ch) == 2 ? cellW * 2 : cellW
                    let decoColor = cell.attrs.underlineColor == .default
                        ? fg
                        : palette.rgb(for: cell.attrs.underlineColor, fallback: fg)
                    if flags.contains(.doubleUnderline) {
                        decorations.append((CGRect(x: x, y: baseline + 2, width: span, height: terminalFont.underlineThickness), decoColor, .line))
                        decorations.append((CGRect(x: x, y: baseline + 2 + terminalFont.underlineThickness * 2.5, width: span, height: terminalFont.underlineThickness), decoColor, .line))
                    } else if flags.contains(.curlyUnderline) {
                        decorations.append((CGRect(x: x, y: baseline + 1.5, width: span, height: terminalFont.underlineThickness * 2.5), decoColor, .curly))
                    } else if flags.contains(.underline) {
                        decorations.append((CGRect(x: x, y: baseline + 2, width: span, height: terminalFont.underlineThickness), decoColor, .line))
                    }
                    if flags.contains(.strikethrough) {
                        decorations.append((CGRect(x: x, y: baseline - terminalFont.ascent * 0.32, width: span, height: terminalFont.underlineThickness), decoColor, .line))
                    }
                    if flags.contains(.overline) {
                        decorations.append((CGRect(x: x, y: y, width: span, height: terminalFont.underlineThickness), decoColor, .line))
                    }
                }
            }
        }

        // --- Cursor block goes under the glyphs so the character shows on top
        if drawCursorHere {
            drawCursor(ctx, emulator: emulator, row: cursorRow, col: cursorCol)
        }

        // --- Batched glyph draws: one call per (face, colour) pair ---
        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.translateBy(x: 0, y: flipHeight)
        ctx.scaleBy(x: 1, y: -1)

        for (key, batch) in buckets {
            guard !batch.glyphs.isEmpty else { continue }
            ctx.setFillColor(key.color.cgColor)
            let face = terminalFont.fonts[key.style]
            CTFontDrawGlyphs(face, batch.glyphs, batch.positions, batch.glyphs.count, ctx)
        }

        for (line, point) in fallbacks {
            ctx.textPosition = point
            CTLineDraw(line, ctx)
        }

        drawGhostText(ctx, emulator: emulator, flipHeight: flipHeight, gutterX: gutterX)

        ctx.restoreGState()

        for deco in decorations {
            ctx.setFillColor(deco.color.cgColor)
            switch deco.style {
            case .line:
                ctx.fill(deco.rect)
            case .curly:
                drawCurly(ctx, in: deco.rect, color: deco.color)
            }
        }
    }

    // MARK: - Ghost text

    /// Draws the suggestion after the cursor, in the theme's own dimmed
    /// foreground.
    ///
    /// Called from inside the flipped CTM the glyph batches use, so positions
    /// are in that space; the rects recorded for hit testing are converted
    /// back, because a tap arrives in ordinary view coordinates.
    ///
    /// The text is an overlay and never enters the buffer. Nothing here can
    /// change what the terminal believes is on screen, which is what makes it
    /// safe to draw over a live grid.
    private func drawGhostText(_ ctx: CGContext, emulator: Emulator,
                               flipHeight: CGFloat, gutterX: CGFloat) {
        ghostRects = []
        guard !ghostText.isEmpty, !emulator.modes.altScreen else { return }

        let buffer = emulator.buffer
        let cellW = cellSize.width
        let cellH = cellSize.height
        var row = buffer.scrollbackCount + buffer.cursorY
        var col = buffer.cursorX

        // Only ever at the end of the line. The engine holds a suggestion
        // through redraws and cursor movement so it does not flicker; this
        // is the other half of that bargain — nothing is drawn mid-line.
        guard row < buffer.totalRows else { return }
        let cursorLine = buffer.row(at: row)
        guard col >= cursorLine.trimmedLength else { return }

        let color = palette.secondaryForeground()
        let face = terminalFont.fonts[TerminalFont.Style.regular.rawValue]

        // The first character sits under the cursor. A block cursor would
        // hide it, so that one is drawn in the cursor's contrasting colour —
        // the same treatment real text under the cursor gets.
        let underBlockCursor = shouldDrawCursor(emulator)
            && effectiveCursorShape(emulator) == .block && isInputFocused

        var glyphs: [CGGlyph] = []
        var positions: [CGPoint] = []
        var firstGlyph: (glyph: CGGlyph, position: CGPoint)?

        let layout = self.layout
        for (index, character) in ghostText.enumerated() {
            if col >= buffer.cols {
                col = 0
                row += 1
            }
            let y = layout.y(forRow: row) - scrollOffset
            if y >= bounds.height { break }
            let x = gutterX + CGFloat(col) * cellW
            ghostRects.append(CGRect(x: x, y: y, width: cellW, height: cellH))

            let baseline = y + terminalFont.ascent
            if y + cellH > 0, character != " " {
                var unichars = Array(String(character).utf16)
                var glyph = CGGlyph(0)
                if CTFontGetGlyphsForCharacters(face, &unichars, &glyph, 1), glyph != 0 {
                    let position = CGPoint(x: x, y: flipHeight - baseline)
                    if index == 0 && underBlockCursor {
                        firstGlyph = (glyph, position)
                    } else {
                        glyphs.append(glyph)
                        positions.append(position)
                    }
                }
            }
            col += 1
        }

        if !glyphs.isEmpty {
            ctx.setFillColor(color.cgColor)
            CTFontDrawGlyphs(face, glyphs, positions, glyphs.count, ctx)
        }
        if let first = firstGlyph {
            var glyph = first.glyph
            var position = first.position
            ctx.setFillColor(palette.cursorTextColor().cgColor)
            CTFontDrawGlyphs(face, &glyph, &position, 1, ctx)
        }
    }

    private enum DecorationStyle { case line, curly }

    private func drawCurly(_ ctx: CGContext, in rect: CGRect, color: Theme.RGB) {
        ctx.saveGState()
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(terminalFont.underlineThickness)
        ctx.setLineCap(.round)
        let midY = rect.midY
        let amplitude = rect.height / 2
        let period = max(4, rect.width / 2)
        ctx.beginPath()
        ctx.move(to: CGPoint(x: rect.minX, y: midY))
        var x = rect.minX
        var up = true
        while x < rect.maxX {
            let nextX = min(x + period / 2, rect.maxX)
            ctx.addQuadCurve(to: CGPoint(x: nextX, y: midY),
                             control: CGPoint(x: (x + nextX) / 2, y: midY + (up ? -amplitude : amplitude)))
            up.toggle()
            x = nextX
        }
        ctx.strokePath()
        ctx.restoreGState()
    }

    // MARK: - Cursor

    private func effectiveCursorShape(_ emulator: Emulator) -> CursorShape {
        // A program that explicitly sets a cursor style wins over the user's
        // preference — vim's insert-mode bar is meant to be visible.
        emulator.modes.cursorShape
    }

    private func shouldDrawCursor(_ emulator: Emulator) -> Bool {
        guard emulator.modes.cursorVisible else { return false }
        // Scrolled back into history, the cursor is not where the user is
        // looking; keep drawing it, but hollow (handled in drawCursor).
        if !isInputFocused { return true }
        if emulator.modes.cursorBlink && !cursorBlinkOn { return false }
        return true
    }

    private func drawCursor(_ ctx: CGContext, emulator: Emulator, row: Int, col: Int) {
        var r = rect(row: row, col: col)
        guard r.maxY > 0, r.minY < bounds.height else { return }

        let line = emulator.buffer.row(at: row)
        if col < line.count, CharWidth.width(of: line[col].ch) == 2 {
            r.size.width *= 2
        }
        lastCursorRect = r.insetBy(dx: -1, dy: -1)

        let color = palette.cursorColor
        ctx.setFillColor(color.cgColor)

        guard isInputFocused else {
            // Unfocused cursors are outlines in every terminal worth using.
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(1)
            ctx.stroke(r.insetBy(dx: 0.5, dy: 0.5))
            return
        }

        switch effectiveCursorShape(emulator) {
        case .block:
            ctx.fill(r)
        case .underline:
            ctx.fill(CGRect(x: r.minX, y: r.maxY - max(2, r.height * 0.12),
                            width: r.width, height: max(2, r.height * 0.12)))
        case .bar:
            ctx.fill(CGRect(x: r.minX, y: r.minY, width: max(2, r.width * 0.15), height: r.height))
        }
    }

    // MARK: - Text extraction

    /// Plain text for a selection, joining rows that the terminal wrapped
    /// rather than inserting a line break the user never typed.
    func text(for selection: TerminalSelection) -> String {
        guard let emulator else { return "" }
        let buffer = emulator.buffer
        var out = String()
        let s = selection.start, e = selection.end
        guard s.row <= e.row else { return "" }

        for row in s.row...min(e.row, buffer.totalRows - 1) {
            guard row >= 0 else { continue }
            let line = buffer.row(at: row)
            guard let range = selection.range(forRow: row, width: line.count) else { continue }

            var slice = line.text(from: range.lowerBound, to: range.upperBound)
            if range.upperBound >= line.trimmedLength {
                // Trailing blanks in a terminal row are padding, not content.
                while slice.hasSuffix(" ") { slice.removeLast() }
            }
            out += slice

            if row < e.row {
                // A wrapped line continues; a hard line break does not.
                if !line.wrapped || selection.isBlock { out += "\n" }
            }
        }
        return out
    }

    /// Whole-buffer text, used by "Copy All" and by search.
    func allText() -> String {
        guard let emulator else { return "" }
        let buffer = emulator.buffer
        guard buffer.totalRows > 0 else { return "" }
        var out = String()
        for row in 0..<buffer.totalRows {
            let line = buffer.row(at: row)
            var slice = line.text(to: line.trimmedLength)
            while slice.hasSuffix(" ") { slice.removeLast() }
            out += slice
            if !line.wrapped { out += "\n" }
        }
        return out
    }

    /// The word around a position, for double-tap selection.
    func wordRange(at position: GridPosition) -> TerminalSelection? {
        guard let emulator else { return nil }
        let buffer = emulator.buffer
        guard position.row >= 0, position.row < buffer.totalRows else { return nil }
        let line = buffer.row(at: position.row)
        guard position.col >= 0, position.col < line.count else { return nil }

        // Path-ish characters count as word constituents; selecting half a
        // file path is never what someone wants in a terminal.
        func isWord(_ ch: Character) -> Bool {
            ch.isLetter || ch.isNumber || "_-./~:@+=%#".contains(ch)
        }

        guard isWord(line[position.col].ch) else { return nil }
        var lo = position.col, hi = position.col
        while lo > 0, isWord(line[lo - 1].ch) { lo -= 1 }
        while hi + 1 < line.count, isWord(line[hi + 1].ch) { hi += 1 }
        return TerminalSelection(anchor: GridPosition(row: position.row, col: lo),
                                 head: GridPosition(row: position.row, col: hi + 1))
    }

    /// The OSC 8 hyperlink or bare URL under a position, if any.
    func link(at position: GridPosition) -> String? {
        guard let emulator else { return nil }
        let buffer = emulator.buffer
        guard position.row >= 0, position.row < buffer.totalRows else { return nil }
        let line = buffer.row(at: position.row)
        guard position.col >= 0, position.col < line.count else { return nil }

        let linkID = line[position.col].attrs.linkID
        if linkID != 0, let uri = emulator.hyperlinks[linkID] { return uri }

        guard Preferences.shared.detectLinks else { return nil }

        // Fall back to scanning the row's text; wrapped continuation rows are
        // joined so a URL split across the edge is still found.
        var text = line.text(to: line.trimmedLength)
        var columnOffset = position.col
        var startRow = position.row
        while startRow > 0, buffer.row(at: startRow - 1).wrapped {
            startRow -= 1
            let prev = buffer.row(at: startRow)
            let prefix = prev.text(to: prev.count)
            columnOffset += prefix.count
            text = prefix + text
        }
        var endRow = position.row
        while endRow + 1 < buffer.totalRows, buffer.row(at: endRow).wrapped {
            endRow += 1
            let next = buffer.row(at: endRow)
            text += next.text(to: next.trimmedLength)
        }

        return TerminalView.detector?.firstURL(in: text, containing: columnOffset)
    }

    private static let detector: URLDetector? = URLDetector()
}

/// Finds bare URLs in a line of terminal text.
final class URLDetector {
    private let detector: NSDataDetector?

    init?() {
        detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        if detector == nil { return nil }
    }

    func firstURL(in text: String, containing characterIndex: Int) -> String? {
        guard let detector, !text.isEmpty else { return nil }
        let ns = text as NSString
        let matches = detector.matches(in: text, range: NSRange(location: 0, length: ns.length))
        for match in matches {
            guard let url = match.url else { continue }
            if NSLocationInRange(characterIndex, match.range) {
                // Only hand the system schemes it makes sense to open.
                let scheme = url.scheme?.lowercased() ?? ""
                guard ["http", "https", "mailto", "ftp"].contains(scheme) else { return nil }
                return url.absoluteString
            }
        }
        return nil
    }
}
