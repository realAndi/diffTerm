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
        case .home:       return "Where your dotfiles live. Inside the jailbreak, which a reinstall replaces."
        case .root:       return nil
        case .lastUsed:   return "Wherever the last terminal ended up."
        case .custom:     return nil
        }
    }
}

private enum PreferenceKeys {
    static var all: [String] = []
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
        PreferenceKeys.all.append(key)
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

    func resetAll(keeping: Set<String>) {
        for key in PreferenceKeys.all where !keeping.contains(key) {
            UserDefaults.standard.removeObject(forKey: key)
        }
        changed()
    }

    // MARK: Appearance

    @Stored("themeMode", ThemeMode.automatic.rawValue) private var themeModeRaw: String
    var themeMode: ThemeMode {
        get { ThemeMode(rawValue: themeModeRaw) ?? .automatic }
        set {
            let value = newValue.rawValue
            guard value != themeModeRaw else { return }
            themeModeRaw = value
            changed()
        }
    }

    @Stored("darkThemeID", "diffterm-dark") private var darkThemeIDStored: String
    var darkThemeID: String {
        get { darkThemeIDStored }
        set {
            guard newValue != darkThemeIDStored else { return }
            darkThemeIDStored = newValue
            changed()
        }
    }

    @Stored("lightThemeID", "diffterm-light") private var lightThemeIDStored: String
    var lightThemeID: String {
        get { lightThemeIDStored }
        set {
            guard newValue != lightThemeIDStored else { return }
            lightThemeIDStored = newValue
            changed()
        }
    }

    @Stored("matchIconToTheme", true) private var matchIconStored: Bool
    var matchIconToTheme: Bool {
        get { matchIconStored }
        set {
            guard newValue != matchIconStored else { return }
            matchIconStored = newValue
            changed()
        }
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
        set {
            guard newValue != fontNameStored else { return }
            fontNameStored = newValue
            changed()
        }
    }

    @Stored("fontSize", DeviceMetrics.defaultFontSize) private var fontSizeStored: Double
    var fontSize: CGFloat {
        get { CGFloat(min(max(fontSizeStored, 6), 32)) }
        set {
            let clamped = Double(min(max(newValue, 6), 32))
            guard clamped != fontSizeStored else { return }
            fontSizeStored = clamped
            changed()
        }
    }

    @Stored("lineHeightScale", 1.0) private var lineHeightStored: Double
    var lineHeightScale: CGFloat {
        get { CGFloat(min(max(lineHeightStored, 0.85), 1.6)) }
        set {
            let clamped = Double(min(max(newValue, 0.85), 1.6))
            guard clamped != lineHeightStored else { return }
            lineHeightStored = clamped
            changed()
        }
    }

    @Stored("boldIsBright", true) private var boldIsBrightStored: Bool
    var boldIsBright: Bool {
        get { boldIsBrightStored }
        set {
            guard newValue != boldIsBrightStored else { return }
            boldIsBrightStored = newValue
            changed()
        }
    }

    @Stored("useBoldFont", true) private var useBoldFontStored: Bool
    var useBoldFont: Bool {
        get { useBoldFontStored }
        set {
            guard newValue != useBoldFontStored else { return }
            useBoldFontStored = newValue
            changed()
        }
    }

    // MARK: Cursor

    @Stored("cursorShape", CursorShape.block.rawValue) private var cursorShapeStored: Int
    var cursorShape: CursorShape {
        get { CursorShape(rawValue: cursorShapeStored) ?? .block }
        set {
            let value = newValue.rawValue
            guard value != cursorShapeStored else { return }
            cursorShapeStored = value
            changed()
        }
    }

    @Stored("cursorBlink", true) private var cursorBlinkStored: Bool
    var cursorBlink: Bool {
        get { cursorBlinkStored }
        set {
            guard newValue != cursorBlinkStored else { return }
            cursorBlinkStored = newValue
            changed()
        }
    }

    // MARK: Behaviour

    @Stored("scrollbackLines", 10_000) private var scrollbackStored: Int
    var scrollbackLines: Int {
        get { min(max(scrollbackStored, 100), 200_000) }
        set {
            let clamped = min(max(newValue, 100), 200_000)
            guard clamped != scrollbackStored else { return }
            scrollbackStored = clamped
            changed()
        }
    }

    @Stored("bell", BellBehaviour.haptic.rawValue) private var bellStored: String
    var bell: BellBehaviour {
        get { BellBehaviour(rawValue: bellStored) ?? .haptic }
        set {
            let value = newValue.rawValue
            guard value != bellStored else { return }
            bellStored = value
            changed()
        }
    }

    @Stored("copyOnSelect", false) private var copyOnSelectStored: Bool
    var copyOnSelect: Bool {
        get { copyOnSelectStored }
        set {
            guard newValue != copyOnSelectStored else { return }
            copyOnSelectStored = newValue
            changed()
        }
    }

    /// Puts the app's own `pbcopy`/`pbpaste` ahead of the bootstrap's on the
    /// child PATH. On by default because the ones in the bootstrap are broken
    /// here — they cannot reach the pasteboard and exit 0 regardless — but it
    /// is a setting because putting anything ahead of a user's PATH is the
    /// sort of thing they are entitled to say no to.
    @Stored("clipboardHelpers", true) private var clipboardHelpersStored: Bool
    var clipboardHelpers: Bool {
        get { clipboardHelpersStored }
        set {
            guard newValue != clipboardHelpersStored else { return }
            clipboardHelpersStored = newValue
            changed()
        }
    }

    @Stored("clipboardReadAccess", ClipboardReadAccess.ask.rawValue)
    private var clipboardReadAccessStored: String
    var clipboardReadAccess: ClipboardReadAccess {
        get { ClipboardReadAccess(rawValue: clipboardReadAccessStored) ?? .ask }
        set {
            let value = newValue.rawValue
            guard value != clipboardReadAccessStored else { return }
            clipboardReadAccessStored = value
            changed()
        }
    }

    /// Whether the screen comes back after the app is killed in the
    /// background. The processes never do — see `SessionSnapshot`.
    @Stored("restoreSessions", true) private var restoreSessionsStored: Bool
    var restoreSessions: Bool {
        get { restoreSessionsStored }
        set {
            guard newValue != restoreSessionsStored else { return }
            restoreSessionsStored = newValue
            changed()
        }
    }

    /// Local notification when a long command finishes while you are in
    /// another app. Driven by OSC 133 marks, not by program output.
    @Stored("notifyOnCommandFinish", true) private var notifyOnCommandFinishStored: Bool
    var notifyOnCommandFinish: Bool {
        get { notifyOnCommandFinishStored }
        set {
            guard newValue != notifyOnCommandFinishStored else { return }
            notifyOnCommandFinishStored = newValue
            changed()
        }
    }

    // MARK: Blocks

    /// Warp-style command blocks: a status rail and a divider per command, so
    /// a screen of scrollback reads as separate results rather than one wall
    /// of text. Off by default — it needs a shell that emits OSC 133, and
    /// with no marks there is nothing to divide.
    @Stored("blockMode", false) private var blockModeStored: Bool
    var blockMode: Bool {
        get { blockModeStored }
        set {
            guard newValue != blockModeStored else { return }
            blockModeStored = newValue
            changed()
        }
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
        set {
            guard newValue != commandSuggestionsStored else { return }
            commandSuggestionsStored = newValue
            changed()
        }
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
        set {
            guard newValue != shellCompletionsStored else { return }
            shellCompletionsStored = newValue
            changed()
        }
    }

    /// Whether Tab takes the suggestion. Off means only the arrow key and a
    /// tap do, leaving Tab entirely to the shell's own completion.
    @Stored("suggestionAcceptsTab", true) private var suggestionAcceptsTabStored: Bool
    var suggestionAcceptsTab: Bool {
        get { suggestionAcceptsTabStored }
        set {
            guard newValue != suggestionAcceptsTabStored else { return }
            suggestionAcceptsTabStored = newValue
            changed()
        }
    }

    @Stored("detectLinks", true) private var detectLinksStored: Bool
    var detectLinks: Bool {
        get { detectLinksStored }
        set {
            guard newValue != detectLinksStored else { return }
            detectLinksStored = newValue
            changed()
        }
    }

    @Stored("confirmClose", true) private var confirmCloseStored: Bool
    var confirmCloseWithRunningProcess: Bool {
        get { confirmCloseStored }
        set {
            guard newValue != confirmCloseStored else { return }
            confirmCloseStored = newValue
            changed()
        }
    }

    /// Ask before pasting text with a line break in it into a program that
    /// has not turned on bracketed paste — where every newline runs a command.
    @Stored("confirmMultilinePaste", true) private var confirmMultilinePasteStored: Bool
    var confirmMultilinePaste: Bool {
        get { confirmMultilinePasteStored }
        set {
            guard newValue != confirmMultilinePasteStored else { return }
            confirmMultilinePasteStored = newValue
            changed()
        }
    }

    /// Keep the screen from locking while a command is running. A locked phone
    /// suspends the app, and a shell the app owns stops with it.
    @Stored("keepScreenAwake", true) private var keepScreenAwakeStored: Bool
    var keepScreenAwakeWhileRunning: Bool {
        get { keepScreenAwakeStored }
        set {
            guard newValue != keepScreenAwakeStored else { return }
            keepScreenAwakeStored = newValue
            changed()
        }
    }

    /// While a car is connected and the phone is locked or showing another
    /// app, size the shell for the car's screen. The phone always has its own
    /// size while it shows diffTerm. Off, the shell stays the phone's size
    /// and the car shows the part of it the cursor is in. See CarPlayLink.
    @Stored("carPlayLeads", true) private var carPlayLeadsStored: Bool
    var carPlayLeads: Bool {
        get { carPlayLeadsStored }
        set {
            guard newValue != carPlayLeadsStored else { return }
            carPlayLeadsStored = newValue
            changed()
        }
    }

    @Stored("keyboardHaptics", true) private var keyboardHapticsStored: Bool
    var keyboardHaptics: Bool {
        get { keyboardHapticsStored }
        set {
            guard newValue != keyboardHapticsStored else { return }
            keyboardHapticsStored = newValue
            changed()
        }
    }

    @Stored("trackpadSensitivity", TrackpadSensitivity.medium.rawValue)
    private var trackpadStored: String
    var trackpadSensitivity: TrackpadSensitivity {
        get { TrackpadSensitivity(rawValue: trackpadStored) ?? .medium }
        set {
            let value = newValue.rawValue
            guard value != trackpadStored else { return }
            trackpadStored = value
            changed()
        }
    }

    @Stored("showKeyRow", true) private var showKeyRowStored: Bool
    var showKeyRow: Bool {
        get { showKeyRowStored }
        set {
            guard newValue != showKeyRowStored else { return }
            showKeyRowStored = newValue
            changed()
        }
    }

    @Stored("keyRowShowsFunctionKeys", false) private var fnRowStored: Bool
    var keyRowShowsFunctionKeys: Bool {
        get { fnRowStored }
        set {
            guard newValue != fnRowStored else { return }
            fnRowStored = newValue
            changed()
        }
    }

    // MARK: Shell

    @Stored("shellPath", "") private var shellPathStored: String
    /// Empty means "pick the best available shell at launch".
    var shellPath: String {
        get { shellPathStored }
        set {
            guard newValue != shellPathStored else { return }
            shellPathStored = newValue
            changed()
        }
    }

    @Stored("loginShell", true) private var loginShellStored: Bool
    var loginShell: Bool {
        get { loginShellStored }
        set {
            guard newValue != loginShellStored else { return }
            loginShellStored = newValue
            changed()
        }
    }

    @Stored("startDirectory", StartDirectory.deviceHome.rawValue) private var startDirStored: String
    var startDirectory: StartDirectory {
        get { StartDirectory(rawValue: startDirStored) ?? .home }
        set {
            let value = newValue.rawValue
            guard value != startDirStored else { return }
            startDirStored = value
            changed()
        }
    }

    /// In the shell's spelling, like every stored path: it is what the user
    /// typed, and it has no random roothide part to go stale.
    @Stored("customStartDirectory", "") private var customStartDirStored: String
    var customStartDirectory: String {
        get { customStartDirStored.isEmpty ? JailbreakRoot.toShell(UserEnvironment.deviceHome) : customStartDirStored }
        set {
            guard newValue != customStartDirStored else { return }
            customStartDirStored = newValue
            changed()
        }
    }

    /// Whether a new tab starts where the tab it was opened from is, rather
    /// than at Start In. Split panes always follow the pane they came from —
    /// a split is a second view of the work in front of you, and starting it
    /// somewhere else would be answering a question nobody asked.
    @Stored("newTabInheritsDirectory", true) private var newTabInheritsDirStored: Bool
    var newTabInheritsDirectory: Bool {
        get { newTabInheritsDirStored }
        set {
            guard newValue != newTabInheritsDirStored else { return }
            newTabInheritsDirStored = newValue
            changed()
        }
    }

    /// Updated as sessions report their cwd via OSC 7, so a new tab can open
    /// where the last one left off.
    /// In the shell's spelling; see `customStartDirectory`.
    @Stored("lastWorkingDirectory", "") private var lastWorkingDirectoryStored: String
    var lastWorkingDirectory: String {
        get { lastWorkingDirectoryStored.isEmpty ? JailbreakRoot.toShell(UserEnvironment.deviceHome) : lastWorkingDirectoryStored }
        set { lastWorkingDirectoryStored = newValue }
    }

    @Stored("startupCommand", "") private var startupCommandStored: String
    var startupCommand: String {
        get { startupCommandStored }
        set {
            guard newValue != startupCommandStored else { return }
            startupCommandStored = newValue
            changed()
        }
    }

    // MARK: Key row contents

    @Stored("hiddenKeyRowKeys", [] as [String]) private var hiddenKeyRowKeysStored: [String]
    /// Ids of the built-in keys switched off in Settings. Stored as the
    /// exceptions rather than the whole list, so a key added in a later
    /// version shows up instead of being silently absent.
    var hiddenKeyRowKeys: Set<String> {
        get { Set(hiddenKeyRowKeysStored) }
        set {
            let value = newValue.sorted()
            guard value != hiddenKeyRowKeysStored else { return }
            hiddenKeyRowKeysStored = value
            changed()
        }
    }

    @Stored("customKeys", [] as [[String: String]]) private var customKeysStored: [[String: String]]
    var customKeys: [CustomKey] {
        get { customKeysStored.compactMap(CustomKey.init(dictionary:)) }
        set {
            let value = newValue.map { $0.dictionary }
            guard value != customKeysStored else { return }
            customKeysStored = value
            changed()
        }
    }

    // MARK: Snippets

    @Stored("snippetsSeeded", false) private var snippetsSeededStored: Bool
    var snippetsSeeded: Bool {
        get { snippetsSeededStored }
        set {
            guard newValue != snippetsSeededStored else { return }
            snippetsSeededStored = newValue
            changed()
        }
    }

    @Stored("snippets", [] as [[String: String]]) private var snippetsStored: [[String: String]]
    var snippets: [Snippet] {
        get { snippetsStored.compactMap(Snippet.init(dictionary:)) }
        set {
            let value = newValue.map { $0.dictionary }
            guard value != snippetsStored else { return }
            snippetsStored = value
            changed()
        }
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
