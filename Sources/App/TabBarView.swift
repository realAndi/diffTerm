import UIKit

protocol TabBarViewDelegate: AnyObject {
    func tabBar(_ bar: TabBarView, didSelectTabAt index: Int)
    func tabBar(_ bar: TabBarView, didCloseTabAt index: Int)
    func tabBarDidRequestNewTab(_ bar: TabBarView)
    func tabBarMenu(_ bar: TabBarView) -> UIMenu
}

/// The tab strip. Written by hand rather than using `UITabBar` because tabs
/// here are documents, not top-level sections: they are created, closed and
/// reordered by the user and there can be a lot of them.
final class TabBarView: UIView {

    weak var delegate: TabBarViewDelegate?

    static var preferredHeight: CGFloat { DeviceMetrics.tabBarHeight }

    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private let addButton = UIButton(type: .system)
    private let menuButton = UIButton(type: .system)
    private let hairline = UIView()

    private var chips: [TabChip] = []
    private(set) var selectedIndex = 0

    /// The strip is painted from the palette rather than from a system
    /// material, for two reasons: it has to be the same colour as the status
    /// bar above it, and the system's label colours follow the *system's*
    /// light/dark setting — which is not the theme's. A dark theme on a phone
    /// in light mode was putting black text on a dark strip.
    private var theme: Theme = Preferences.shared.theme(for: UITraitCollection.current.userInterfaceStyle)

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: TabBarView.preferredHeight)
    }

    private func setUp() {
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        stack.axis = .horizontal
        stack.spacing = 4
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)

        addButton.setImage(UIImage(systemName: "plus"), for: .normal)
        addButton.addTarget(self, action: #selector(addTapped), for: .touchUpInside)
        addButton.translatesAutoresizingMaskIntoConstraints = false
        addButton.accessibilityLabel = "New Tab"
        addSubview(addButton)

        menuButton.setImage(UIImage(systemName: "ellipsis.circle"), for: .normal)
        menuButton.showsMenuAsPrimaryAction = true
        // Built on each press: what belongs in it depends on how many panes
        // the current tab has, which changes underneath us.
        if #available(iOS 15.0, *) {
            menuButton.menu = UIMenu(children: [
                UIDeferredMenuElement.uncached { [weak self] completion in
                    guard let self, let delegate = self.delegate else { completion([]); return }
                    _ = delegate
                    completion(self.resolvedMenuElements())
                }
            ])
        } else {
            // iOS 14's deferred element caches what it is given, and what
            // belongs in this menu changes as panes come and go — so rebuild
            // it as the button goes down, before the menu is shown.
            menuButton.addTarget(self, action: #selector(rebuildMenu), for: .touchDown)
            menuButton.menu = UIMenu(children: resolvedMenuElements())
        }
        menuButton.translatesAutoresizingMaskIntoConstraints = false
        menuButton.accessibilityLabel = "More"
        addSubview(menuButton)

        addSubview(hairline)
        apply(theme: theme)

        NSLayoutConstraint.activate([
            menuButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            menuButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            menuButton.widthAnchor.constraint(equalToConstant: 34),

            addButton.trailingAnchor.constraint(equalTo: menuButton.leadingAnchor, constant: -2),
            addButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            addButton.widthAnchor.constraint(equalToConstant: 34),

            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            scrollView.trailingAnchor.constraint(equalTo: addButton.leadingAnchor, constant: -4),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        ])
    }

    /// The elements the ⋯ button actually shows.
    ///
    /// Note the `.children` — handing back the containing menu instead would
    /// nest it a level, and a non-inline `UIMenu` inside a menu renders as a
    /// submenu row you have to expand rather than as flat sections.
    @objc private func rebuildMenu() {
        menuButton.menu = UIMenu(children: resolvedMenuElements())
    }

    func resolvedMenuElements() -> [UIMenuElement] {
        guard let delegate else { return [] }
        // The delegate's menu is a container of inline sections. Handing the
        // container itself to the button renders as one row you must expand
        // into; its children render as the flat menu this is meant to be.
        return delegate.tabBarMenu(self).children
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let px = 1 / (window?.screen.scale ?? 2)
        hairline.frame = CGRect(x: 0, y: bounds.height - px, width: bounds.width, height: px)
    }

    // MARK: - Contents

    /// The two mixes a chip is painted with, here rather than inside the chip
    /// so that the contrast checks measure the colours that actually ship
    /// instead of a second copy of the arithmetic.
    ///
    /// Both amounts are deliberately small. Lifting the active chip's
    /// background towards the foreground spends the very contrast its title
    /// needs, and on a palette like Solarized Light — 4.1:1 between its own
    /// two colours before anything is asked of it — there is nothing to spend.
    static func activeChipBackground(for theme: Theme) -> Theme.RGB {
        theme.background.blended(with: theme.foreground, amount: 0.05)
    }

    /// The active tab is marked by a rule underneath it in the cursor's
    /// colour, which is the one colour every palette guarantees stands out
    /// against its own background. Doing the work with a colour the palette
    /// already reserves for "this is where you are" costs the title none of
    /// its contrast.
    static func activeChipIndicator(for theme: Theme) -> Theme.RGB { theme.cursor }

    static func inactiveChipText(for theme: Theme) -> Theme.RGB {
        theme.background.blended(with: theme.foreground, amount: 0.80)
    }

    func apply(theme: Theme) {
        self.theme = theme
        backgroundColor = theme.background.uiColor
        // A quarter of the way to the foreground: visible as a boundary
        // against both the strip above it and the terminal below, without
        // becoming a line anyone notices.
        hairline.backgroundColor = theme.background.blended(with: theme.foreground,
                                                            amount: 0.25).uiColor
        addButton.tintColor = theme.foreground.uiColor
        menuButton.tintColor = theme.foreground.uiColor
        for chip in chips { chip.apply(theme: theme) }
    }

    func reload(titles: [String], statuses: [CommandStatus], selected: Int) {
        selectedIndex = selected

        while chips.count > titles.count {
            let chip = chips.removeLast()
            stack.removeArrangedSubview(chip)
            chip.removeFromSuperview()
        }
        while chips.count < titles.count {
            let chip = TabChip()
            chip.onSelect = { [weak self, weak chip] in
                guard let self, let chip, let index = self.chips.firstIndex(of: chip) else { return }
                self.delegate?.tabBar(self, didSelectTabAt: index)
            }
            chip.onClose = { [weak self, weak chip] in
                guard let self, let chip, let index = self.chips.firstIndex(of: chip) else { return }
                self.delegate?.tabBar(self, didCloseTabAt: index)
            }
            chip.apply(theme: theme)
            stack.addArrangedSubview(chip)
            chips.append(chip)
        }

        for (index, chip) in chips.enumerated() {
            chip.configure(title: titles[index],
                           status: index < statuses.count ? statuses[index] : .none,
                           isSelected: index == selected,
                           showsClose: titles.count > 1)
        }

        // A tab selected by keyboard shortcut may be off-screen.
        if selected < chips.count {
            let chip = chips[selected]
            layoutIfNeeded()
            scrollView.scrollRectToVisible(chip.frame.insetBy(dx: -12, dy: 0), animated: true)
        }
    }

    @objc private func addTapped() {
        delegate?.tabBarDidRequestNewTab(self)
    }
}

/// One tab. Shows a title, a close button, and a subtle selected state.
private final class TabChip: UIControl {

    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?

    private let label = UILabel()
    private let closeButton = UIButton(type: .system)

    private let indicator = UIView()
    /// A command still running, or the last one having failed, is worth seeing
    /// without switching to the tab. Success shows nothing — a dot on every
    /// finished command would be noise.
    private let statusDot = UIView()
    private var labelLeading: NSLayoutConstraint!
    private var status: CommandStatus = .none
    private var isSelectedTab = false
    private var theme: Theme = Preferences.shared.theme(for: UITraitCollection.current.userInterfaceStyle)

    override init(frame: CGRect) {
        super.init(frame: frame)

        layer.cornerRadius = 8
        layer.cornerCurve = .continuous

        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        closeButton.setImage(UIImage(systemName: "xmark",
                                     withConfiguration: UIImage.SymbolConfiguration(pointSize: 9, weight: .bold)),
                             for: .normal)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeButton.accessibilityLabel = "Close Tab"
        addSubview(closeButton)

        indicator.layer.cornerRadius = 1
        indicator.isHidden = true
        indicator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(indicator)

        statusDot.layer.cornerRadius = 3
        statusDot.isHidden = true
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusDot)

        addTarget(self, action: #selector(selectTapped), for: .touchUpInside)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 78),
            widthAnchor.constraint(lessThanOrEqualToConstant: 190),

            label.centerYAnchor.constraint(equalTo: centerYAnchor),

            statusDot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            statusDot.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusDot.widthAnchor.constraint(equalToConstant: 6),
            statusDot.heightAnchor.constraint(equalToConstant: 6),

            closeButton.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 4),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 20),
            closeButton.heightAnchor.constraint(equalToConstant: 20),

            indicator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            indicator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            indicator.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            indicator.heightAnchor.constraint(equalToConstant: 2),
        ])

        labelLeading = label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10)
        labelLeading.isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func apply(theme: Theme) {
        self.theme = theme
        refreshColors()
    }

    func configure(title: String, status: CommandStatus, isSelected: Bool, showsClose: Bool) {
        label.text = title.isEmpty ? "shell" : title
        closeButton.isHidden = !showsClose
        self.isSelectedTab = isSelected
        self.status = status

        let showsDot = status != .none
        statusDot.isHidden = !showsDot
        labelLeading.constant = showsDot ? 21 : 10

        switch status {
        case .none:    accessibilityValue = nil
        case .running: accessibilityValue = "running"
        case .failed:  accessibilityValue = "last command failed"
        }
        refreshColors()
    }

    /// Mixed from the palette's own two colours, so a chip is legible on
    /// every theme without a per-theme table to keep in step.
    private func refreshColors() {
        let raised = TabBarView.activeChipBackground(for: theme)
        let dimmed = TabBarView.inactiveChipText(for: theme)
        backgroundColor = isSelectedTab ? raised.uiColor : .clear
        label.textColor = (isSelectedTab ? theme.foreground : dimmed).uiColor
        closeButton.tintColor = (isSelectedTab ? theme.foreground : dimmed).uiColor
        indicator.backgroundColor = TabBarView.activeChipIndicator(for: theme).uiColor
        indicator.isHidden = !isSelectedTab

        // From the theme's own palette, so the dot belongs to whatever the
        // user picked rather than being a fixed system red.
        switch status {
        case .none:    break
        case .running: statusDot.backgroundColor = theme.cursor.uiColor
        case .failed:  statusDot.backgroundColor = theme.ansi.count > 1
                            ? theme.ansi[1].uiColor : UIColor.systemRed
        }
    }

    @objc private func selectTapped() { onSelect?() }
    @objc private func closeTapped() { onClose?() }
}
