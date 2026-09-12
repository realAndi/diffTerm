import Foundation

/// A color as understood by the terminal. Kept small: the grid holds two of
/// these per cell, so an enum with payload beats boxing into a UIColor.
enum TermColor: Equatable, Hashable {
    case `default`
    case indexed(UInt8)
    case rgb(UInt8, UInt8, UInt8)
}

struct CellFlags: OptionSet, Hashable {
    let rawValue: UInt16
    static let bold          = CellFlags(rawValue: 1 << 0)
    static let faint         = CellFlags(rawValue: 1 << 1)
    static let italic        = CellFlags(rawValue: 1 << 2)
    static let underline     = CellFlags(rawValue: 1 << 3)
    static let blink         = CellFlags(rawValue: 1 << 4)
    static let inverse       = CellFlags(rawValue: 1 << 5)
    static let invisible     = CellFlags(rawValue: 1 << 6)
    static let strikethrough = CellFlags(rawValue: 1 << 7)
    static let doubleUnderline = CellFlags(rawValue: 1 << 8)
    static let curlyUnderline  = CellFlags(rawValue: 1 << 9)
    static let overline        = CellFlags(rawValue: 1 << 10)
    /// Set on the trailing half of a double-width glyph.
    static let wideTrailer     = CellFlags(rawValue: 1 << 11)

    var anyUnderline: Bool {
        !isDisjoint(with: [.underline, .doubleUnderline, .curlyUnderline])
    }
}

/// Everything about a cell except its character. Compared often (run
/// coalescing in the renderer), so it stays Equatable and cheap.
struct CellAttributes: Equatable, Hashable {
    var fg: TermColor = .default
    var bg: TermColor = .default
    /// Colour for the underline when set via SGR 58.
    var underlineColor: TermColor = .default
    var flags: CellFlags = []
    /// Index into the emulator's hyperlink table, 0 = none (OSC 8).
    var linkID: UInt32 = 0

    static let blank = CellAttributes()
}

struct Cell {
    /// A grapheme cluster. Swift's small-string form keeps this allocation
    /// free for anything under 16 UTF-8 bytes, which covers realistic input.
    var ch: Character
    var attrs: CellAttributes

    static let blank = Cell(ch: " ", attrs: .blank)

    @inline(__always) var isBlank: Bool { ch == " " }
}

/// One row of the grid. `wrapped` records that the line was broken by
/// autowrap rather than a newline, which matters for reflow and for copying
/// text back out as the user typed it.
struct Line {
    var cells: [Cell]
    var wrapped: Bool = false

    init(width: Int, template: Cell = .blank) {
        cells = Array(repeating: template, count: width)
    }

    init(cells: [Cell], wrapped: Bool) {
        self.cells = cells
        self.wrapped = wrapped
    }

    var count: Int { cells.count }

    subscript(i: Int) -> Cell {
        get { cells[i] }
        set { cells[i] = newValue }
    }

    mutating func resize(to width: Int, template: Cell = .blank) {
        if cells.count < width {
            cells.append(contentsOf: Array(repeating: template, count: width - cells.count))
        } else if cells.count > width {
            cells.removeLast(cells.count - width)
        }
    }

    /// Index one past the last non-blank cell — lets the renderer and the
    /// copy path skip trailing whitespace.
    var trimmedLength: Int {
        var n = cells.count
        while n > 0, cells[n - 1].isBlank, cells[n - 1].attrs.bg == .default { n -= 1 }
        return n
    }

    func text(from: Int = 0, to: Int? = nil) -> String {
        let end = min(to ?? cells.count, cells.count)
        guard from < end else { return "" }
        var s = String()
        s.reserveCapacity(end - from)
        for i in from..<end where !cells[i].attrs.flags.contains(.wideTrailer) {
            s.append(cells[i].ch)
        }
        return s
    }
}
