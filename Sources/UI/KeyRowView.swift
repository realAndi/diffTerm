import UIKit

enum KeyRowAction: Equatable {
    case special(SpecialKeyID)
    case text(String)
    case modifier(KeyModifiers)
    /// A whole combination in one press, rather than arming a modifier and
    /// then hunting for the key it applies to.
    case combo(KeyModifiers, KeyRowBase)
    case toggleFunctionKeys
    case dismissKeyboard
    case snippets
}

/// What a combination ends on: a named key, or a character to type.
enum KeyRowBase: Equatable {
    case special(SpecialKeyID)
    case character(String)
}

/// A serialisable stand-in for `SpecialKey`, which carries an associated value
/// and so is awkward to put in a table.
enum SpecialKeyID: String {
    case escape, tab, up, down, left, right
    case home, end, pageUp, pageDown, insert, delete, backspace
    case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12

    var key: SpecialKey {
        switch self {
        case .escape: return .escape
        case .tab: return .tab
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .home: return .home
        case .end: return .end
        case .pageUp: return .pageUp
        case .pageDown: return .pageDown
        case .insert: return .insert
        case .delete: return .delete
        case .backspace: return .backspace
        case .f1: return .f(1)
        case .f2: return .f(2)
        case .f3: return .f(3)
        case .f4: return .f(4)
        case .f5: return .f(5)
        case .f6: return .f(6)
        case .f7: return .f(7)
        case .f8: return .f(8)
        case .f9: return .f(9)
        case .f10: return .f(10)
        case .f11: return .f(11)
        case .f12: return .f(12)
        }
    }
}

protocol KeyRowViewDelegate: AnyObject {
    func keyRow(_ view: KeyRowView, didTrigger action: KeyRowAction)
    /// Which modifiers are currently armed, so the row can show them latched.
    func keyRowActiveModifiers(_ view: KeyRowView) -> KeyModifiers
    func keyRowLockedModifiers(_ view: KeyRowView) -> KeyModifiers
}

/// The row of keys a phone keyboard doesn't have. Scrolls horizontally so the
/// full set is reachable without shrinking the touch targets below what a
/// thumb can hit.
final class KeyRowView: UIView {

    weak var delegate: KeyRowViewDelegate?

    private let scrollView = KeyRowScrollView()
    private let stack = UIStackView()
    /// Pinned outside the scroll view: dismissing the keyboard must never be
    /// something you have to go looking for.
    private let dismissButton = KeyButton(title: "", symbolName: "keyboard.chevron.compact.down", wide: false)
    private let background = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
    private let hairline = UIView()

    private var buttons: [(button: KeyButton, action: KeyRowAction)] = []
    private var showingFunctionKeys = false

    /// Holding an arrow or a delete key keeps sending it. A button knows only
    /// about taps, so the hold is run here.
    private let repeater = KeyRepeater()

    private let rowHeight: CGFloat = DeviceMetrics.keyRowHeight

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: rowHeight)
    }

    private func setUp() {
        autoresizingMask = .flexibleHeight

        background.frame = bounds
        background.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(background)

        hairline.backgroundColor = UIColor.separator
        addSubview(hairline)

        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        scrollView.contentInsetAdjustmentBehavior = .never
        // A held key has to start counting from the moment it goes down, and
        // the default quarter-second of "is this a scroll?" is a quarter of
        // the hold delay. Handing the touch straight to the key is only half
        // the bargain; `KeyRowScrollView` is the half that takes it back when
        // the finger turns out to be scrolling.
        scrollView.delaysContentTouches = false
        scrollView.canCancelContentTouches = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        stack.axis = .horizontal
        stack.spacing = 6
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)

        dismissButton.addTarget(self, action: #selector(dismissTapped), for: .touchUpInside)
        dismissButton.accessibilityLabel = "Hide Keyboard"
        addSubview(dismissButton)

        NSLayoutConstraint.activate([
            dismissButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            dismissButton.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),

            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: dismissButton.leadingAnchor, constant: -6),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.heightAnchor.constraint(equalToConstant: rowHeight),

            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        ])

        rebuild()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let px = 1 / (window?.screen.scale ?? 2)
        hairline.frame = CGRect(x: 0, y: 0, width: bounds.width, height: px)
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        // The keyboard going away takes the row with it, and no release will
        // ever arrive for whatever was under the finger.
        if newWindow == nil { repeater.stop() }
    }

    // MARK: - Contents

    private struct Definition {
        /// Stable across versions: it is what Settings stores when a key is
        /// switched off, so renaming a button must not orphan the preference.
        let id: String
        let title: String
        let symbol: String?
        let action: KeyRowAction
        let wide: Bool
        init(_ id: String, _ title: String, symbol: String? = nil,
             _ action: KeyRowAction, wide: Bool = false) {
            self.id = id
            self.title = title
            self.symbol = symbol
            self.action = action
            self.wide = wide
        }
    }

    /// Keys are laid out singly or in tight clusters. A cluster reads as one
    /// control — the arrows are a d-pad, not four unrelated buttons.
    private enum Item {
        case key(Definition)
        case cluster(String, [Definition])

        /// A cluster reads as one control, so it is shown or hidden as one.
        var id: String {
            switch self {
            case .key(let definition): return definition.id
            case .cluster(let id, _): return id
            }
        }
    }

    /// The built-in keys, in row order, as Settings lists them. Anything not
    /// named here (the function-key toggle, custom keys) is governed
    /// elsewhere.
    static let toggleableKeys: [(id: String, name: String)] = [
        ("esc", "Escape"),
        ("tab", "Tab"),
        ("ctrl", "Control"),
        ("alt", "Alt"),
        ("arrows", "Arrow keys"),
        ("shift", "Shift"),
        ("shifttab", "Shift-Tab"),
        ("homeend", "Home and End"),
        ("pages", "Page Up and Page Down"),
        ("del", "Forward Delete"),
        ("snippets", "Snippets"),
    ]

    /// Every character on this row used to be one the iOS keyboard already
    /// offers a tap or two away, which pushed the arrow keys off-screen behind
    /// a scroll. The row now carries only what the software keyboard has no
    /// way to produce at all. Backspace briefly lived here, because the iOS
    /// delete key would not repeat; it went back to the software keyboard
    /// where it belongs once the host view started claiming to be a text
    /// input, which is what makes iOS drive that repeat.
    private var items: [Item] {
        if showingFunctionKeys {
            var defs: [Item] = [.key(Definition("fn", "abc", .toggleFunctionKeys, wide: true))]
            var row: [Definition] = []
            for n in 1...12 {
                guard let id = SpecialKeyID(rawValue: "f\(n)") else { continue }
                row.append(Definition("f\(n)", "F\(n)", .special(id)))
            }
            defs.append(.cluster("fkeys", row))
            return defs
        }

        // Everything before the arrows is width the arrows do not get, and a
        // d-pad you have to scroll to reach is a d-pad you stop using — the
        // checks fail if the arrows leave the screen at iPhone width. So only
        // the two modifiers a shell needs constantly, ctrl and alt, come
        // first; shift is rarer in a terminal and sits after, next to the
        // back-tab it mostly exists for.
        var result: [Item] = [
            .key(Definition("esc", "esc", .special(.escape), wide: true)),
            .key(Definition("tab", "tab", symbol: "arrow.right.to.line", .special(.tab))),
            .key(Definition("ctrl", "ctrl", .modifier(.control), wide: true)),
            .key(Definition("alt", "alt", .modifier(.alt), wide: true)),
            .cluster("arrows", [
                Definition("left", "", symbol: "arrow.left", .special(.left)),
                Definition("down", "", symbol: "arrow.down", .special(.down)),
                Definition("up", "", symbol: "arrow.up", .special(.up)),
                Definition("right", "", symbol: "arrow.right", .special(.right)),
            ]),
            .key(Definition("shift", "shift", .modifier(.shift), wide: true)),
            // Back-tab in one press. Shift is spent as part of the
            // combination rather than latched, because ⇧tab is a single
            // gesture in every shell that uses it.
            .key(Definition("shifttab", "⇧tab", .combo(.shift, .special(.tab)), wide: true)),
            .cluster("homeend", [
                Definition("home", "home", .special(.home), wide: true),
                Definition("end", "end", .special(.end), wide: true),
            ]),
            .cluster("pages", [
                Definition("pageup", "", symbol: "arrow.up.to.line", .special(.pageUp)),
                Definition("pagedown", "", symbol: "arrow.down.to.line", .special(.pageDown)),
            ]),
            .key(Definition("del", "del", symbol: "delete.forward", .special(.delete))),
        ]

        let hidden = Preferences.shared.hiddenKeyRowKeys
        result = result.filter { !hidden.contains($0.id) }

        for (index, key) in Preferences.shared.customKeys.enumerated() {
            result.append(.key(Definition("custom\(index)", key.title,
                                          .combo(key.modifiers, key.base), wide: true)))
        }

        if Preferences.shared.keyRowShowsFunctionKeys {
            result.append(.key(Definition("fn", "fn", .toggleFunctionKeys, wide: true)))
        }
        if !hidden.contains("snippets") {
            result.append(.key(Definition("snippets", "", symbol: "text.badge.plus", .snippets)))
        }
        return result
    }

    func rebuild() {
        // The button being held is about to be thrown away.
        repeater.stop()
        buttons.removeAll()
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for item in items {
            switch item {
            case .key(let def):
                stack.addArrangedSubview(makeButton(def))
            case .cluster(_, let defs):
                let group = UIStackView(arrangedSubviews: defs.map(makeButton))
                group.axis = .horizontal
                group.spacing = 2
                group.alignment = .center
                stack.addArrangedSubview(group)
            }
        }
        refreshModifierState()
    }

    private func makeButton(_ def: Definition) -> KeyButton {
        let button = KeyButton(title: def.title, symbolName: def.symbol, wide: def.wide)
        button.addTarget(self, action: #selector(keyTapped(_:)), for: .touchUpInside)
        if def.action.repeatsWhenHeld {
            button.addTarget(self, action: #selector(keyHeld(_:)), for: .touchDown)
            button.addTarget(self, action: #selector(keyHoldCancelled(_:)),
                             for: [.touchUpOutside, .touchDragExit, .touchCancel])
        }
        buttons.append((button, def.action))
        return button
    }

    @objc private func dismissTapped() {
        delegate?.keyRow(self, didTrigger: .dismissKeyboard)
    }

    /// A key going down. Nothing is sent yet — a tap still commits on release,
    /// so sliding off cancels it — but the clock starts, and once the hold
    /// passes the delay the repeats take over.
    @objc private func keyHeld(_ sender: KeyButton) {
        guard let entry = buttons.first(where: { $0.button === sender }) else { return }
        // A modifier armed for the next key has to stay armed for the whole
        // hold: arming is spent on the press that uses it, and a hold is one
        // press however many characters it moves.
        let action = repeatAction(for: entry.action)
        repeater.begin(ObjectIdentifier(sender)) { [weak self] in
            guard let self else { return }
            self.delegate?.keyRow(self, didTrigger: action)
            self.refreshModifierState()
        }
    }

    @objc private func keyHoldCancelled(_ sender: KeyButton) {
        repeater.stop(ObjectIdentifier(sender))
    }

    @objc private func keyTapped(_ sender: KeyButton) {
        // The release that ends a hold must not add one more press on top of
        // everything the hold already sent.
        guard repeater.stop(ObjectIdentifier(sender)) == 0 else { return }
        guard let entry = buttons.first(where: { $0.button === sender }) else { return }
        if case .toggleFunctionKeys = entry.action {
            showingFunctionKeys.toggle()
            rebuild()
            return
        }
        delegate?.keyRow(self, didTrigger: entry.action)
        refreshModifierState()
    }

    /// What a repeat of `action` should send. Modifiers latched when the key
    /// went down are folded in, because by the second repeat the armed ones
    /// have been spent on the first.
    private func repeatAction(for action: KeyRowAction) -> KeyRowAction {
        guard case .special(let id) = action, let delegate else { return action }
        let modifiers = delegate.keyRowActiveModifiers(self)
            .union(delegate.keyRowLockedModifiers(self))
        return modifiers.isEmpty ? action : .combo(modifiers, .special(id))
    }

    /// The ids of the row's items, in the order they are drawn. Settings lists
    /// the same keys, and a list in a different order from the thing it
    /// describes is a list you have to read twice, so the checks hold the two
    /// to each other.
    var orderedItemIDs: [String] { items.map(\.id) }

    /// The actions currently on the row, in order. Also what the checks use
    /// to keep keyboard-reachable characters from creeping back on.
    var orderedActions: [KeyRowAction] { buttons.map(\.action) }

    /// Total width of the scrolling keys, and how much of it is on screen.
    /// Exposed so the layout can be measured rather than eyeballed.
    var contentWidth: CGFloat {
        stack.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width + 16
    }
    var visibleScrollWidth: CGFloat { scrollView.bounds.width }

    /// Drives one control event on a key from the checks, which have neither
    /// touches to synthesise nor an application to route them through. It runs
    /// whatever the button actually registered for that event, so a key wired
    /// up wrongly fails here rather than passing on a stand-in.
    func simulate(_ event: UIControl.Event, on action: KeyRowAction) {
        guard let button = buttons.first(where: { $0.action == action })?.button else { return }
        for name in button.actions(forTarget: self, forControlEvent: event) ?? [] {
            perform(Selector(name), with: button)
        }
    }

    /// Frame of a key in the row's own coordinates, after layout. Lets the
    /// checks assert that a key is actually on screen rather than just present.
    func frame(for action: KeyRowAction) -> CGRect? {
        guard let entry = buttons.first(where: { $0.action == action }) else { return nil }
        return entry.button.convert(entry.button.bounds, to: self)
    }

    /// Whether a drag that began on a key hands the touch over to the scroll
    /// view. It has to, or the row scrolls only from the gaps between keys.
    /// Runs the real scroll view, so the answer is the one a finger gets.
    func scrollCancelsTouch(on action: KeyRowAction) -> Bool {
        guard let button = buttons.first(where: { $0.action == action })?.button else { return false }
        return scrollView.touchesShouldCancel(in: button)
    }

    /// Redraws the latched state of the modifier keys.
    func refreshModifierState() {
        guard let delegate else { return }
        let active = delegate.keyRowActiveModifiers(self)
        let locked = delegate.keyRowLockedModifiers(self)
        for (button, action) in buttons {
            guard case .modifier(let mod) = action else { continue }
            if locked.contains(mod) {
                button.latchState = .locked
            } else if active.contains(mod) {
                button.latchState = .armed
            } else {
                button.latchState = .off
            }
        }
    }
}

/// The scrolling half of the row.
///
/// A scroll view refuses by default to take a touch back off a `UIControl`,
/// and every key here is one. With `delaysContentTouches` off there is no
/// quarter-second of hesitation to catch the drag first either, so a swipe
/// that started on a key used to do nothing at all — the row moved only when
/// the finger happened to land in one of the few points of gap between keys.
/// Keys are the whole width of the row, so that is most of the row refusing
/// to scroll. Letting the scroll view cancel a key touch costs nothing: a tap
/// commits on release, so a touch that becomes a scroll was never a press.
final class KeyRowScrollView: UIScrollView {
    override func touchesShouldCancel(in view: UIView) -> Bool {
        true
    }
}

/// One key. Deliberately chunky: the whole point of this row is that it can be
/// hit reliably while typing with thumbs.
final class KeyButton: UIButton {

    enum LatchState { case off, armed, locked }

    var latchState: LatchState = .off {
        didSet { if latchState != oldValue { updateAppearance() } }
    }

    private let wide: Bool

    init(title: String, symbolName: String?, wide: Bool) {
        self.wide = wide
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        if let symbolName,
           let image = UIImage(systemName: symbolName,
                               withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)) {
            setImage(image, for: .normal)
        } else {
            setTitle(title, for: .normal)
            titleLabel?.font = .systemFont(ofSize: 14, weight: .medium)
        }

        layer.cornerRadius = 7
        layer.cornerCurve = .continuous

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 34),
            widthAnchor.constraint(greaterThanOrEqualToConstant: wide ? 40 : 34),
        ])
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isHighlighted: Bool {
        didSet { updateAppearance() }
    }

    /// Horizontal breathing room around the label. Done here rather than with
    /// `contentEdgeInsets`, which iOS 15 deprecated.
    override var intrinsicContentSize: CGSize {
        var size = super.intrinsicContentSize
        size.width += 14
        return size
    }

    private func updateAppearance() {
        switch latchState {
        case .off:
            backgroundColor = isHighlighted
                ? UIColor.tertiarySystemFill
                : UIColor.secondarySystemFill.withAlphaComponent(0.35)
            tintColor = .label
            setTitleColor(.label, for: .normal)
            layer.borderWidth = 0
        case .armed:
            backgroundColor = UIColor.accentCompat.withAlphaComponent(0.9)
            tintColor = .white
            setTitleColor(.white, for: .normal)
            layer.borderWidth = 0
        case .locked:
            backgroundColor = UIColor.accentCompat
            tintColor = .white
            setTitleColor(.white, for: .normal)
            layer.borderWidth = 2
            layer.borderColor = UIColor.label.withAlphaComponent(0.5).cgColor
        }
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        updateAppearance()
    }
}
