import UIKit
import AudioToolbox

protocol TerminalPaneDelegate: AnyObject {
    func paneDidRequestClose(_ pane: TerminalPaneController)
    /// The shell exited. The container decides whether that closes the pane,
    /// because only it knows whether there are siblings to fall back to.
    func paneDidFinish(_ pane: TerminalPaneController, exitCode: Int32)
    func paneDidBecomeActive(_ pane: TerminalPaneController)
    func pane(_ pane: TerminalPaneController, didUpdateTitle title: String)
    func paneDidRequestNewTab(_ pane: TerminalPaneController)
    func paneDidRequestSplit(_ pane: TerminalPaneController, vertical: Bool)
    func paneDidRequestSettings(_ pane: TerminalPaneController)
    func paneDidRequestNextTab(_ pane: TerminalPaneController)
    func paneDidRequestPreviousTab(_ pane: TerminalPaneController)
    func pane(_ pane: TerminalPaneController, didRequestTabAtIndex index: Int)
}

/// A single terminal: scroll view, grid, keyboard handling, selection.
final class TerminalPaneController: UIViewController {

    weak var delegate: TerminalPaneDelegate?

    let session: TerminalSession
    private(set) var terminalView: TerminalView!
    private let scrollView = ScrollCapturingScrollView()
    private var hostView: TerminalHostView { view as! TerminalHostView }

    private var keyRow: KeyRowView?
    private let searchBar = TerminalSearchBar()

    /// Modifiers armed by the on-screen key row: `armed` applies to the next
    /// key only, `locked` stays until tapped off.
    private var armedModifiers: KeyModifiers = []
    private var lockedModifiers: KeyModifiers = []
    private var lastModifierTap: (modifier: KeyModifiers, time: TimeInterval)?
    private var lastKeyHaptic: CFTimeInterval = 0

    private var currentFont: TerminalFont!
    private var palette: TerminalPalette!

    private var selectionOrigin: GridPosition?
    /// Typed `Any?` because `UIEditMenuInteraction` is iOS 16 and the floor
    /// is 14; older systems get `UIMenuController` instead.
    private var editMenuInteraction: Any?

    /// The link the pre-16 menu was raised on. `UIMenuItem` carries a bare
    /// selector with nowhere to put an argument, so it has to be stashed.
    private var legacyMenuLink: String?

    private var pinchStartFontSize: CGFloat = 13

    /// Set while the user is scrolled up, so output does not yank the view.
    var isPinnedToBottomInternal = true

    /// Last seen eviction count, to convert "lines aged out of the ring" into
    /// the offset correction that keeps scrolled-back text under the finger.
    private var lastScrollbackEvicted = 0

    private var bellFeedback: UIImpactFeedbackGenerator?
    private var flashView: UIView?

    /// Extra scrollable height reserved below the buffer so a suggestion that
    /// wraps past the last visible row is not clipped. See setGhostText.
    private var ghostOverflowHeight: CGFloat = 0

    /// Command blocks the user has folded, by stable prompt row. Held here
    /// so it survives a view rebuild, and pushed to the view to lay out.
    private var collapsedBlocks: Set<Int> = [] {
        didSet { terminalView?.collapsedBlocks = collapsedBlocks }
    }

    /// Ghost text: what to suggest next, and the history it learns from.
    private(set) lazy var suggestions = SuggestionEngine(sessionKey: session.identifier.uuidString)

    /// Find-in-scrollback state.
    var searchMatches: [TerminalSelection] = []
    var searchIndex: Int?

    // MARK: - Init

    init(session: TerminalSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
        session.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        view = TerminalHostView()
        hostView.owner = self
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        rebuildAppearance()

        terminalView = TerminalView(font: currentFont, palette: palette)
        terminalView.geometryDelegate = self
        // The view exists now, so the preferences that live on it can finally
        // be applied. See `applyViewPreferences`.
        applyViewPreferences()

        scrollView.alwaysBounceVertical = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.delegate = self
        scrollView.shouldCaptureTouches = { [weak self] in
            // While a program tracks the pointer, dragging belongs to it.
            guard let self else { return true }
            return self.session.emulator.modes.mouseTracking == .none
        }
        scrollView.keyboardDismissMode = .none
        scrollView.addSubview(terminalView)
        view.addSubview(scrollView)

        searchBar.isHidden = true
        searchBar.delegate = self
        view.addSubview(searchBar)

        installGestures()

        if #available(iOS 16.0, *) {
            let interaction = UIEditMenuInteraction(delegate: self)
            terminalView.addInteraction(interaction)
            editMenuInteraction = interaction
        }

        session.attach(view: terminalView)

        NotificationCenter.default.addObserver(
            self, selector: #selector(preferencesChanged),
            name: Preferences.didChangeNotification, object: nil)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        let insets = view.safeAreaInsets
        var frame = view.bounds
        frame.origin.x += insets.left
        frame.size.width -= insets.left + insets.right
        scrollView.frame = frame

        // The grid view is always viewport-sized; see TerminalView for why.
        terminalView.frame = CGRect(x: 0, y: scrollView.contentOffset.y,
                                    width: scrollView.bounds.width,
                                    height: scrollView.bounds.height)
        terminalView.layoutIfNeeded()

        searchBar.frame = CGRect(x: frame.minX, y: view.safeAreaInsets.top,
                                 width: frame.width, height: 44)

        syncScrollGeometry(keepAtBottom: isPinnedToBottomInternal)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if session.exitCode == nil && !session.isRunning { session.start() }
        becomeFirstResponderIfPossible()
    }

    override var canBecomeFirstResponder: Bool { true }

    @discardableResult
    func becomeFirstResponderIfPossible() -> Bool {
        hostView.becomeFirstResponder()
    }

    // MARK: - Appearance

    private func rebuildAppearance() {
        let prefs = Preferences.shared
        let theme = prefs.theme(for: traitCollection.userInterfaceStyle)
        let scale = view.window?.screen.scale ?? UIScreen.main.scale

        currentFont = TerminalFont(familyName: prefs.fontName,
                                   pointSize: prefs.fontSize,
                                   lineHeightScale: prefs.lineHeightScale,
                                   scale: scale)
        palette = TerminalPalette(theme: theme,
                                  paletteOverrides: session.emulator.paletteOverrides,
                                  foregroundOverride: session.emulator.overrideForeground,
                                  backgroundOverride: session.emulator.overrideBackground,
                                  cursorOverride: session.emulator.overrideCursorColor)

        view.backgroundColor = palette.defaultBackground.uiColor
        scrollView.backgroundColor = palette.defaultBackground.uiColor
        scrollView.indicatorStyle = theme.isDark ? .white : .black

        applyViewPreferences()
    }

    /// The half of `rebuildAppearance` that needs the terminal view.
    ///
    /// Split out because `rebuildAppearance` runs once *before* the view
    /// exists — it is what computes the font the view is then built with — so
    /// on that first pass every one of these assignments went to nil and was
    /// silently dropped. That was survivable only for as long as every one of
    /// these preferences happened to default to the same value the view
    /// already had; `blockMode` does not, and blocks stayed off at every
    /// launch until some unrelated setting was changed.
    private func applyViewPreferences() {
        guard let terminalView else { return }
        let prefs = Preferences.shared
        terminalView.update(font: currentFont)
        terminalView.update(palette: palette)
        terminalView.boldIsBright = prefs.boldIsBright
        terminalView.useBoldFont = prefs.useBoldFont
        terminalView.preferredCursorShape = prefs.cursorShape
        terminalView.blockMode = prefs.blockMode
        // Tell a program that asked (DEC 2031) which way the theme reads, and
        // let it re-theme live when the user switches between light and dark.
        let theme = prefs.theme(for: traitCollection.userInterfaceStyle)
        session.emulator.colorSchemeChanged(isDark: theme.isDark)
        // A program that has not expressed an opinion follows the user's.
        if session.emulator.modes.cursorShape == .block && prefs.cursorShape != .block {
            session.emulator.modes.cursorShape = prefs.cursorShape
        }
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        if previous?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            rebuildAppearance()
            syncScrollGeometry(keepAtBottom: isPinnedToBottomInternal)
        }
    }

    @objc private func preferencesChanged() {
        rebuildAppearance()
        session.applyPreferences()
        keyRow?.rebuild()
        updateKeyRowVisibility()
        syncScrollGeometry(keepAtBottom: isPinnedToBottomInternal)
        recomputeTerminalSize()
    }

    // MARK: - Geometry

    private func recomputeTerminalSize() {
        let cols = terminalView.visibleCols
        let rows = terminalView.visibleRows
        guard cols > 0, rows > 0 else { return }
        session.resize(cols: cols, rows: rows,
                       pixelWidth: CGFloat(cols) * terminalView.cellSize.width,
                       pixelHeight: CGFloat(rows) * terminalView.cellSize.height)
        syncScrollGeometry(keepAtBottom: isPinnedToBottomInternal)
    }

    private func syncScrollGeometry(keepAtBottom: Bool) {
        updateContentSize()
        if keepAtBottom {
            scrollToBottom(animated: false)
        } else {
            updateTerminalOffset()
        }
    }

    /// The scroll view's content is the whole buffer, so its height has to
    /// track `totalRows`.
    private func updateContentSize() {
        guard terminalView != nil, scrollView.bounds.height > 0 else { return }
        let height = max(terminalView.contentHeight + ghostOverflowHeight, scrollView.bounds.height)
        let newSize = CGSize(width: scrollView.bounds.width, height: height)
        if scrollView.contentSize != newSize {
            scrollView.contentSize = newSize
        }
    }

    /// Runs after every batch of output. Output does not invalidate layout, so
    /// without this the scroll view keeps the content height it had at the
    /// last layout pass — at launch, exactly the viewport — and nothing
    /// printed since can be scrolled back to. Full-screen TUIs that never
    /// trigger a layout pass, Claude Code among them, hit that hardest.
    func syncAfterOutput() {
        guard terminalView != nil, scrollView.bounds.height > 0 else { return }

        let evicted = session.emulator.buffer.scrollbackEvicted
        let dropped = evicted - lastScrollbackEvicted
        lastScrollbackEvicted = evicted

        updateContentSize()

        if isPinnedToBottomInternal {
            // A drag in progress owns the offset. Snapping back mid-gesture is
            // what makes a terminal feel like it is fighting the user.
            guard !scrollView.isDragging, !scrollView.isDecelerating else { return }
            scrollToBottom(animated: false)
        } else if dropped > 0 {
            // Lines aged out of the top of the ring, so everything below them
            // moved up by exactly that much. Move with it, rather than letting
            // the view drift through text someone is reading.
            let shift = CGFloat(dropped) * terminalView.cellSize.height
            scrollView.contentOffset.y =
                min(max(0, scrollView.contentOffset.y - shift), maxContentOffsetY)
        } else {
            updateTerminalOffset()
        }

        refreshSuggestion()
    }

    private var maxContentOffsetY: CGFloat {
        max(0, scrollView.contentSize.height - scrollView.bounds.height)
    }

    func scrollToBottom(animated: Bool) {
        updateContentSize()
        let target = CGPoint(x: 0, y: maxContentOffsetY)
        if animated {
            scrollView.setContentOffset(target, animated: true)
        } else {
            scrollView.contentOffset = target
            updateTerminalOffset()
        }
        isPinnedToBottomInternal = true
    }

    private func updateTerminalOffset() {
        let y = max(0, scrollView.contentOffset.y)
        terminalView.frame.origin.y = y
        terminalView.scrollOffset = y
    }

    /// Sets the ghost text and reserves room for it.
    ///
    /// A suggestion that wraps past the last visible row used to be clipped:
    /// the continuation belongs on a row the buffer does not have yet (you
    /// have not typed it), and it fell below the viewport. Reserving that many
    /// rows of scroll space below the content, and — while pinned to the
    /// bottom — scrolling into it, floats the input line up just enough that
    /// the whole suggestion shows. The reserved space vanishes when the ghost
    /// shrinks or clears, so nothing lingers.
    func setGhostText(_ text: String) {
        guard terminalView != nil, terminalView.ghostText != text else { return }
        terminalView.ghostText = text
        let previous = ghostOverflowHeight
        ghostOverflowHeight = ghostOverflowReservation()
        guard ghostOverflowHeight != previous else { return }
        updateContentSize()
        if isPinnedToBottomInternal { scrollToBottom(animated: false) }
    }

    /// How much vertical space the current ghost needs below the last grid
    /// row, in points. Zero unless pinned to the bottom (typing at the live
    /// prompt), where the clipping happens.
    private func ghostOverflowReservation() -> CGFloat {
        guard let view = terminalView, isPinnedToBottomInternal, !view.ghostText.isEmpty else { return 0 }
        let e = session.emulator
        let cols = max(1, e.cols)
        var col = e.buffer.cursorX
        var rowsBelowCursor = 0
        for _ in view.ghostText {
            if col >= cols { col = 0; rowsBelowCursor += 1 }
            col += 1
        }
        let ghostBottomRow = e.buffer.cursorY + rowsBelowCursor
        let overflowRows = max(0, ghostBottomRow - (e.rows - 1))
        return CGFloat(overflowRows) * view.cellSize.height
    }

    // MARK: - Key row

    func makeKeyRow() -> KeyRowView {
        if let keyRow { return keyRow }
        let row = KeyRowView()
        row.delegate = self
        keyRow = row
        return row
    }

    private func updateKeyRowVisibility() {
        hostView.reloadInputViews()
    }

    var wantsKeyRow: Bool { Preferences.shared.showKeyRow }

    // MARK: - Gestures

    private func installGestures() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.delegate = self
        terminalView.addGestureRecognizer(tap)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.delegate = self
        terminalView.addGestureRecognizer(doubleTap)
        tap.require(toFail: doubleTap)

        let tripleTap = UITapGestureRecognizer(target: self, action: #selector(handleTripleTap(_:)))
        tripleTap.numberOfTapsRequired = 3
        tripleTap.delegate = self
        terminalView.addGestureRecognizer(tripleTap)
        doubleTap.require(toFail: tripleTap)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.35
        longPress.delegate = self
        terminalView.addGestureRecognizer(longPress)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        terminalView.addGestureRecognizer(pinch)

        // Two-finger pan scrolls whatever owns the screen — a mouse-tracking
        // program or the alternate screen — so the one-finger scroll gesture
        // keeps working the way iOS users expect.
        let mousePan = UIPanGestureRecognizer(target: self, action: #selector(handleMousePan(_:)))
        mousePan.minimumNumberOfTouches = 2
        mousePan.maximumNumberOfTouches = 2
        mousePan.delegate = self
        terminalView.addGestureRecognizer(mousePan)
    }

    private func gridPosition(for recognizer: UIGestureRecognizer) -> GridPosition {
        terminalView.gridPosition(at: recognizer.location(in: terminalView))
    }

    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        if !session.isRunning, session.exitCode != nil {
            restartSession()
            return
        }
        if handleSuggestionTap(at: g.location(in: terminalView)) { return }
        if let block = terminalView.blockForGutterTap(at: g.location(in: terminalView),
                                                      emulator: session.emulator) {
            toggleCollapse(of: block)
            return
        }
        if session.emulator.modes.mouseTracking != .none {
            sendMouse(kind: .press, at: gridPosition(for: g))
            sendMouse(kind: .release, at: gridPosition(for: g))
            return
        }
        if terminalView.selection != nil {
            clearSelection()
            return
        }
        if let link = terminalView.link(at: gridPosition(for: g)) {
            confirmOpen(link)
            return
        }
        becomeFirstResponderIfPossible()
    }

    /// Everything on screen arrived as bytes from somewhere — a program, a
    /// pipe, the far end of an ssh session — so a link in a terminal is
    /// untrusted by construction. OSC 8 makes that concrete: the text can read
    /// "apple.com" while the target is anywhere at all. So: never open on a
    /// tap alone, and show the address that will actually be opened rather
    /// than the words that were clicked.
    func confirmOpen(_ link: String) {
        guard let url = URL(string: link),
              let scheme = url.scheme?.lowercased(),
              ["http", "https", "file", "mailto", "ftp"].contains(scheme) else { return }

        var target = url.absoluteString
        if target.count > 200 { target = String(target.prefix(200)) + "…" }

        let inSafari = scheme == "http" || scheme == "https"
        let alert = UIAlertController(title: inSafari ? "Open in Safari?" : "Open Link?",
                                      message: target,
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Open", style: .default) { _ in
            UIApplication.shared.open(url)
        })
        alert.addAction(UIAlertAction(title: "Copy Link", style: .default) { _ in
            UIPasteboard.general.string = link
        })
        present(alert, animated: true)
    }

    @objc private func handleDoubleTap(_ g: UITapGestureRecognizer) {
        guard session.emulator.modes.mouseTracking == .none else { return }
        let position = gridPosition(for: g)
        guard let word = terminalView.wordRange(at: position) else { return }
        setSelection(word, showMenu: true, at: g.location(in: terminalView))
    }

    @objc private func handleTripleTap(_ g: UITapGestureRecognizer) {
        guard session.emulator.modes.mouseTracking == .none else { return }
        let position = gridPosition(for: g)
        let buffer = session.emulator.buffer
        guard position.row >= 0, position.row < buffer.totalRows else { return }
        // Extend across wrapped rows so a long command line selects whole.
        var start = position.row
        while start > 0, buffer.row(at: start - 1).wrapped { start -= 1 }
        var end = position.row
        while end + 1 < buffer.totalRows, buffer.row(at: end).wrapped { end += 1 }
        let selection = TerminalSelection(
            anchor: GridPosition(row: start, col: 0),
            head: GridPosition(row: end, col: buffer.row(at: end).count))
        setSelection(selection, showMenu: true, at: g.location(in: terminalView))
    }

    /// Folds or unfolds a block's output. Tapping its rail is how Warp does
    /// it, and on a phone it is the difference between one command filling the
    /// screen and a scannable list of them.
    private func toggleCollapse(of block: CommandBlock) {
        let key = block.promptStart
        if collapsedBlocks.contains(key) { collapsedBlocks.remove(key) }
        else { collapsedBlocks.insert(key) }
        UISelectionFeedbackGenerator().selectionChanged()
        // Setting the view's collapsed set rebuilds the layout and fires a
        // geometry pass, which resizes the scroll content to match — so there
        // is nothing more to do here.
    }

    @objc private func handleLongPress(_ g: UILongPressGestureRecognizer) {
        let point = g.location(in: terminalView)
        let position = terminalView.gridPosition(at: point)

        switch g.state {
        case .began:
            if let block = terminalView.blockForGutterTap(at: point, emulator: session.emulator) {
                presentBlockMenu(for: block, at: point)
                return
            }
            if session.emulator.modes.mouseTracking != .none {
                sendMouse(kind: .press, at: position)
                return
            }
            selectionOrigin = position
            let word = terminalView.wordRange(at: position)
            let selection = word ?? TerminalSelection(anchor: position,
                                                      head: GridPosition(row: position.row, col: position.col + 1))
            selectionOrigin = selection.anchor
            terminalView.selection = selection
            UISelectionFeedbackGenerator().selectionChanged()

        case .changed:
            if session.emulator.modes.mouseTracking != .none {
                sendMouse(kind: .drag, at: position)
                return
            }
            guard let origin = selectionOrigin else { return }
            terminalView.selection = TerminalSelection(anchor: origin, head: position)

        case .ended, .cancelled, .failed:
            if session.emulator.modes.mouseTracking != .none {
                sendMouse(kind: .release, at: position)
                return
            }
            guard let selection = terminalView.selection, !selection.isEmpty else {
                clearSelection()
                return
            }
            if Preferences.shared.copyOnSelect { copySelection() }
            presentEditMenu(at: point)

        default:
            break
        }
    }

    @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
        switch g.state {
        case .began:
            pinchStartFontSize = Preferences.shared.fontSize
        case .changed:
            let target = (pinchStartFontSize * g.scale).rounded()
            guard target != Preferences.shared.fontSize, target >= 6, target <= 32 else { return }
            Preferences.shared.fontSize = target
        default:
            break
        }
    }

    /// Two-finger drag is the scroll gesture for anything that has taken over
    /// the screen. Deliberate dragging inside such a program — selecting in
    /// tmux, say — is the long-press gesture, which reports a real button.
    @objc private func handleMousePan(_ g: UIPanGestureRecognizer) {
        let position = terminalView.gridPosition(at: g.location(in: terminalView))

        guard g.state == .changed else {
            if g.state == .began { altScrollAccumulator = 0 }
            return
        }

        altScrollAccumulator += g.translation(in: terminalView).y
        g.setTranslation(.zero, in: terminalView)

        let cellH = terminalView.cellSize.height
        guard cellH > 0 else { return }
        while abs(altScrollAccumulator) >= cellH {
            let up = altScrollAccumulator > 0
            altScrollAccumulator += up ? -cellH : cellH
            let bytes = scrollStepBytes(up: up, at: position)
            if !bytes.isEmpty { session.send(bytes: bytes) }
        }
    }

    /// One step of that gesture, as bytes.
    ///
    /// A program that tracks the mouse scrolls its own view and expects wheel
    /// buttons to do it; sending a press/drag/release instead reads as a click
    /// and drag, which is how a scroll turns into a selection. On the
    /// alternate screen with no tracking there is no scrollback to move, so
    /// the arrow keys the program is already listening for are the honest
    /// translation. Returned rather than sent, so the harness can check the
    /// wire format without synthesising a gesture.
    func scrollStepBytes(up: Bool, at position: GridPosition) -> [UInt8] {
        let modes = session.emulator.modes

        if modes.mouseTracking != .none {
            guard MouseEncoder.shouldReport(kind: .scroll, tracking: modes.mouseTracking) else {
                return []
            }
            let screenRow = position.row - session.emulator.buffer.scrollbackCount
            guard screenRow >= 0, screenRow < session.emulator.rows else { return [] }
            return MouseEncoder.bytes(button: up ? .scrollUp : .scrollDown,
                                      kind: .scroll,
                                      col: min(position.col, session.emulator.cols - 1),
                                      row: screenRow,
                                      modifiers: currentModifiers,
                                      encoding: modes.mouseEncoding)
        }

        guard modes.altScreen else { return [] }
        return KeyEncoder.bytes(for: up ? .up : .down, modifiers: [],
                                applicationCursorKeys: modes.applicationCursorKeys,
                                applicationKeypad: modes.applicationKeypad)
    }

    private var altScrollAccumulator: CGFloat = 0

    private func sendMouse(kind: MouseEncoder.Kind, at position: GridPosition) {
        let modes = session.emulator.modes
        guard MouseEncoder.shouldReport(kind: kind, tracking: modes.mouseTracking) else { return }
        // Mouse coordinates are relative to the visible grid, not scrollback.
        let screenRow = position.row - session.emulator.buffer.scrollbackCount
        guard screenRow >= 0, screenRow < session.emulator.rows else { return }
        let bytes = MouseEncoder.bytes(button: .left,
                                       kind: kind,
                                       col: min(position.col, session.emulator.cols - 1),
                                       row: screenRow,
                                       modifiers: currentModifiers,
                                       encoding: modes.mouseEncoding)
        session.send(bytes: bytes)
    }

    // MARK: - Selection & clipboard

    private func setSelection(_ selection: TerminalSelection, showMenu: Bool, at point: CGPoint) {
        terminalView.selection = selection
        if Preferences.shared.copyOnSelect { copySelection() }
        if showMenu { presentEditMenu(at: point) }
    }

    func clearSelection() {
        terminalView.selection = nil
        selectionOrigin = nil
    }

    private func presentEditMenu(at point: CGPoint) {
        if #available(iOS 16.0, *) {
            let configuration = UIEditMenuConfiguration(identifier: nil, sourcePoint: point)
            (editMenuInteraction as? UIEditMenuInteraction)?.presentEditMenu(with: configuration)
            return
        }
        presentLegacyEditMenu(at: point)
    }

    /// Before iOS 16 the same job was `UIMenuController`: the standard actions
    /// are offered by answering `canPerformAction`, and anything else has to
    /// be a menu item naming a bare selector. Both menus end up calling the
    /// same methods, so there is one implementation of each action.
    @available(iOS, deprecated: 16.0, message: "UIEditMenuInteraction is used from 16")
    private func presentLegacyEditMenu(at point: CGPoint) {
        legacyMenuLink = terminalView.link(at: terminalView.gridPosition(at: point))

        var items: [UIMenuItem] = []
        if legacyMenuLink != nil {
            items.append(UIMenuItem(title: "Open Link", action: #selector(menuOpenLink)))
            items.append(UIMenuItem(title: "Copy Link", action: #selector(menuCopyLink)))
        }
        items.append(UIMenuItem(title: "Find", action: #selector(menuFind)))

        let menu = UIMenuController.shared
        menu.menuItems = items
        becomeFirstResponderIfPossible()
        menu.showMenu(from: terminalView, rect: CGRect(origin: point, size: .zero))
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        switch action {
        case #selector(copy(_:)):
            return terminalView?.selection.map { !$0.isEmpty } ?? false
        case #selector(paste(_:)):
            return UIPasteboard.general.hasStrings
        case #selector(selectAll(_:)), #selector(menuFind):
            return true
        case #selector(menuOpenLink), #selector(menuCopyLink):
            return legacyMenuLink != nil
        default:
            return super.canPerformAction(action, withSender: sender)
        }
    }

    @objc override func copy(_ sender: Any?) {
        copySelection()
        clearSelection()
    }

    @objc override func paste(_ sender: Any?) { pasteFromClipboard() }

    @objc override func selectAll(_ sender: Any?) { selectAllText() }

    @objc private func menuFind() { showSearch() }

    @objc private func menuOpenLink() {
        guard let link = legacyMenuLink else { return }
        confirmOpen(link)
    }

    @objc private func menuCopyLink() {
        UIPasteboard.general.string = legacyMenuLink
    }

    @objc func copySelection() {
        guard let selection = terminalView.selection else { return }
        let text = terminalView.text(for: selection)
        guard !text.isEmpty else { return }
        UIPasteboard.general.string = text
    }

    @objc func pasteFromClipboard() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
        session.paste(text)
        clearSelection()
        scrollToBottom(animated: false)
    }

    @objc func selectAllText() {
        let buffer = session.emulator.buffer
        guard buffer.totalRows > 0 else { return }
        terminalView.selection = TerminalSelection(
            anchor: GridPosition(row: 0, col: 0),
            head: GridPosition(row: buffer.totalRows - 1, col: buffer.cols))
    }

    // MARK: - Actions

    @objc func clearScreen() {
        // Same effect as `clear`: wipe the screen and the scrollback with it.
        session.emulator.feed("\u{1B}[H\u{1B}[2J\u{1B}[3J")
        session.emulator.clearScrollback()
        terminalView.setNeedsDisplay()
        syncScrollGeometry(keepAtBottom: true)
    }

    @objc func resetTerminal() {
        session.emulator.hardReset()
        terminalView.setNeedsDisplay()
        syncScrollGeometry(keepAtBottom: true)
    }

    func showSearch() {
        searchBar.isHidden = false
        searchBar.beginEditing()
    }

    // MARK: - Modifiers

    var currentModifiers: KeyModifiers {
        armedModifiers.union(lockedModifiers)
    }

    var armedModifiersPublic: KeyModifiers { armedModifiers }
    var lockedModifiersPublic: KeyModifiers { lockedModifiers }

    /// One tap arms a modifier for the next key; a second tap within the
    /// double-tap window locks it until tapped off again. This is the
    /// interaction people already know from iOS's own shift key.
    func toggleModifier(_ modifier: KeyModifiers) {
        let now = CACurrentMediaTime()
        if lockedModifiers.contains(modifier) {
            lockedModifiers.subtract(modifier)
            armedModifiers.subtract(modifier)
        } else if armedModifiers.contains(modifier) {
            if let last = lastModifierTap, last.modifier == modifier, now - last.time < 0.4 {
                armedModifiers.subtract(modifier)
                lockedModifiers.insert(modifier)
            } else {
                armedModifiers.subtract(modifier)
            }
        } else {
            armedModifiers.insert(modifier)
        }
        lastModifierTap = (modifier, now)
        keyRow?.refreshModifierState()
    }

    private func consumeArmedModifiers() {
        if !armedModifiers.isEmpty {
            armedModifiers = []
            keyRow?.refreshModifierState()
        }
    }

    /// How far the finger travels before the floating cursor steps one
    /// character. Nil when the spacebar trackpad is switched off.
    ///
    /// A floor keeps a very small font from turning the gesture into a
    /// stream of arrow keys nobody can aim.
    var trackpadStep: CGFloat? {
        guard let cells = Preferences.shared.trackpadSensitivity.cellsPerStep else { return nil }
        let cellWidth = terminalView?.cellSize.width ?? 8
        return max(3, cellWidth * cells)
    }

    // MARK: - Sending input

    func sendKey(_ key: SpecialKey, extraModifiers: KeyModifiers = []) {
        let modifiers = currentModifiers.union(extraModifiers)

        // Ghost text intercepts three keys, and only while it is showing —
        // with nothing suggested every one of them reaches the shell
        // unchanged, so no binding is permanently taken away.
        if hasSuggestion {
            switch key {
            case .tab where modifiers.isEmpty && Preferences.shared.suggestionAcceptsTab:
                // A second Tab, with the suggestion gone, falls through to
                // the shell's own completion.
                if acceptSuggestion() { return }
            case .right where modifiers.isEmpty:
                if acceptSuggestion() { return }
            case .right where modifiers == [.alt]:
                // Word-right takes one word, as it does in Warp and fish.
                if acceptSuggestionWord() { return }
            case .escape where modifiers.isEmpty:
                dismissSuggestion()
                return
            default:
                break
            }
        }
        // Running something retires the suggestion without holding it against
        // the command — dismissing is the user saying no, this is not.
        switch key {
        case .enter, .keypadEnter: suggestions.clear()
        default: break
        }

        let bytes = KeyEncoder.bytes(
            for: key,
            modifiers: modifiers,
            applicationCursorKeys: session.emulator.modes.applicationCursorKeys,
            applicationKeypad: session.emulator.modes.applicationKeypad)
        deliver(bytes)
    }

    func sendText(_ text: String, extraModifiers: KeyModifiers = []) {
        let modifiers = currentModifiers.union(extraModifiers)
        deliver(KeyEncoder.bytes(for: text, modifiers: modifiers))
    }

    var scrollViewHeight: CGFloat { scrollView.bounds.height }

    // The harness has no other way to see what the scroll view believes.
    var scrollContentHeight: CGFloat { scrollView.contentSize.height }
    var scrollOffsetY: CGFloat { scrollView.contentOffset.y }

    func scrollTo(offsetY: CGFloat) {
        let clamped = min(max(offsetY, 0), maxContentOffsetY)
        scrollView.setContentOffset(CGPoint(x: 0, y: clamped), animated: true)
        isPinnedToBottomInternal = clamped >= maxContentOffsetY - 2
    }

    func resignPaneFirstResponder() {
        _ = hostView.resignFirstResponder()
        terminalView?.isInputFocused = false
    }

    func recomputeTerminalSizeFromView() {
        recomputeTerminalSize()
    }

    /// Rebuilds only the colour table, for OSC palette changes — the font and
    /// layout are untouched, so there is no need to re-measure anything.
    func refreshPalette() {
        let theme = Preferences.shared.theme(for: traitCollection.userInterfaceStyle)
        palette = TerminalPalette(theme: theme,
                                  paletteOverrides: session.emulator.paletteOverrides,
                                  foregroundOverride: session.emulator.overrideForeground,
                                  backgroundOverride: session.emulator.overrideBackground,
                                  cursorOverride: session.emulator.overrideCursorColor)
        view.backgroundColor = palette.defaultBackground.uiColor
        scrollView.backgroundColor = palette.defaultBackground.uiColor
        terminalView?.update(palette: palette)
    }

    func flashScreen() {
        let flash = flashView ?? {
            let v = UIView()
            v.isUserInteractionEnabled = false
            view.addSubview(v)
            flashView = v
            return v
        }()
        flash.frame = view.bounds
        flash.backgroundColor = palette.defaultForeground.uiColor
        flash.alpha = 0
        view.bringSubviewToFront(flash)
        UIView.animate(withDuration: 0.06, animations: { flash.alpha = 0.35 }) { _ in
            UIView.animate(withDuration: 0.16) { flash.alpha = 0 }
        }
    }

    /// Restarts a session the user has exited out of. Reachable by tapping
    /// the dead terminal, which is what people try first.
    func restartSession() {
        guard !session.isRunning else { return }
        session.restart()
        session.restartCursorBlink()
        terminalView?.setNeedsDisplay()
        becomeFirstResponderIfPossible()
        delegate?.pane(self, didUpdateTitle: session.displayTitle)
    }

    func showExitBanner(code: Int32) {
        // Rather than closing out from under the user (which loses whatever
        // the program printed), say what happened and offer a restart.
        let status = code == 0 ? "[process completed" : "[process exited with status \(code)"
        let message = "\r\n\u{1B}[2m\(status) — tap to start a new session]\u{1B}[0m\r\n"
        session.emulator.feed(message)
        syncAfterOutput()
        terminalView?.setNeedsDisplay()
        delegate?.pane(self, didUpdateTitle: session.displayTitle)
    }

    func presentSnippets() {
        let snippets = Preferences.shared.snippets
        let sheet = UIAlertController(title: "Snippets",
                                      message: snippets.isEmpty ? "Add snippets in Settings." : nil,
                                      preferredStyle: .actionSheet)
        for snippet in snippets {
            sheet.addAction(UIAlertAction(title: snippet.title, style: .default) { [weak self] _ in
                guard let self else { return }
                self.session.send(text: snippet.command + (snippet.runsImmediately ? "\n" : ""))
                self.scrollToBottom(animated: false)
            })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = keyRow ?? view
            popover.sourceRect = CGRect(x: (keyRow ?? view).bounds.midX,
                                        y: 0, width: 1, height: 1)
        }
        present(sheet, animated: true)
    }

    private func deliver(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        consumeArmedModifiers()
        session.send(bytes: bytes)
        // The shell has to echo before there is a new line to read, so the
        // suggestion is recomputed when that output arrives, not here.
        clearSelection()
        scrollToBottom(animated: false)
        session.restartCursorBlink()
        if Preferences.shared.keyboardHaptics {
            // A held key repeats faster than the taptic engine can usefully
            // answer, and without a floor a hold becomes one long buzz.
            let now = CACurrentMediaTime()
            if now - lastKeyHaptic > 0.05 {
                lastKeyHaptic = now
                UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.4)
            }
        }
    }
}
