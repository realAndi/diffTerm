import CoreGraphics

/// The vertical layout of the grid once command blocks add space of their own.
///
/// Without blocks the map from a row to a y position is just `row *
/// cellHeight`, and every coordinate in the view assumes it. Warp-style blocks
/// break that: a gap sits between one command and the next, and a collapsed
/// command hides its output. So the linear map becomes a piecewise one, and
/// this is the single place that owns it — everything else asks it for
/// `y(forRow:)`, `row(atY:)`, `totalHeight` and `isHidden(row:)` rather than
/// multiplying by `cellHeight`.
///
/// It is built from the block boundaries in *absolute* row coordinates (the
/// caller converts from the stable rows the shell integration records) and is
/// O(blocks): a handful of segments, never one per row, so rebuilding it when
/// the blocks or the collapse set change is cheap even against a deep buffer.
///
/// When blocks are off, or on the alternate screen, the caller builds the
/// identity layout, which is exactly `row * cellHeight` again — the whole
/// mechanism folds away with no special cases at the call sites.
struct BlockLayout {

    /// One run of consecutive rows that share a regime.
    struct Segment {
        var firstRow: Int
        /// One past the last row in the run.
        var endRow: Int
        /// y of the top of `firstRow`.
        var top: CGFloat
        /// Height of the whole run in the laid-out space. For a visible run
        /// this is `rows * cellHeight`; for a hidden (collapsed) run it is the
        /// height of the single summary strip that stands in for it.
        var height: CGFloat
        var hidden: Bool

        var rowCount: Int { endRow - firstRow }
    }

    let cellHeight: CGFloat
    let totalRows: Int
    private(set) var segments: [Segment]
    private(set) var totalHeight: CGFloat

    /// The identity layout: `y == row * cellHeight`, nothing hidden. Used when
    /// block mode is off or a full-screen program owns the screen.
    init(rows: Int, cellHeight: CGFloat) {
        self.cellHeight = cellHeight
        self.totalRows = rows
        self.segments = [Segment(firstRow: 0, endRow: max(0, rows), top: 0,
                                 height: CGFloat(max(0, rows)) * cellHeight, hidden: false)]
        self.totalHeight = CGFloat(max(0, rows)) * cellHeight
    }

    /// A block, in absolute row coordinates, as the layout needs it.
    struct Span {
        /// The prompt row — where a gap is inserted above.
        var promptRow: Int
        /// First row of output, if any. Rows before it (the prompt and the
        /// typed command) stay visible even when collapsed.
        var outputRow: Int?
        /// One past the block's last row.
        var endRow: Int
        var collapsed: Bool
    }

    /// Builds the piecewise layout from ordered, non-overlapping spans.
    ///
    /// `gap` is the space above each block after the first — the air between
    /// cards. `summaryHeight` is what a collapsed block's hidden output is
    /// replaced by (the "N lines hidden" strip).
    init(rows totalRows: Int, cellHeight: CGFloat, gap: CGFloat, summaryHeight: CGFloat,
         spans: [Span]) {
        self.cellHeight = cellHeight
        self.totalRows = totalRows

        var segments: [Segment] = []
        var y: CGFloat = 0
        var row = 0

        func emitVisible(_ from: Int, _ to: Int) {
            guard to > from else { return }
            let h = CGFloat(to - from) * cellHeight
            segments.append(Segment(firstRow: from, endRow: to, top: y, height: h, hidden: false))
            y += h
        }

        for span in spans {
            let promptRow = min(max(span.promptRow, 0), totalRows)
            let end = min(max(span.endRow, promptRow), totalRows)
            guard promptRow >= row else { continue }   // ignore overlaps defensively

            // Ordinary rows before this block.
            emitVisible(row, promptRow)

            // Air above the block — never above the very first row.
            if promptRow > 0 { y += gap }

            if span.collapsed, let out = span.outputRow, out > promptRow, out < end {
                let head = min(max(out, promptRow), end)
                emitVisible(promptRow, head)                 // prompt + command line
                // The output, hidden, standing in as one summary strip.
                segments.append(Segment(firstRow: head, endRow: end, top: y,
                                        height: summaryHeight, hidden: true))
                y += summaryHeight
            } else {
                emitVisible(promptRow, end)
            }
            row = end
        }
        emitVisible(row, totalRows)

        if segments.isEmpty {
            segments = [Segment(firstRow: 0, endRow: max(0, totalRows), top: 0,
                                height: CGFloat(max(0, totalRows)) * cellHeight, hidden: false)]
        }
        self.segments = segments
        self.totalHeight = y
    }

    // MARK: - Queries

    /// The segment containing `row` (or the last one for a row past the end).
    private func segmentIndex(forRow row: Int) -> Int {
        var lo = 0, hi = segments.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if segments[mid].firstRow <= row { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// y of the top of a row.
    func y(forRow row: Int) -> CGFloat {
        guard !segments.isEmpty else { return CGFloat(row) * cellHeight }
        if row < 0 { return CGFloat(row) * cellHeight }   // above the buffer, linear
        let seg = segments[segmentIndex(forRow: row)]
        if seg.hidden { return seg.top }                  // collapsed rows sit at the strip top
        let clamped = min(max(row, seg.firstRow), seg.endRow)
        return seg.top + CGFloat(clamped - seg.firstRow) * cellHeight
    }

    /// The row at a y position, for hit testing. A y inside a collapsed
    /// strip resolves to that block's first hidden row, so a tap there maps
    /// to the block rather than to nothing.
    func row(atY target: CGFloat) -> Int {
        guard !segments.isEmpty else { return Int((target / cellHeight).rounded(.down)) }
        if target < 0 { return Int((target / cellHeight).rounded(.down)) }
        // Binary search for the segment whose vertical extent holds `target`.
        var lo = 0, hi = segments.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if segments[mid].top <= target { lo = mid } else { hi = mid - 1 }
        }
        let seg = segments[lo]
        if seg.hidden { return seg.firstRow }
        let into = Int(((target - seg.top) / cellHeight).rounded(.down))
        return min(seg.firstRow + max(0, into), max(0, totalRows - 1))
    }

    /// Whether a row is inside a collapsed block's hidden output, so the
    /// renderer skips it.
    func isHidden(row: Int) -> Bool {
        guard !segments.isEmpty, row >= 0 else { return false }
        return segments[segmentIndex(forRow: row)].hidden
    }

    /// The collapsed summary strip covering a row, if any — its rect top and
    /// the count of rows it stands in for.
    func summary(forRow row: Int) -> (top: CGFloat, hiddenRows: Int)? {
        guard row >= 0, !segments.isEmpty else { return nil }
        let seg = segments[segmentIndex(forRow: row)]
        guard seg.hidden else { return nil }
        return (seg.top, seg.rowCount)
    }
}
