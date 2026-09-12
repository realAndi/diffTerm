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
         shellSection(), tmuxSection(), snippetsSection(), aboutSection()]
    }

    private func appearanceSection() -> SettingsSection {
        SettingsSection(header: "Appearance", footer: nil, rows: [
            .choice(title: "Theme Mode",
                    value: { self.prefs.themeMode.title },
                    pick: { [weak self] host in
                        guard let self else { return }
                        self.pushPicker(from: host, title: "Theme Mode",
                                        options: ThemeMode.allCases.map { mode in
                            ListPickerController.Option(
                                title: mode.title, subtitle: nil, swatch: nil,
                                isSelected: self.prefs.themeMode == mode,
                                select: { self.prefs.themeMode = mode })
                        })
                    }),
            .choice(title: "Dark Theme",
                    value: { Theme.theme(withID: self.prefs.darkThemeID).name },
                    pick: { [weak self] host in
                        self?.pushThemePicker(from: host, dark: true)
                    }),
            .choice(title: "Light Theme",
                    value: { Theme.theme(withID: self.prefs.lightThemeID).name },
                    pick: { [weak self] host in
                        self?.pushThemePicker(from: host, dark: false)
                    }),
            .toggle(title: "App Icon Follows Theme",
                    subtitle: "Matches the home screen icon to the terminal theme. Turn this off if you theme icons yourself — the stock icon comes back. Icon-theme engines like SnowBoard can briefly flash a blank icon on launch while both reskin it; turning this off lets the engine own the icon and stops the flash.",
                    get: { self.prefs.matchIconToTheme },
                    set: { self.prefs.matchIconToTheme = $0 }),
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
                        get: { self.prefs.blockMode },
                        set: { self.prefs.blockMode = $0 }),
                .disclosure(title: "Shell Integration",
                            detail: {
                                let shell = ShellIntegrationInstaller.currentShell
                                return ShellIntegrationInstaller.isInstalled(for: shell)
                                    ? "Installed" : "Not set up"
                            }(),
                            action: { [weak self] host in
                                self?.presentShellIntegration(from: host)
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
                        get: { self.prefs.commandSuggestions },
                        set: { self.prefs.commandSuggestions = $0 }),
                .toggle(title: "Tab Takes The Suggestion",
                        subtitle: "With a suggestion showing, Tab accepts it. With none showing, "
                                + "Tab always goes to the shell's own completion.",
                        get: { self.prefs.suggestionAcceptsTab },
                        set: { self.prefs.suggestionAcceptsTab = $0 }),
                .button(title: "Clear Command History", destructive: true,
                        action: { [weak self] host in
                            self?.confirmClearHistory(from: host)
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
                        get: { self.prefs.clipboardHelpers },
                        set: { self.prefs.clipboardHelpers = $0 }),
                .choice(title: "Allow Reading",
                        value: { self.prefs.clipboardReadAccess.title },
                        pick: { [weak self] host in
                            guard let self else { return }
                            self.pushPicker(from: host, title: "Allow Reading",
                                            options: ClipboardReadAccess.allCases.map { access in
                                ListPickerController.Option(
                                    title: access.title, subtitle: nil, swatch: nil,
                                    isSelected: self.prefs.clipboardReadAccess == access,
                                    select: { self.prefs.clipboardReadAccess = access })
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
                ShellIntegrationInstaller.uninstall(for: shell)
                self?.rebuild()
            })
        } else {
            alert.addAction(UIAlertAction(title: "Install", style: .default) { [weak self] _ in
                do {
                    try ShellIntegrationInstaller.install(for: shell)
                    self?.rebuild()
                } catch {
                    let failure = UIAlertController(
                        title: "Could Not Install",
                        message: error.localizedDescription, preferredStyle: .alert)
                    failure.addAction(UIAlertAction(title: "OK", style: .default))
                    host.present(failure, animated: true)
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
                    value: { self.currentFontDisplayName() },
                    pick: { [weak self] host in self?.pushFontPicker(from: host) }),
            .stepper(title: "Size",
                     value: { "\(Int(self.prefs.fontSize)) pt" },
                     decrement: { self.prefs.fontSize -= 1 },
                     increment: { self.prefs.fontSize += 1 },
                     canDecrement: { self.prefs.fontSize > 6 },
                     canIncrement: { self.prefs.fontSize < 32 }),
            .stepper(title: "Line Height",
                     value: { String(format: "%.2f×", self.prefs.lineHeightScale) },
                     decrement: { self.prefs.lineHeightScale -= 0.05 },
                     increment: { self.prefs.lineHeightScale += 0.05 },
                     canDecrement: { self.prefs.lineHeightScale > 0.86 },
                     canIncrement: { self.prefs.lineHeightScale < 1.59 }),
            .toggle(title: "Bold Text Uses Bold Font", subtitle: nil,
                    get: { self.prefs.useBoldFont },
                    set: { self.prefs.useBoldFont = $0 }),
            .toggle(title: "Bold Text Is Brighter",
                    subtitle: "Draw the first eight ANSI colours in their bright variant when bold.",
                    get: { self.prefs.boldIsBright },
                    set: { self.prefs.boldIsBright = $0 }),
        ])
    }

    private func cursorSection() -> SettingsSection {
        SettingsSection(header: "Cursor", footer: "Programs that set their own cursor style override this.", rows: [
            .choice(title: "Shape",
                    value: { self.cursorShapeName(self.prefs.cursorShape) },
                    pick: { [weak self] host in
                        guard let self else { return }
                        let shapes: [CursorShape] = [.block, .underline, .bar]
                        self.pushPicker(from: host, title: "Cursor Shape",
                                        options: shapes.map { shape in
                            ListPickerController.Option(
                                title: self.cursorShapeName(shape), subtitle: nil, swatch: nil,
                                isSelected: self.prefs.cursorShape == shape,
                                select: { self.prefs.cursorShape = shape })
                        })
                    }),
            .toggle(title: "Blink", subtitle: nil,
                    get: { self.prefs.cursorBlink },
                    set: { self.prefs.cursorBlink = $0 }),
        ])
    }

    private func terminalSection() -> SettingsSection {
        let scrollbackOptions = [1_000, 5_000, 10_000, 25_000, 50_000, 100_000]
        return SettingsSection(header: "Terminal", footer: nil, rows: [
            .choice(title: "Scrollback",
                    value: { "\(self.prefs.scrollbackLines) lines" },
                    pick: { [weak self] host in
                        guard let self else { return }
                        self.pushPicker(from: host, title: "Scrollback",
                                        options: scrollbackOptions.map { n in
                            ListPickerController.Option(
                                title: "\(n) lines", subtitle: nil, swatch: nil,
                                isSelected: self.prefs.scrollbackLines == n,
                                select: { self.prefs.scrollbackLines = n })
                        })
                    }),
            .choice(title: "Bell",
                    value: { self.prefs.bell.title },
                    pick: { [weak self] host in
                        guard let self else { return }
                        self.pushPicker(from: host, title: "Bell",
                                        options: BellBehaviour.allCases.map { bell in
                            ListPickerController.Option(
                                title: bell.title, subtitle: nil, swatch: nil,
                                isSelected: self.prefs.bell == bell,
                                select: { self.prefs.bell = bell })
                        })
                    }),
            .toggle(title: "Copy on Select", subtitle: nil,
                    get: { self.prefs.copyOnSelect },
                    set: { self.prefs.copyOnSelect = $0 }),
            .toggle(title: "Detect Links",
                    subtitle: "Recognise URLs in output so they can be opened from the long-press menu.",
                    get: { self.prefs.detectLinks },
                    set: { self.prefs.detectLinks = $0 }),
            .toggle(title: "Confirm Before Closing",
                    subtitle: "Ask before closing a terminal that still has a process running.",
                    get: { self.prefs.confirmCloseWithRunningProcess },
                    set: { self.prefs.confirmCloseWithRunningProcess = $0 }),
        ])
    }

    private func keyboardSection() -> SettingsSection {
        SettingsSection(header: "Keyboard", footer: "Tap a modifier once to arm it for the next key, twice to lock it. Hold the spacebar and slide to move the cursor along the line.", rows: [
            .toggle(title: "Show Key Row", subtitle: nil,
                    get: { self.prefs.showKeyRow },
                    set: { self.prefs.showKeyRow = $0 }),
            .toggle(title: "Include Function Keys", subtitle: nil,
                    get: { self.prefs.keyRowShowsFunctionKeys },
                    set: { self.prefs.keyRowShowsFunctionKeys = $0 }),
            .toggle(title: "Haptic Feedback", subtitle: nil,
                    get: { self.prefs.keyboardHaptics },
                    set: { self.prefs.keyboardHaptics = $0 }),
            .choice(title: "Spacebar Trackpad",
                    value: { self.prefs.trackpadSensitivity.title },
                    pick: { [weak self] host in
                        guard let self else { return }
                        self.pushPicker(from: host, title: "Spacebar Trackpad",
                                        options: TrackpadSensitivity.allCases.map { level in
                            ListPickerController.Option(
                                title: level.title, subtitle: level.detail, swatch: nil,
                                isSelected: self.prefs.trackpadSensitivity == level,
                                select: { self.prefs.trackpadSensitivity = level })
                        })
                    }),
        ])
    }

    private func shellSection() -> SettingsSection {
        var rows: [SettingsRow] = [
            .choice(title: "Shell",
                    value: { self.shellDisplayName() },
                    pick: { [weak self] host in self?.pushShellPicker(from: host) }),
            .toggle(title: "Run as Login Shell",
                    subtitle: "Starts the shell with a leading dash so it reads your profile files.",
                    get: { self.prefs.loginShell },
                    set: { self.prefs.loginShell = $0 }),
            .choice(title: "Start In",
                    value: { self.prefs.startDirectory.title },
                    pick: { [weak self] host in
                        guard let self else { return }
                        self.pushPicker(from: host, title: "Start In",
                                        options: StartDirectory.allCases.map { dir in
                            ListPickerController.Option(
                                title: dir.title, subtitle: dir.detail, swatch: nil,
                                isSelected: self.prefs.startDirectory == dir,
                                select: { self.prefs.startDirectory = dir })
                        })
                    }),
        ]
        if prefs.startDirectory == .custom {
            rows.append(.text(title: "Path", placeholder: "/var/mobile",
                              get: { self.prefs.customStartDirectory },
                              set: { self.prefs.customStartDirectory = $0 }))
        }
        rows.append(.toggle(title: "New Tabs Follow the Current Tab",
                            subtitle: "Off starts every new tab at Start In. Split panes always follow the pane they came from.",
                            get: { self.prefs.newTabInheritsDirectory },
                            set: { self.prefs.newTabInheritsDirectory = $0 }))
        rows.append(.text(title: "On Launch", placeholder: "command",
                          get: { self.prefs.startupCommand },
                          set: { self.prefs.startupCommand = $0 }))
        return SettingsSection(header: "Shell",
                               footer: "Changes apply to terminals opened from now on.",
                               rows: rows)
    }

    private func tmuxSection() -> SettingsSection {
        let installed = TmuxEnvironment.isInstalled
        var rows: [SettingsRow] = [
            .toggle(title: "Run Shells in tmux",
                    subtitle: installed
                        ? "Shells keep running when the app is killed, and you can reattach from anywhere."
                        : "Needs tmux installed. Install it with your package manager first.",
                    get: { installed && self.prefs.tmuxSessions },
                    set: { self.prefs.tmuxSessions = installed && $0 }),
        ]
        if installed {
            rows.append(.info(title: "Session", detail: TmuxEnvironment.sessionName))
        }
        return SettingsSection(
            header: "tmux",
            footer: installed
                ? "Applies to terminals opened from now on. If tmux cannot be reached, the terminal falls back to an ordinary shell."
                : "tmux was not found at \(TmuxEnvironment.executable).",
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
            .button(title: "Reset All Settings", destructive: true, action: { [weak self] host in
                let alert = UIAlertController(title: "Reset all settings?",
                                              message: "Themes, fonts, shell and keyboard preferences go back to their defaults. Snippets are kept.",
                                              preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
                alert.addAction(UIAlertAction(title: "Reset", style: .destructive) { _ in
                    self?.resetSettings()
                })
                host.present(alert, animated: true)
            }),
        ])
    }

    private func resetSettings() {
        let defaults = UserDefaults.standard
        for key in ["themeMode", "darkThemeID", "lightThemeID", "fontName", "fontSize",
                    "lineHeightScale", "boldIsBright", "useBoldFont", "cursorShape",
                    "cursorBlink", "scrollbackLines", "bell", "copyOnSelect", "detectLinks",
                    "confirmClose", "keyboardHaptics", "trackpadSensitivity",
                    "showKeyRow", "keyRowShowsFunctionKeys",
                    "shellPath", "loginShell", "startDirectory", "customStartDirectory",
                    "newTabInheritsDirectory", "startupCommand"] {
            defaults.removeObject(forKey: key)
        }
        NotificationCenter.default.post(name: Preferences.didChangeNotification, object: nil)
        rebuild()
    }

    // MARK: - Pickers

    private func pushPicker(from host: UIViewController, title: String,
                            options: [ListPickerController.Option]) {
        let picker = ListPickerController(title: title, options: options) { [weak self] in
            self?.rebuild()
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
                    if dark { self?.prefs.darkThemeID = theme.id }
                    else { self?.prefs.lightThemeID = theme.id }
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
                select: { [weak self] in self?.prefs.fontName = entry.familyName })
        }
        pushPicker(from: host, title: "Font", options: options)
    }

    private func pushShellPicker(from host: UIViewController) {
        var candidates = ["/var/jb/usr/bin/zsh", "/var/jb/usr/bin/bash",
                          "/var/jb/usr/bin/sh", "/var/jb/usr/bin/dash",
                          "/var/jb/bin/sh", "/bin/sh"]
        // Anything the user configured by hand stays in the list even if it
        // is not one of ours.
        let configured = prefs.shellPath
        if !configured.isEmpty, !candidates.contains(configured) { candidates.insert(configured, at: 0) }
        let available = candidates.filter { FileManager.default.isExecutableFile(atPath: $0) }

        var options: [ListPickerController.Option] = [
            ListPickerController.Option(
                title: "Automatic",
                subtitle: TerminalSession.resolvedShell(),
                swatch: nil,
                isSelected: configured.isEmpty,
                select: { [weak self] in self?.prefs.shellPath = "" })
        ]
        options += available.map { path in
            ListPickerController.Option(
                title: (path as NSString).lastPathComponent,
                subtitle: path,
                swatch: nil,
                isSelected: configured == path,
                select: { [weak self] in self?.prefs.shellPath = path })
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
