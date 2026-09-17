import Foundation

/// Drives ghost text for one pane: records what was run, asks the predictor
/// what is likely next, and holds the suggestion while the user types.
///
/// It never touches the input line itself. Accepting a suggestion returns the
/// text to send, and the caller writes it to the pty exactly as if it had been
/// typed — so the shell echoes it, moves its own cursor, and stays the single
/// source of truth for what is on the line.
final class SuggestionEngine {

    private(set) var current: Autosuggestion?

    /// Suggestions the user waved away. Cleared for a command once they run
    /// it: dismissing `git push` today should not bury it forever.
    private var ignored: Set<String> = []

    /// Blocks already written to history, keyed by prompt row, so a redrawn
    /// prompt or a repeated mark cannot record a command twice.
    private var recordedStart: [Int: Int] = [:]
    private var recordedFinish: Set<Int> = []

    private var predictor: NextCommandPredictor

    /// Everything a prediction depends on that can change while the shell
    /// sits at a prompt.
    private struct PredictionKey: Equatable {
        var line: String
        var lastCommandID: Int?
        var lastExitCode: Int?
        var pwd: String
        var shell: String
        var historyRevision: Int
    }

    /// The last prediction and what it was made against. Refresh runs after
    /// every batch of output, and a prompt that redraws a clock produces a
    /// batch a second with nothing in it that could change the answer, so
    /// an identical key reuses the result — "nothing to suggest" included —
    /// rather than running the cascade and its filesystem checks again.
    private var lastPrediction: (key: PredictionKey, result: Autosuggestion?)?

    /// Identifies this pane's command sequence in the shared history.
    let sessionKey: String

    /// `predictor` is a test seam; the app always uses the shared history.
    init(sessionKey: String, predictor: NextCommandPredictor = NextCommandPredictor()) {
        self.sessionKey = sessionKey
        self.predictor = predictor
    }

    var visibleSuffix: String {
        guard Preferences.shared.commandSuggestions else { return "" }
        return current?.suffix ?? ""
    }

    var hasVisibleSuggestion: Bool { !visibleSuffix.isEmpty }

    /// Installs a suggestion directly. Test seam: the accept paths are worth
    /// checking without a shell behind them.
    func seed(_ suggestion: Autosuggestion) { current = suggestion }

    // MARK: - Recording

    /// Mirrors the shell's marks into the history store.
    ///
    /// Called whenever a mark arrives. `C` opens a row, `D` closes it with the
    /// status — the same two events the block rail is drawn from, so history
    /// and blocks can never disagree about what ran.
    func recordMarks(emulator: Emulator, commandText: (CommandBlock) -> String?,
                     pwd: String, shell: String) {
        guard Preferences.shared.commandSuggestions else { return }
        let store = predictor.store

        for block in emulator.shellIntegration.blocks.suffix(4) {
            let key = block.promptStart

            if block.outputStart != nil, recordedStart[key] == nil {
                guard let text = commandText(block), !text.isEmpty else { continue }
                // A leading space is the conventional way to ask a shell not
                // to remember a command. Honour it here too.
                guard !text.hasPrefix(" ") else {
                    recordedStart[key] = -1
                    continue
                }
                recordedStart[key] = store.begin(command: text, pwd: pwd, shell: shell,
                                                 hostname: SuggestionEngine.hostname,
                                                 session: sessionKey)
                ignored.remove(text)
                lastPrediction = nil
            }

            if block.outputEnd != nil, !recordedFinish.contains(key),
               let id = recordedStart[key], id >= 0 {
                recordedFinish.insert(key)
                store.finish(id: id, exitCode: block.exitCode)
                lastPrediction = nil
            }
        }

        // The map only ever needs the handful of blocks still in flight.
        if recordedStart.count > 64 {
            let live = Set(emulator.shellIntegration.blocks.suffix(16).map(\.promptStart))
            recordedStart = recordedStart.filter { live.contains($0.key) }
            recordedFinish = recordedFinish.intersection(live)
        }
    }

    // MARK: - Predicting

    /// Recomputes the suggestion for the current state of the input line.
    /// Returns true when what should be drawn has changed.
    @discardableResult
    func refresh(emulator: Emulator, pwd: String, shell: String) -> Bool {
        let before = visibleSuffix
        guard Preferences.shared.commandSuggestions else {
            current = nil
            return before != ""
        }

        guard emulator.isAtPrompt else {
            current = nil
            return before != ""
        }
        guard let line = emulator.currentInputLine else {
            // At a prompt, but the line is momentarily unreadable: the shell
            // is mid-redraw, or the cursor has stepped off the end. Hold what
            // is showing. Clearing here and restoring a frame later is the
            // flicker that makes ghost text feel like it is fighting you —
            // and the view refuses to draw it anywhere but the end of the
            // line, so holding is safe even when the cursor has moved.
            return false
        }

        // An existing suggestion that still agrees with the line shrinks
        // rather than being replaced. Recomputing here is what makes ghost
        // text flicker as it is typed through.
        if var existing = current {
            if existing.update(buffer: line) {
                if existing.isVisible {
                    current = existing
                    return visibleSuffix != before
                }
                // Diverged and only kept for a backspace. The line has moved
                // on, so try a fresh prediction; if none appears, the hidden
                // suggestion stays. A visible one is never swapped like this.
                if let prediction = predictSuggestion(emulator: emulator, pwd: pwd,
                                                      shell: shell, line: line) {
                    current = prediction
                    return visibleSuffix != before
                }
                current = existing
                return visibleSuffix != before
            }
            current = nil
        }

        if let prediction = predictSuggestion(emulator: emulator, pwd: pwd,
                                              shell: shell, line: line) {
            current = prediction
        }
        return visibleSuffix != before
    }

    /// Asks the predictor for a suggestion for `line`, using the same context
    /// the main refresh path builds.
    ///
    /// Callers still decide what to do with the answer, so reusing one never
    /// swaps visible ghost text: that rule lives in `refresh`, which does not
    /// ask at all while a suggestion is showing.
    private func predictSuggestion(emulator: Emulator, pwd: String, shell: String,
                                   line: String) -> Autosuggestion? {
        let finished = lastFinishedBlock(emulator: emulator)
        let key = PredictionKey(line: line,
                                lastCommandID: finished?.id,
                                lastExitCode: finished?.exitCode,
                                pwd: pwd,
                                shell: shell,
                                historyRevision: predictor.store.revision)
        if let last = lastPrediction, last.key == key { return last.result }

        predictor.ignored = ignored
        let context = NextCommandPredictor.Context(
            lastCommand: finished.flatMap { predictor.store.command(forID: $0.id) },
            lastExitCode: finished?.exitCode,
            pwd: pwd,
            shell: shell,
            hostname: SuggestionEngine.hostname,
            prefix: line)

        let result = predictor.predict(context).flatMap {
            Autosuggestion(full: $0.command, buffer: line, source: $0.source)
        }
        lastPrediction = (key, result)
        return result
    }

    /// The history id of the command before the one being typed, with the
    /// status it exited with — the key the episode lookup turns on. The id
    /// rather than the text, so the cache key costs no history lookup.
    private func lastFinishedBlock(emulator: Emulator) -> (id: Int, exitCode: Int?)? {
        let blocks = emulator.shellIntegration.blocks
        guard blocks.count >= 2 else { return nil }
        let previous = blocks[blocks.count - 2]
        guard previous.outputEnd != nil,
              let id = recordedStart[previous.promptStart], id >= 0 else { return nil }
        return (id, previous.exitCode)
    }

    // MARK: - Acting

    /// The text to send to accept the whole suggestion, if there is one.
    func accept() -> String? {
        let suffix = visibleSuffix
        guard !suffix.isEmpty else { return nil }
        current = nil
        return suffix
    }

    /// The text to send to accept one word — the phone-friendly middle ground
    /// between all of it and none.
    func acceptWord() -> String? {
        accept(throughCharacter: 0)
    }

    /// Accepts through the end of the word containing character `index` of
    /// the visible suffix. Tapping the third word of a five-word suggestion
    /// takes the first three: long suggestions are often right about the
    /// command and wrong about the tail, and this keeps the good part.
    ///
    /// Taking the whole thing when the tap lands in the last word means the
    /// common case — tap the end of it — still accepts everything.
    func accept(throughCharacter index: Int) -> String? {
        let suffix = visibleSuffix
        guard !suffix.isEmpty else { return nil }
        let chars = Array(suffix)
        var end = min(max(index, 0), chars.count - 1)
        // Skip separators under the tap, then run to the end of the word.
        while end < chars.count, chars[end] == " " { end += 1 }
        while end < chars.count, chars[end] != " " { end += 1 }
        guard end > 0 else { return nil }
        let taken = String(chars[0..<end])
        if end >= chars.count {
            current = nil
        } else if var advanced = current {
            // The suggestion continues from where the acceptance ends, so
            // the remainder is still offered after the shell echoes.
            _ = advanced.update(buffer: advanced.snapshot + taken)
            current = advanced
        }
        return taken
    }

    /// Hides the suggestion and remembers not to offer it again.
    func dismiss() {
        if let command = current?.full {
            ignored.insert(command)
            // The cached answer may be the very suggestion just turned down.
            lastPrediction = nil
        }
        current = nil
    }

    /// Drops the suggestion without holding it against the command — what
    /// running something should do.
    func clear() {
        current = nil
    }

    private static let hostname: String = {
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count - 1) == 0 else { return "localhost" }
        return String(cString: buffer)
    }()
}

extension CommandHistoryStore {
    /// The command text for a recorded id, for keying an episode lookup off
    /// what actually went into history rather than re-reading the grid.
    func command(forID id: Int) -> String? {
        record(id: id)?.command
    }
}
