import Foundation

/// One command, as reported by a shell that emits OSC 133 marks.
///
/// Rows are *stable* history coordinates: `scrollbackEvicted + absolute row`,
/// which keeps counting up as lines age out of the ring, so a block recorded
/// ten thousand lines ago still names the same text. `Emulator.absoluteRow(for:)`
/// converts back for anything that wants to index the buffer.
struct CommandBlock {
    /// Row the prompt begins on — OSC 133;A.
    var promptStart: Int
    /// Where the typed command begins — OSC 133;B. Absent until the shell
    /// says so, which some shells never do.
    var commandStart: (row: Int, col: Int)?
    /// First row of the command's output — OSC 133;C.
    var outputStart: Int?
    /// One past the last row of output — OSC 133;D. Absent while running.
    var outputEnd: Int?
    /// Exit status, when the shell reported one with D.
    var exitCode: Int?
    /// Wall-clock time the command started running, for "finished after 4m".
    var startedAt: Date?
    var finishedAt: Date?

    /// How long the command ran, once it has finished.
    var duration: TimeInterval? {
        guard let startedAt, let finishedAt else { return nil }
        return finishedAt.timeIntervalSince(startedAt)
    }

    /// True between C and D: the command has started and not yet finished.
    var isRunning: Bool { outputStart != nil && outputEnd == nil }

    /// The half-open row range holding the output, if there is any.
    var outputRows: Range<Int>? {
        guard let start = outputStart else { return nil }
        let end = outputEnd ?? start
        return end > start ? start..<end : nil
    }
}

/// The recorded blocks for one terminal.
///
/// Shells emit these marks all the time — starship, powerlevel10k, zsh's
/// bundled integration and fish all do — and the emulator was accepting and
/// discarding them. Keeping them is what makes "jump to the previous prompt"
/// and "copy the output of that command" possible without guessing where a
/// command started by looking at the pixels.
struct ShellIntegration {

    /// Blocks in row order, oldest first.
    private(set) var blocks: [CommandBlock] = []

    /// Anything older than this many commands is dropped. A long-lived shell
    /// would otherwise accumulate one of these per prompt forever, and the
    /// text they point at left scrollback long ago.
    private let limit = 512

    var isEmpty: Bool { blocks.isEmpty }

    /// The most recent block, running or finished.
    var last: CommandBlock? { blocks.last }

    /// The most recent block that actually produced output.
    var lastWithOutput: CommandBlock? {
        blocks.last(where: { $0.outputRows != nil })
    }

    mutating func removeAll() { blocks.removeAll() }

    // MARK: - Recording

    mutating func beginPrompt(at row: Int) {
        // A prompt appearing while the previous command is still open means we
        // never saw its D — ^C, or a shell that only emits some of the marks.
        // Close it here rather than leaving a block that grows forever.
        if var open = blocks.last, open.outputEnd == nil {
            open.outputEnd = row
            blocks[blocks.count - 1] = open
        }
        // Re-drawn prompts (a resize, or zsh redrawing after a completion
        // menu) repeat A at the same place; keep one block per position.
        if let existing = blocks.last, existing.promptStart == row, existing.outputStart == nil {
            blocks[blocks.count - 1] = CommandBlock(promptStart: row)
            return
        }
        blocks.append(CommandBlock(promptStart: row))
        if blocks.count > limit { blocks.removeFirst(blocks.count - limit) }
    }

    mutating func beginCommand(at row: Int, col: Int) {
        guard !blocks.isEmpty else { return }
        blocks[blocks.count - 1].commandStart = (row, col)
    }

    mutating func beginOutput(at row: Int) {
        guard !blocks.isEmpty else { return }
        guard blocks[blocks.count - 1].outputStart == nil else { return }
        blocks[blocks.count - 1].outputStart = row
        blocks[blocks.count - 1].startedAt = Date()
    }

    mutating func endCommand(at row: Int, exitCode: Int?) {
        guard !blocks.isEmpty else { return }
        var block = blocks[blocks.count - 1]
        // D without a preceding C: the command produced nothing.
        if block.outputStart == nil { block.outputStart = row }
        block.outputEnd = row
        block.exitCode = exitCode
        block.finishedAt = Date()
        blocks[blocks.count - 1] = block
    }

    /// Drops blocks whose text has aged out of scrollback entirely.
    mutating func discard(before oldestStableRow: Int) {
        guard let first = blocks.first, first.promptStart < oldestStableRow else { return }
        blocks.removeAll { block in
            (block.outputEnd ?? block.outputStart ?? block.promptStart) < oldestStableRow
        }
    }

    // MARK: - Navigation

    /// The prompt immediately above `row`, for jump-to-previous-prompt.
    func promptRow(before row: Int) -> Int? {
        blocks.last(where: { $0.promptStart < row })?.promptStart
    }

    /// The prompt immediately below `row`.
    func promptRow(after row: Int) -> Int? {
        blocks.first(where: { $0.promptStart > row })?.promptStart
    }

    /// The block whose prompt-to-end span contains `row`, which is what turns
    /// a tap in the middle of some output into "this command".
    func block(containing row: Int) -> CommandBlock? {
        var candidate: CommandBlock?
        for block in blocks {
            if block.promptStart > row { break }
            candidate = block
        }
        guard let found = candidate else { return nil }
        // A row past the end of the last finished block belongs to no command.
        if let end = found.outputEnd, row >= end, found.promptStart != row { return nil }
        return found
    }
}

extension CommandBlock {

    /// How a finished command turned out, for the block rail.
    enum Outcome {
        /// Between C and D — still producing output.
        case running
        /// D with exit code 0.
        case succeeded
        /// D with a non-zero exit code.
        case failed
        /// A prompt with nothing run yet, or a shell that reported D without
        /// a status. Neither is an error, so neither gets an error colour.
        case pending
    }

    var outcome: Outcome {
        if isRunning { return .running }
        guard outputEnd != nil, let code = exitCode else { return .pending }
        return code == 0 ? .succeeded : .failed
    }

    /// The block's full extent — prompt row through the last row of output —
    /// in stable coordinates.
    ///
    /// `liveEnd` closes a block that has not finished yet: the D mark is what
    /// normally ends one, and a running command has not sent it. The end mark
    /// sits on the row the *next* prompt will use, so the last row that
    /// belongs to this block is the one before it.
    func stableRows(liveEnd: Int) -> ClosedRange<Int> {
        let last = outputEnd.map { $0 - 1 } ?? max(promptStart, liveEnd)
        return promptStart...max(promptStart, last)
    }
}

extension ShellIntegration {

    /// Blocks overlapping a range of stable rows, oldest first.
    ///
    /// The renderer asks this once per draw for the rows on screen, so it
    /// binary-searches rather than scanning: a long-lived shell holds up to
    /// `limit` blocks and a scan per frame is work for nothing.
    func blocks(overlapping range: ClosedRange<Int>, liveEnd: Int) -> ArraySlice<CommandBlock> {
        guard !blocks.isEmpty else { return [] }

        // First block that could reach into the range. Blocks are in prompt
        // order and do not overlap, so the one before the first prompt past
        // `lowerBound` is the only earlier candidate that can still cover it.
        var lo = 0, hi = blocks.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if blocks[mid].promptStart <= range.lowerBound { lo = mid + 1 } else { hi = mid }
        }
        let start = lo > 0 && blocks[lo - 1].stableRows(liveEnd: liveEnd).upperBound >= range.lowerBound
            ? lo - 1 : lo

        // Last block whose prompt begins at or before the end of the range.
        var end = start
        while end < blocks.count, blocks[end].promptStart <= range.upperBound { end += 1 }

        guard start < end else { return [] }
        return blocks[start..<end]
    }
}
