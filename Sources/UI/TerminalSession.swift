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
    private var transport: SessionTransport = Pty()

    /// A stable id for this session in the launchd daemon, so a reattach after
    /// the app was killed finds the same shell. Random per new session; a
    /// restored session carries its own forward. Non-zero.
    var daemonSessionID: UInt32 = UInt32.random(in: 1...UInt32.max)

    private(set) var isRunning = false
    private(set) var exitCode: Int32?

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
    var shellName: String {
        (TerminalSession.resolvedShell() as NSString).lastPathComponent
    }

    private(set) var workingDirectory: String

    /// Test seam: every chunk exactly as it comes off the pty, before the
    /// emulator or anything else has looked at it. Nil in normal use.
    static var debugRawOutput: (([UInt8]) -> Void)?

    /// Bytes read from the pty that the emulator has not consumed yet.
    private var pendingOutput: [UInt8] = []
    /// Prompt row of the last command we notified about, so a redrawn prompt
    /// or a second D mark cannot fire twice for one command.
    private var lastNotifiedCommand: Int?
    private let pendingLock = NSLock()

    private weak var view: TerminalView?
    private var displayLink: CADisplayLink?

    /// How many bytes to emulate per frame. High enough that bulk output is
    /// fast, low enough that the UI never stops responding.
    private let bytesPerFrame = 512 * 1024

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
                               workingDirectory: workingDirectory,
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
    func restore(from snapshot: SessionSnapshot, includeScreen: Bool = true) {
        let restoredDirectory = UserEnvironment.logicalPath(snapshot.workingDirectory)
        if isDirectory(restoredDirectory) {
            workingDirectory = restoredDirectory
        }
        if !snapshot.title.isEmpty { emulator.title = snapshot.title }
        if snapshot.daemonSessionID != 0 { daemonSessionID = snapshot.daemonSessionID }

        // Reattaching a live session: the daemon replays its own buffer, which
        // is the authoritative live screen, so the saved (older) one is
        // skipped to avoid drawing it twice.
        guard includeScreen else { return }

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

    private func isDirectory(_ path: String) -> Bool {
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

    /// Chooses how this session reaches its shell: the daemon when it is
    /// enabled and reachable (so the shell survives the app), otherwise a
    /// local pty. Falls back silently, so the terminal always works.
    private func makeTransport() -> SessionTransport {
        if Preferences.shared.tmuxSessions, TmuxEnvironment.isInstalled {
            // The session id is what makes a tab rejoin its own shell rather
            // than someone else's: it is random per new session, carried
            // forward in the snapshot, and so names the same tmux window
            // across a restart.
            return TmuxTransport(windowName: "dt-\(daemonSessionID)")
        }
        if Preferences.shared.persistentSessions,
           DaemonSessionManager.shared.isAvailable {
            return DaemonTransport(sessionID: daemonSessionID)
        }
        return Pty()
    }

    func start() {
        guard !isRunning else { return }

        let shell = TerminalSession.resolvedShell()
        defaultTitle = (shell as NSString).lastPathComponent

        var arguments = [Preferences.shared.loginShell ? "-\((shell as NSString).lastPathComponent)" : shell]
        if !Preferences.shared.loginShell { arguments = [shell] }

        var env = TerminalSession.environment()
        // Hand the shell the *logical* working directory as `$PWD`. The kernel
        // resolves the chdir to the physical path regardless, but with `$PWD`
        // set to a logical path that names the same inode, zsh keeps it — so
        // `%~` condenses `~` instead of the full `/private/preboot/...` path.
        env["PWD"] = workingDirectory

        func attempt(_ candidate: SessionTransport) -> Bool {
            transport = candidate
            installTransportHandlers()
            do {
                try candidate.start(executable: shell, arguments: arguments, environment: env,
                                    workingDirectory: workingDirectory,
                                    cols: emulator.cols, rows: emulator.rows)
                isRunning = true
                pushWindowSize()
                runStartupCommandIfNeeded()
                return true
            } catch { lastStartError = error; return false }
        }

        if attempt(makeTransport()) { return }
        // The daemon or tmux path failed — fall back to a local shell so the
        // terminal still works. The only cost is that this session will not
        // survive the app being killed. A terminal that will not open is a
        // worse outcome than one whose shells are not persistent.
        if transport is DaemonTransport || transport is TmuxTransport, attempt(Pty()) { return }

        let error = lastStartError ?? PtyError.spawnFailed(0)
        delegate?.session(self, didFailToStart: error)
        showStartupFailure(error)
    }

    private var lastStartError: Error?

    /// Wires the current transport's output and exit back into the session.
    /// Re-run when the transport changes (a daemon-to-local fallback).
    private func installTransportHandlers() {
        transport.onRead = { [weak self] chunk in
            guard let self else { return }
            TerminalSession.debugRawOutput?(chunk)
            self.pendingLock.lock()
            // A runaway program can outrun the emulator; drop the oldest
            // backlog rather than growing without bound.
            if self.pendingOutput.count > 16 << 20 {
                self.pendingOutput.removeFirst(self.pendingOutput.count / 2)
            }
            self.pendingOutput.append(contentsOf: chunk)
            self.pendingLock.unlock()
        }
        transport.onExit = { [weak self] code in
            guard let self else { return }
            self.isRunning = false
            self.exitCode = code
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

    private func showStartupFailure(_ error: Error) {
        let message = "\r\n\u{1B}[1;31mdiffTerm:\u{1B}[0m \(error.localizedDescription)\r\n"
        emulator.feed(message)
        view?.setNeedsDisplay()
    }

    func stop() {
        guard isRunning else { return }
        transport.terminate()
    }

    /// The app is going away, but this session should live on. A daemon or
    /// tmux session is detached, so the shell keeps running in something that
    /// is not our child; a local one has nothing to keep and simply ends with
    /// the app.
    ///
    /// The tmux client would die with the app anyway, but closing it here is
    /// the difference between leaving deliberately and being killed — and it
    /// is the line that would have to change if the client ever stops being a
    /// child process.
    func detachKeepingAlive() {
        (transport as? DaemonTransport)?.detach()
        (transport as? TmuxTransport)?.detach()
    }

    /// Starts a fresh shell in place of one that has exited. A `Pty` owns a
    /// descriptor and a latched exit, so restarting means a new one rather
    /// than trying to revive the old.
    func restart() {
        guard !isRunning else { return }
        transport.onRead = nil
        transport.onExit = nil
        transport = makeTransport()
        exitCode = nil
        cachedForegroundName = nil
        pendingLock.lock()
        pendingOutput.removeAll(keepingCapacity: true)
        pendingLock.unlock()
        workingDirectory = inheritedDirectory ?? TerminalSession.resolvedStartDirectory()
        start()
    }

    // MARK: - Output pump

    private func drainPendingOutput(all: Bool = false) {
        pendingLock.lock()
        if pendingOutput.isEmpty {
            pendingLock.unlock()
            return
        }
        let take = all ? pendingOutput.count : min(pendingOutput.count, bytesPerFrame)
        let chunk = Array(pendingOutput[0..<take])
        pendingOutput.removeFirst(take)
        pendingLock.unlock()

        emulator.feed(chunk)

        refreshForegroundName()
        delegate?.sessionDidProduceOutput(self)

        guard let view else { return }

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
        restartCursorBlink()
    }

    private var lastForegroundCheck = Date.distantPast
    private func refreshForegroundName() {
        // Reading /proc-equivalents per frame would be wasteful; twice a
        // second is plenty for a tab title.
        guard Date().timeIntervalSince(lastForegroundCheck) > 0.5 else { return }
        lastForegroundCheck = Date()
        let name = transport.foregroundProcessName()
        if name != cachedForegroundName {
            cachedForegroundName = name
            delegate?.sessionDidUpdateTitle(self)
        }
    }

    // MARK: - Input

    func send(bytes: [UInt8]) {
        guard isRunning, !bytes.isEmpty else { return }
        transport.write(bytes)
    }

    func send(text: String) {
        send(bytes: Array(text.utf8))
    }

    func paste(_ text: String) {
        send(bytes: KeyEncoder.paste(text, bracketed: emulator.modes.bracketedPaste))
    }

    func sendSignal(_ signal: Int32) {
        transport.sendSignal(signal)
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
        transport.resize(cols: cols, rows: rows,
                   pixelWidth: Int(pixelWidth), pixelHeight: Int(pixelHeight))
    }

    private func pushWindowSize() {
        transport.resize(cols: emulator.cols, rows: emulator.rows,
                   pixelWidth: Int(emulator.reportedPixelWidth),
                   pixelHeight: Int(emulator.reportedPixelHeight))
    }

    // MARK: - Cursor blink

    func restartCursorBlink() {
        cursorBlinkTimer?.invalidate()
        view?.cursorBlinkOn = true
        guard Preferences.shared.cursorBlink, emulator.modes.cursorBlink else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 0.53, repeats: true) { [weak self] _ in
            guard let self, let v = self.view else { return }
            v.cursorBlinkOn.toggle()
        }
        RunLoop.main.add(timer, forMode: .common)
        cursorBlinkTimer = timer
    }

    // MARK: - Preferences applied at runtime

    func applyPreferences() {
        emulator.setScrollbackLimit(Preferences.shared.scrollbackLines)
        restartCursorBlink()
    }

    // MARK: - Environment

    static func resolvedShell() -> String {
        let configured = Preferences.shared.shellPath.trimmingCharacters(in: .whitespaces)
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
            "/var/jb/usr/bin/zsh", "/var/jb/bin/zsh",
            "/var/jb/usr/bin/bash", "/var/jb/bin/bash",
            "/var/jb/usr/bin/sh", "/var/jb/bin/sh",
            "/bin/sh",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return "/bin/sh"
    }

    /// Nil unless the path names a directory that is really there, so a pane
    /// split from one whose directory has since been deleted falls back to the
    /// preference rather than failing to start a shell at all.
    static func usableDirectory(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir),
              isDir.boolValue else { return nil }
        return path
    }

    static func resolvedStartDirectory() -> String {
        let fm = FileManager.default
        func usable(_ p: String) -> Bool {
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: p, isDirectory: &isDir) && isDir.boolValue
        }
        let home = UserEnvironment.home
        switch Preferences.shared.startDirectory {
        case .deviceHome:
            let device = UserEnvironment.deviceHome
            return usable(device) ? device : (usable(home) ? home : "/")
        case .home:
            return usable(home) ? home : "/"
        case .root:
            return "/"
        case .lastUsed:
            let last = Preferences.shared.lastWorkingDirectory
            return usable(last) ? last : home
        case .custom:
            let custom = Preferences.shared.customStartDirectory
            return usable(custom) ? custom : home
        }
    }

    static func environment() -> [String: String] {
        var env: [String: String] = [:]

        // Start from the process environment so that anything the jailbreak's
        // launch environment set (notably a working PATH) survives.
        for (key, value) in ProcessInfo.processInfo.environment {
            env[key] = value
        }

        let jbPath = "/var/jb/usr/bin:/var/jb/bin:/var/jb/usr/sbin:/var/jb/sbin"
        let systemPath = "/usr/bin:/bin:/usr/sbin:/sbin"
        let existing = env["PATH"] ?? ""
        var parts = "\(jbPath):\(systemPath)".components(separatedBy: ":")
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
        env["PATH"] = parts.joined(separator: ":")

        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "diffTerm"
        env["TERM_PROGRAM_VERSION"] = DiffTermVersion.short
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        env["LC_CTYPE"] = env["LC_CTYPE"] ?? "en_US.UTF-8"
        // HOME must match the passwd database the rest of the bootstrap uses,
        // or the shell reads no rc files, ssh finds no keys and git finds no
        // config — all while appearing to work.
        env["HOME"] = UserEnvironment.home
        env["USER"] = UserEnvironment.userName
        env["LOGNAME"] = UserEnvironment.userName
        env["SHELL"] = resolvedShell()
        env["TMPDIR"] = "/var/tmp"
        if env["TERMINFO"] == nil, FileManager.default.fileExists(atPath: "/var/jb/usr/share/terminfo") {
            env["TERMINFO"] = "/var/jb/usr/share/terminfo"
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
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir),
              isDir.boolValue else { return nil }
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
        // Keep the logical form so the prompt stays condensed (`~/proj`) and
        // the stored directory survives a reboot that renames the physical
        // jailbreak root.
        let logical = UserEnvironment.logicalPath(path)
        workingDirectory = logical
        Preferences.shared.lastWorkingDirectory = logical
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

    func emulator(_ emulator: Emulator, didScrollBy lines: Int) {
        // Handled by the controller through didProduceOutputWhileScrolled.
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
        CommandNotifier.commandFinished(block,
                                        command: commandText(for: block),
                                        title: displayTitle)
    }

    /// The command line the user typed, read back off the grid between the
    /// `B` and `C` marks. It comes from parsed cells, so it holds no control
    /// bytes, and it is capped because a notification is not a transcript.
    private func commandText(for block: CommandBlock) -> String? {
        guard let start = block.commandStart,
              let row = emulator.absoluteRow(for: start.row) else { return nil }
        let line = emulator.normal.row(at: row)
        guard start.col < line.count else { return nil }
        var text = line.text(from: start.col, to: line.trimmedLength)
            .trimmingCharacters(in: .whitespaces)
        if text.count > 60 { text = String(text.prefix(59)) + "…" }
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
