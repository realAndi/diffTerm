import UIKit

/// Owns the tab strip and the stack of tabs. Each tab is a
/// `SplitContainerController` holding one or more terminals.
final class RootViewController: UIViewController {

    private let tabBar = TabBarView()
    private let containerView = UIView()

    private var tabs: [SplitContainerController] = []
    private var selectedIndex = 0

    private var keyboardOverlap: CGFloat = 0
    private var tabBarRefreshScheduled = false
    private var bannerView: NotificationBanner?

    override func viewDidLoad() {
        super.viewDidLoad()

        applyThemeBackground()

        containerView.clipsToBounds = true
        view.addSubview(containerView)

        tabBar.delegate = self
        view.addSubview(tabBar)

        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardWillChangeFrame(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardWillHide(_:)),
            name: UIResponder.keyboardWillHideNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(programNotification(_:)),
            name: TerminalSession.didPostProgramNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(preferencesChanged),
            name: Preferences.didChangeNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(commandStateChanged),
            name: TerminalSession.commandStateDidChangeNotification, object: nil)

        NotificationCenter.default.addObserver(
            self, selector: #selector(applicationDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification, object: nil)

        restoreOrOpenFirstTab()
        refreshAppIcon()
    }

    /// Shell integration marks arrive on the emulator's own thread of control
    /// during output; coalesce so a fast script does not rebuild the tab bar
    /// once per prompt.
    @objc private func commandStateChanged() {
        guard !tabBarRefreshScheduled else { return }
        tabBarRefreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            self.tabBarRefreshScheduled = false
            self.refreshTabBar()
        }
    }

    @objc private func applicationDidBecomeActive() {
        AppIconManager.applyPendingIfNeeded()
        refreshAppIcon()
    }

    /// Turning the preference off restores the stock icon, so someone using an
    /// icon theme gets back the one their theme actually targets.
    private func refreshAppIcon() {
        guard Preferences.shared.matchIconToTheme else {
            AppIconManager.restoreDefault()
            return
        }
        AppIconManager.apply(theme: Preferences.shared.theme(for: traitCollection.userInterfaceStyle))
    }

    /// The status bar and home indicator strips are outside the safe area, so
    /// nothing is ever laid out in them — but they are still the app, and
    /// leaving them black framed the terminal in a letterbox that made a
    /// full-screen app look like it was running in a window. They get the
    /// theme's background instead, so the colour runs edge to edge.
    private func applyThemeBackground() {
        let theme = Preferences.shared.theme(for: traitCollection.userInterfaceStyle)
        view.backgroundColor = theme.background.uiColor
        view.window?.backgroundColor = theme.background.uiColor
        tabBar.apply(theme: theme)
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        let theme = Preferences.shared.theme(for: traitCollection.userInterfaceStyle)
        return theme.isDark ? .lightContent : .darkContent
    }

    override var childForStatusBarStyle: UIViewController? { nil }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutChrome()
    }

    private func layoutChrome() {
        let top = view.safeAreaInsets.top
        let showsTabBar = tabs.count > 0
        let tabHeight = showsTabBar ? TabBarView.preferredHeight : 0

        tabBar.frame = CGRect(x: 0, y: top, width: view.bounds.width, height: tabHeight)
        tabBar.isHidden = !showsTabBar

        // The keyboard (plus its accessory row) eats into the bottom; the home
        // indicator inset only applies when the keyboard is down.
        let bottomInset = keyboardOverlap > 0 ? keyboardOverlap : view.safeAreaInsets.bottom
        let containerTop = top + tabHeight
        containerView.frame = CGRect(x: 0, y: containerTop,
                                     width: view.bounds.width,
                                     height: max(0, view.bounds.height - containerTop - bottomInset))

        for tab in tabs { tab.view.frame = containerView.bounds }
        bannerView?.frame = bannerFrame()
    }

    // MARK: - Tabs

    var activeTab: SplitContainerController? {
        tabs.indices.contains(selectedIndex) ? tabs[selectedIndex] : nil
    }

    /// Puts back whatever was on screen when the app was last backgrounded.
    /// Falls back to a single empty tab, which is also what happens the first
    /// time and whenever the feature is switched off.
    private func restoreOrOpenFirstTab() {
        let snapshots = Preferences.shared.restoreSessions ? SessionStore.load() : []
        guard !snapshots.isEmpty else {
            addTab(activate: true)
            return
        }
        // Ask the daemon which of the saved sessions are still alive, so
        // those tabs reattach to a running shell (and skip restoring the
        // stale screen) while the rest restore from the snapshot as before.
        let live = Preferences.shared.persistentSessions
            ? DaemonSessionManager.shared.liveSessionIDs() : []
        for snapshot in snapshots {
            let isLive = snapshot.daemonSessionID != 0 && live.contains(snapshot.daemonSessionID)
            addTab(activate: false, restoring: snapshot, reattachLive: isLive)
        }
        selectTab(at: 0)
    }

    /// Writes every tab's screen to disk. Called on the way into the
    /// background — the last moment we are reliably given — and again on
    /// termination, which iOS often skips.
    func saveSessionState() {
        guard Preferences.shared.restoreSessions else {
            SessionStore.clear()
            return
        }
        SessionStore.save(tabs.map { $0.activePane.session.snapshot() })
    }

    @discardableResult
    func addTab(activate: Bool, restoring snapshot: SessionSnapshot? = nil,
                reattachLive: Bool = false,
                inheriting directory: String? = nil) -> SplitContainerController {
        let size = containerView.bounds.size == .zero ? view.bounds.size : containerView.bounds.size
        // The real geometry arrives on first layout; this just keeps the shell
        // from starting at a nonsense size.
        let session = TerminalSession(cols: max(20, Int(size.width / 8)),
                                      rows: max(5, Int(size.height / 17)),
                                      inheriting: directory)
        // Before the pane exists, so the restored history is already in
        // scrollback when the shell writes its first prompt. A tab reattaching
        // to a live daemon session skips the saved screen — the daemon replays
        // the live one — but still takes the session id and directory.
        if let snapshot { session.restore(from: snapshot, includeScreen: !reattachLive) }

        let pane = TerminalPaneController(session: session)
        let tab = SplitContainerController(initialPane: pane)
        tab.delegate = self

        addChild(tab)
        containerView.addSubview(tab.view)
        tab.view.frame = containerView.bounds
        tab.didMove(toParent: self)

        tabs.append(tab)
        if activate {
            selectTab(at: tabs.count - 1)
        } else {
            tab.view.isHidden = true
            refreshTabBar()
        }
        return tab
    }

    /// Where a new tab should start. Following the tab it was opened from is
    /// what most people mean by "another one of these", but starting somewhere
    /// predictable is a position people hold just as firmly, so it is a
    /// setting rather than a decision made for them.
    private func directoryForNewTab() -> String? {
        guard Preferences.shared.newTabInheritsDirectory else { return nil }
        return activeTab?.activePane.session.workingDirectory
    }

    func selectTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        selectedIndex = index
        for (i, tab) in tabs.enumerated() {
            tab.view.isHidden = i != index
        }
        refreshTabBar()
        view.setNeedsLayout()
        tabs[index].activePane.becomeFirstResponderIfPossible()
    }

    func closeTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        let tab = tabs[index]

        let performClose = { [weak self] in
            guard let self, let currentIndex = self.tabs.firstIndex(of: tab) else { return }
            tab.closeAll()
            tab.willMove(toParent: nil)
            tab.view.removeFromSuperview()
            tab.removeFromParent()
            self.tabs.remove(at: currentIndex)

            if self.tabs.isEmpty {
                self.addTab(activate: true)
            } else {
                self.selectTab(at: min(currentIndex, self.tabs.count - 1))
            }
        }

        let hasRunning = tab.panes.contains { $0.session.isRunning }
        guard hasRunning, Preferences.shared.confirmCloseWithRunningProcess else {
            performClose()
            return
        }

        let alert = UIAlertController(
            title: tab.panes.count > 1 ? "Close this tab?" : "Close this terminal?",
            message: "A process is still running and will be stopped.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Close", style: .destructive) { _ in performClose() })
        present(alert, animated: true)
    }

    private func refreshTabBar() {
        let titles = tabs.map { tab -> String in
            let title = tab.activePane.session.displayTitle
            return tab.panes.count > 1 ? "\(title) ⧉" : title
        }
        // Across every pane in the tab, not just the active one: the whole
        // point is to see that something is happening where you are not
        // looking. Anything failing wins over anything running.
        let statuses = tabs.map { tab -> CommandStatus in
            let all = tab.panes.map { CommandStatus.from($0.session.emulator.shellIntegration) }
            if all.contains(where: { $0 == .failed }) { return .failed }
            return all.contains(where: { $0 == .running }) ? .running : .none
        }
        tabBar.reload(titles: titles, statuses: statuses, selected: selectedIndex)
        setNeedsStatusBarAppearanceUpdate()
    }

    /// The app is terminating. Daemon-backed sessions are *detached* so their
    /// shells keep running for next launch; only a session that cannot survive
    /// the app going away is stopped.
    func prepareForTermination() {
        for tab in tabs {
            for pane in tab.panes where pane.session.isRunning {
                pane.session.detachKeepingAlive()
            }
        }
    }

    // MARK: - Settings

    func presentSettings() {
        // Settings is a place you go, not a drawer over the terminal: a sheet
        // left the shell visible behind it and the keyboard up in front of it.
        // Full screen, and the terminal gives up first responder on the way
        // out — otherwise the software keyboard stays raised under the modal
        // and Settings opens into whatever space is left.
        for tab in tabs {
            for pane in tab.panes { pane.resignPaneFirstResponder() }
        }
        view.endEditing(true)

        let settings = SettingsViewController()
        let nav = UINavigationController(rootViewController: settings)
        nav.modalPresentationStyle = .fullScreen
        present(nav, animated: true)
    }

    @objc private func preferencesChanged() {
        applyThemeBackground()
        setNeedsStatusBarAppearanceUpdate()
        view.setNeedsLayout()
        refreshAppIcon()
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        // "Match System" means the effective theme flips with appearance, and
        // the icon follows it.
        if previous?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            applyThemeBackground()
            setNeedsStatusBarAppearanceUpdate()
            refreshAppIcon()
        }
    }

    // MARK: - Keyboard

    @objc private func keyboardWillChangeFrame(_ note: Notification) {
        guard let end = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
        else { return }
        let converted = view.convert(end, from: nil)
        keyboardOverlap = max(0, view.bounds.maxY - converted.minY)
        animateLayout(with: note)
    }

    @objc private func keyboardWillHide(_ note: Notification) {
        keyboardOverlap = 0
        animateLayout(with: note)
    }

    private func animateLayout(with note: Notification) {
        let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        let curveRaw = (note.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int) ?? 7
        let options = UIView.AnimationOptions(rawValue: UInt(curveRaw) << 16)
        UIView.animate(withDuration: duration, delay: 0, options: options) {
            self.layoutChrome()
            self.view.layoutIfNeeded()
        }
    }

    // MARK: - Banner

    @objc private func programNotification(_ note: Notification) {
        let title = note.userInfo?["title"] as? String ?? "diffTerm"
        let body = note.userInfo?["body"] as? String ?? ""
        showBanner(title: title, body: body)
    }

    private func bannerFrame() -> CGRect {
        let width = min(view.bounds.width - 24, 420)
        return CGRect(x: (view.bounds.width - width) / 2,
                      y: view.safeAreaInsets.top + TabBarView.preferredHeight + 8,
                      width: width, height: 56)
    }

    private func showBanner(title: String, body: String) {
        bannerView?.removeFromSuperview()
        let banner = NotificationBanner(title: title, body: body)
        banner.frame = bannerFrame()
        banner.alpha = 0
        banner.transform = CGAffineTransform(translationX: 0, y: -12)
        view.addSubview(banner)
        bannerView = banner

        UIView.animate(withDuration: 0.22) {
            banner.alpha = 1
            banner.transform = .identity
        }
        UIView.animate(withDuration: 0.22, delay: 3.0, options: []) {
            banner.alpha = 0
            banner.transform = CGAffineTransform(translationX: 0, y: -12)
        } completion: { _ in
            banner.removeFromSuperview()
            if self.bannerView === banner { self.bannerView = nil }
        }
    }
}

// MARK: - Tab bar delegate

extension RootViewController: TabBarViewDelegate {

    func tabBar(_ bar: TabBarView, didSelectTabAt index: Int) {
        selectTab(at: index)
    }

    func tabBar(_ bar: TabBarView, didCloseTabAt index: Int) {
        closeTab(at: index)
    }

    func tabBarDidRequestNewTab(_ bar: TabBarView) {
        addTab(activate: true, inheriting: directoryForNewTab())
    }

    func tabBarMenu(_ bar: TabBarView) -> UIMenu {
        var splitActions: [UIAction] = [
            UIAction(title: "Split Right", image: UIImage(systemName: "rectangle.split.2x1")) { [weak self] _ in
                guard let tab = self?.activeTab else { return }
                tab.split(pane: tab.activePane, vertical: true)
            },
            UIAction(title: "Split Down", image: UIImage(systemName: "rectangle.split.1x2")) { [weak self] _ in
                guard let tab = self?.activeTab else { return }
                tab.split(pane: tab.activePane, vertical: false)
            },
        ]

        // Only meaningful once the tab is actually split, and there is no
        // other way to do it by touch.
        if (activeTab?.panes.count ?? 0) > 1 {
            splitActions.append(UIAction(title: "Close Pane",
                                         image: UIImage(systemName: "xmark.rectangle"),
                                         attributes: .destructive) { [weak self] _ in
                self?.activeTab?.closeActivePane()
            })
            splitActions.append(UIAction(title: "Close Other Panes",
                                         image: UIImage(systemName: "rectangle.on.rectangle.slash"),
                                         attributes: .destructive) { [weak self] _ in
                self?.activeTab?.closeOtherPanes()
            })
            splitActions.append(UIAction(title: "Even Out Splits",
                                         image: UIImage(systemName: "arrow.left.and.right.square")) { [weak self] _ in
                self?.activeTab?.evenOutSplits()
            })
        }

        let split = UIMenu(title: "Split", options: .displayInline, children: splitActions)

        let terminal = UIMenu(title: "Terminal", options: .displayInline, children: [
            UIAction(title: "Clear", image: UIImage(systemName: "trash")) { [weak self] _ in
                self?.activeTab?.activePane.clearScreen()
            },
            UIAction(title: "Reset", image: UIImage(systemName: "arrow.counterclockwise")) { [weak self] _ in
                self?.activeTab?.activePane.resetTerminal()
            },
            UIAction(title: "Find", image: UIImage(systemName: "magnifyingglass")) { [weak self] _ in
                self?.activeTab?.activePane.showSearch()
            },
            UIAction(title: "Send Ctrl-C", image: UIImage(systemName: "stop.circle")) { [weak self] _ in
                self?.activeTab?.activePane.session.send(bytes: [0x03])
            },
        ])

        let app = UIMenu(title: "", options: .displayInline, children: [
            UIAction(title: "Settings", image: UIImage(systemName: "gearshape")) { [weak self] _ in
                self?.presentSettings()
            },
        ])

        return UIMenu(children: [split, terminal, app])
    }
}

// MARK: - Split container delegate

extension RootViewController: SplitContainerDelegate {

    func splitContainer(_ container: SplitContainerController, didChangeActivePane pane: TerminalPaneController) {
        guard let index = tabs.firstIndex(of: container) else { return }
        if index != selectedIndex { selectTab(at: index) }
        refreshTabBar()
    }

    func splitContainerDidBecomeEmpty(_ container: SplitContainerController) {
        guard let index = tabs.firstIndex(of: container) else { return }
        // The pane already tore itself down; close the tab without asking
        // again about a process that is no longer running.
        container.willMove(toParent: nil)
        container.view.removeFromSuperview()
        container.removeFromParent()
        tabs.remove(at: index)
        if tabs.isEmpty {
            addTab(activate: true)
        } else {
            selectTab(at: min(index, tabs.count - 1))
        }
    }

    func splitContainer(_ container: SplitContainerController, didUpdateTitle title: String) {
        guard tabs.contains(container) else { return }
        refreshTabBar()
    }

    func splitContainerDidRequestNewTab(_ container: SplitContainerController) {
        addTab(activate: true, inheriting: directoryForNewTab())
    }

    func splitContainerDidRequestSettings(_ container: SplitContainerController) {
        presentSettings()
    }

    func splitContainerDidRequestNextTab(_ container: SplitContainerController) {
        guard !tabs.isEmpty else { return }
        selectTab(at: (selectedIndex + 1) % tabs.count)
    }

    func splitContainerDidRequestPreviousTab(_ container: SplitContainerController) {
        guard !tabs.isEmpty else { return }
        selectTab(at: (selectedIndex - 1 + tabs.count) % tabs.count)
    }

    func splitContainer(_ container: SplitContainerController, didRequestTabAtIndex index: Int) {
        selectTab(at: index)
    }
}

/// Small transient banner for OSC 9 / OSC 777 notifications.
final class NotificationBanner: UIView {

    init(title: String, body: String) {
        super.init(frame: .zero)

        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterial))
        blur.frame = bounds
        blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        blur.layer.cornerRadius = 14
        blur.layer.cornerCurve = .continuous
        blur.clipsToBounds = true
        addSubview(blur)

        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.18
        layer.shadowRadius = 10
        layer.shadowOffset = CGSize(width: 0, height: 4)

        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)

        let bodyLabel = UILabel()
        bodyLabel.text = body
        bodyLabel.font = .systemFont(ofSize: 12)
        bodyLabel.textColor = .secondaryLabel
        bodyLabel.lineBreakMode = .byTruncatingTail

        let stack = UIStackView(arrangedSubviews: [titleLabel, bodyLabel])
        stack.axis = .vertical
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}
