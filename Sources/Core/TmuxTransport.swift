import Foundation

enum TmuxError: LocalizedError {
    case notInstalled
    case attachFailed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "tmux is not installed. Install it with your package manager, then try again."
        case .attachFailed(let reason):
            return "Couldn't attach to tmux: \(reason)"
        }
    }
}

/// Where tmux is, and how to talk to it on this device.
///
/// Both constants here are workarounds for the same thing — a rootless
/// jailbreak puts everything behind `/var/jb`, which is a link into
/// `/private/preboot/<UUID>/...` — and both were found by running the real
/// binary rather than by reading its manual.
enum TmuxEnvironment {

    static let executable = "/var/jb/usr/bin/tmux"

    static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: executable)
    }

    /// tmux refuses to start without a UTF-8 `LC_CTYPE`, and this device has
    /// no compiled locales at all: `locale -a` is empty, so the `en_US.UTF-8`
    /// in the environment resolves to `C` and tmux exits with "invalid LC_ALL,
    /// LC_CTYPE or LANG" before it does anything else. Darwin's locale
    /// directory is named plain `UTF-8`, which is the one value that resolves.
    static let ctype = "UTF-8"

    /// tmux's own socket would go in `$TMPDIR`, which here is `/var/jb/tmp` —
    /// 166 characters once resolved, against a 104-byte `sun_path`. tmux
    /// resolves the path before binding, so it fails with "File name too long"
    /// and no server ever starts. An explicit short socket outside the
    /// bootstrap fixes both that and the durability problem: a socket under
    /// `/var/jb` would not survive reinstalling the jailbreak, and neither
    /// would the sessions it names.
    static var socketPath: String {
        UserEnvironment.deviceHome + "/Library/Application Support/diffTerm/tmux.sock"
    }

    /// The shared session diffTerm attaches to. One name, so a second launch
    /// of the app rejoins the shells the first one left running.
    static let sessionName = "diffterm"

    /// Arguments for `tmux -C`, attaching to the shared session or creating it.
    static func attachArguments(socket: String, session: String,
                                cols: Int, rows: Int) -> [String] {
        [executable, "-C", "-S", socket,
         "new-session", "-A", "-s", session,
         "-x", String(max(1, cols)), "-y", String(max(1, rows))]
    }
}

/// A session whose shell lives inside tmux, reached over control mode.
///
/// The point is survival: tmux's server is not our child — the client forks it
/// and it daemonises — so shells outlive the app the way the shelved sessiond
/// was meant to make them, using a program that has been doing it for twenty
/// years instead of one we would have to debug ourselves.
///
/// It is a *conduit*, not a second terminal. tmux is asked for raw pane output
/// and that is handed to the session's own emulator untouched, so OSC 133
/// marks, command blocks and ghost text keep working exactly as they do over a
/// plain pty. Control mode is what makes that possible: `tmux attach` would put
/// tmux's own screen in the way and swallow the marks.
final class TmuxTransport: SessionTransport {

    var onRead: (([UInt8]) -> Void)?
    var onExit: ((Int32) -> Void)?

    /// Fired for the notifications the UI cares about, on the main queue.
    /// Windows becoming tabs is the caller's business, not the transport's.
    var onNotification: ((TmuxNotification) -> Void)?

    /// The pane this transport is the terminal for. Nil until tmux answers
    /// `list-panes`, which is why writes are queued rather than dropped.
    private(set) var paneID: String?

    private let pty = Pty()
    private var parser = TmuxControlParser()
    private let queue = DispatchQueue(label: "dev.diffterm.tmux")

    /// Input that arrived before the pane id did. Someone who starts typing
    /// the instant a tab opens must not lose the first keystrokes.
    private var pendingInput: [UInt8] = []
    /// The size to apply once attached, for the same reason.
    private var pendingSize: (cols: Int, rows: Int)?
    /// Output seen before we knew which pane was ours. A window's first prompt
    /// is written the moment the window exists, which is before the reply
    /// naming its pane gets back to us — so without this the shell's opening
    /// prompt is the one thing the terminal never shows.
    private var pendingOutput: [(pane: String, bytes: [UInt8])] = []

    private var didExit = false
    /// Where a window this transport creates should start. tmux inherits the
    /// session's directory otherwise, which belongs to whichever tab last
    /// touched it.
    private var startDirectory: String?
    private let socket: String
    private let sessionName: String
    private let windowName: String

    /// What the handshake is waiting for. Control mode numbers its replies,
    /// but a client learns its own command's number only by counting, so the
    /// two commands that run before anything else is sent are tracked by state
    /// instead — which is enough, because nothing else is sent until they are
    /// done.
    private enum Handshake {
        case findingWindow
        case creatingWindow
        case done
    }
    private var handshake: Handshake = .findingWindow

    /// - Parameter windowName: the tmux window this terminal owns. One window
    ///   per tab, named after the session's own id, is what keeps two tabs from
    ///   showing the same shell — every control-mode client attached to a
    ///   session shares its *current* window, so asking tmux which pane is in
    ///   front gives every tab the same answer. A stable name also means a tab
    ///   rejoins its own shell after the app restarts rather than starting a
    ///   new one beside it.
    init(socket: String = TmuxEnvironment.socketPath,
         session: String = TmuxEnvironment.sessionName,
         windowName: String) {
        self.socket = socket
        self.sessionName = session
        self.windowName = windowName
    }

    // MARK: - Lifecycle

    func start(executable: String, arguments: [String], environment: [String: String],
               workingDirectory: String, cols: Int, rows: Int) throws {
        guard TmuxEnvironment.isInstalled else { throw TmuxError.notInstalled }
        startDirectory = workingDirectory

        // The socket directory has to exist before tmux binds in it; tmux
        // creates its own default directory but not one we named.
        try? FileManager.default.createDirectory(
            atPath: (socket as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)

        var env = environment
        env["LC_CTYPE"] = TmuxEnvironment.ctype
        // A tmux started from inside a tmux refuses to nest. The app is not a
        // tmux client, but it inherits its environment from whatever launched
        // it, and that can carry a stale $TMUX.
        env.removeValue(forKey: "TMUX")
        env.removeValue(forKey: "TMUX_PANE")

        pty.onRead = { [weak self] chunk in self?.receive(chunk) }
        pty.onExit = { [weak self] code in self?.finish(code) }

        try pty.start(executable: TmuxEnvironment.executable,
                      arguments: TmuxEnvironment.attachArguments(
                        socket: socket, session: sessionName, cols: cols, rows: rows),
                      environment: env,
                      workingDirectory: workingDirectory,
                      cols: cols, rows: rows)

        // Look for this terminal's own window first: if the app was killed
        // with a build running, it is still there and this is where we rejoin
        // it. Everything else waits on the answer, because a command needs a
        // target and guessing `%0` is wrong the moment a second window exists.
        handshake = .findingWindow
        send(TmuxCommand.listPanes(window: windowName))
    }

    /// Writes one control-mode command. Commands are lines; the newline is the
    /// only framing tmux has.
    private func send(_ command: String) {
        pty.write(Array((command + "\n").utf8))
    }

    // MARK: - Reading

    private func receive(_ chunk: [UInt8]) {
        queue.async { [weak self] in
            guard let self else { return }
            for notification in self.parser.feed(chunk) {
                self.handle(notification)
            }
        }
    }

    private func handle(_ notification: TmuxNotification) {
        switch notification {
        case .output(let pane, let bytes):
            // Only our own pane's bytes are this terminal's; another pane's
            // belong to another tab and are the caller's to route.
            guard paneID != nil else {
                // Bounded: a tmux that never answers the handshake must not be
                // able to fill memory with output for a pane we may not own.
                if pendingOutput.count < 256 { pendingOutput.append((pane, bytes)) }
                return
            }
            if pane == paneID {
                onRead?(bytes)
            } else {
                forward(notification)
            }

        case .reply(_, let lines, let isError):
            guard paneID == nil else { return }
            let pane = lines.first(where: { $0.hasPrefix("%") })?
                .trimmingCharacters(in: .whitespaces)
            switch handshake {
            case .findingWindow:
                if !isError, let pane {
                    handshake = .done
                    adopt(pane: pane)
                } else {
                    // No window of ours yet — a first run, or one whose window
                    // was closed from inside tmux. `list-panes` fails outright
                    // for an unknown target, which is the signal to make one.
                    handshake = .creatingWindow
                    send(TmuxCommand.newWindow(named: windowName,
                                               directory: startDirectory))
                }
            case .creatingWindow:
                if let pane {
                    handshake = .done
                    adopt(pane: pane)
                }
            case .done:
                break
            }

        case .exit:
            // The server is going away, so the shell is gone with it.
            finish(0)

        default:
            forward(notification)
        }
    }

    private func adopt(pane: String) {
        paneID = pane
        // Everything held back while the pane was unknown, in the order tmux
        // produced it — the opening prompt above all.
        let held = pendingOutput
        pendingOutput.removeAll()
        for item in held {
            if item.pane == pane {
                onRead?(item.bytes)
            } else {
                forward(.output(pane: item.pane, bytes: item.bytes))
            }
        }
        if let size = pendingSize {
            pendingSize = nil
            send(TmuxCommand.refreshClient(cols: size.cols, rows: size.rows))
        }
        if !pendingInput.isEmpty {
            let queued = pendingInput
            pendingInput.removeAll()
            send(TmuxCommand.sendKeys(pane: pane, bytes: queued))
        }
    }

    private func forward(_ notification: TmuxNotification) {
        guard let onNotification else { return }
        DispatchQueue.main.async { onNotification(notification) }
    }

    private func finish(_ code: Int32) {
        queue.async { [weak self] in
            guard let self, !self.didExit else { return }
            self.didExit = true
            let handler = self.onExit
            DispatchQueue.main.async { handler?(code) }
        }
    }

    // MARK: - Writing

    func write(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        queue.async { [weak self] in
            guard let self else { return }
            guard let pane = self.paneID else {
                // Bounded, because a tmux that never answers must not let a
                // held key grow this without limit.
                if self.pendingInput.count < 1 << 16 { self.pendingInput += bytes }
                return
            }
            self.send(TmuxCommand.sendKeys(pane: pane, bytes: bytes))
        }
    }

    /// tmux sizes a control-mode client's windows from what the client claims,
    /// not from the pty's winsize, so resizing the pty alone changes nothing.
    func resize(cols: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.paneID != nil else {
                self.pendingSize = (cols, rows)
                return
            }
            self.send(TmuxCommand.refreshClient(cols: cols, rows: rows))
        }
    }

    /// Ends this shell for good. Closing a tab is a decision to be rid of the
    /// work, and an orphan window left behind for every tab ever closed would
    /// make the session unusable within a day.
    func terminate() {
        queue.async { [weak self] in
            guard let self else { return }
            // The window, not the pane: this transport made the window and is
            // the only thing using it.
            if self.paneID != nil { self.send(TmuxCommand.killWindow(self.windowName)) }
            self.pty.terminate()
        }
    }

    /// Drops the client and leaves the server running — what the app does on
    /// its way out, and the whole reason this transport exists.
    func detach() {
        queue.async { [weak self] in self?.pty.terminate() }
    }

    func sendSignal(_ signal: Int32) {
        if signal == SIGHUP || signal == SIGTERM || signal == SIGKILL { terminate() }
    }

    /// The pty belongs to the tmux client, not to the shell, so its foreground
    /// process is always `tmux`. tmux knows the real answer and reports it as
    /// a window rename, which is where the title comes from instead.
    func foregroundProcessName() -> String? { nil }
}
