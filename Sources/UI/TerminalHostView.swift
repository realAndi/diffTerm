import UIKit

/// The first responder for a pane. Owns keyboard handling for both the
/// software keyboard (via `UIKeyInput`) and hardware keyboards (via key
/// presses), and supplies the accessory key row.
final class TerminalHostView: UIView, UIKeyInput, UITextInputTraits {

    weak var owner: TerminalPaneController?

    // MARK: - Text input plumbing
    //
    // The stored half of the `UITextInput` conformance, which lives in
    // TerminalTextInput.swift and exists so that iOS drives the software
    // keyboard's delete-key repeat. A protocol's stored properties cannot be
    // added in an extension, so they are here.

    weak var inputDelegate: UITextInputDelegate?
    var selectedTextRange: UITextRange?
    var markedTextRange: UITextRange?
    var markedTextStyle: [NSAttributedString.Key: Any]?
    /// Built on first use: it needs `self`, which does not exist while the
    /// stored properties are being initialised.
    lazy var tokenizer: UITextInputTokenizer = UITextInputStringTokenizer(textInput: self)

    /// Where the floating cursor was when it last moved the caret, not where
    /// the gesture began: the leftover fraction of a cell has to carry across
    /// touch updates or a slow drag falls behind the finger.
    var floatingCursorAnchor: CGPoint?

    override var canBecomeFirstResponder: Bool { true }
    override var canResignFirstResponder: Bool { true }

    // MARK: - Input traits
    //
    // Everything that "helps" while writing prose actively harms while typing
    // shell commands, so all of it is off.

    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var keyboardType: UIKeyboardType = .asciiCapable
    var keyboardAppearance: UIKeyboardAppearance = .default
    var returnKeyType: UIReturnKeyType = .default
    var enablesReturnKeyAutomatically: Bool = false
    var isSecureTextEntry: Bool = false
    var textContentType: UITextContentType! = nil

    // MARK: - Accessory

    override var inputAccessoryView: UIView? {
        guard let owner, owner.wantsKeyRow else { return nil }
        return owner.makeKeyRow()
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        owner?.hostViewFocusChanged(isFocused: result)
        return result
    }

    override func resignFirstResponder() -> Bool {
        // Nothing will report the release of a key held while focus moves.
        repeater.stop()
        let result = super.resignFirstResponder()
        owner?.hostViewFocusChanged(isFocused: !result ? true : false)
        return result
    }

    // MARK: - UIKeyInput

    /// Guards against a hardware key being delivered twice: once as a press
    /// and again as text insertion. Which of the two paths fires depends on
    /// the keyboard and iOS version, so we accept either and drop duplicates.
    private var lastHardwareText: (text: String, time: CFTimeInterval)?

    func insertText(_ text: String) {
        if let last = lastHardwareText,
           last.text == text,
           CACurrentMediaTime() - last.time < 0.08 {
            lastHardwareText = nil
            return
        }
        guard let owner else { return }
        if text == "\n" {
            owner.sendKey(.enter)
        } else {
            owner.sendText(text)
        }
    }

    func deleteBackward() {
        owner?.sendKey(.backspace)
    }

    /// UIKit asks before each repeat of the delete key, and stops when the
    /// answer is no. There is no document to be empty, so the answer is always
    /// yes; what happens to a backspace at the start of a line is the shell's
    /// business, not ours.
    var hasText: Bool { true }

    // MARK: - Hardware keys

    /// UIKit reports a hardware key once, however long it is held: there is no
    /// repeat in `pressesBegan` the way there is in the text path. Arrows and
    /// backspace would therefore move exactly one cell per press, so the
    /// repeat is run here instead.
    let repeater = KeyRepeater()

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handledAny = false
        for press in presses {
            guard let key = press.key else { continue }
            if handle(key: key) { handledAny = true }
        }
        if !handledAny {
            super.pressesBegan(presses, with: event)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            guard let key = press.key else { continue }
            repeater.stop(key.keyCode.rawValue)
        }
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            guard let key = press.key else { continue }
            repeater.stop(key.keyCode.rawValue)
        }
        super.pressesCancelled(presses, with: event)
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil { repeater.stop() }
    }

    private func handle(key: UIKey) -> Bool {
        guard let owner else { return false }

        var modifiers: KeyModifiers = []
        if key.modifierFlags.contains(.shift)     { modifiers.insert(.shift) }
        if key.modifierFlags.contains(.alternate) { modifiers.insert(.alt) }
        if key.modifierFlags.contains(.control)   { modifiers.insert(.control) }
        if key.modifierFlags.contains(.command)   { modifiers.insert(.command) }

        // Command combinations belong to the app, not the shell; they are
        // declared as key commands so they also appear in the iPad menu.
        if modifiers.contains(.command) { return false }

        if let special = TerminalHostView.specialKey(for: key.keyCode) {
            let extra = modifiers.subtracting(.command)
            owner.sendKey(special, extraModifiers: extra)
            // A second press of a key that is already down is iOS repeating it
            // for us, on the keyboards and versions that do. Stand aside
            // rather than send everything twice.
            if repeater.isHolding(key.keyCode.rawValue) {
                repeater.stop()
            } else if special.repeatsWhenHeld {
                repeater.begin(key.keyCode.rawValue) { [weak owner] in
                    owner?.sendKey(special, extraModifiers: extra)
                }
            } else {
                repeater.stop()
            }
            return true
        }

        let characters = key.charactersIgnoringModifiers
        guard !characters.isEmpty else { return false }

        // A bare modifier press reports an empty string on some layouts and a
        // control character on others; neither should reach the shell.
        if characters.unicodeScalars.count == 1,
           let scalar = characters.unicodeScalars.first,
           scalar.value < 0x20, !modifiers.contains(.control) {
            return false
        }

        if !modifiers.contains(.control) && !modifiers.contains(.alt) {
            // Plain typing: let the text input path handle it so that dead
            // keys and IME composition keep working.
            lastHardwareText = (key.characters, CACurrentMediaTime())
            guard !key.characters.isEmpty else { return false }
            // Typing while an arrow is held hands the repeat to the new key,
            // as it would on any keyboard — and characters repeat through the
            // text path on their own, so nothing takes it up here.
            repeater.stop()
            owner.sendText(key.characters)
            return true
        }

        repeater.stop()
        owner.sendText(characters, extraModifiers: modifiers)
        return true
    }

    private static func specialKey(for code: UIKeyboardHIDUsage) -> SpecialKey? {
        switch code {
        case .keyboardUpArrow:          return .up
        case .keyboardDownArrow:        return .down
        case .keyboardLeftArrow:        return .left
        case .keyboardRightArrow:       return .right
        case .keyboardHome:             return .home
        case .keyboardEnd:              return .end
        case .keyboardPageUp:           return .pageUp
        case .keyboardPageDown:         return .pageDown
        case .keyboardInsert:           return .insert
        case .keyboardDeleteForward:    return .delete
        case .keyboardDeleteOrBackspace:return .backspace
        case .keyboardReturnOrEnter:    return .enter
        case .keypadEnter:              return .keypadEnter
        case .keyboardTab:              return .tab
        case .keyboardEscape:           return .escape
        case .keyboardF1:  return .f(1)
        case .keyboardF2:  return .f(2)
        case .keyboardF3:  return .f(3)
        case .keyboardF4:  return .f(4)
        case .keyboardF5:  return .f(5)
        case .keyboardF6:  return .f(6)
        case .keyboardF7:  return .f(7)
        case .keyboardF8:  return .f(8)
        case .keyboardF9:  return .f(9)
        case .keyboardF10: return .f(10)
        case .keyboardF11: return .f(11)
        case .keyboardF12: return .f(12)
        default: return nil
        }
    }

    // MARK: - Command shortcuts

    override var keyCommands: [UIKeyCommand]? {
        owner?.paneKeyCommands
    }
}
