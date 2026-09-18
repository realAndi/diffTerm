import UIKit

final class SettingsViewController: SettingsTableViewController {

    private let prefs = Preferences.shared

    init() {
        super.init(title: "Settings")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done, target: self, action: #selector(done))
    }

    @objc private func done() {
        view.endEditing(true)
        dismiss(animated: true)
    }

    private func reloadPreservingEditing() {
        rebuild()
    }

    // MARK: - Model

    override func buildSections() -> [SettingsSection] {
        [appearanceSection(), blocksSection(), predictionSection(),
         fontSection(), cursorSection(), terminalSection(),
         clipboardSection(), keyboardSection(), keyRowSection(),
         shellSection(), snippetsSection(), aboutSection()]
    }

    private func appearanceSection() -> SettingsSection {
        SettingsSection(header: "Appearance", footer: nil, rows: [
            .choice(title: "Theme Mode",
                    value: { [unowned self] in self.prefs.themeMode.title },
                    pick: { [unowned self] host in
                        self.pushPicker(from: host, title: "Theme Mode",
                                        options: ThemeMode.allCases.map { mode in
                            ListPickerController.Option(
                                title: mode.title, subtitle: nil, swatch: nil,
                                isSelected: self.prefs.themeMode == mode,
                                select: { [weak self] in
                                    guard let self else { return }
                                    self.prefs.themeMode = mode
                                })
                        })
                    }),
            .choice(title: "Dark Theme",
                    value: { [unowned self] in Theme.theme(withID: self.prefs.darkThemeID).name },
                    pick: { [unowned self] host in
                        self.pushThemePicker(from: host, dark: true)
                    }),
            .choice(title: "Light Theme",
                    value: { [unowned self] in Theme.theme(withID: self.prefs.lightThemeID).name },
                    pick: { [unowned self] host in
                        self.pushThemePicker(from: host, dark: false)
                    }),
            .toggle(title: "App Icon Follows Theme",
                    subtitle: "Matches the home screen icon to the terminal theme. Turn this off if you theme icons yourself — the stock icon comes back. Icon-theme engines like SnowBoard can briefly flash a blank icon on launch while both reskin it; turning this off lets the engine own the icon and stops the flash.",
                    get: { [unowned self] in self.prefs.matchIconToTheme },
                    set: { [unowned self] in self.prefs.matchIconToTheme = $0 }),
        ])
    }

    private func blocksSection() -> SettingsSection {
        SettingsSection(
            header: "Blocks",
            footer: "Needs a shell that reports where commands begin and end (OSC 133) — "
                  + "starship, powerlevel10k, and the integrations bundled with zsh and fish all do. "
                  + "Without those marks nothing is drawn.",
            rows: [
                .toggle(title: "Command Blocks",
                        subtitle: "Give each command and its output a status rail and a divider. "
                                + "Tap a rail for that command's output.",
                        get: { [unowned self] in self.prefs.blockMode },
                        set: { [unowned self] in self.prefs.blockMode = $0 }),
                .disclosure(title: "Shell Integration",
                            detail: {
                                let shell = ShellIntegrationInstaller.currentShell
                                return ShellIntegrationInstaller.isInstalled(for: shell)
                                    ? "Installed" : "Not set up"
                            }(),
                            action: { [unowned self] host in
                                self.presentShellIntegration(from: host)
                            }),
            ])
    }

    private func predictionSection() -> SettingsSection {
        SettingsSection(
            header: "Prediction",
            footer: nil,
            rows: [
                .toggle(title: "Suggest Next Command",
                        subtitle: "Show the command you are most likely to run next as dim text "
                                + "after the cursor. Tap it or press → to take it. "
                                + "Learned from this device's own history; nothing is sent anywhere.",
                        get: { [unowned self] in self.prefs.commandSuggestions },
                        set: { [unowned self] in self.prefs.commandSuggestions = $0 }),
                .toggle(title: "Tab Takes The Suggestion",
                        subtitle: "With a suggestion showing, Tab accepts it. With none showing, "
                                + "Tab always goes to the shell's own completion.",
                        get: { [unowned self] in self.prefs.suggestionAcceptsTab },
                        set: { [unowned self] in self.prefs.suggestionAcceptsTab = $0 }),
                .button(title: "Clear Command History", destructive: true,
                        action: { [unowned self] host in
                            self.confirmClearHistory(from: host)
                        }),
            ])
    }

    private func clipboardSection() -> SettingsSection {
        SettingsSection(
            header: "Clipboard",
            footer: "The bootstrap's own pbcopy cannot reach the pasteboard and reports success anyway, "
                  + "so diffTerm ships replacements and puts them first on PATH. Writes are never gated — "
                  + "any program that can print to the terminal can already set the clipboard. Reads are, "
                  + "and nothing outside diffTerm can make one.",
            rows: [
                .toggle(title: "Provide pbcopy and pbpaste",
                        subtitle: "Add the bundled copies to PATH ahead of the system ones.",
                        get: { [unowned self] in self.prefs.clipboardHelpers },
                        set: { [unowned self] in self.prefs.clipboardHelpers = $0 }),
                .choice(title: "Allow Reading",
                        value: { [unowned self] in self.prefs.clipboardReadAccess.title },
                        pick: { [unowned self] host in
                            self.pushPicker(from: host, title: "Allow Reading",
                                            options: ClipboardReadAccess.allCases.map { access in
                                ListPickerController.Option(
                                    title: access.title, subtitle: nil, swatch: nil,
                                    isSelected: self.prefs.clipboardReadAccess == access,
                                    select: { [weak self] in
                                        guard let self else { return }
                                        self.prefs.clipboardReadAccess = access
                                    })
                            })
                        }),
            ])
    }

    private func keyRowSection() -> SettingsSection {
        SettingsSection(header: "Key Row",
                        footer: "Which keys the row carries, and your own combinations.", rows: [
            .disclosure(title: "Customise Key Row",
                        detail: prefs.customKeys.isEmpty ? nil : "\(prefs.customKeys.count) custom",
                        action: { host in
                            host.navigationController?.pushViewController(
                                KeyRowSettingsViewController(), animated: true)
                        }),
        ])
    }

    private func confirmClearHistory(from host: UIViewController) {
        let store = CommandHistoryStore.shared
        let alert = UIAlertController(
            title: "Clear Command History?",
            message: "Deletes the \(store.count) recorded commands that suggestions are drawn from. "
                   + "This does not touch your shell's own history file.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Clear", style: .destructive) { _ in
            store.removeAll()
        })
        host.present(alert, animated: true)
    }

    /// Offers to add the source line, and says exactly what will be written
    /// where before doing it. Editing someone's shell configuration without
    /// showing them the edit is not on.
    private func presentShellIntegration(from host: UIViewController) {
        let shell = ShellIntegrationInstaller.currentShell
        let installed = ShellIntegrationInstaller.isInstalled(for: shell)

        let message: String
        if installed {
            message = "\(shell.displayName) is reporting where commands begin and end. "
                    + "Blocks and suggestions work in every new tab.\n\n"
                    + "Installed at \(ShellIntegrationInstaller.scriptPath(for: shell))"
        } else {
            message = "Blocks and next-command suggestions need your shell to report where "
                    + "each command starts and finishes (OSC 133). \(shell.displayName) is not "
                    + "doing that yet.\n\nThis copies a script to "
                    + "\(ShellIntegrationInstaller.installDirectory) and appends two lines to "
                    + "\(shell.rcPath):\n\n"
                    + "# diffTerm shell integration\n"
                    + ShellIntegrationInstaller.sourceLine(for: shell)
                    + "\n\nOpen a new tab afterwards. It does nothing in other terminals."
        }

        let alert = UIAlertController(title: "Shell Integration",
                                      message: message, preferredStyle: .alert)

        if installed {
            alert.addAction(UIAlertAction(title: "Remove", style: .destructive) { [weak self] _ in
                guard let self else { return }
                ShellIntegrationInstaller.uninstall(for: shell)
                self.rebuild()
            })
        } else {
            alert.addAction(UIAlertAction(title: "Install", style: .default) { [weak self, weak host] _ in
                guard let self else { return }
                do {
                    try ShellIntegrationInstaller.install(for: shell)
                    self.rebuild()
                } catch {
                    let failure = UIAlertController(
                        title: "Could Not Install",
                        message: error.localizedDescription
                            + "\n\nIf this keeps happening, please report it on GitHub.",
                        preferredStyle: .alert)
                    failure.addAction(UIAlertAction(title: "OK", style: .cancel))
                    let report = Diagnostics.newIssueURL(
                        headline: "Could not install \(shell.rawValue) shell integration: \(error.localizedDescription)",
                        facts: Diagnostics.facts(shell: TerminalSession.resolvedShell(), workingDirectory: nil))
                    if let url = URL(string: report) {
                        failure.addAction(UIAlertAction(title: "Report on GitHub", style: .default) { _ in
                            UIApplication.shared.open(url)
                        })
                    }
                    host?.present(failure, animated: true)
                }
            })
        }

        if let script = ShellIntegrationInstaller.scriptContents(for: shell) {
            alert.addAction(UIAlertAction(title: "Copy Script", style: .default) { _ in
                UIPasteboard.general.string = script
            })
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        host.present(alert, animated: true)
    }

    private func fontSection() -> SettingsSection {
        SettingsSection(header: "Text", footer: "Pinch in the terminal to change the size quickly.", rows: [
            .choice(title: "Font",
                    value: { [unowned self] in self.currentFontDisplayName() },
                    pick: { [unowned self] host in self.pushFontPicker(from: host) }),
            .stepper(title: "Size",
                     value: { [unowned self] in "\(Int(self.prefs.fontSize)) pt" },
                     decrement: { [unowned self] in self.prefs.fontSize -= 1 },
                     increment: { [unowned self] in self.prefs.fontSize += 1 },
                     canDecrement: { [unowned self] in self.prefs.fontSize > 6 },
                     canIncrement: { [unowned self] in self.prefs.fontSize < 32 }),
            .stepper(title: "Line Height",
                     value: { [unowned self] in String(format: "%.2f×", self.prefs.lineHeightScale) },
                     decrement: { [unowned self] in self.prefs.lineHeightScale -= 0.05 },
                     increment: { [unowned self] in self.prefs.lineHeightScale += 0.05 },
                     canDecrement: { [unowned self] in self.prefs.lineHeightScale > 0.86 },
                     canIncrement: { [unowned self] in self.prefs.lineHeightScale < 1.59 }),
            .toggle(title: "Bold Text Uses Bold Font", subtitle: nil,
                    get: { [unowned self] in self.prefs.useBoldFont },
                    set: { [unowned self] in self.prefs.useBoldFont = $0 }),
            .toggle(title: "Bold Text Is Brighter",
                    subtitle: "Draw the first eight ANSI colours in their bright variant when bold.",
                    get: { [unowned self] in self.prefs.boldIsBright },
                    set: { [unowned self] in self.prefs.boldIsBright = $0 }),
        ])
    }

    private func cursorSection() -> SettingsSection {
        SettingsSection(header: "Cursor", footer: "Programs that set their own cursor style override this.", rows: [
            .choice(title: "Shape",
                    value: { [unowned self] in self.cursorShapeName(self.prefs.cursorShape) },
                    pick: { [unowned self] host in
                        let shapes: [CursorShape] = [.block, .underline, .bar]
                        self.pushPicker(from: host, title: "Cursor Shape",
                                        options: shapes.map { shape in
                            ListPickerController.Option(
                                title: self.cursorShapeName(shape), subtitle: nil, swatch: nil,
                                isSelected: self.prefs.cursorShape == shape,
                                select: { [weak self] in
                                    guard let self else { return }
                                    self.prefs.cursorShape = shape
                                })
                        })
                    }),
            .toggle(title: "Blink", subtitle: nil,
                    get: { [unowned self] in self.prefs.cursorBlink },
                    set: { [unowned self] in self.prefs.cursorBlink = $0 }),
        ])
    }

    private func terminalSection() -> SettingsSection {
        let scrollbackOptions = [1_000, 5_000, 10_000, 25_000, 50_000, 100_000]
        return SettingsSection(header: "Terminal", footer: nil, rows: [
            .choice(title: "Scrollback",
                    value: { [unowned self] in "\(self.prefs.scrollbackLines) lines" },
                    pick: { [unowned self] host in
                        self.pushPicker(from: host, title: "Scrollback",
                                        options: scrollbackOptions.map { n in
                            ListPickerController.Option(
                                title: "\(n) lines", subtitle: nil, swatch: nil,
                                isSelected: self.prefs.scrollbackLines == n,
                                select: { [weak self] in
                                    guard let self else { return }
                                    self.prefs.scrollbackLines = n
                                })
                        })
                    }),
            .choice(title: "Bell",
                    value: { [unowned self] in self.prefs.bell.title },
                    pick: { [unowned self] host in
                        self.pushPicker(from: host, title: "Bell",
                                        options: BellBehaviour.allCases.map { bell in
                            ListPickerController.Option(
                                title: bell.title, subtitle: nil, swatch: nil,
                                isSelected: self.prefs.bell == bell,
                                select: { [weak self] in
                                    guard let self else { return }
                                    self.prefs.bell = bell
                                })
                        })
                    }),
            .toggle(title: "Copy on Select", subtitle: nil,
                    get: { [unowned self] in self.prefs.copyOnSelect },
                    set: { [unowned self] in self.prefs.copyOnSelect = $0 }),
            .toggle(title: "Detect Links",
                    subtitle: "Recognise URLs in output so they can be opened from the long-press menu.",
                    get: { [unowned self] in self.prefs.detectLinks },
                    set: { [unowned self] in self.prefs.detectLinks = $0 }),
            .toggle(title: "Confirm Before Closing",
                    subtitle: "Ask before closing a terminal that still has a process running.",
                    get: { [unowned self] in self.prefs.confirmCloseWithRunningProcess },
                    set: { [unowned self] in self.prefs.confirmCloseWithRunningProcess = $0 }),
            .toggle(title: "Confirm Multi-line Paste",
                    subtitle: "Ask before pasting text that spans multiple lines.",
                    get: { [unowned self] in self.prefs.confirmMultilinePaste },
                    set: { [unowned self] in self.prefs.confirmMultilinePaste = $0 }),
            .toggle(title: "Keep Screen Awake While Running",
                    subtitle: "Prevent automatic screen locking while a command is running.",
                    get: { [unowned self] in self.prefs.keepScreenAwakeWhileRunning },
                    set: { [unowned self] in self.prefs.keepScreenAwakeWhileRunning = $0 }),
        ])
    }

    private func keyboardSection() -> SettingsSection {
        SettingsSection(header: "Keyboard", footer: "Tap a modifier once to arm it for the next key, twice to lock it. Hold the spacebar and slide to move the cursor along the line.", rows: [
            .toggle(title: "Show Key Row", subtitle: nil,
                    get: { [unowned self] in self.prefs.showKeyRow },
                    set: { [unowned self] in self.prefs.showKeyRow = $0 }),
            .toggle(title: "Include Function Keys", subtitle: nil,
                    get: { [unowned self] in self.prefs.keyRowShowsFunctionKeys },
                    set: { [unowned self] in self.prefs.keyRowShowsFunctionKeys = $0 }),
            .toggle(title: "Haptic Feedback", subtitle: nil,
                    get: { [unowned self] in self.prefs.keyboardHaptics },
                    set: { [unowned self] in self.prefs.keyboardHaptics = $0 }),
            .choice(title: "Spacebar Trackpad",
                    value: { [unowned self] in self.prefs.trackpadSensitivity.title },
                    pick: { [unowned self] host in
                        self.pushPicker(from: host, title: "Spacebar Trackpad",
                                        options: TrackpadSensitivity.allCases.map { level in
                            ListPickerController.Option(
                                title: level.title, subtitle: level.detail, swatch: nil,
                                isSelected: self.prefs.trackpadSensitivity == level,
                                select: { [weak self] in
                                    guard let self else { return }
                                    self.prefs.trackpadSensitivity = level
                                })
                        })
                    }),
        ])
    }

    private func shellSection() -> SettingsSection {
        var rows: [SettingsRow] = [
            .choice(title: "Shell",
                    value: { [unowned self] in self.shellDisplayName() },
                    pick: { [unowned self] host in self.pushShellPicker(from: host) }),
            .toggle(title: "Run as Login Shell",
                    subtitle: "Starts the shell with a leading dash so it reads your profile files.",
                    get: { [unowned self] in self.prefs.loginShell },
                    set: { [unowned self] in self.prefs.loginShell = $0 }),
            .choice(title: "Start In",
                    value: { [unowned self] in self.prefs.startDirectory.title },
                    pick: { [unowned self] host in
                        self.pushPicker(from: host, title: "Start In",
                                        options: StartDirectory.allCases.map { dir in
                            ListPickerController.Option(
                                title: dir.title, subtitle: dir.detail, swatch: nil,
                                isSelected: self.prefs.startDirectory == dir,
                                select: { [weak self] in
                                    guard let self else { return }
                                    self.prefs.startDirectory = dir
                                })
                        })
                    }),
        ]
        if prefs.startDirectory == .custom {
            rows.append(.text(title: "Path", placeholder: "/var/mobile",
                              get: { [unowned self] in self.prefs.customStartDirectory },
                              set: { [unowned self] in self.prefs.customStartDirectory = $0 }))
        }
        rows.append(.toggle(title: "New Tabs Follow the Current Tab",
                            subtitle: "Off starts every new tab at Start In. Split panes always follow the pane they came from.",
                            get: { [unowned self] in self.prefs.newTabInheritsDirectory },
                            set: { [unowned self] in self.prefs.newTabInheritsDirectory = $0 }))
        rows.append(.text(title: "On Launch", placeholder: "command",
                          get: { [unowned self] in self.prefs.startupCommand },
                          set: { [unowned self] in self.prefs.startupCommand = $0 }))
        return SettingsSection(header: "Shell",
                               footer: "Changes apply to terminals opened from now on.",
                               rows: rows)
    }

    private func snippetsSection() -> SettingsSection {
        SettingsSection(header: "Snippets", footer: "Reachable from the key row while typing.", rows: [
            .disclosure(title: "Edit Snippets",
                        detail: "\(prefs.snippets.count)",
                        action: { host in
                            host.navigationController?.pushViewController(
                                SnippetsViewController(), animated: true)
                        }),
        ])
    }

    private func aboutSection() -> SettingsSection {
        SettingsSection(header: "About", footer: nil, rows: [
            .info(title: "Version", detail: DiffTermVersion.short),
            .info(title: "Terminal Type", detail: "xterm-256color"),
            .button(title: "Reset All Settings", destructive: true, action: { [unowned self] host in
                let alert = UIAlertController(title: "Reset all settings?",
                                              message: "Themes, fonts, shell and keyboard preferences go back to their defaults. Snippets are kept.",
                                              preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
                alert.addAction(UIAlertAction(title: "Reset", style: .destructive) { [weak self] _ in
                    guard let self else { return }
                    self.resetSettings()
                })
                host.present(alert, animated: true)
            }),
        ])
    }

    private func resetSettings() {
        // The seeded flag travels with the snippets, or an emptied list refills.
        Preferences.shared.resetAll(keeping: ["snippets", "snippetsSeeded", "lastWorkingDirectory"])
        rebuild()
    }

    // MARK: - Pickers

    private func pushPicker(from host: UIViewController, title: String,
                            options: [ListPickerController.Option]) {
        let picker = ListPickerController(title: title, options: options) { [weak self] in
            guard let self else { return }
            self.rebuild()
        }
        host.navigationController?.pushViewController(picker, animated: true)
    }

    private func pushThemePicker(from host: UIViewController, dark: Bool) {
        let themes = Theme.builtIn.filter { $0.isDark == dark }
        let current = dark ? prefs.darkThemeID : prefs.lightThemeID
        let options = themes.map { theme in
            ListPickerController.Option(
                title: theme.name,
                subtitle: nil,
                swatch: [theme.background.uiColor, theme.ansi[1].uiColor, theme.ansi[2].uiColor,
                         theme.ansi[4].uiColor, theme.foreground.uiColor],
                isSelected: theme.id == current,
                select: { [weak self] in
                    guard let self else { return }
                    if dark { self.prefs.darkThemeID = theme.id }
                    else { self.prefs.lightThemeID = theme.id }
                })
        }
        pushPicker(from: host, title: dark ? "Dark Theme" : "Light Theme", options: options)
    }

    private func pushFontPicker(from host: UIViewController) {
        let families = TerminalFont.availableFamilies()
        let options = families.map { entry in
            ListPickerController.Option(
                title: entry.displayName,
                subtitle: nil,
                swatch: nil,
                isSelected: prefs.fontName == entry.familyName,
                select: { [weak self] in
                    guard let self else { return }
                    self.prefs.fontName = entry.familyName
                })
        }
        pushPicker(from: host, title: "Font", options: options)
    }

    /// The list is checked in the app's spelling and shown and stored in the
    /// shell's, which is what `pwd` and `echo $SHELL` would say.
    private func pushShellPicker(from host: UIViewController) {
        var candidates = ["/usr/bin/zsh", "/usr/bin/bash", "/usr/bin/sh", "/usr/bin/dash", "/bin/sh"]
            .map(JailbreakRoot.jb)
        if !candidates.contains("/bin/sh") { candidates.append("/bin/sh") }
        // Anything the user configured by hand stays in the list even if it
        // is not one of ours.
        let configured = prefs.shellPath
        let configuredPath = JailbreakRoot.fromShell(configured)
        if !configured.isEmpty, !candidates.contains(configuredPath) { candidates.insert(configuredPath, at: 0) }
        let available = candidates
            .filter { FileManager.default.isExecutableFile(atPath: $0) }
            .map(JailbreakRoot.toShell)

        var options: [ListPickerController.Option] = [
            ListPickerController.Option(
                title: "Automatic",
                subtitle: JailbreakRoot.toShell(TerminalSession.resolvedShell()),
                swatch: nil,
                isSelected: configured.isEmpty,
                select: { [weak self] in
                    guard let self else { return }
                    self.prefs.shellPath = ""
                })
        ]
        options += available.map { path in
            ListPickerController.Option(
                title: (path as NSString).lastPathComponent,
                subtitle: path,
                swatch: nil,
                isSelected: configured == path,
                select: { [weak self] in
                    guard let self else { return }
                    self.prefs.shellPath = path
                })
        }
        pushPicker(from: host, title: "Shell", options: options)
    }

    // MARK: - Display helpers

    private func currentFontDisplayName() -> String {
        let name = prefs.fontName
        if name == TerminalFont.systemMonospacedName { return "System Mono" }
        return name
    }

    private func shellDisplayName() -> String {
        let configured = prefs.shellPath
        if configured.isEmpty { return "Automatic" }
        return (configured as NSString).lastPathComponent
    }

    private func cursorShapeName(_ shape: CursorShape) -> String {
        switch shape {
        case .block: return "Block"
        case .underline: return "Underline"
        case .bar: return "Bar"
        }
    }
}
