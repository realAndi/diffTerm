import UIKit

/// Ghost text, wired into the pane.
///
/// The shell keeps its line editor. Everything here reads the screen and
/// writes to the pty: the suggestion is drawn as an overlay, and accepting it
/// sends the remaining characters as if they had been typed. `zsh` echoes
/// them, moves its own cursor, and keeps completion, `^R` and vi mode intact —
/// which is the whole reason for doing it this way rather than owning the
/// buffer the way Warp does.
extension TerminalPaneController {

    // MARK: - Refresh

    /// Recomputes the suggestion and pushes it to the view.
    ///
    /// Called after every batch of output, which is the only thing that can
    /// move the prompt or change what is on the input line — the user's own
    /// keystrokes only matter once the shell has echoed them back.
    func refreshSuggestion() {
        guard terminalView != nil else { return }
        guard Preferences.shared.commandSuggestions else {
            if !terminalView.ghostText.isEmpty { setGhostText("") }
            return
        }

        suggestions.recordMarks(emulator: session.emulator,
                                commandText: { [weak self] in self?.commandText(for: $0) },
                                pwd: session.workingDirectory,
                                shell: session.shellName)

        suggestions.refresh(emulator: session.emulator,
                            pwd: session.workingDirectory,
                            shell: session.shellName)

        setGhostText(suggestions.visibleSuffix)
    }

    // MARK: - Accepting

    var hasSuggestion: Bool {
        Preferences.shared.commandSuggestions && suggestions.hasVisibleSuggestion
    }

    /// Takes the whole suggestion.
    @discardableResult
    func acceptSuggestion() -> Bool {
        guard let text = suggestions.accept() else { return false }
        setGhostText("")
        session.send(text: text)
        scrollToBottom(animated: false)
        if Preferences.shared.keyboardHaptics {
            UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.6)
        }
        return true
    }

    /// Takes one word of it. On a phone this is the useful middle setting:
    /// long suggestions are often right about the command and wrong about the
    /// arguments, and a word at a time lets you keep the good half.
    @discardableResult
    func acceptSuggestionWord() -> Bool {
        guard let text = suggestions.acceptWord() else { return false }
        setGhostText(suggestions.visibleSuffix)
        session.send(text: text)
        scrollToBottom(animated: false)
        return true
    }

    /// Waves it away and does not offer it again until it is actually run.
    func dismissSuggestion() {
        guard hasSuggestion else { return }
        suggestions.dismiss()
        setGhostText("")
    }

    /// A tap on the ghost text takes it through the end of the word that was
    /// tapped — the last word takes all of it. Returns false when the tap
    /// was somewhere else, so the caller can carry on with what a tap
    /// normally means.
    func handleSuggestionTap(at point: CGPoint) -> Bool {
        guard hasSuggestion else { return false }
        let rects = terminalView.ghostRects
        guard !rects.isEmpty else { return false }

        // A generous target vertically: the text is one cell tall and a
        // thumb is not. Horizontally, find the character under the tap, or
        // treat a tap just past the end as the end.
        let rowHit = rects.contains { $0.insetBy(dx: -6, dy: -10).contains(point) }
        guard rowHit else { return false }
        let index = rects.firstIndex { $0.insetBy(dx: 0, dy: -10).contains(point) }
            ?? (rects.count - 1)

        guard let text = suggestions.accept(throughCharacter: index) else { return false }
        setGhostText(suggestions.visibleSuffix)
        session.send(text: text)
        scrollToBottom(animated: false)
        if Preferences.shared.keyboardHaptics {
            UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.6)
        }
        return true
    }
}
