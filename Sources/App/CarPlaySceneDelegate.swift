import CarPlay

/// The terminal on a CarPlay screen.
///
/// CarPlay only lets a navigation app draw its own content: it gets a window
/// whose root view — the "map" — is whatever the app likes, with a map
/// template laid over it for the buttons. So diffTerm presents itself as one
/// (the `carplay-maps` entitlement), the terminal is the map, and the
/// templates carry what a driver can do: four keys beside the text, the rest
/// a tap away, the car's keyboard for a whole line, a list of the tabs, and
/// scrolling back. The phone stays the real keyboard.
///
/// Nothing here may wait on the car. Every template call is a message to
/// another process, CarPlayTemplateUIHost, and a few of them wait for its
/// answer: `CPMapTemplate.isPanningInterfaceVisible`, and
/// `CPInterfaceController`'s `topTemplate`, `templates` and
/// `presentedTemplate`. Asked while the car's scene is still being set up,
/// the host is waiting on us while we wait on it, and ten seconds later the
/// watchdog kills the app — which is what every "diffTerm will not load in
/// the car" crash report on the development phone was. So none of them is
/// used, and what they would say is kept here, from the delegate callbacks.
///
/// The Objective-C name is fixed because Info.plist names the class, and the
/// Swift module name follows APP_NAME, which a second install changes.
@objc(DTCarPlaySceneDelegate)
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate,
                                  CPMapTemplateDelegate, CPSessionConfigurationDelegate {

    private var interfaceController: CPInterfaceController?
    private var mapTemplate: CPMapTemplate?
    private var terminal: CarPlayTerminalController?
    private var commandLine: CarPlayCommandLine?

    /// The car's own say in what it will show. Cars commonly refuse the
    /// keyboard while moving, and then the button that opens it is hidden
    /// rather than left there to do nothing.
    private var sessionConfiguration: CPSessionConfiguration?
    private var keyboardLimited = false

    /// Whether the car is showing its panning arrows. Kept from the delegate
    /// callbacks rather than asked for: see the class comment.
    private var panning = false

    /// What the navigation bar was last set to. Each change is a message to
    /// the car and a redraw of its bar, so it is only sent when this changes.
    private var navigationBar: NavigationBar?

    private var observers: [NSObjectProtocol] = []

    private enum NavigationBar: Equatable {
        case panning
        case normal(keyboard: Bool, scrolledBack: Bool)
    }

    /// How long a command has to run before the car says it finished. The
    /// same as the phone's notification: shorter ones finished while you were
    /// still watching.
    private static let alertAfter = CommandNotifier.minimumDuration

    /// Connecting has ten seconds of wall clock, total, and the car's own
    /// systems are waiting on it — so this does the least it can: hand over a
    /// view, hand over a template, and get out. Everything else happens on
    /// the next turn of the run loop, in `finishConnecting`.
    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController,
                                  to window: CPWindow) {
        trace("connecting")
        self.interfaceController = interfaceController

        let terminal = CarPlayTerminalController()
        terminal.onStateChange = { [weak self] in self?.updateNavigationBar() }
        if #available(iOS 15.4, *) {
            terminal.overrideUserInterfaceStyle = templateApplicationScene.contentStyle
        }
        // Where the car puts its own buttons, so the text never runs under
        // the keys.
        terminal.buttonArea = { [weak window] in
            guard let window else { return .zero }
            return window.mapButtonSafeAreaLayoutGuide.layoutFrame
        }
        window.rootViewController = terminal
        self.terminal = terminal

        commandLine = CarPlayCommandLine(interfaceController: interfaceController)

        let map = CPMapTemplate()
        map.mapDelegate = self
        // The map buttons are the keys, so they stay put. Only the
        // navigation bar gets out of the way when nobody is reaching for it.
        map.automaticallyHidesNavigationBar = true
        map.hidesButtonsWithNavigationBar = false
        map.mapButtons = makeKeys()
        mapTemplate = map
        updateNavigationBar()
        trace("setting the root template")
        interfaceController.setRootTemplate(map, animated: false, completion: nil)

        DispatchQueue.main.async { [weak self] in self?.finishConnecting(window: window) }
        trace("connected")
    }

    /// The rest of connecting, once the car has its scene update back.
    private func finishConnecting(window: CPWindow) {
        // The car may be the first screen this launch has, with nothing on
        // the phone to lay the tabs out.
        trace("laying out the tabs")
        RootViewController.shared.prepareWithoutWindowIfNeeded()

        trace("asking the car about its keyboard")
        let configuration = CPSessionConfiguration(delegate: self)
        keyboardLimited = configuration.limitedUserInterfaces.contains(.keyboard)
        sessionConfiguration = configuration
        updateNavigationBar()

        trace("starting frames")
        terminal?.start(on: window.screen)

        // Handing the app a second window can take the key window with it,
        // and the phone's keyboard goes with that. The phone is still where
        // the typing happens.
        PhoneSceneDelegate.takeBackKeyWindow()

        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: TerminalSession.commandDidFinishNotification,
                               object: nil, queue: .main) { [weak self] note in
                self?.commandFinished(note)
            },
            center.addObserver(forName: TerminalSession.didPostProgramNotification,
                               object: nil, queue: .main) { [weak self] note in
                self?.programPosted(note)
            },
        ]

        // Last, and on its own turn of the run loop: forking a shell is the
        // slowest step here, and by now the car is already showing whatever
        // the last session left on screen.
        DispatchQueue.main.async {
            self.trace("starting the shells")
            RootViewController.shared.startSessionsIfNeeded()
            self.trace("ready")
        }
    }

    /// Breadcrumbs for a screen that can only be tested in a car: the last
    /// line logged before a hang says which step did not come back. Visible
    /// in Console.app with the phone attached, filtered to diffTerm.
    private func trace(_ step: String) {
        NSLog("diffTerm carplay: %@", step)
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnect interfaceController: CPInterfaceController,
                                  from window: CPWindow) {
        trace("disconnecting")
        // Only the car's view goes. The shells belong to RootViewController
        // and carry on, on the phone or in the background as usual.
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        terminal?.stop()
        // The phone takes its own size back.
        CarPlayLink.shared.disconnect()
        window.rootViewController = nil
        terminal = nil
        commandLine = nil
        sessionConfiguration = nil
        mapTemplate = nil
        navigationBar = nil
        panning = false
        self.interfaceController = nil
    }

    func sessionConfiguration(_ sessionConfiguration: CPSessionConfiguration,
                              limitedUserInterfacesChanged limitedUserInterfaces: CPLimitableUserInterface) {
        keyboardLimited = limitedUserInterfaces.contains(.keyboard)
        updateNavigationBar()
    }

    /// The car switched between its day and night looks.
    @available(iOS 15.4, *)
    func contentStyleDidChange(_ contentStyle: UIUserInterfaceStyle) {
        terminal?.overrideUserInterfaceStyle = contentStyle
    }

    // MARK: - Keys, which are the only keyboard CarPlay gives an app

    /// A key the car can press, and what the phone's key row would send for
    /// it. Nothing new is invented here: every one of these goes through the
    /// same `sendKey` the on-screen keyboard uses.
    private enum Key {
        case special(SpecialKeyID)
        case bytes([UInt8])
    }

    private func press(_ key: Key) {
        guard let pane = RootViewController.shared.activeTab?.activePane else { return }
        switch key {
        case .special(let id): pane.sendKey(id.key)
        case .bytes(let bytes): pane.session.send(bytes: bytes)
        }
    }

    /// Sizes a symbol for the car, which draws these much larger than a
    /// phone does. Takes the image rather than its name so the names stay
    /// literal in the source, where the harness checks that each one resolves.
    private func sized(_ image: UIImage?, points: CGFloat = 20) -> UIImage {
        let configuration = UIImage.SymbolConfiguration(pointSize: points, weight: .semibold)
        return image?.applyingSymbolConfiguration(configuration) ?? image ?? UIImage()
    }

    /// Four keys, always on screen beside the text: stop something, walk
    /// back through history, and answer a prompt. Built once — they never
    /// change, and setting them again redraws them on the car.
    private func makeKeys() -> [CPMapButton] {
        func key(_ image: UIImage?, _ key: Key) -> CPMapButton {
            let button = CPMapButton { [weak self] _ in self?.press(key) }
            button.image = sized(image)
            return button
        }
        return [
            key(UIImage(systemName: "stop.circle"), .bytes([0x03])),
            key(UIImage(systemName: "arrow.up"), .special(.up)),
            key(UIImage(systemName: "arrow.down"), .special(.down)),
            key(UIImage(systemName: "return"), .special(.enter)),
        ]
    }

    /// The navigation bar: the tabs on one side, the keys and the car's
    /// keyboard on the other, and — like the recentre button a maps app
    /// shows once you have dragged the map — Live, once the view has been
    /// moved off the newest output.
    private func updateNavigationBar() {
        guard let map = mapTemplate else { return }
        let bar: NavigationBar = panning
            ? .panning
            : .normal(keyboard: !keyboardLimited, scrolledBack: terminal?.isScrolledBack ?? false)
        guard bar != navigationBar else { return }
        navigationBar = bar

        switch bar {
        case .panning:
            // The car draws its own arrows; this is the way out.
            map.leadingNavigationBarButtons = []
            map.trailingNavigationBarButtons = [
                CPBarButton(title: "Done") { [weak self] _ in
                    self?.mapTemplate?.dismissPanningInterface(animated: true)
                },
            ]
        case .normal(let keyboard, let scrolledBack):
            var leading = [CPBarButton(title: "Tabs") { [weak self] _ in self?.presentTabs() }]
            if scrolledBack {
                leading.append(CPBarButton(title: "Live") { [weak self] _ in
                    self?.terminal?.scrollToLive()
                })
            }
            map.leadingNavigationBarButtons = leading

            var trailing = [CPBarButton(title: "Keys") { [weak self] _ in self?.presentKeys() }]
            if keyboard {
                trailing.append(CPBarButton(title: "Type") { [weak self] _ in self?.commandLine?.present() })
            }
            map.trailingNavigationBarButtons = trailing
        }
    }

    /// The rest of the key row, as a page of eight. A template covers the
    /// terminal while it is open, which is the trade for having more than
    /// four keys: press what you need, then go back to watching.
    private func presentKeys() {
        var buttons: [CPGridButton] = []

        func button(_ title: String, _ image: UIImage?, _ action: @escaping () -> Void) {
            buttons.append(CPGridButton(titleVariants: [title],
                                        image: sized(image, points: 30)) { _ in action() })
        }
        func key(_ title: String, _ image: UIImage?, _ key: Key) {
            button(title, image) { [weak self] in self?.press(key) }
        }

        key("esc", UIImage(systemName: "escape"), .special(.escape))
        key("tab", UIImage(systemName: "arrow.right.to.line"), .special(.tab))
        key("left", UIImage(systemName: "arrow.left"), .special(.left))
        key("right", UIImage(systemName: "arrow.right"), .special(.right))
        key("ctrl-c", UIImage(systemName: "stop.circle"), .bytes([0x03]))
        key("ctrl-d", UIImage(systemName: "d.circle"), .bytes([0x04]))

        // Not keys. Scrolling is dragging on a touchscreen, but a car driven
        // by a knob or a touchpad needs the car's panning arrows for it, and
        // this is the way in.
        button("scroll", UIImage(systemName: "arrow.up.arrow.down")) { [weak self] in
            self?.interfaceController?.popToRootTemplate(animated: true) { _, _ in
                self?.mapTemplate?.showPanningInterface(animated: true)
            }
        }
        button("live", UIImage(systemName: "arrow.down.to.line")) { [weak self] in
            self?.terminal?.scrollToLive()
            self?.interfaceController?.popToRootTemplate(animated: true, completion: nil)
        }

        let pad = CPGridTemplate(title: "Keys", gridButtons: buttons)
        interfaceController?.pushTemplate(pad, animated: true, completion: nil)
    }

    // MARK: - Tabs

    /// Every tab, with what it is doing, and a new one. Picking one shows it
    /// on both screens and goes back to the terminal.
    private func presentTabs() {
        let root = RootViewController.shared
        let home = UserEnvironment.home
        var items: [CPListItem] = []

        // Room for the New Tab row under however many tabs the car will list.
        let limit = max(1, Int(CPListTemplate.maximumItemCount) - 1)
        for (index, tab) in root.tabSummaries.prefix(limit).enumerated() {
            let session = tab.pane.session
            let block = session.emulator.shellIntegration.last
            let row = CarPlayTabRows.row(for: CarPlayTabRows.Tab(
                title: session.displayTitle,
                paneCount: tab.paneCount,
                shellExitCode: session.exitCode,
                command: block.flatMap { session.commandText(for: $0) },
                commandRunning: block?.isRunning ?? false,
                commandExitCode: block?.exitCode,
                directory: session.workingDirectory), home: home)

            let selected = index == root.selectedTabIndex
            let item = CPListItem(text: row.title, detailText: row.detail,
                                  image: sized(symbol(for: row.state), points: 24),
                                  accessoryImage: selected ? sized(UIImage(systemName: "checkmark")) : nil,
                                  accessoryType: .none)
            item.handler = { [weak self] _, completion in
                RootViewController.shared.selectTab(at: index)
                self?.interfaceController?.popToRootTemplate(animated: true, completion: nil)
                completion()
            }
            items.append(item)
        }

        let newTab = CPListItem(text: "New Tab", detailText: nil,
                                image: sized(UIImage(systemName: "plus"), points: 24))
        newTab.handler = { [weak self] _, completion in
            RootViewController.shared.openTabFromCar()
            self?.interfaceController?.popToRootTemplate(animated: true, completion: nil)
            completion()
        }
        items.append(newTab)

        let list = CPListTemplate(title: "Tabs", sections: [CPListSection(items: items)])
        interfaceController?.pushTemplate(list, animated: true, completion: nil)
    }

    private func symbol(for state: CarPlayTabRows.State) -> UIImage? {
        switch state {
        case .idle: return UIImage(systemName: "terminal")
        case .running: return UIImage(systemName: "hourglass")
        case .failed: return UIImage(systemName: "exclamationmark.triangle")
        case .exited: return UIImage(systemName: "xmark.circle")
        }
    }

    // MARK: - Alerts

    /// A long command finished, in any tab. The phone's own notification
    /// needs the app in the background, which a car on its screen prevents,
    /// so the car says it instead.
    private func commandFinished(_ note: Notification) {
        guard Preferences.shared.notifyOnCommandFinish,
              let session = note.object as? TerminalSession,
              let info = note.userInfo,
              let duration = info["duration"] as? TimeInterval,
              duration >= Self.alertAfter else { return }
        let code = info["exitCode"] as? Int
        let failed = (code ?? 0) != 0
        let summary = CommandNotifier.summary(command: info["command"] as? String,
                                              exitCode: code, duration: duration)
        showAlert(title: failed ? "Command failed" : "Command finished",
                  subtitle: summary,
                  image: failed ? UIImage(systemName: "xmark.octagon") : UIImage(systemName: "checkmark.circle"),
                  about: session)
    }

    /// A program asked to tell someone something (OSC 9 or 777). On the
    /// phone that is a banner over the terminal, which nobody sees while it
    /// is locked in a car.
    private func programPosted(_ note: Notification) {
        guard let session = note.object as? TerminalSession else { return }
        let title = note.userInfo?["title"] as? String ?? "diffTerm"
        let body = note.userInfo?["body"] as? String ?? ""
        showAlert(title: title, subtitle: body, image: UIImage(systemName: "bell"), about: session)
    }

    /// Shows a banner on the car, replacing any already up: the car shows one
    /// at a time and ignores a second. Show switches to the tab it is about,
    /// if that is not the one on screen already.
    private func showAlert(title: String, subtitle: String, image: UIImage?, about session: TerminalSession) {
        guard let map = mapTemplate else { return }
        let showing = RootViewController.shared.activeTab?.activePane.session === session

        let dismiss = CPAlertAction(title: showing ? "OK" : "Dismiss", style: .cancel) { _ in }
        let primary = showing ? dismiss : CPAlertAction(title: "Show", style: .default) { _ in
            RootViewController.shared.selectTab(containing: session)
        }
        let alert = CPNavigationAlert(titleVariants: [title],
                                      subtitleVariants: subtitle.isEmpty ? [] : [subtitle],
                                      image: sized(image, points: 24),
                                      primaryAction: primary,
                                      secondaryAction: showing ? nil : dismiss,
                                      duration: 8)
        map.dismissNavigationAlert(animated: false) { [weak self, weak map] _ in
            DispatchQueue.main.async {
                guard let map, map === self?.mapTemplate else { return }
                map.present(navigationAlert: alert, animated: true)
            }
        }
    }

    // MARK: - Panning

    func mapTemplateDidShowPanningInterface(_ mapTemplate: CPMapTemplate) {
        panning = true
        updateNavigationBar()
    }

    func mapTemplateDidDismissPanningInterface(_ mapTemplate: CPMapTemplate) {
        panning = false
        updateNavigationBar()
    }

    /// The panning arrows, or a knob or touchpad nudged while panning.
    func mapTemplate(_ mapTemplate: CPMapTemplate, panWith direction: CPMapTemplate.PanDirection) {
        if direction.contains(.up) {
            terminal?.scrollPage(up: true)
        } else if direction.contains(.down) {
            terminal?.scrollPage(up: false)
        } else if direction.contains(.left) {
            terminal?.panPage(left: true)
        } else if direction.contains(.right) {
            terminal?.panPage(left: false)
        }
    }

    /// A finger dragged across a touchscreen.
    func mapTemplateDidBeginPanGesture(_ mapTemplate: CPMapTemplate) {
        terminal?.beginDrag()
    }

    func mapTemplate(_ mapTemplate: CPMapTemplate,
                     didUpdatePanGestureWithTranslation translation: CGPoint, velocity: CGPoint) {
        terminal?.drag(by: translation)
    }

    func mapTemplate(_ mapTemplate: CPMapTemplate, didEndPanGestureWithVelocity velocity: CGPoint) {
        terminal?.endDrag()
    }
}
