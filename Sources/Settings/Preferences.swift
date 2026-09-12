import UIKit

enum BellBehaviour: String, CaseIterable {
    case none, visual, haptic, sound

    var title: String {
        switch self {
        case .none:   return "Off"
        case .visual: return "Flash"
        case .haptic: return "Vibrate"
        case .sound:  return "Sound"
        }
    }
}

enum ThemeMode: String, CaseIterable {
    case automatic, dark, light

    var title: String {
        switch self {
        case .automatic: return "Match System"
        case .dark:      return "Always Dark"
        case .light:     return "Always Light"
        }
    }
}

/// Who may read the clipboard back. Writes are never gated — a program that
/// can print to the terminal can already set the clipboard via OSC 52 — but a
/// read is the direction that leaks, so it has a policy.
enum ClipboardReadAccess: String, CaseIterable {
    case ask, allow, deny

    var title: String {
        switch self {
        case .ask:   return "Ask Once Per Launch"
        case .allow: return "Always Allow"
        case .deny:  return "Never"
        }
    }
}

/// How far a finger travels on the spacebar trackpad before the caret steps
/// one character.
enum TrackpadSensitivity: String, CaseIterable {
    case off, low, medium, high

    var title: String {
        switch self {
        case .off:    return "Off"
        case .low:    return "Low"
        case .medium: return "Medium"
        case .high:   return "High"
        }
    }

    /// Measured in character cells rather than points, so the gesture means
    /// the same thing at every font size. Medium is exactly one cell, which
    /// puts the caret under the fingertip: drag across four characters and the
    /// caret moves four. The other two trade that away for reach or precision.
    var cellsPerStep: CGFloat? {
        switch self {
        case .off:    return nil
        case .low:    return 1.6
        case .medium: return 1.0
        case .high:   return 0.6
        }
    }

    var detail: String? {
        switch self {
        case .off:    return "The spacebar does nothing when held."
        case .low:    return "Reaches further for the same drag."
        case .medium: return "The caret keeps pace with your finger."
        case .high:   return "Finer control over a shorter drag."
        }
    }
}

enum StartDirectory: String, CaseIterable {
    case deviceHome, home, root, lastUsed, custom

    var title: String {
        switch self {
        case .deviceHome: return "Device Home (/var/mobile)"
        case .home:       return "Shell Home (~)"
        case .root:       return "Filesystem Root (/)"
        case .lastUsed:   return "Last Used"
        case .custom:     return "Custom Path"
        }
    }

    /// The difference between the first two is not obvious and matters: `~` is
    /// inside the bootstrap, which a jailbreak reinstall replaces.
    var detail: String? {
        switch self {
        case .deviceHome: return "Outside the bootstrap, so it survives reinstalling the jailbreak."
        case .home:       return "Where your dotfiles live. Inside /var/jb, which a jailbreak reinstall replaces."
        case .root:       return nil
        case .lastUsed:   return "Wherever the last terminal ended up."
        case .custom:     return nil
        }
    }
}

@propertyWrapper
struct Stored<Value> {
    let key: String
    let defaultValue: Value
    let store: UserDefaults

    init(_ key: String, _ defaultValue: Value, store: UserDefaults = .standard) {
        self.key = key
        self.defaultValue = defaultValue
        self.store = store
    }

    var wrappedValue: Value {
        get { store.object(forKey: key) as? Value ?? defaultValue }
        set { store.set(newValue, forKey: key) }
    }
}

/// Everything the user can change. Reads go straight to `UserDefaults` so
/// that a change made in Settings is visible to every open session at once,
/// with one notification to tell them to re-read.
final class Preferences {

    static let shared = Preferences()

    static let didChangeNotification = Notification.Name("dev.diffterm.preferencesDidChange")

    private init() {}

    private func changed() {
        NotificationCenter.default.post(name: Preferences.didChangeNotification, object: self)
    }

    // MARK: Appearance

    @Stored("themeMode", ThemeMode.automatic.rawValue) private var themeModeRaw: String
    var themeMode: ThemeMode {
        get { ThemeMode(rawValue: themeModeRaw) ?? .automatic }
        set { themeModeRaw = newValue.rawValue; changed() }
    }

    @Stored("darkThemeID", "diffterm-dark") private var darkThemeIDStored: String
    var darkThemeID: String {
        get { darkThemeIDStored }
        set { darkThemeIDStored = newValue; changed() }
    }

    @Stored("lightThemeID", "diffterm-light") private var lightThemeIDStored: String
    var lightThemeID: String {
        get { lightThemeIDStored }
        set { lightThemeIDStored = newValue; changed() }
    }

    @Stored("matchIconToTheme", true) private var matchIconStored: Bool
    var matchIconToTheme: Bool {
        get { matchIconStored }
        set { matchIconStored = newValue; changed() }
    }

    func theme(for style: UIUserInterfaceStyle) -> Theme {
        switch themeMode {
        case .dark:  return Theme.theme(withID: darkThemeID)
        case .light: return Theme.theme(withID: lightThemeID)
        case .automatic:
            return style == .light ? Theme.theme(withID: lightThemeID)
                                   : Theme.theme(withID: darkThemeID)
        }
    }

    // MARK: Font

    /// Bundled, so this always resolves. Menlo is a fine terminal face but
    /// has none of the private-use glyphs that starship, powerlevel10k, eza
    /// and lazygit draw with, and iOS ships nothing that does — they come out
    /// as tofu. Someone who prefers Menlo can still pick it.
    @Stored("fontName", "JetBrainsMono Nerd Font Mono") private var fontNameStored: String
    var fontName: String {
        get { fontNameStored }
        set { fontNameStored = newValue; changed() }
    }

    @Stored("fontSize", DeviceMetrics.defaultFontSize) private var fontSizeStored: Double
    var fontSize: CGFloat {
        get { CGFloat(min(max(fontSizeStored, 6), 32)) }
        set { fontSizeStored = Double(min(max(newValue, 6), 32)); changed() }
    }

    @Stored("lineHeightScale", 1.0) private var lineHeightStored: Double
    var lineHeightScale: CGFloat {
        get { CGFloat(min(max(lineHeightStored, 0.85), 1.6)) }
        set { lineHeightStored = Double(min(max(newValue, 0.85), 1.6)); changed() }
    }

    @Stored("boldIsBright", true) private var boldIsBrightStored: Bool
    var boldIsBright: Bool {
        get { boldIsBrightStored }
        set { boldIsBrightStored = newValue; changed() }
    }

    @Stored("useBoldFont", true) private var useBoldFontStored: Bool
    var useBoldFont: Bool {
        get { useBoldFontStored }
        set { useBoldFontStored = newValue; changed() }
    }

    // MARK: Cursor

    @Stored("cursorShape", CursorShape.block.rawValue) private var cursorShapeStored: Int
    var cursorShape: CursorShape {
        get { CursorShape(rawValue: cursorShapeStored) ?? .block }
        set { cursorShapeStored = newValue.rawValue; changed() }
    }

    @Stored("cursorBlink", true) private var cursorBlinkStored: Bool
    var cursorBlink: Bool {
        get { cursorBlinkStored }
        set { cursorBlinkStored = newValue; changed() }
    }

    // MARK: Behaviour

    @Stored("scrollbackLines", 10_000) private var scrollbackStored: Int
    var scrollbackLines: Int {
        get { min(max(scrollbackStored, 100), 200_000) }
        set { scrollbackStored = min(max(newValue, 100), 200_000); changed() }
    }

    @Stored("bell", BellBehaviour.haptic.rawValue) private var bellStored: String
    var bell: BellBehaviour {
        get { BellBehaviour(rawValue: bellStored) ?? .haptic }
        set { bellStored = newValue.rawValue; changed() }
    }

    @Stored("copyOnSelect", false) private var copyOnSelectStored: Bool
    var copyOnSelect: Bool {
        get { copyOnSelectStored }
        set { copyOnSelectStored = newValue; changed() }
    }

    /// Puts the app's own `pbcopy`/`pbpaste` ahead of the bootstrap's on the
    /// child PATH. On by default because the ones in the bootstrap are broken
    /// here — they cannot reach the pasteboard and exit 0 regardless — but it
    /// is a setting because putting anything ahead of a user's PATH is the
    /// sort of thing they are entitled to say no to.
    @Stored("clipboardHelpers", true) private var clipboardHelpersStored: Bool
    var clipboardHelpers: Bool {
        get { clipboardHelpersStored }
        set { clipboardHelpersStored = newValue; changed() }
    }

    @Stored("clipboardReadAccess", ClipboardReadAccess.ask.rawValue)
    private var clipboardReadAccessStored: String
    var clipboardReadAccess: ClipboardReadAccess {
        get { ClipboardReadAccess(rawValue: clipboardReadAccessStored) ?? .ask }
        set { clipboardReadAccessStored = newValue.rawValue; changed() }
    }

    /// Run shells inside the launchd session daemon, so they survive the app
    /// being backgrounded, killed or force-quit. Off by default and treated as
    /// experimental: the daemon is fast in isolation but has proven unstable
    /// under real multi-tab use on device (it crashes and does not always
    /// recover), which shows up as sluggish, dropping sessions. Left in place,
    /// opt-in, until it is hardened. When off, shells run locally — fast, and
    /// they die with the app, which is the historical behaviour.
    @Stored("persistentSessions", false) private var persistentSessionsStored: Bool
    var persistentSessions: Bool {
        get { persistentSessionsStored }
        set { persistentSessionsStored = newValue; changed() }
    }

    /// Run shells inside tmux, reached over its control mode, so they survive
    /// the app the way `persistentSessions` was meant to. tmux's server is not
    /// the app's child and has been keeping shells alive for twenty years,
    /// which is the argument for it over the daemon we would have to harden
    /// ourselves. Off by default because it needs tmux installed, and because
    /// a terminal that silently routes through something else is a surprise.
    @Stored("tmuxSessions", false) private var tmuxSessionsStored: Bool
    var tmuxSessions: Bool {
        get { tmuxSessionsStored }
        set { tmuxSessionsStored = newValue; changed() }
    }

    /// Whether the screen comes back after the app is killed in the
    /// background. The processes never do — see `SessionSnapshot`.
    @Stored("restoreSessions", true) private var restoreSessionsStored: Bool
    var restoreSessions: Bool {
        get { restoreSessionsStored }
        set { restoreSessionsStored = newValue; changed() }
    }

    /// Local notification when a long command finishes while you are in
    /// another app. Driven by OSC 133 marks, not by program output.
    @Stored("notifyOnCommandFinish", true) private var notifyOnCommandFinishStored: Bool
    var notifyOnCommandFinish: Bool {
        get { notifyOnCommandFinishStored }
        set { notifyOnCommandFinishStored = newValue; changed() }
    }

    // MARK: Blocks

    /// Warp-style command blocks: a status rail and a divider per command, so
    /// a screen of scrollback reads as separate results rather than one wall
    /// of text. Off by default — it needs a shell that emits OSC 133, and
    /// with no marks there is nothing to divide.
    @Stored("blockMode", false) private var blockModeStored: Bool
    var blockMode: Bool {
        get { blockModeStored }
        set { blockModeStored = newValue; changed() }
    }

    /// Ghost text after the cursor: the command you are most likely to run
    /// next, drawn dim and accepted with Tab or a tap.
    ///
    /// Local only. The prediction is read out of this device's own command
    /// history and nothing is sent anywhere, which is the difference between
    /// this and the feature it is modelled on.
    @Stored("commandSuggestions", false) private var commandSuggestionsStored: Bool
    var commandSuggestions: Bool {
        get { commandSuggestionsStored }
        set { commandSuggestionsStored = newValue; changed() }
    }

    /// Ask a zsh of our own — with the user's rc files loaded — what its
    /// completion system would insert, whenever nothing local has an answer.
    /// It is how a suggestion can know this repo's branches or this
    /// Makefile's targets. On by default because that is the value; a
    /// setting because it runs completion functions per keystroke, and
    /// someone is entitled to say no to that.
    @Stored("shellCompletions", true) private var shellCompletionsStored: Bool
    var shellCompletions: Bool {
        get { shellCompletionsStored }
        set { shellCompletionsStored = newValue; changed() }
    }

    /// Whether Tab takes the suggestion. Off means only the arrow key and a
    /// tap do, leaving Tab entirely to the shell's own completion.
    @Stored("suggestionAcceptsTab", true) private var suggestionAcceptsTabStored: Bool
    var suggestionAcceptsTab: Bool {
        get { suggestionAcceptsTabStored }
        set { suggestionAcceptsTabStored = newValue; changed() }
    }

    @Stored("detectLinks", true) private var detectLinksStored: Bool
    var detectLinks: Bool {
        get { detectLinksStored }
        set { detectLinksStored = newValue; changed() }
    }

    @Stored("confirmClose", true) private var confirmCloseStored: Bool
    var confirmCloseWithRunningProcess: Bool {
        get { confirmCloseStored }
        set { confirmCloseStored = newValue; changed() }
    }

    @Stored("keyboardHaptics", true) private var keyboardHapticsStored: Bool
    var keyboardHaptics: Bool {
        get { keyboardHapticsStored }
        set { keyboardHapticsStored = newValue; changed() }
    }

    @Stored("trackpadSensitivity", TrackpadSensitivity.medium.rawValue)
    private var trackpadStored: String
    var trackpadSensitivity: TrackpadSensitivity {
        get { TrackpadSensitivity(rawValue: trackpadStored) ?? .medium }
        set { trackpadStored = newValue.rawValue; changed() }
    }

    @Stored("showKeyRow", true) private var showKeyRowStored: Bool
    var showKeyRow: Bool {
        get { showKeyRowStored }
        set { showKeyRowStored = newValue; changed() }
    }

    @Stored("keyRowShowsFunctionKeys", false) private var fnRowStored: Bool
    var keyRowShowsFunctionKeys: Bool {
        get { fnRowStored }
        set { fnRowStored = newValue; changed() }
    }

    // MARK: Shell

    @Stored("shellPath", "") private var shellPathStored: String
    /// Empty means "pick the best available shell at launch".
    var shellPath: String {
        get { shellPathStored }
        set { shellPathStored = newValue; changed() }
    }

    @Stored("loginShell", true) private var loginShellStored: Bool
    var loginShell: Bool {
        get { loginShellStored }
        set { loginShellStored = newValue; changed() }
    }

    @Stored("startDirectory", StartDirectory.deviceHome.rawValue) private var startDirStored: String
    var startDirectory: StartDirectory {
        get { StartDirectory(rawValue: startDirStored) ?? .home }
        set { startDirStored = newValue.rawValue; changed() }
    }

    @Stored("customStartDirectory", "") private var customStartDirStored: String
    var customStartDirectory: String {
        get { customStartDirStored.isEmpty ? UserEnvironment.deviceHome : customStartDirStored }
        set { customStartDirStored = newValue; changed() }
    }

    /// Whether a new tab starts where the tab it was opened from is, rather
    /// than at Start In. Split panes always follow the pane they came from —
    /// a split is a second view of the work in front of you, and starting it
    /// somewhere else would be answering a question nobody asked.
    @Stored("newTabInheritsDirectory", true) private var newTabInheritsDirStored: Bool
    var newTabInheritsDirectory: Bool {
        get { newTabInheritsDirStored }
        set { newTabInheritsDirStored = newValue; changed() }
    }

    /// Updated as sessions report their cwd via OSC 7, so a new tab can open
    /// where the last one left off.
    @Stored("lastWorkingDirectory", "") private var lastWorkingDirectoryStored: String
    var lastWorkingDirectory: String {
        get { lastWorkingDirectoryStored.isEmpty ? UserEnvironment.deviceHome : lastWorkingDirectoryStored }
        set { lastWorkingDirectoryStored = newValue }
    }

    @Stored("startupCommand", "") private var startupCommandStored: String
    var startupCommand: String {
        get { startupCommandStored }
        set { startupCommandStored = newValue; changed() }
    }

    // MARK: Key row contents

    @Stored("hiddenKeyRowKeys", [] as [String]) private var hiddenKeyRowKeysStored: [String]
    /// Ids of the built-in keys switched off in Settings. Stored as the
    /// exceptions rather than the whole list, so a key added in a later
    /// version shows up instead of being silently absent.
    var hiddenKeyRowKeys: Set<String> {
        get { Set(hiddenKeyRowKeysStored) }
        set { hiddenKeyRowKeysStored = newValue.sorted(); changed() }
    }

    @Stored("customKeys", [] as [[String: String]]) private var customKeysStored: [[String: String]]
    var customKeys: [CustomKey] {
        get { customKeysStored.compactMap(CustomKey.init(dictionary:)) }
        set { customKeysStored = newValue.map { $0.dictionary }; changed() }
    }

    // MARK: Snippets

    @Stored("snippets", [] as [[String: String]]) private var snippetsStored: [[String: String]]
    var snippets: [Snippet] {
        get { snippetsStored.compactMap(Snippet.init(dictionary:)) }
        set { snippetsStored = newValue.map { $0.dictionary }; changed() }
    }
}

/// A key row button someone defined for themselves: a label, the modifiers
/// to hold, and the key to hold them on. `ctrl` + `c`, `alt` + `.`,
/// `shift` + `tab`. One press sends the whole combination, rather than arming
/// a modifier and then going to look for the key.
struct CustomKey: Equatable {
    var title: String
    var modifiers: KeyModifiers
    /// Exactly one of these is set: a named key, or the character to send.
    var special: SpecialKeyID?
    var character: String

    var base: KeyRowBase {
        if let special { return .special(special) }
        return .character(character)
    }

    /// What the button will actually send, spelled the way a terminal user
    /// writes it, for the settings list.
    var summary: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.alt) { parts.append("alt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        parts.append(special?.rawValue ?? character)
        return parts.joined(separator: "+")
    }

    var dictionary: [String: String] {
        ["title": title,
         "mods": CustomKey.encode(modifiers),
         "special": special?.rawValue ?? "",
         "char": character]
    }

    init(title: String, modifiers: KeyModifiers, special: SpecialKeyID?, character: String) {
        self.title = title
        self.modifiers = modifiers
        self.special = special
        self.character = character
    }

    init?(dictionary: [String: String]) {
        guard let title = dictionary["title"] else { return nil }
        let special = (dictionary["special"]).flatMap { $0.isEmpty ? nil : SpecialKeyID(rawValue: $0) }
        let character = dictionary["char"] ?? ""
        guard special != nil || !character.isEmpty else { return nil }
        self.title = title
        self.modifiers = CustomKey.decode(dictionary["mods"] ?? "")
        self.special = special
        self.character = character
    }

    static func encode(_ modifiers: KeyModifiers) -> String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.alt) { parts.append("alt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        return parts.joined(separator: ",")
    }

    static func decode(_ text: String) -> KeyModifiers {
        var modifiers: KeyModifiers = []
        for part in text.split(separator: ",") {
            switch part {
            case "ctrl": modifiers.insert(.control)
            case "alt": modifiers.insert(.alt)
            case "shift": modifiers.insert(.shift)
            default: break
            }
        }
        return modifiers
    }
}

struct Snippet: Equatable {
    var title: String
    var command: String
    /// When true the command is sent with a trailing return.
    var runsImmediately: Bool

    var dictionary: [String: String] {
        ["title": title, "command": command, "run": runsImmediately ? "1" : "0"]
    }

    init(title: String, command: String, runsImmediately: Bool) {
        self.title = title
        self.command = command
        self.runsImmediately = runsImmediately
    }

    init?(dictionary: [String: String]) {
        guard let t = dictionary["title"], let c = dictionary["command"] else { return nil }
        title = t
        command = c
        runsImmediately = dictionary["run"] == "1"
    }
}
