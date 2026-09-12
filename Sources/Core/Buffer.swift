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

    /// Resizes the grid. Growing taller pulls lines back out of scrollback so
    /// that content the user could already see stays put instead of the shell
    /// prompt jumping to the top of the window.
    func resize(cols newCols: Int, rows newRows: Int, blank: Cell) {
        let newCols = max(1, newCols), newRows = max(1, newRows)

        if newCols != cols {
            for i in 0..<lines.count { lines[i].resize(to: newCols, template: blank) }
            // Scrollback is deliberately left at its natural width. Shrinking
            // a line drops the cells past the new width, and scrollback is
            // history — resizing it to a narrower grid destroyed it for good,
            // which (compounded by save/restore re-truncating each launch) is
            // what decayed restored prompts to single letters. The renderer
            // clips each line to `cols` when drawing and selection uses the
            // line's own length, so a scrollback line wider or narrower than
            // the grid is already handled; and a line pulled back onto the
            // grid when rows grow is resized to `cols` there, at that point.
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
    }
}
