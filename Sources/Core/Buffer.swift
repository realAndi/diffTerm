import Foundation

/// Fixed-capacity FIFO of lines. Scrollback churns one line at a time at both
/// ends, so an array with `removeFirst` would be O(n) per scrolled line; a ring
/// keeps it O(1).
struct LineRing {
    private var storage: [Line?]
    private var head = 0            // index of oldest element
    private(set) var count = 0
    /// Lines that have aged out of the ring. Monotonic; the view uses the
    /// delta to keep a scrolled-back position anchored to the same text.
    private(set) var evictedCount = 0

    var capacity: Int { storage.count }

    init(capacity: Int) {
        storage = Array(repeating: nil, count: max(1, capacity))
    }

    subscript(i: Int) -> Line {
        get {
            precondition(i >= 0 && i < count, "scrollback index out of range")
            return storage[(head + i) % storage.count]!
        }
        set {
            precondition(i >= 0 && i < count, "scrollback index out of range")
            storage[(head + i) % storage.count] = newValue
        }
    }

    /// Appends, dropping the oldest line when full. Returns true if a line was
    /// evicted, which the view uses to keep its scroll offset anchored.
    @discardableResult
    mutating func append(_ line: Line) -> Bool {
        if storage.count == 0 { return false }
        if count < storage.count {
            storage[(head + count) % storage.count] = line
            count += 1
            return false
        }
        storage[head] = line
        head = (head + 1) % storage.count
        evictedCount += 1
        return true
    }

    mutating func removeLast() -> Line? {
        guard count > 0 else { return nil }
        count -= 1
        let idx = (head + count) % storage.count
        let l = storage[idx]
        storage[idx] = nil
        return l
    }

    mutating func removeAll() {
        // Dropped lines count as evictions. Anything holding a position in
        // history — the scroll offset, a recorded command boundary — is
        // expressed relative to this counter, so discarding lines without
        // advancing it would silently re-point those at different text.
        evictedCount += count
        storage = Array(repeating: nil, count: storage.count)
        head = 0
        count = 0
    }

    /// Replaces every line, oldest first, keeping the newest that fit. Lines
    /// that do not fit count as evicted on top of `evictedBefore`, so stable
    /// row numbers stay continuous across a reflow.
    mutating func replace(with lines: ArraySlice<Line>, evictedBefore: Int) {
        let keep = min(lines.count, storage.count)
        storage = Array(repeating: nil, count: storage.count)
        for (i, line) in lines.suffix(keep).enumerated() { storage[i] = line }
        head = 0
        count = keep
        evictedCount = evictedBefore + (lines.count - keep)
    }

    mutating func setCapacity(_ newCapacity: Int) {
        let cap = max(1, newCapacity)
        guard cap != storage.count else { return }
        // Keep the most recent lines when shrinking.
        let keep = min(count, cap)
        evictedCount += count - keep
        var kept: [Line?] = []
        kept.reserveCapacity(cap)
        for i in (count - keep)..<count { kept.append(self[i]) }
        kept.append(contentsOf: Array(repeating: nil, count: cap - keep))
        storage = kept
        head = 0
        count = keep
    }
}

/// One screen's worth of state. The emulator owns two: the normal buffer,
/// which accumulates scrollback, and the alternate buffer used by full-screen
/// programs, which deliberately does not.
final class Buffer {
    private(set) var cols: Int
    private(set) var rows: Int

    /// Visible grid, `rows` entries.
    var lines: [Line]
    var scrollback: LineRing

    var cursorX = 0
    var cursorY = 0

    /// Set once the cursor has been parked past the last column; the next
    /// printable character wraps. Deferring the wrap this way is what lets a
    /// program write exactly `cols` characters without scrolling.
    var wrapPending = false

    var scrollTop = 0
    var scrollBottom: Int

    var tabStops: [Bool]

    struct SavedCursor {
        var x = 0, y = 0
        var attrs = CellAttributes.blank
        var originMode = false
        var wrapPending = false
        var charsets: [CharacterSet94] = [.ascii, .ascii, .ascii, .ascii]
        var gl = 0, gr = 2
    }
    var saved = SavedCursor()

    let allowsScrollback: Bool

    init(cols: Int, rows: Int, scrollbackLimit: Int, allowsScrollback: Bool) {
        let width = max(1, cols)
        let height = max(1, rows)
        self.cols = width
        self.rows = height
        self.allowsScrollback = allowsScrollback
        self.scrollback = LineRing(capacity: allowsScrollback ? max(1, scrollbackLimit) : 1)
        self.lines = (0..<height).map { _ in Line(width: width) }
        self.scrollBottom = height - 1
        self.tabStops = Buffer.defaultTabStops(cols: width)
    }

    static func defaultTabStops(cols: Int) -> [Bool] {
        (0..<max(1, cols)).map { $0 % 8 == 0 && $0 != 0 }
    }

    var scrollbackCount: Int { allowsScrollback ? scrollback.count : 0 }

    /// Total lines pushed out of the far end of scrollback since launch.
    var scrollbackEvicted: Int { allowsScrollback ? scrollback.evictedCount : 0 }

    /// Total addressable rows: scrollback followed by the live grid.
    var totalRows: Int { scrollbackCount + rows }

    /// Row at absolute index, where 0 is the oldest scrollback line.
    func row(at index: Int) -> Line {
        let sb = scrollbackCount
        if index < sb { return scrollback[index] }
        let r = index - sb
        return r < lines.count ? lines[r] : Line(width: cols)
    }

    func setRow(at index: Int, _ line: Line) {
        let sb = scrollbackCount
        if index < sb { scrollback[index] = line }
        else {
            let r = index - sb
            if r < lines.count { lines[r] = line }
        }
    }

    func setScrollbackLimit(_ limit: Int) {
        guard allowsScrollback else { return }
        scrollback.setCapacity(max(1, limit))
    }

    func clearScrollback() {
        scrollback.removeAll()
    }

    // MARK: - Cursor helpers

    @inline(__always)
    func clampCursor() {
        cursorX = min(max(cursorX, 0), cols - 1)
        cursorY = min(max(cursorY, 0), rows - 1)
    }

    // MARK: - Scrolling

    /// Scrolls the region up by `n`, pushing displaced lines into scrollback
    /// when the region is the full screen (which is what makes output history
    /// accumulate only for ordinary output, not for full-screen redraws).
    func scrollUp(_ n: Int, blank: Cell) {
        let count = min(n, scrollBottom - scrollTop + 1)
        guard count > 0 else { return }
        let intoScrollback = allowsScrollback && scrollTop == 0 && scrollBottom == rows - 1
        for _ in 0..<count {
            let removed = lines.remove(at: scrollTop)
            if intoScrollback { scrollback.append(removed) }
            lines.insert(Line(width: cols, template: blank), at: scrollBottom)
        }
    }

    func scrollDown(_ n: Int, blank: Cell) {
        let count = min(n, scrollBottom - scrollTop + 1)
        guard count > 0 else { return }
        for _ in 0..<count {
            lines.remove(at: scrollBottom)
            lines.insert(Line(width: cols, template: blank), at: scrollTop)
        }
    }

    // MARK: - Resize

    /// A position in the buffer, as an absolute row and a column.
    struct Position: Hashable {
        var row: Int
        var col: Int
    }

    /// Where things ended up after a reflow. Rows are indices into the
    /// reflowed sequence of every line — scrollback then grid — counted
    /// before any of it aged out of scrollback, which is what lets stable row
    /// numbers be carried across as `evictedBefore + row`.
    struct Reflow {
        /// For each row that existed before, the row its first cell is on now.
        var rows: [Int]
        /// The positions asked to be tracked, in the order they were given.
        var positions: [Position]
    }

    /// Resizes the grid. Growing taller pulls lines back out of scrollback so
    /// that content the user could already see stays put instead of the shell
    /// prompt jumping to the top of the window.
    ///
    /// A change of width re-wraps the normal buffer (see `reflow`) and returns
    /// where rows and the `tracking` positions moved to. The alternate buffer
    /// is only padded or cut: the program drawing it repaints on SIGWINCH.
    @discardableResult
    func resize(cols newCols: Int, rows newRows: Int, blank: Cell,
                tracking positions: [Position] = []) -> Reflow? {
        let newCols = max(1, newCols), newRows = max(1, newRows)
        var reflowed: Reflow?

        if newCols != cols {
            if allowsScrollback {
                reflowed = reflow(toCols: newCols, blank: blank, tracking: positions)
            } else {
                for i in 0..<lines.count { lines[i].resize(to: newCols, template: blank) }
            }
            tabStops = Buffer.defaultTabStops(cols: newCols)
            cols = newCols
        }

        if newRows != rows {
            if newRows < rows {
                // Prefer to drop blank lines below the cursor; only then push
                // real content up into scrollback.
                var removeFromBottom = rows - newRows
                while removeFromBottom > 0, lines.count > 0,
                      lines.count - 1 > cursorY,
                      lines[lines.count - 1].trimmedLength == 0 {
                    lines.removeLast()
                    removeFromBottom -= 1
                }
                for _ in 0..<removeFromBottom {
                    let removed = lines.removeFirst()
                    if allowsScrollback { scrollback.append(removed) }
                    cursorY -= 1
                }
            } else {
                var toAdd = newRows - rows
                if allowsScrollback {
                    while toAdd > 0, scrollback.count > 0 {
                        guard let restored = scrollback.removeLast() else { break }
                        var l = restored
                        l.resize(to: newCols, template: blank)
                        lines.insert(l, at: 0)
                        cursorY += 1
                        toAdd -= 1
                    }
                }
                for _ in 0..<toAdd { lines.append(Line(width: newCols, template: blank)) }
            }
            rows = newRows
        }

        scrollTop = 0
        scrollBottom = rows - 1
        clampCursor()
        return reflowed
    }

    // MARK: - Reflow

    /// Re-wraps scrollback and grid at a new width, so rotating the phone or
    /// resizing a split rearranges text instead of cutting every line at the
    /// edge — which destroyed whatever was past it, for good.
    ///
    /// Rows that autowrap continued are joined back into one logical line and
    /// wrapped again at `newCols`. A line that already fits is kept as it is,
    /// cells and all, so the common case copies nothing. Runs at the current
    /// height; `resize` deals with a change of rows afterwards.
    private func reflow(toCols newCols: Int, blank: Cell, tracking: [Position]) -> Reflow {
        let sb = scrollback.count
        let oldTotal = sb + rows
        let cursorRow = sb + cursorY

        // Blank grid rows under the last content (and under the cursor) are
        // not text to wrap; they are rebuilt as blank rows afterwards.
        var lastContent = cursorRow
        for r in stride(from: rows - 1, to: cursorY, by: -1)
            where lines[r].trimmedLength > 0 || lines[r].wrapped {
            lastContent = sb + r
            break
        }

        // Offsets are resolved in logical-line order, so bucket what to look
        // for by row. Slot -1 is the cursor.
        var wanted: [Int: [(col: Int, slot: Int)]] = [:]
        for (slot, position) in tracking.enumerated() where position.row >= 0 && position.row < oldTotal {
            wanted[position.row, default: []].append((position.col, slot))
        }
        wanted[cursorRow, default: []].append((cursorX + (wrapPending ? 1 : 0), -1))
        // The saved cursor (DECSC, and what leaving the alternate screen puts
        // back) is a grid position too. Left alone it pointed into whatever
        // text had moved onto its old row.
        wanted[sb + min(saved.y, rows - 1), default: []].append((saved.x, -2))

        var output: [Line] = []
        output.reserveCapacity(lastContent + 1)
        var rowMap = [Int](repeating: 0, count: oldTotal)
        var resolved = tracking
        var cursor = (row: 0, col: 0, wrapPending: false)
        var savedCursor = (row: 0, col: 0)

        func place(slot: Int, row: Int, col: Int, pastEdge: Bool) {
            if slot == -1 {
                cursor = (row, pastEdge ? newCols - 1 : col, pastEdge)
            } else if slot == -2 {
                savedCursor = (row, min(col, newCols - 1))
            } else {
                resolved[slot] = Position(row: row, col: min(col, newCols - 1))
            }
        }

        var row = 0
        while row <= lastContent {
            var end = row
            while end < lastContent, self.row(at: end).wrapped { end += 1 }
            let first = self.row(at: row)

            if row == end, wanted[row] == nil, first.trimmedLength <= newCols {
                rowMap[row] = output.count
                output.append(first)
                row += 1
                continue
            }

            // Gather the logical line's cells, noting where each old row began
            // and the offsets being tracked on it.
            var cells: [Cell] = []
            var rowStarts: [Int] = []
            var targets: [(offset: Int, slot: Int)] = []
            for r in row...end {
                let line = self.row(at: r)
                rowStarts.append(cells.count)
                var take = line.count
                if r < end {
                    // A wide character that did not fit at the edge left a
                    // blank in the last column: padding, not text.
                    if take > 0, line.cells[take - 1].attrs.flags.contains(.wrapPadding) {
                        take -= 1
                    }
                } else {
                    take = line.trimmedLength
                }
                for want in wanted[r] ?? [] {
                    let offset = cells.count + want.col
                    targets.append((offset, want.slot))
                    // Keep the blanks up to the cursor: the space after a
                    // prompt is part of where the next character goes.
                    if want.slot == -1 { take = max(take, min(line.count, want.col)) }
                }
                cells.append(contentsOf: line.cells[0..<take])
            }
            if let cursorOffset = targets.first(where: { $0.slot == -1 })?.offset,
               cursorOffset > cells.count {
                cells.append(contentsOf: repeatElement(Cell.blank, count: cursorOffset - cells.count))
            }
            targets.sort { $0.offset < $1.offset }

            var current: [Cell] = []
            current.reserveCapacity(newCols)
            var nextRow = 0
            var nextTarget = 0
            var i = 0
            while i < cells.count {
                let wide = newCols >= 2 && i + 1 < cells.count
                    && cells[i + 1].attrs.flags.contains(.wideTrailer)
                let width = wide ? 2 : 1
                if current.count + width > newCols {
                    if current.count < newCols {
                        var padding = Cell.blank
                        padding.attrs.flags.insert(.wrapPadding)
                        current.append(padding)
                    }
                    var line = Line(cells: current, wrapped: true)
                    line.resize(to: newCols, template: .blank)
                    output.append(line)
                    current.removeAll(keepingCapacity: true)
                }
                while nextRow < rowStarts.count, rowStarts[nextRow] <= i {
                    rowMap[row + nextRow] = output.count
                    nextRow += 1
                }
                while nextTarget < targets.count, targets[nextTarget].offset < i + width {
                    let target = targets[nextTarget]
                    place(slot: target.slot, row: output.count,
                          col: current.count + (target.offset - i), pastEdge: false)
                    nextTarget += 1
                }
                current.append(cells[i])
                if wide { current.append(cells[i + 1]) }
                i += width
            }
            // Whatever is left sits at the end of the text: rows that held
            // nothing but trimmed blanks, and a cursor after the last character.
            while nextRow < rowStarts.count {
                rowMap[row + nextRow] = output.count
                nextRow += 1
            }
            while nextTarget < targets.count {
                let full = current.count >= newCols
                place(slot: targets[nextTarget].slot, row: output.count,
                      col: current.count, pastEdge: full)
                nextTarget += 1
            }
            var last = Line(cells: current, wrapped: false)
            last.resize(to: newCols, template: .blank)
            output.append(last)
            row = end + 1
        }

        let contentRows = output.count
        for r in (lastContent + 1)..<oldTotal {
            rowMap[r] = contentRows + (r - lastContent - 1)
        }

        // Which rows end up on screen. A cursor on the last row is following
        // output, so the grid stays pinned to the bottom of the text. Anywhere
        // else — a prompt at the top after a clear, a short session — the text
        // that was at the top of the screen stays there. Either way every line
        // after the cursor must fit below it, and the cursor stays on screen.
        let lowestTop = max(0, output.count - rows)
        let preferredTop = cursorY == rows - 1 ? lowestTop : rowMap[sb]
        let gridTop = min(max(preferredTop, lowestTop), cursor.row)
        var grid = Array(output[gridTop..<min(output.count, gridTop + rows)])
        for i in grid.indices { grid[i].resize(to: newCols, template: blank) }
        while grid.count < rows { grid.append(Line(width: newCols, template: blank)) }

        scrollback.replace(with: output[0..<gridTop], evictedBefore: scrollback.evictedCount)
        lines = grid
        cursorY = cursor.row - gridTop
        cursorX = min(cursor.col, newCols - 1)
        wrapPending = cursor.wrapPending
        saved.y = min(max(savedCursor.row - gridTop, 0), rows - 1)
        saved.x = savedCursor.col

        return Reflow(rows: rowMap, positions: resolved)
    }
}
