import UIKit

/// A position in a document that does not exist.
///
/// `UITextInput` is written for a view that owns editable text. A terminal
/// owns none: what has been typed belongs to the program on the other end of
/// the pty, which may have echoed it, rewritten it, or thrown it away. So the
/// document here is permanently empty and every position in it is the same
/// one. The arithmetic still has to be consistent, because UIKit compares and
/// offsets these before it decides what to send.
final class TerminalTextPosition: UITextPosition {
    let offset: Int
    init(offset: Int) {
        self.offset = offset
        super.init()
    }
}

final class TerminalTextRange: UITextRange {
    private let from: TerminalTextPosition
    private let to: TerminalTextPosition

    override var start: UITextPosition { from }
    override var end: UITextPosition { to }
    override var isEmpty: Bool { from.offset == to.offset }

    init(from: TerminalTextPosition, to: TerminalTextPosition? = nil) {
        self.from = from
        self.to = to ?? from
        super.init()
    }
}

// MARK: - UITextInput

/// Why a terminal implements a text editing protocol it has no use for.
///
/// The software keyboard's delete key repeats while it is held, and that
/// repeat lives inside UIKit, not in the app: `UIKeyboardImpl` runs the timer
/// and calls the first responder. It only does so for a responder that claims
/// to be a text input. A view that implements `UIKeyInput` alone gets exactly
/// one `deleteBackward()` however long the key is held, which is why leaning
/// on backspace used to erase a single character.
///
/// Conforming makes iOS drive the repeat, so backspace behaves the way it does
/// in every other app on the phone. Everything below is inert: no text is
/// stored, every rect is empty so that UIKit paints no caret or selection over
/// the terminal's own, and every position is the start of a document with
/// nothing in it. `hasText` is the one deliberate lie — it is what keeps the
/// keyboard willing to go on deleting.
extension TerminalHostView: UITextInput {

    // MARK: Text

    func text(in range: UITextRange) -> String? { nil }
    func replace(_ range: UITextRange, withText text: String) {}

    // MARK: Marked and selected text

    func setMarkedText(_ markedText: String?, selectedRange: NSRange) {}
    func unmarkText() {}

    // MARK: Positions

    var beginningOfDocument: UITextPosition { TerminalTextPosition(offset: 0) }
    var endOfDocument: UITextPosition { TerminalTextPosition(offset: 0) }

    func textRange(from: UITextPosition, to: UITextPosition) -> UITextRange? {
        guard let from = from as? TerminalTextPosition,
              let to = to as? TerminalTextPosition else { return nil }
        return TerminalTextRange(from: from, to: to)
    }

    func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
        guard let position = position as? TerminalTextPosition else { return nil }
        return TerminalTextPosition(offset: position.offset + offset)
    }

    func position(from position: UITextPosition,
                  in direction: UITextLayoutDirection,
                  offset: Int) -> UITextPosition? {
        self.position(from: position, offset: offset)
    }

    func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult {
        guard let a = position as? TerminalTextPosition,
              let b = other as? TerminalTextPosition else { return .orderedSame }
        if a.offset < b.offset { return .orderedAscending }
        if a.offset > b.offset { return .orderedDescending }
        return .orderedSame
    }

    func offset(from: UITextPosition, to: UITextPosition) -> Int {
        guard let from = from as? TerminalTextPosition,
              let to = to as? TerminalTextPosition else { return 0 }
        return to.offset - from.offset
    }

    func position(within range: UITextRange,
                  farthestIn direction: UITextLayoutDirection) -> UITextPosition? {
        range.start
    }

    func characterRange(byExtending position: UITextPosition,
                        in direction: UITextLayoutDirection) -> UITextRange? {
        guard let position = position as? TerminalTextPosition else { return nil }
        return TerminalTextRange(from: position)
    }

    // MARK: Writing direction

    func baseWritingDirection(for position: UITextPosition,
                              in direction: UITextStorageDirection) -> NSWritingDirection {
        .natural
    }

    func setBaseWritingDirection(_ writingDirection: NSWritingDirection,
                                 for range: UITextRange) {}

    // MARK: Geometry
    //
    // All empty. The terminal draws its own caret and its own selection, and a
    // second set painted by UIKit on top of them would be a ghost the user
    // cannot get rid of.

    func firstRect(for range: UITextRange) -> CGRect { .zero }
    func caretRect(for position: UITextPosition) -> CGRect { .zero }
    func selectionRects(for range: UITextRange) -> [UITextSelectionRect] { [] }

    func closestPosition(to point: CGPoint) -> UITextPosition? {
        TerminalTextPosition(offset: 0)
    }

    func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? {
        range.start
    }

    func characterRange(at point: CGPoint) -> UITextRange? { nil }

    // MARK: Floating cursor
    //
    // The spacebar trackpad: hold the space key and slide, and the caret walks
    // along the line. iOS offers this to anything that is a text input, and a
    // terminal is where it is wanted most — placing a caret in the middle of a
    // long command with a fingertip is otherwise the worst interaction on the
    // phone, and the reason people retype a line rather than fix it.
    //
    // There is no caret of ours to drag, so the gesture becomes the arrow keys
    // the shell already understands. That is what makes it work everywhere at
    // once: zsh's line editor, vim, a REPL, anything reading the line.

    @objc func beginFloatingCursor(at point: CGPoint) {
        // A key held when the gesture starts would go on repeating underneath
        // it, fighting the drag.
        repeater.stop()
        floatingCursorAnchor = point
    }

    @objc func updateFloatingCursor(at point: CGPoint) {
        guard let anchor = floatingCursorAnchor,
              let owner,
              let step = owner.trackpadStep else { return }

        let (steps, consumed) = TerminalHostView.floatingCursorSteps(
            travelled: point.x - anchor.x, step: step)
        guard steps != 0 else { return }

        // A flick can cross several characters between two touch updates, so
        // the whole distance is spent rather than one step per callback.
        for _ in 0..<abs(steps) {
            owner.sendKey(steps > 0 ? .right : .left)
        }
        floatingCursorAnchor = CGPoint(x: anchor.x + consumed, y: point.y)
    }

    @objc func endFloatingCursor() {
        floatingCursorAnchor = nil
    }

    /// How many characters a drag of `travelled` points is worth, and how much
    /// of that drag those characters spent.
    ///
    /// The remainder stays on the clock deliberately: rounding it away would
    /// lose a fraction of a cell on every touch update, and a slow drag would
    /// move the caret noticeably less far than the finger.
    static func floatingCursorSteps(travelled: CGFloat,
                                    step: CGFloat) -> (steps: Int, consumed: CGFloat) {
        guard step > 0 else { return (0, 0) }
        let steps = Int((travelled / step).rounded(.towardZero))
        return (steps, CGFloat(steps) * step)
    }
}
