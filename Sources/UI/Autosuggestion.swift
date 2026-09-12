import Foundation

/// The life of one ghost-text suggestion.
///
/// The rules are the ones that stop a suggestion feeling like a twitch:
///
/// - It must start with what is already typed, and only the remainder is
///   drawn. Ghost text that contradicts the line is worse than none.
/// - Typing that agrees with the suggestion **shrinks** it rather than
///   recomputing it. That is what keeps it from flickering as it is typed out.
/// - Typing that diverges hides it but keeps it, so backing up brings it back
///   without another lookup.
/// - Visible ghost text is never swapped for different ghost text. A
///   suggestion that changes under the cursor is unreadable.
struct Autosuggestion: Equatable {

    /// The whole command being suggested.
    let full: String
    /// What was on the input line when it was computed.
    private(set) var snapshot: String
    /// Whether it is currently drawn. False after divergence, until the line
    /// agrees with it again.
    private(set) var isVisible: Bool
    let source: NextCommandPredictor.Source

    init?(full: String, buffer: String, source: NextCommandPredictor.Source) {
        guard full.hasPrefix(buffer), full.count > buffer.count else { return nil }
        self.full = full
        self.snapshot = buffer
        self.isVisible = true
        self.source = source
    }

    /// The part drawn after the cursor.
    var suffix: String {
        guard isVisible, full.hasPrefix(snapshot) else { return "" }
        return String(full.dropFirst(snapshot.count))
    }

    /// Re-points the suggestion at a changed input line.
    ///
    /// Returns false when the suggestion is spent — the line has moved past
    /// it, or matched it exactly — and the caller should drop it and look
    /// again.
    mutating func update(buffer: String) -> Bool {
        if buffer == full {
            // Fully typed out by hand. Nothing left to offer.
            return false
        }
        if full.hasPrefix(buffer) {
            snapshot = buffer
            isVisible = true
            return true
        }
        // Diverged. Keep it — a backspace often brings it straight back — but
        // stop drawing it.
        isVisible = false
        return !buffer.isEmpty && full.hasPrefix(String(buffer.prefix(1)))
    }
}
