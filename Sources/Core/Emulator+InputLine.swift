import Foundation

/// Reading what the user has typed, without owning the input buffer.
///
/// Warp can show ghost text because Warp *is* the line editor: it holds the
/// buffer, and hands the finished line to the shell only on Enter. That is
/// also why Warp has to re-implement completion, history search, vi mode and
/// every zle widget a user has bound.
///
/// diffTerm does not need to. The shell's own line editor stays exactly where
/// it is, and the typed text is read back off the grid instead — from the
/// OSC 133 `B` mark, which is the shell telling us where its own input begins,
/// to wherever it has put the cursor. Everything downstream of this (the
/// suggestion, the ghost text, accepting it) is then a read of the screen and
/// a write to the pty, so `zsh` keeps completion, `^R`, vi mode and history
/// exactly as configured.
extension Emulator {

    /// What the user has typed on the current input line, or nil when there
    /// is no line to read.
    ///
    /// Returns nil — meaning "do not suggest anything" — whenever the answer
    /// would be a guess:
    ///
    /// - on the alternate screen, where there is no prompt at all;
    /// - while a command is running, since anything typed then is that
    ///   program's input, not a command line;
    /// - when the shell has not sent a `B` mark, so we do not know where its
    ///   prompt ends and the user's text starts;
    /// - when the cursor is not at the end of the text, because a prefix read
    ///   up to a cursor the user has moved left is not the line they are
    ///   editing.
    var currentInputLine: String? {
        guard !modes.altScreen else { return nil }
        guard let block = shellIntegration.last,
              block.outputStart == nil,
              let start = block.commandStart,
              let firstRow = absoluteRow(for: start.row) else { return nil }

        let cursorRow = normal.scrollbackCount + normal.cursorY
        let cursorCol = normal.cursorX
        guard cursorRow >= firstRow, cursorRow < normal.totalRows else { return nil }

        // The cursor has to be sitting past everything on its row. Typing in
        // the middle of a line is editing, and a suggestion appended to a
        // half-read prefix would be nonsense.
        let cursorLine = normal.row(at: cursorRow)
        guard cursorCol >= cursorLine.trimmedLength else { return nil }

        var text = ""
        for row in firstRow...cursorRow {
            let line = normal.row(at: row)
            let from = row == firstRow ? start.col : 0
            let to: Int
            if row == cursorRow {
                // The cursor row is read up to the cursor — everything before
                // it is real input, trailing spaces included.
                to = min(cursorCol, line.count)
            } else if line.wrapped {
                // A wrapped row is full by definition, and a space sitting in
                // its last column is a space the user typed, not padding.
                // Trimming it dropped a character from a command that wrapped
                // right after a space (`git commit ...`), so the suggestion
                // stopped matching and cut off at the line break. Read the
                // whole width.
                to = line.count
            } else {
                to = line.trimmedLength
            }
            guard from <= to, from < line.count else { continue }
            text += line.text(from: from, to: min(to, line.count))
        }

        // No trailing-space trim. The line is read only up to the cursor, so
        // everything in it is real input — including a space the user just
        // typed. Trimming it made the ghost for a command with spaces stall:
        // typing the space in "git status" left the ghost showing " status"
        // with its leading space, drawn after the cursor, which reads as the
        // suggestion refusing to fill in. Padding lives *past* the cursor and
        // is never read here. A leading space is likewise kept — it is how a
        // user asks the shell not to record a command.
        return text
    }

    /// Where the cursor is, as an absolute row and column — the anchor ghost
    /// text is drawn from.
    var cursorAnchor: (row: Int, col: Int) {
        (buffer.scrollbackCount + buffer.cursorY, buffer.cursorX)
    }

    /// True when the shell is sitting at a prompt with nothing running.
    var isAtPrompt: Bool {
        guard !modes.altScreen, let block = shellIntegration.last else { return false }
        return block.outputStart == nil
    }
}
