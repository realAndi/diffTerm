import UIKit

/// A binary tree of panes. Leaves are terminals; internal nodes are splits
/// with a draggable divider.
final class SplitNode {
    enum Kind {
        case leaf(TerminalPaneController)
        case split(vertical: Bool, first: SplitNode, second: SplitNode)
    }

    var kind: Kind
    /// Fraction of the axis given to `first`, 0...1.
    var ratio: CGFloat = 0.5
    weak var parent: SplitNode?

    init(kind: Kind) { self.kind = kind }

    static func leaf(_ pane: TerminalPaneController) -> SplitNode {
        SplitNode(kind: .leaf(pane))
    }

    var panes: [TerminalPaneController] {
        switch kind {
        case .leaf(let pane): return [pane]
        case .split(_, let a, let b): return a.panes + b.panes
        }
    }

    func node(containing pane: TerminalPaneController) -> SplitNode? {
        switch kind {
        case .leaf(let p):
            return p === pane ? self : nil
        case .split(_, let a, let b):
            return a.node(containing: pane) ?? b.node(containing: pane)
        }
    }
}

protocol SplitContainerDelegate: AnyObject {
    func splitContainer(_ container: SplitContainerController, didChangeActivePane pane: TerminalPaneController)
    func splitContainerDidBecomeEmpty(_ container: SplitContainerController)
    func splitContainer(_ container: SplitContainerController, didUpdateTitle title: String)
    func splitContainerDidRequestNewTab(_ container: SplitContainerController)
    func splitContainerDidRequestSettings(_ container: SplitContainerController)
    func splitContainerDidRequestNextTab(_ container: SplitContainerController)
    func splitContainerDidRequestPreviousTab(_ container: SplitContainerController)
    func splitContainer(_ container: SplitContainerController, didRequestTabAtIndex index: Int)
}

/// One tab's worth of terminals.
final class SplitContainerController: UIViewController {

    weak var delegate: SplitContainerDelegate?

    private(set) var root: SplitNode
    private(set) var activePane: TerminalPaneController

    private var dividers: [ObjectIdentifier: DividerView] = [:]

    private let minimumPaneSize: CGFloat = 120

    init(initialPane: TerminalPaneController) {
        root = .leaf(initialPane)
        activePane = initialPane
        super.init(nibName: nil, bundle: nil)
        adopt(initialPane)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var panes: [TerminalPaneController] { root.panes }

    var title_: String { activePane.session.displayTitle }

    override func viewDidLoad() {
        super.viewDidLoad()
        applyThemeBackground()
        NotificationCenter.default.addObserver(
            self, selector: #selector(applyThemeBackground),
            name: Preferences.didChangeNotification, object: nil)
    }

    /// Shows through the gaps between panes, so it has to be the theme's
    /// background rather than black.
    @objc private func applyThemeBackground() {
        view.backgroundColor = Preferences.shared
            .theme(for: traitCollection.userInterfaceStyle).background.uiColor
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        if previous?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            applyThemeBackground()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layout(node: root, in: view.bounds)
    }

    // MARK: - Child management

    private func adopt(_ pane: TerminalPaneController) {
        pane.delegate = self
        addChild(pane)
        view.addSubview(pane.view)
        pane.didMove(toParent: self)
    }

    private func discard(_ pane: TerminalPaneController) {
        pane.willMove(toParent: nil)
        pane.view.removeFromSuperview()
        pane.removeFromParent()
        pane.session.detachView()
        pane.session.stop()
    }

    // MARK: - Layout

    private func layout(node: SplitNode, in frame: CGRect) {
        switch node.kind {
        case .leaf(let pane):
            pane.view.frame = frame

        case .split(let vertical, let first, let second):
            let dividerThickness: CGFloat = 6
            let divider = dividerView(for: node, vertical: vertical)
            view.bringSubviewToFront(divider)

            if vertical {
                let available = max(0, frame.width - dividerThickness)
                let firstWidth = (available * node.ratio).rounded()
                layout(node: first, in: CGRect(x: frame.minX, y: frame.minY,
                                               width: firstWidth, height: frame.height))
                divider.frame = CGRect(x: frame.minX + firstWidth, y: frame.minY,
                                       width: dividerThickness, height: frame.height)
                layout(node: second, in: CGRect(x: frame.minX + firstWidth + dividerThickness,
                                                y: frame.minY,
                                                width: available - firstWidth,
                                                height: frame.height))
            } else {
                let available = max(0, frame.height - dividerThickness)
                let firstHeight = (available * node.ratio).rounded()
                layout(node: first, in: CGRect(x: frame.minX, y: frame.minY,
                                               width: frame.width, height: firstHeight))
                divider.frame = CGRect(x: frame.minX, y: frame.minY + firstHeight,
                                       width: frame.width, height: dividerThickness)
                layout(node: second, in: CGRect(x: frame.minX,
                                                y: frame.minY + firstHeight + dividerThickness,
                                                width: frame.width,
                                                height: available - firstHeight))
            }
        }
    }

    private func dividerView(for node: SplitNode, vertical: Bool) -> DividerView {
        let key = ObjectIdentifier(node)
        if let existing = dividers[key] {
            existing.isVertical = vertical
            return existing
        }
        let divider = DividerView()
        divider.isVertical = vertical
        divider.onDrag = { [weak self, weak node] translation, containerSize in
            guard let self, let node else { return }
            self.adjust(node: node, by: translation, containerSize: containerSize)
        }
        divider.onDoubleTap = { [weak self, weak node] in
            guard let self, let node else { return }
            node.ratio = 0.5
            self.view.setNeedsLayout()
            UIView.animate(withDuration: 0.2) { self.view.layoutIfNeeded() }
        }
        view.addSubview(divider)
        dividers[key] = divider
        return divider
    }

    private func adjust(node: SplitNode, by translation: CGPoint, containerSize: CGSize) {
        guard case .split(let vertical, _, _) = node.kind else { return }
        let axisLength = vertical ? containerSize.width : containerSize.height
        guard axisLength > 0 else { return }
        let delta = (vertical ? translation.x : translation.y) / axisLength
        // Keep both sides usable; a zero-width pane is a bug, not a layout.
        let minimumRatio = minimumPaneSize / axisLength
        node.ratio = min(max(node.ratio + delta, minimumRatio), 1 - minimumRatio)
        view.setNeedsLayout()
        view.layoutIfNeeded()
    }

    // MARK: - Splitting

    func split(pane: TerminalPaneController, vertical: Bool) {
        guard let node = root.node(containing: pane) else { return }

        // A split is a second view of the work in front of you, so it starts
        // where that work is.
        let newPane = makePane(inheriting: pane.session.workingDirectory)
        adopt(newPane)

        let existingLeaf = SplitNode.leaf(pane)
        let newLeaf = SplitNode.leaf(newPane)
        node.kind = .split(vertical: vertical, first: existingLeaf, second: newLeaf)
        node.ratio = 0.5
        existingLeaf.parent = node
        newLeaf.parent = node

        view.setNeedsLayout()
        view.layoutIfNeeded()
        setActive(newPane)
        newPane.becomeFirstResponderIfPossible()
    }

    private func makePane(inheriting directory: String?) -> TerminalPaneController {
        let size = view.bounds.size
        // Guess a sensible starting grid; it is corrected the moment the view
        // lays out, but a shell that starts at 0x0 prints nothing at all.
        let session = TerminalSession(cols: max(20, Int(size.width / 8)),
                                      rows: max(5, Int(size.height / 17)),
                                      inheriting: directory)
        return TerminalPaneController(session: session)
    }

    // MARK: - Closing

    func close(pane: TerminalPaneController) {
        guard let node = root.node(containing: pane) else { return }

        guard let parent = node.parent else {
            // Last pane in this tab.
            discard(pane)
            delegate?.splitContainerDidBecomeEmpty(self)
            return
        }

        guard case .split(_, let first, let second) = parent.kind else { return }
        let sibling = (first === node) ? second : first

        discard(pane)
        if let divider = dividers.removeValue(forKey: ObjectIdentifier(parent)) {
            divider.removeFromSuperview()
        }

        // Promote the sibling into the parent's place.
        parent.kind = sibling.kind
        parent.ratio = sibling.ratio
        if case .split(_, let a, let b) = parent.kind {
            a.parent = parent
            b.parent = parent
            // The sibling's own divider is now keyed to the wrong node.
            if let moved = dividers.removeValue(forKey: ObjectIdentifier(sibling)) {
                dividers[ObjectIdentifier(parent)] = moved
            }
        }

        view.setNeedsLayout()
        view.layoutIfNeeded()

        if let next = root.panes.first {
            setActive(next)
            next.becomeFirstResponderIfPossible()
        } else {
            delegate?.splitContainerDidBecomeEmpty(self)
        }
    }

    /// Closes whichever pane currently has focus.
    func closeActivePane() {
        close(pane: activePane)
    }

    /// Collapses the tab back to a single terminal.
    func closeOtherPanes() {
        let keep = activePane
        // `close` re-picks the active pane as it goes, so the one to keep is
        // captured up front rather than read back out of `activePane`.
        for pane in root.panes where pane !== keep {
            close(pane: pane)
        }
        if root.node(containing: keep) != nil { setActive(keep) }
    }

    /// Resets every divider in the tab to an even split.
    func evenOutSplits() {
        func walk(_ node: SplitNode) {
            guard case .split(_, let a, let b) = node.kind else { return }
            node.ratio = 0.5
            walk(a)
            walk(b)
        }
        walk(root)
        view.setNeedsLayout()
        UIView.animate(withDuration: 0.2) { self.view.layoutIfNeeded() }
    }

    func closeAll() {
        for pane in root.panes { discard(pane) }
        dividers.values.forEach { $0.removeFromSuperview() }
        dividers.removeAll()
    }

    // MARK: - Focus

    func setActive(_ pane: TerminalPaneController) {
        guard root.node(containing: pane) != nil else { return }
        activePane = pane
        for p in root.panes {
            p.view.layer.borderWidth = (root.panes.count > 1 && p === pane) ? 1 : 0
            p.view.layer.borderColor = UIColor.accentCompat.withAlphaComponent(0.6).cgColor
        }
        delegate?.splitContainer(self, didChangeActivePane: pane)
        delegate?.splitContainer(self, didUpdateTitle: pane.session.displayTitle)
    }
}

// MARK: - Pane delegate

extension SplitContainerController: TerminalPaneDelegate {

    func paneDidRequestClose(_ pane: TerminalPaneController) {
        let running = pane.session.isRunning
        guard running, Preferences.shared.confirmCloseWithRunningProcess else {
            close(pane: pane)
            return
        }
        let alert = UIAlertController(
            title: "Close this terminal?",
            message: "A process is still running and will be stopped.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Close", style: .destructive) { [weak self] _ in
            self?.close(pane: pane)
        })
        present(alert, animated: true)
    }

    func paneDidFinish(_ pane: TerminalPaneController, exitCode: Int32) {
        // With siblings on screen, `exit` should do what it does in tmux and
        // every desktop terminal: close the pane. On the last one there is
        // nowhere to go, so the output stays put and the banner offers a
        // restart instead.
        if root.panes.count > 1 {
            close(pane: pane)
        } else {
            pane.showExitBanner(code: exitCode)
        }
    }

    func paneDidBecomeActive(_ pane: TerminalPaneController) {
        guard pane !== activePane else { return }
        setActive(pane)
    }

    func pane(_ pane: TerminalPaneController, didUpdateTitle title: String) {
        guard pane === activePane else { return }
        delegate?.splitContainer(self, didUpdateTitle: title)
    }

    func paneDidRequestNewTab(_ pane: TerminalPaneController) {
        delegate?.splitContainerDidRequestNewTab(self)
    }

    func paneDidRequestSplit(_ pane: TerminalPaneController, vertical: Bool) {
        split(pane: pane, vertical: vertical)
    }

    func paneDidRequestSettings(_ pane: TerminalPaneController) {
        delegate?.splitContainerDidRequestSettings(self)
    }

    func paneDidRequestNextTab(_ pane: TerminalPaneController) {
        delegate?.splitContainerDidRequestNextTab(self)
    }

    func paneDidRequestPreviousTab(_ pane: TerminalPaneController) {
        delegate?.splitContainerDidRequestPreviousTab(self)
    }

    func pane(_ pane: TerminalPaneController, didRequestTabAtIndex index: Int) {
        delegate?.splitContainer(self, didRequestTabAtIndex: index)
    }
}

/// The draggable bar between two panes.
final class DividerView: UIView {

    var isVertical = true { didSet { setNeedsLayout() } }
    /// Called with the incremental drag and the size of the container.
    var onDrag: ((CGPoint, CGSize) -> Void)?
    var onDoubleTap: (() -> Void)?

    private let grip = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.separator

        grip.backgroundColor = UIColor.systemGray
        grip.layer.cornerRadius = 1.5
        addSubview(grip)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        addGestureRecognizer(pan)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)

        isUserInteractionEnabled = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let length: CGFloat = 28
        if isVertical {
            grip.frame = CGRect(x: bounds.midX - 1.5, y: bounds.midY - length / 2, width: 3, height: length)
        } else {
            grip.frame = CGRect(x: bounds.midX - length / 2, y: bounds.midY - 1.5, width: length, height: 3)
        }
    }

    /// Widen the touch area beyond the visible bar — six points is too thin
    /// to grab reliably with a finger.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let slop: CGFloat = 11
        return bounds.insetBy(dx: isVertical ? -slop : 0, dy: isVertical ? 0 : -slop).contains(point)
    }

    @objc private func handleDoubleTap() {
        onDoubleTap?()
    }

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        guard let container = superview else { return }
        let translation = g.translation(in: container)
        g.setTranslation(.zero, in: container)
        onDrag?(translation, container.bounds.size)
    }
}
