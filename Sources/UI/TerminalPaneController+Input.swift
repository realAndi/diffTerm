import UIKit
import AudioToolbox

// MARK: - Focus

extension TerminalPaneController {

    func hostViewFocusChanged(isFocused: Bool) {
        terminalView?.isInputFocused = isFocused
        if isFocused { delegate?.paneDidBecomeActive(self) }
    }
}

// MARK: - Scrolling

extension TerminalPaneController: UIScrollViewDelegate {

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard terminalView != nil else { return }
        let y = max(0, scrollView.contentOffset.y)
        terminalView.frame.origin.y = y
        terminalView.scrollOffset = y

        let distanceFromBottom = max(0, scrollView.contentSize.height
                                     - scrollView.bounds.height - scrollView.contentOffset.y)
        // A couple of pixels of slack keeps rubber-banding from counting as
        // "scrolled back".
        isPinnedToBottomInternal = distanceFromBottom < 2
    }
}

// MARK: - Terminal view geometry

extension TerminalPaneController: TerminalViewDelegate {

    func terminalViewDidChangeGeometry(_ view: TerminalView) {
        recomputeTerminalSizeFromView()
    }
}

// MARK: - Session

extension TerminalPaneController: TerminalSessionDelegate {

    func sessionDidUpdateTitle(_ session: TerminalSession) {
        delegate?.pane(self, didUpdateTitle: session.displayTitle)
    }

    func sessionDidRing(_ session: TerminalSession) {
        switch Preferences.shared.bell {
        case .none:
            break
        case .haptic:
            let generator = UIImpactFeedbackGenerator(style: .medium)
            generator.prepare()
            generator.impactOccurred()
        case .visual:
            flashScreen()
        case .sound:
            AudioBell.shared.play()
        }
    }

    func session(_ session: TerminalSession, didExitWith code: Int32) {
        delegate?.paneDidFinish(self, exitCode: code)
    }

    func session(_ session: TerminalSession, didFailToStart error: Error) {
        // The message has already been written into the terminal, which is
        // where someone debugging a shell problem will look for it.
    }

    func sessionDidProduceOutput(_ session: TerminalSession) {
        syncAfterOutput()
    }

    func session(_ session: TerminalSession, didRequestClipboardWrite text: String) {
        UIPasteboard.general.string = text
    }

    func sessionPaletteDidChange(_ session: TerminalSession) {
        refreshPalette()
    }
}

// MARK: - Key row

extension TerminalPaneController: KeyRowViewDelegate {

    func keyRow(_ view: KeyRowView, didTrigger action: KeyRowAction) {
        switch action {
        case .special(let id):
            sendKey(id.key)
        case .text(let text):
            sendText(text)
        case .modifier(let modifier):
            toggleModifier(modifier)
        case .combo(let modifiers, let base):
            switch base {
            case .special(let id): sendKey(id.key, extraModifiers: modifiers)
            case .character(let text): sendText(text, extraModifiers: modifiers)
            }
        case .dismissKeyboard:
            _ = view.resignFirstResponder()
            resignPaneFirstResponder()
        case .snippets:
            presentSnippets()
        case .toggleFunctionKeys:
            break
        }
    }

    func keyRowActiveModifiers(_ view: KeyRowView) -> KeyModifiers { armedModifiersPublic }
    func keyRowLockedModifiers(_ view: KeyRowView) -> KeyModifiers { lockedModifiersPublic }
}

// MARK: - Gestures

extension TerminalPaneController: UIGestureRecognizerDelegate {

    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // The pinch-to-resize gesture must not fight the scroll view.
        if g is UIPinchGestureRecognizer || other is UIPinchGestureRecognizer { return true }
        return false
    }

    func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        if g is UILongPressGestureRecognizer, terminalView.selection != nil {
            // Let a long press inside an existing selection fall through to
            // the edit menu rather than starting a new selection.
            return true
        }
        return true
    }
}

// MARK: - Edit menu

@available(iOS 16.0, *)
extension TerminalPaneController: UIEditMenuInteractionDelegate {

    func editMenuInteraction(_ interaction: UIEditMenuInteraction,
                             menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        var actions: [UIAction] = []

        if let selection = terminalView.selection, !selection.isEmpty {
            actions.append(UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                self?.copySelection()
                self?.clearSelection()
            })
        }

        if UIPasteboard.general.hasStrings {
            actions.append(UIAction(title: "Paste", image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in
                self?.pasteFromClipboard()
            })
        }

        if let block = commandBlock(at: configuration.sourcePoint),
           selection(forOutputOf: block) != nil {
            actions.append(UIAction(title: "Copy Command Output",
                                    image: UIImage(systemName: "text.alignleft")) { [weak self] _ in
                self?.copyOutput(of: block)
            })
            actions.append(UIAction(title: "Select Command Output",
                                    image: UIImage(systemName: "selection.pin.in.out")) { [weak self] _ in
                self?.selectOutput(of: block)
            })
        }

        let position = terminalView.gridPosition(at: configuration.sourcePoint)
        if let link = terminalView.link(at: position) {
            actions.append(UIAction(title: "Open Link", image: UIImage(systemName: "safari")) { [weak self] _ in
                self?.confirmOpen(link)
            })
            actions.append(UIAction(title: "Copy Link", image: UIImage(systemName: "link")) { _ in
                UIPasteboard.general.string = link
            })
        }

        actions.append(UIAction(title: "Select All", image: UIImage(systemName: "selection.pin.in.out")) { [weak self] _ in
            self?.selectAllText()
        })

        actions.append(UIAction(title: "Find", image: UIImage(systemName: "magnifyingglass")) { [weak self] _ in
            self?.showSearch()
        })

        return UIMenu(children: actions)
    }
}

// MARK: - Command shortcuts

extension TerminalPaneController {

    var paneKeyCommands: [UIKeyCommand] {
        func command(_ title: String, _ input: String,
                     _ flags: UIKeyModifierFlags, _ selector: Selector) -> UIKeyCommand {
            let c = UIKeyCommand(title: title, action: selector, input: input, modifierFlags: flags)
            if #available(iOS 15.0, *) { c.wantsPriorityOverSystemBehavior = true }
            return c
        }

        var commands: [UIKeyCommand] = [
            command("Copy", "c", .command, #selector(copySelection)),
            command("Paste", "v", .command, #selector(pasteFromClipboard)),
            command("Select All", "a", .command, #selector(selectAllText)),
            command("Clear", "k", .command, #selector(clearScreen)),
            command("Reset Terminal", "r", .command, #selector(resetTerminal)),
            command("Find", "f", .command, #selector(commandFind)),
            command("New Tab", "t", .command, #selector(commandNewTab)),
            command("Close Tab", "w", .command, #selector(commandCloseTab)),
            command("Split Right", "d", .command, #selector(commandSplitVertical)),
            command("Split Down", "d", [.command, .shift], #selector(commandSplitHorizontal)),
            command("Next Tab", "]", [.command, .shift], #selector(commandNextTab)),
            command("Previous Tab", "[", [.command, .shift], #selector(commandPreviousTab)),
            command("Settings", ",", .command, #selector(commandSettings)),
            command("Bigger Text", "+", .command, #selector(commandIncreaseFontSize)),
            command("Bigger Text", "=", .command, #selector(commandIncreaseFontSize)),
            command("Smaller Text", "-", .command, #selector(commandDecreaseFontSize)),
            command("Previous Prompt", UIKeyCommand.inputUpArrow, .command,
                    #selector(commandPreviousPrompt)),
            command("Next Prompt", UIKeyCommand.inputDownArrow, .command,
                    #selector(commandNextPrompt)),
            command("Copy Last Output", "c", [.command, .shift],
                    #selector(copyLastCommandOutput)),
        ]

        for i in 1...9 {
            commands.append(command("Tab \(i)", "\(i)", .command, #selector(commandSelectTab(_:))))
        }
        return commands
    }

    @objc func commandFind() { showSearch() }
    @objc func commandNewTab() { delegate?.paneDidRequestNewTab(self) }
    @objc func commandCloseTab() { delegate?.paneDidRequestClose(self) }
    @objc func commandSplitVertical() { delegate?.paneDidRequestSplit(self, vertical: true) }
    @objc func commandSplitHorizontal() { delegate?.paneDidRequestSplit(self, vertical: false) }
    @objc func commandNextTab() { delegate?.paneDidRequestNextTab(self) }
    @objc func commandPreviousTab() { delegate?.paneDidRequestPreviousTab(self) }
    @objc func commandSettings() { delegate?.paneDidRequestSettings(self) }

    @objc func commandIncreaseFontSize() {
        Preferences.shared.fontSize = Preferences.shared.fontSize + 1
    }

    @objc func commandDecreaseFontSize() {
        Preferences.shared.fontSize = Preferences.shared.fontSize - 1
    }

    @objc func commandSelectTab(_ sender: UIKeyCommand) {
        guard let input = sender.input, let index = Int(input) else { return }
        delegate?.pane(self, didRequestTabAtIndex: index - 1)
    }
}

/// The terminal bell, played through the system sound services so that it
/// respects the ringer switch like every other UI sound.
final class AudioBell {
    static let shared = AudioBell()
    private var lastPlayed = Date.distantPast

    func play() {
        // Rate-limit: a program printing BEL in a loop should not be able to
        // make the device buzz continuously.
        guard Date().timeIntervalSince(lastPlayed) > 0.2 else { return }
        lastPlayed = Date()
        AudioServicesPlaySystemSound(1057)
    }
}
