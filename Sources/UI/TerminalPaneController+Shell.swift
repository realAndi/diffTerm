import UIKit

/// Everything built on the OSC 133 marks the shell emits: jumping between
/// prompts, and selecting or copying a command's output without having to drag
/// across it. On a phone, dragging across half a screen of output to copy a
/// stack trace is the worst interaction in the app; knowing where the output
/// starts removes it.
extension TerminalPaneController {

    private var integration: ShellIntegration { session.emulator.shellIntegration }

    /// Where the top of the viewport currently sits, in stable rows.
    private var topStableRow: Int {
        guard let view = terminalView, view.cellSize.height > 0 else { return 0 }
        let absolute = view.layout.row(atY: scrollOffsetY)
        return session.emulator.oldestStableRow + absolute
    }

    // MARK: - Navigation

    @objc func commandPreviousPrompt() {
        guard let target = integration.promptRow(before: topStableRow) else {
            flashNoMarks()
            return
        }
        scrollTo(stableRow: target)
    }

    @objc func commandNextPrompt() {
        guard let target = integration.promptRow(after: topStableRow) else {
            // Already at the last prompt: the useful thing is the live one.
            scrollToBottom(animated: true)
            return
        }
        scrollTo(stableRow: target)
    }

    private func scrollTo(stableRow: Int) {
        guard let view = terminalView,
              let absolute = session.emulator.absoluteRow(for: stableRow) else { return }
        // A prompt pinned to the very top hides the command that produced what
        // is above it; a row of lead-in makes the jump readable.
        let lead = view.cellSize.height
        scrollTo(offsetY: view.layout.y(forRow: absolute) - lead)
    }

    // MARK: - Output

    /// The block under a point, for the long-press menu.
    func commandBlock(at point: CGPoint) -> CommandBlock? {
        guard let view = terminalView else { return nil }
        let absolute = view.gridPosition(at: point).row
        return integration.block(containing: session.emulator.oldestStableRow + absolute)
    }

    /// Turns a block's output rows into a selection in absolute coordinates.
    /// Nil once the output has aged out of scrollback.
    func selection(forOutputOf block: CommandBlock) -> TerminalSelection? {
        guard let rows = block.outputRows,
              let first = session.emulator.absoluteRow(for: rows.lowerBound) else { return nil }
        let buffer = session.emulator.buffer
        // The end mark sits on the row the next prompt will use, so the last
        // row of output is the one before it — clamped, because a command still
        // running has no end yet and the live cursor row is as far as it goes.
        let lastStable = min(rows.upperBound - 1, session.emulator.stableCursorRow)
        let last = session.emulator.absoluteRow(for: lastStable) ?? (buffer.totalRows - 1)
        guard last >= first else { return nil }
        return TerminalSelection(anchor: GridPosition(row: first, col: 0),
                                 head: GridPosition(row: last, col: buffer.cols))
    }

    func canCopyLastCommandOutput() -> Bool {
        guard let block = integration.lastWithOutput else { return false }
        return selection(forOutputOf: block) != nil
    }

    @objc func copyLastCommandOutput() {
        guard let block = integration.lastWithOutput else {
            flashNoMarks()
            return
        }
        copyOutput(of: block)
    }

    func copyOutput(of block: CommandBlock) {
        guard let view = terminalView, let selection = selection(forOutputOf: block) else { return }
        let text = view.text(for: selection).trimmingCharacters(in: .newlines)
        guard !text.isEmpty else { return }
        UIPasteboard.general.string = text
    }

    func selectOutput(of block: CommandBlock) {
        guard terminalView != nil, let selection = selection(forOutputOf: block) else { return }
        terminalView.selection = selection
    }

    /// Says why nothing happened, rather than appearing to be broken. Without
    /// a shell that emits OSC 133 there is nothing here to navigate, and that
    /// is not obvious from the outside.
    private func flashNoMarks() {
        let alert = UIAlertController(
            title: "No command marks yet",
            message: "This needs a shell that reports where commands begin and end (OSC 133) — "
                   + "starship, powerlevel10k, and the shell integrations bundled with zsh and fish all do.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

/// The menu a block's rail raises. Everything here already existed as a
/// keyboard command or a menu item; the rail just gives it a target you can
/// hit with a thumb, which is the whole point of blocks on a phone.
extension TerminalPaneController {

    func presentBlockMenu(for block: CommandBlock, at point: CGPoint) {
        let sheet = UIAlertController(title: blockMenuTitle(for: block),
                                      message: blockMenuSubtitle(for: block),
                                      preferredStyle: .actionSheet)

        if selection(forOutputOf: block) != nil {
            sheet.addAction(UIAlertAction(title: "Copy Output", style: .default) { [weak self] _ in
                self?.copyOutput(of: block)
            })
            sheet.addAction(UIAlertAction(title: "Select Output", style: .default) { [weak self] _ in
                self?.selectOutput(of: block)
            })
        }

        if let command = commandText(for: block) {
            sheet.addAction(UIAlertAction(title: "Copy Command", style: .default) { _ in
                UIPasteboard.general.string = command
            })
            // Re-running puts the text on the input line without pressing
            // return: a command worth repeating is often one worth editing
            // first, and there is no undo for the other choice.
            sheet.addAction(UIAlertAction(title: "Insert Command", style: .default) { [weak self] _ in
                guard let self else { return }
                self.session.send(text: command)
                self.scrollToBottom(animated: true)
            })
        }

        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = terminalView
            popover.sourceRect = CGRect(origin: point, size: CGSize(width: 1, height: 1))
        }
        present(sheet, animated: true)
    }

    /// The command line as typed, read back off the grid between the B and C
    /// marks — the same trick the finished-command notification uses.
    func commandText(for block: CommandBlock) -> String? {
        guard let start = block.commandStart,
              let row = session.emulator.absoluteRow(for: start.row) else { return nil }
        let line = session.emulator.normal.row(at: row)
        guard start.col < line.count else { return nil }
        let text = line.text(from: start.col, to: line.trimmedLength)
            .trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    private func blockMenuTitle(for block: CommandBlock) -> String {
        guard let command = commandText(for: block) else { return "Command" }
        return command.count > 48 ? String(command.prefix(47)) + "…" : command
    }

    private func blockMenuSubtitle(for block: CommandBlock) -> String? {
        var parts: [String] = []
        switch block.outcome {
        case .running:   parts.append("running")
        case .succeeded: parts.append("exit 0")
        case .failed:    parts.append("exit \(block.exitCode.map(String.init) ?? "?")")
        case .pending:   break
        }
        if let duration = block.duration, duration >= 1 {
            parts.append(TerminalPaneController.durationText(duration))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func durationText(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        let total = Int(seconds.rounded())
        if total < 3600 { return "\(total / 60)m \(total % 60)s" }
        return "\(total / 3600)h \((total % 3600) / 60)m"
    }
}
