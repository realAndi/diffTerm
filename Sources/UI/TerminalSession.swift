import UIKit

protocol TerminalSessionDelegate: AnyObject {
    func sessionDidUpdateTitle(_ session: TerminalSession)
    func sessionDidRing(_ session: TerminalSession)
    func session(_ session: TerminalSession, didExitWith code: Int32)
    func session(_ session: TerminalSession, didFailToStart error: Error)
    /// Fired after every batch of output. Output is the only thing that
    /// changes the buffer's height, and it does not invalidate layout, so this
    /// is the view's one chance to keep its scroll geometry honest.
    func sessionDidProduceOutput(_ session: TerminalSession)
    func session(_ session: TerminalSession, didRequestClipboardWrite text: String)
    func sessionPaletteDidChange(_ session: TerminalSession)
}

/// Nothing the app looked for is there to run as a shell.
struct MissingShellError: LocalizedError {
    var layout: JailbreakRoot.Layout

    var errorDescription: String? {
        if layout.prefix.isEmpty {
            return "Couldn't start a shell: no jailbreak bootstrap was found "
                + "(nothing at /var/jb, and no roothide root), and iOS has no shell of its own."
        }
        return "Couldn't start a shell: none of zsh, bash or sh is in "
            + "\(layout.jb("/usr/bin")) or \(layout.jb("/bin"))."
    }
}

/// One shell, one emulator, one view's worth of state.
///
/// Output arrives on the pty's IO queue and is parked in a buffer; the actual
/// emulation runs on the main thread, paced by the display link. That keeps
/// every screen mutation on one thread (no locking around the grid) while
/// still bounding how much work a runaway program can do per frame.
final class TerminalSession: NSObject {

    let identifier = UUID()
    weak var delegate: TerminalSessionDelegate?

    let emulator: Emulator
    /// The shell is the app's own child, so it ends when the app does.
    private var pty = Pty()

    private(set) var isRunning = false
    private(set) var exitCode: Int32?

    /// When the running shell was started and, once it has, when it exited.
    /// A shell that fails straight away is nearly always a setup problem
    /// rather than someone typing `exit`, and gets a full report.
    private var startedAt: Date?
    private var exitedAt: Date?

    /// Whether the shell failed within moments of starting.
    var failedOnArrival: Bool {
        guard let code = exitCode, code != 0,
              let startedAt, let exitedAt else { return false }
        return exitedAt.timeIntervalSince(startedAt) < 3
    }

    /// Shown in the tab bar: the program's own title if it set one, otherwise
    /// the foreground process name, otherwise the shell.
    var displayTitle: String {
        if !emulator.title.isEmpty {
            let cleaned = emulator.title.strippingLeadingStatusGlyphs
            if !cleaned.isEmpty { return cleaned }
            // A title that was *only* a status glyph (a bare spinner) is no
            // title at all; fall through to the process name.
        }
        if let name = cachedForegroundName, !name.isEmpty { return name }
        return defaultTitle
    }
    private var defaultTitle = "shell"
    private var cachedForegroundName: String?

    /// The shell's short name — `zsh`, `bash`, `fish`. Part of the key the
    /// command history matches on, since what follows a command depends on
    /// which shell is interpreting it.
    var shellName: String { cachedShellName }
    /// Resolving the shell checks the filesystem, and suggestions ask for the
    /// name after every batch of output. Settled once `start` has run.
    private lazy var cachedShellName = (TerminalSession.resolvedShell() as NSString).lastPathComponent

    private(set) var workingDirectory: String

    /// Test seam: every chunk exactly as it comes off the pty, before the
    /// emulator or anything else has looked at it. Nil in normal use.
    static var debugRawOutput: (([UInt8]) -> Void)?

    /// Bytes read from the pty that the emulator has not consumed yet.
    /// Appended to by the reader, under `pendingLock`.
    private var pendingOutput: [UInt8] = []
    /// Set by the reader when it had to throw backlog away, so the drain can
    /// cancel whatever escape sequence the cut left half-read.
    private var droppedOutput = false
    /// Set, under the lock, when the display link has been paused for want of
    /// output; the reader clears it and wakes the link.
    private var linkPaused = false
    /// What the main thread took from `pendingOutput` and has not fed yet.
    /// Swapped rather than copied out, so a large backlog is never shifted
    /// down a byte array under the lock the reader needs.
    private var drainBuffer: [UInt8] = []
    private var drainOffset = 0
    /// When the program opened a synchronized update (DECSET 2026) that is
    /// still holding the screen, if one is.
    private var synchronizedUpdateSince: CFTimeInterval?
    /// Prompt row of the last command we notified about, so a redrawn prompt
    /// or a second D mark cannot fire twice for one command.
    private var lastNotifiedCommand: Int?
    private let pendingLock = NSLock()

    private weak var view: TerminalView?
    private var displayLink: CADisplayLink?

    /// How long one frame may spend emulating. A byte count cannot bound this:
    /// the same half megabyte is milliseconds of plain text and far longer of
    /// dense CJK or colour escapes, on a phone several times slower still.
    private let emulationBudget: CFTimeInterval = 0.008
    /// Output is fed in slices this size, so the budget is checked often.
    private let feedSlice = 32 * 1024
    /// Longest a synchronized update may hold the screen. A program that
    /// opens one and never closes it must not freeze the terminal.
    private let synchronizedUpdateLimit: CFTimeInterval = 0.15
    /// Whether the running blink timer was started for a blinking cursor, so
    /// a program switching to a steady one (DECSCUSR) is noticed.
    private var blinkTimerMode: Bool?

    private var cursorBlinkTimer: Timer?

    /// A directory this session was told to start in — the pane it was split
    /// from, or the tab it was opened from. It outranks the Start In
    /// preference, and it is kept so that restarting a finished shell lands
    /// where the pane was rather than jumping home.
    private let inheritedDirectory: String?

    init(cols: Int, rows: Int, inheriting directory: String? = nil) {
        emulator = Emulator(cols: cols, rows: rows,
                            scrollbackLimit: Preferences.shared.scrollbackLines)
        inheritedDirectory = TerminalSession.usableDirectory(directory)
        workingDirectory = inheritedDirectory ?? TerminalSession.resolvedStartDirectory()
        super.init()
        emulator.delegate = self
    }

    deinit {
        displayLink?.invalidate()
        cursorBlinkTimer?.invalidate()
    }

    // MARK: - Snapshots

    /// The tail of this session's history, for `SessionStore`.
    func snapshot() -> SessionSnapshot {
        let buffer = emulator.normal
        let total = buffer.totalRows
        let start = max(0, total - SessionSnapshot.maxLines)
        var lines: [SnapshotLine] = []
        lines.reserveCapacity(total - start)
        for index in start..<total {
            lines.append(SnapshotLine(buffer.row(at: index)))
        }
        // A terminal's grid is mostly empty below the cursor; saving those rows
        // would restore a screen of blank lines with the prompt off the top.
        while let last = lines.last, last.runs.isEmpty { lines.removeLast() }

        return SessionSnapshot(title: displayTitle,
                               workingDirectory: JailbreakRoot.toShell(workingDirectory),
                               lines: lines,
                               savedAt: Date())
    }

    /// Puts a saved screen back, as scrollback, before the shell starts.
    ///
    /// The restored text goes into scrollback rather than onto the grid so the
    /// new shell's first prompt lands underneath it, exactly where it would
    /// have been. Nothing here is a live session: the marker line says so,
    /// because silently presenting dead output as a running terminal is how
    /// someone ends up waiting on a build that stopped existing hours ago.
    func restore(from snapshot: SessionSnapshot) {
        let restoredDirectory = UserEnvironment.logicalPath(
            JailbreakRoot.fromShell(snapshot.workingDirectory))
        if TerminalSession.isDirectory(restoredDirectory) {
            workingDirectory = restoredDirectory
        }
        if !snapshot.title.isEmpty { emulator.title = snapshot.title }

        // Reconstruct each line at the width its own content needs, not at
        // `emulator.cols`: restore runs during `addTab`, before layout has
        // set the real column count, so `cols` is a placeholder here. Using
        // it truncated every restored line to that placeholder — and because
        // the truncated screen was re-snapshotted and re-truncated on the
        // next launch, a prompt decayed to its first letter over a few
        // relaunches. That is the "A A A F C A" at the top of a restored tab.
        for line in snapshot.lines {
            let width = max(1, max(emulator.cols, line.contentWidth))
            emulator.normal.scrollback.append(line.line(width: width))
        }
        emulator.normal.scrollback.append(
            SessionSnapshot.markerLine(for: snapshot.savedAt, width: max(emulator.cols, 40)))
        emulator.markAll()
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return !path.isEmpty
            && FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
            && isDir.boolValue
    }

    // MARK: - Attaching a view

    func attach(view: TerminalView) {
        self.view = view
        view.emulator = emulator
        startDisplayLink()
        restartCursorBlink()
    }

    func detachView() {
        view = nil
        displayLink?.invalidate()
        displayLink = nil
        cursorBlinkTimer?.invalidate()
        cursorBlinkTimer = nil
    }

    private func startDisplayLink() {
        displayLink?.invalidate()
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func tick() {
        drainPendingOutput()
    }

    // MARK: - Starting

    func start() {
        guard !isRunning else { return }

        let shell = TerminalSession.resolvedShell()
        defaultTitle = (shell as NSString).lastPathComponent
        cachedShellName = defaultTitle

        // `resolvedShell` ends at /bin/sh without checking it, and iOS has no
        // /bin/sh of its own. With no bootstrap found, the exec would fail and
        // all anyone would see is "exited with status 127", every time they
        // tapped to retry. Stop here and say what is missing instead.
        guard FileManager.default.isExecutableFile(atPath: shell) else {
            let error = MissingShellError(layout: JailbreakRoot.current)
            delegate?.session(self, didFailToStart: error)
            showStartupFailure(error, shell: shell)
            return
        }

        // A login shell is started as `-zsh`: the dash is how it knows. The
        // executable path is ours to exec; argv[0] is the shell's to read, so
        // a full path in it gets the shell's spelling.
        let arguments = [Preferences.shared.loginShell ? "-\(defaultTitle)" : JailbreakRoot.toShell(shell)]

        var env = TerminalSession.environment()
        // Hand the shell the *logical* working directory as `$PWD`. The kernel
        // resolves the chdir to the physical path regardless, but with `$PWD`
        // set to a logical path that names the same inode, zsh keeps it — so
        // `%~` condenses `~` instead of the full `/private/preboot/...` path.
        env["PWD"] = JailbreakRoot.toShell(workingDirectory)

        installPtyHandlers()
        do {
            try pty.start(executable: shell, arguments: arguments, environment: env,
                          workingDirectory: workingDirectory,
                          cols: emulator.cols, rows: emulator.rows)
        } catch {
            delegate?.session(self, didFailToStart: error)
            showStartupFailure(error, shell: shell)
            return
        }
        isRunning = true
        startedAt = Date()
        exitedAt = nil
        pushWindowSize()
        runStartupCommandIfNeeded()
    }

    /// Wires the pty's output and exit back into the session. Re-run for the
    /// fresh `Pty` a restart makes.
    private func installPtyHandlers() {
        pty.onRead = { [weak self] chunk in
            guard let self else { return }
            TerminalSession.debugRawOutput?(chunk)
            self.pendingLock.lock()
            // A runaway program can outrun the emulator; drop the backlog
            // rather than growing without bound. What survives is the newest
            // output, which is what the screen should end up showing.
            if self.pendingOutput.count > 16 << 20 {
                self.pendingOutput.removeAll(keepingCapacity: true)
                self.droppedOutput = true
            }
            self.pendingOutput.append(contentsOf: chunk)
            let wake = self.linkPaused
            self.linkPaused = false
            self.pendingLock.unlock()
            if wake {
                DispatchQueue.main.async { [weak self] in self?.displayLink?.isPaused = false }
            }
        }
        pty.onExit = { [weak self] code in
            guard let self else { return }
            self.isRunning = false
            self.exitCode = code
            self.exitedAt = Date()
            self.drainPendingOutput(all: true)
            self.delegate?.session(self, didExitWith: code)
        }
    }

    private func runStartupCommandIfNeeded() {
        let command = Preferences.shared.startupCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }
        // Give the shell a moment to print its prompt first, otherwise the
        // command races the rc files and the line gets mangled.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.isRunning else { return }
            self.send(text: command + "\n")
        }
    }

    private func showStartupFailure(_ error: Error, shell: String) {
        emulator.feed(Diagnostics.terminalReport(
            headline: error.localizedDescription,
            facts: Diagnostics.facts(shell: shell, workingDirectory: workingDirectory)))
        view?.setNeedsDisplay()
    }

    /// The report for a shell that stopped as soon as it started. The shell's
    /// own last words, if it had any, are already on screen above this.
    func failedOnArrivalReport() -> String {
        let code = exitCode ?? 0
        var headline = "The shell stopped as soon as it started (status \(code)"
        if let meaning = Diagnostics.meaning(ofExitStatus: code) { headline += ": \(meaning)" }
        headline += ")."
        return Diagnostics.terminalReport(
            headline: headline,
            facts: Diagnostics.facts(shell: TerminalSession.resolvedShell(),
                                     workingDirectory: workingDirectory))
    }

    func stop() {
        guard isRunning else { return }
        pty.terminate()
    }

    /// Starts a fresh shell in place of one that has exited. A `Pty` owns a
    /// descriptor and a latched exit, so restarting means a new one rather
    /// than trying to revive the old.
    func restart() {
        guard !isRunning else { return }
        pty.onRead = nil
        pty.onExit = nil
        pty = Pty()
        exitCode = nil
        cachedForegroundName = nil
        pendingLock.lock()
        pendingOutput.removeAll(keepingCapacity: true)
        droppedOutput = false
        pendingLock.unlock()
        drainBuffer.removeAll(keepingCapacity: true)
        drainOffset = 0
        workingDirectory = inheritedDirectory ?? TerminalSession.resolvedStartDirectory()
        start()
    }

    // MARK: - Output pump

    private func drainPendingOutput(all: Bool = false) {
        let started = CACurrentMediaTime()
        var fed = false

        while true {
            if drainOffset >= drainBuffer.count {
                // Everything taken so far is fed; take what arrived since.
                drainBuffer.removeAll(keepingCapacity: true)
                drainOffset = 0
                pendingLock.lock()
                swap(&pendingOutput, &drainBuffer)
                let dropped = droppedOutput
                droppedOutput = false
                if drainBuffer.isEmpty, !all, synchronizedUpdateSince == nil {
                    // Nothing to do until the reader wakes the link again.
                    linkPaused = true
                    displayLink?.isPaused = true
                }
                pendingLock.unlock()
                // CAN abandons any sequence the dropped bytes cut in half, so
                // it cannot swallow the text that follows.
                if dropped { emulator.feed([0x18]) }
                if drainBuffer.isEmpty { break }
            }
            let end = all ? drainBuffer.count : min(drainBuffer.count, drainOffset + feedSlice)
            drainBuffer.withUnsafeBufferPointer { buffer in
                emulator.feed(UnsafeBufferPointer(rebasing: buffer[drainOffset..<end]))
            }
            drainOffset = end
            fed = true
            if !all, CACurrentMediaTime() - started > emulationBudget { break }
        }

        guard fed || synchronizedUpdateSince != nil else { return }

        if fed {
            refreshForegroundName()
            delegate?.sessionDidProduceOutput(self)
        }

        guard let view else { return }

        // Synchronized output (DECSET 2026): the program is drawing a frame
        // and asked for it to appear all at once. Keep the damage and hold
        // the screen until it says it is done, or the limit runs out.
        let now = CACurrentMediaTime()
        if emulator.modes.synchronizedUpdate, !all {
            let since = synchronizedUpdateSince ?? now
            synchronizedUpdateSince = since
            if now - since < synchronizedUpdateLimit { return }
        }
        synchronizedUpdateSince = nil

        if emulator.allDirty {
            view.setNeedsDisplay()
        } else if !emulator.dirtyRows.isEmpty {
            view.setNeedsDisplay(rows: emulator.dirtyRows)
        }
        emulator.clearDirty()

        // Moving the cursor changes no cell, so it dirties no row. Arrow keys
        // and the shell's own line editing would otherwise leave the caret
        // behind until something else forced a repaint.
        view.invalidateCursorIfMoved()

        // Any output means the cursor should be solid again — blinking that
        // starts mid-keystroke reads as lag.
        if fed { holdCursorSolid() }
    }

    private var lastForegroundCheck = Date.distantPast
    private func refreshForegroundName() {
        // Reading /proc-equivalents per frame would be wasteful; twice a
        // second is plenty for a tab title.
        guard Date().timeIntervalSince(lastForegroundCheck) > 0.5 else { return }
        lastForegroundCheck = Date()
        let name = pty.foregroundProcessName()
        if name != cachedForegroundName {
            cachedForegroundName = name
            delegate?.sessionDidUpdateTitle(self)
        }
    }

    // MARK: - Input

    func send(bytes: [UInt8]) {
        guard isRunning, !bytes.isEmpty else { return }
        pty.write(bytes)
    }

    func send(text: String) {
        send(bytes: Array(text.utf8))
    }

    func paste(_ text: String) {
        send(bytes: KeyEncoder.paste(text, bracketed: emulator.modes.bracketedPaste))
    }

    func sendSignal(_ signal: Int32) {
        pty.sendSignal(signal)
    }

    // MARK: - Geometry

    func resize(cols: Int, rows: Int, pixelWidth: CGFloat, pixelHeight: CGFloat) {
        guard cols > 0, rows > 0 else { return }
        let changed = cols != emulator.cols || rows != emulator.rows
        emulator.cellSize = CGSize(width: pixelWidth / CGFloat(max(cols, 1)),
                                   height: pixelHeight / CGFloat(max(rows, 1)))
        if changed {
            emulator.resize(cols: cols, rows: rows)
            view?.setNeedsDisplay()
        }
        pty.resize(cols: cols, rows: rows,
                   pixelWidth: Int(pixelWidth), pixelHeight: Int(pixelHeight))
    }

    private func pushWindowSize() {
        pty.resize(cols: emulator.cols, rows: emulator.rows,
                   pixelWidth: Int(emulator.reportedPixelWidth),
                   pixelHeight: Int(emulator.reportedPixelHeight))
    }

    // MARK: - Cursor blink

    func restartCursorBlink() {
        cursorBlinkTimer?.invalidate()
        cursorBlinkTimer = nil
        view?.cursorBlinkOn = true
        blinkTimerMode = emulator.modes.cursorBlink
        guard Preferences.shared.cursorBlink, emulator.modes.cursorBlink else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 0.53, repeats: true) { [weak self] _ in
            guard let self, let v = self.view else { return }
            v.cursorBlinkOn.toggle()
        }
        RunLoop.main.add(timer, forMode: .common)
        cursorBlinkTimer = timer
    }

    /// Shows the cursor and pushes the next blink back, without replacing the
    /// timer — this runs for every frame of output, and a new timer (and a
    /// preferences read) sixty times a second was work for nothing.
    private func holdCursorSolid() {
        guard blinkTimerMode == emulator.modes.cursorBlink else {
            restartCursorBlink()
            return
        }
        view?.cursorBlinkOn = true
        cursorBlinkTimer?.fireDate = Date().addingTimeInterval(0.53)
    }

    // MARK: - Preferences applied at runtime

    func applyPreferences() {
        emulator.setScrollbackLimit(Preferences.shared.scrollbackLines)
        restartCursorBlink()
    }

    // MARK: - Environment

    /// The shell to exec, in the app's spelling.
    static func resolvedShell() -> String {
        let configured = JailbreakRoot.fromShell(
            Preferences.shared.shellPath.trimmingCharacters(in: .whitespaces))
        if !configured.isEmpty, FileManager.default.isExecutableFile(atPath: configured) {
            return configured
        }
        // The passwd entry is the user's stated choice, so it wins over our
        // own preferences about which shell is nicest.
        let fromPasswd = UserEnvironment.loginShell
        if !fromPasswd.isEmpty, FileManager.default.isExecutableFile(atPath: fromPasswd) {
            return fromPasswd
        }
        // Otherwise prefer a full-featured shell, but never fail to open a
        // terminal over it.
        let candidates = [
            "/usr/bin/zsh", "/bin/zsh", "/usr/bin/bash", "/bin/bash", "/usr/bin/sh", "/bin/sh",
        ].map(JailbreakRoot.jb) + ["/bin/sh"]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return "/bin/sh"
    }

    /// Nil unless the path names a directory that is really there, so a pane
    /// split from one whose directory has since been deleted falls back to the
    /// preference rather than failing to start a shell at all.
    static func usableDirectory(_ path: String?) -> String? {
        guard let path, isDirectory(path) else { return nil }
        return path
    }

    static func resolvedStartDirectory() -> String {
        let home = UserEnvironment.home
        switch Preferences.shared.startDirectory {
        case .deviceHome:
            let device = UserEnvironment.deviceHome
            return isDirectory(device) ? device : (isDirectory(home) ? home : "/")
        case .home:
            return isDirectory(home) ? home : "/"
        case .root:
            // The root the shell will show as `/`, which on roothide is the
            // bootstrap's rather than the device's.
            return JailbreakRoot.fromShell("/")
        case .lastUsed:
            let last = JailbreakRoot.fromShell(Preferences.shared.lastWorkingDirectory)
            return isDirectory(last) ? last : home
        case .custom:
            let custom = JailbreakRoot.fromShell(Preferences.shared.customStartDirectory)
            return isDirectory(custom) ? custom : home
        }
    }

    static func environment() -> [String: String] {
        var env: [String: String] = [:]

        // Start from the process environment so that anything the jailbreak's
        // launch environment set (notably a working PATH) survives.
        for (key, value) in ProcessInfo.processInfo.environment {
            env[key] = value
        }

        // Every directory here is in the app's spelling until the end, where
        // the whole list is translated for the shell that will search it.
        let jbPath = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"].map(JailbreakRoot.jb)
        let systemPath = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let existing = env["PATH"] ?? ""
        var parts = jbPath + systemPath
        for p in existing.components(separatedBy: ":") where !p.isEmpty && !parts.contains(p) {
            parts.append(p)
        }

        // Our pbcopy/pbpaste go *ahead* of the bootstrap's, which cannot reach
        // the pasteboard from a command-line process and — the part that makes
        // it invisible — exit 0 while failing. The socket they talk to is
        // handed over in the environment, so a process outside diffTerm never
        // has an address to connect to.
        if Preferences.shared.clipboardHelpers, let helpers = helperDirectory() {
            parts.insert(helpers, at: 0)
            if let socket = ClipboardServer.shared.socketPath {
                env["DIFFTERM_CLIPBOARD"] = socket
            }
        }
        env["PATH"] = parts.map(JailbreakRoot.toShell).joined(separator: ":")

        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "diffTerm"
        env["TERM_PROGRAM_VERSION"] = DiffTermVersion.short
        // `LC_CTYPE` is what decides whether the shell and everything it runs
        // treat input as UTF-8, and it outranks `LANG`, so setting it is both
        // necessary and enough. Setting *only* it is deliberate: the one value
        // iOS accepts for the character type is the bare codeset `UTF-8`,
        // which is not a complete locale, and as `$LANG` it would make
        // `setlocale(LC_ALL, "")` fail and drop the shell back to US-ASCII.
        //
        // An inherited `LANG` or `LC_ALL` naming a locale this device does not
        // have is dropped rather than passed along. `LC_ALL` outranks the
        // value set here, so leaving a bad one in place would crash bash in
        // readline exactly as before — see `UserEnvironment.ctypeLocale`.
        if let ctype = UserEnvironment.ctypeLocale {
            env["LC_CTYPE"] = ctype
            for key in ["LANG", "LC_ALL"] {
                if let value = env[key], !UserEnvironment.isCompleteLocale(value) {
                    env.removeValue(forKey: key)
                }
            }
        }
        // And whatever a dotfile or a command sets later, the common UTF-8
        // names resolve rather than crash readline: see `localeDirectory`.
        // In the device's spelling even on roothide, since it is the system's
        // libc that reads it — the same libc that finds `UTF-8` in iOS's own
        // /usr/share/locale for a roothide shell today.
        if env["LC_CTYPE"] != nil, let locales = UserEnvironment.localeDirectory {
            env["PATH_LOCALE"] = locales
        }
        // HOME must match the passwd database the rest of the bootstrap uses,
        // or the shell reads no rc files, ssh finds no keys and git finds no
        // config — all while appearing to work.
        env["HOME"] = JailbreakRoot.toShell(UserEnvironment.home)
        env["USER"] = UserEnvironment.userName
        env["LOGNAME"] = UserEnvironment.userName
        env["SHELL"] = JailbreakRoot.toShell(resolvedShell())
        env["TMPDIR"] = JailbreakRoot.toShell("/var/tmp")
        let terminfo = JailbreakRoot.jb("/usr/share/terminfo")
        if env["TERMINFO"] == nil, FileManager.default.fileExists(atPath: terminfo) {
            env["TERMINFO"] = JailbreakRoot.toShell(terminfo)
        }

        // These leak the app's own sandbox into the child and confuse tools
        // that inspect them.
        for key in ["CFFIXED_USER_HOME", "XPC_SERVICE_NAME", "XPC_FLAGS",
                    "DYLD_INSERT_LIBRARIES", "_MSSafeMode"] {
            env.removeValue(forKey: key)
        }

        // An *empty* ZDOTDIR is worse than none: zsh uses it in place of HOME
        // to find its rc files, so it goes looking for `/.zshrc` at the root
        // of the filesystem, finds nothing, and starts with no user config at
        // all — no aliases, no PATH edits, and no shell integration, while
        // looking perfectly normal. A set-and-empty value is never meaningful,
        // so drop it and let HOME win. A real one is left alone.
        if let zdotdir = env["ZDOTDIR"], zdotdir.isEmpty {
            env.removeValue(forKey: "ZDOTDIR")
        }

        return env
    }

    /// The `helpers` directory inside the app bundle, if it was built.
    private static func helperDirectory() -> String? {
        let path = Bundle.main.bundlePath + "/helpers"
        guard isDirectory(path) else { return nil }
        return path
    }
}

// MARK: - EmulatorDelegate

extension TerminalSession: EmulatorDelegate {

    func emulatorWrite(_ emulator: Emulator, data: [UInt8]) {
        send(bytes: data)
    }

    func emulatorRing(_ emulator: Emulator) {
        delegate?.sessionDidRing(self)
    }

    func emulator(_ emulator: Emulator, didSetTitle title: String) {
        delegate?.sessionDidUpdateTitle(self)
    }

    func emulator(_ emulator: Emulator, didSetWorkingDirectory path: String) {
        // The shell reports its directory in its own spelling. Keep the logical
        // form so the prompt stays condensed (`~/proj`) and the stored
        // directory survives a reboot that renames the physical jailbreak root
        // — and store it in the shell's spelling, which survives a roothide
        // reinstall renaming the whole bootstrap.
        let logical = UserEnvironment.logicalPath(JailbreakRoot.fromShell(path))
        workingDirectory = logical
        Preferences.shared.lastWorkingDirectory = JailbreakRoot.toShell(logical)
    }

    func emulator(_ emulator: Emulator, didRequestClipboardWrite text: String) {
        delegate?.session(self, didRequestClipboardWrite: text)
    }

    func emulator(_ emulator: Emulator, didPostNotification title: String, body: String) {
        // Presented in-app rather than as a system notification; the app has
        // no notification entitlement and asking for one to let arbitrary
        // shell output post alerts would be a poor trade.
        NotificationCenter.default.post(
            name: TerminalSession.didPostProgramNotification,
            object: self,
            userInfo: ["title": title, "body": body])
    }

    func emulatorPaletteDidChange(_ emulator: Emulator) {
        delegate?.sessionPaletteDidChange(self)
    }

    func emulatorShellIntegrationDidChange(_ emulator: Emulator) {
        // Only the tab chip cares, and only about the newest command, so this
        // is a broadcast rather than another link in the delegate chain.
        NotificationCenter.default.post(
            name: TerminalSession.commandStateDidChangeNotification, object: self)

        guard let block = emulator.shellIntegration.last,
              block.finishedAt != nil,
              block.promptStart != lastNotifiedCommand else { return }
        lastNotifiedCommand = block.promptStart
        let command = commandText(for: block).map { text in
            var text = text
            // Cap the text because a notification is not a transcript.
            if text.count > 60 { text = String(text.prefix(59)) + "…" }
            return text
        }
        CommandNotifier.commandFinished(block,
                                        command: command,
                                        title: displayTitle)
    }

    /// The command line the user typed, read back off the grid between the
    /// `B` and `C` marks. It comes from parsed cells, so it holds no control
    /// bytes.
    func commandText(for block: CommandBlock) -> String? {
        guard let start = block.commandStart,
              let row = emulator.absoluteRow(for: start.row) else { return nil }
        let line = emulator.normal.row(at: row)
        guard start.col < line.count else { return nil }
        let text = line.text(from: start.col, to: line.trimmedLength)
            .trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    static let didPostProgramNotification = Notification.Name("dev.diffterm.programNotification")
    /// Fired when a command starts or finishes, so the tab chips can show it.
    static let commandStateDidChangeNotification =
        Notification.Name("dev.diffterm.commandStateDidChange")
}

extension String {
    /// Drops a leading run of status decoration a program prefixes its title
    /// with — a spinner or star like `✳`, `◐◑◒◓`, `⏺` — plus the whitespace
    /// after it. Claude Code and friends animate these into the title; in a
    /// tab chip they render as a colour emoji and duplicate the running dot
    /// the chip already shows, so they are stripped for display.
    ///
    /// Only *non-ASCII* symbol and emoji glyphs are removed, so an ordinary
    /// title — `~/proj`, `-zsh`, `vim file.c` — is never touched, and the
    /// strip stops at the first real character.
    var strippingLeadingStatusGlyphs: String {
        // Iterate whole graphemes, not scalars: an emoji like `✳️` is a base
        // symbol plus a variation selector, and dropping only the base would
        // leave the selector behind as a stray mark.
        var rest = Substring(self)
        var removedGlyph = false
        while let ch = rest.first, let first = ch.unicodeScalars.first {
            if first.value > 0x7F {
                let category = first.properties.generalCategory
                let isSymbol = category == .otherSymbol || category == .modifierSymbol
                    || category == .mathSymbol || category == .currencySymbol
                let isEmoji = ch.unicodeScalars.contains {
                    $0.properties.isEmojiPresentation || ($0.properties.isEmoji && $0.value > 0x2000)
                }
                if isSymbol || isEmoji {
                    rest = rest.dropFirst()
                    removedGlyph = true
                    continue
                }
            }
            // Whitespace only counts as decoration once a glyph led it.
            if removedGlyph, ch == " " || ch == "\u{09}" || ch == "\u{00A0}" {
                rest = rest.dropFirst()
                continue
            }
            break
        }
        return String(rest)
    }
}
