import Foundation

/// A position in the terminal's absolute coordinate space, where row 0 is the
/// oldest line still in scrollback.
struct GridPosition: Comparable, Hashable {
    var row: Int
    var col: Int

    static func < (a: GridPosition, b: GridPosition) -> Bool {
        a.row != b.row ? a.row < b.row : a.col < b.col
    }
}

/// A text selection. `end` is exclusive on its row, matching how a caret sits
/// between characters.
struct TerminalSelection: Equatable {
    var anchor: GridPosition
    var head: GridPosition
    /// Rectangular (column-locked) selection, for grabbing a column of output.
    var isBlock: Bool = false

    var start: GridPosition { min(anchor, head) }
    var end: GridPosition { max(anchor, head) }

    var isEmpty: Bool { anchor == head }

    func contains(row: Int, col: Int) -> Bool {
        let s = start, e = end
        if isBlock {
            guard row >= s.row, row <= e.row else { return false }
            let lo = min(s.col, e.col), hi = max(s.col, e.col)
            return col >= lo && col < hi
        }
        if row < s.row || row > e.row { return false }
        if row == s.row && row == e.row { return col >= s.col && col < e.col }
        if row == s.row { return col >= s.col }
        if row == e.row { return col < e.col }
        return true
    }

    /// Column range to copy from `row`, or nil if the row is outside.
    func range(forRow row: Int, width: Int) -> Range<Int>? {
        let s = start, e = end
        guard row >= s.row, row <= e.row else { return nil }
        if isBlock {
            let lo = min(s.col, e.col), hi = max(s.col, e.col)
            guard lo < hi else { return nil }
            return max(0, lo)..<min(width, hi)
        }
        let lo = (row == s.row) ? s.col : 0
        let hi = (row == e.row) ? e.col : width
        guard lo < hi else { return nil }
        return max(0, lo)..<min(width, hi)
    }
}
