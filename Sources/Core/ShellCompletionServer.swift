import Foundation

/// A zsh of the app's own, kept alive to answer one question: what would Tab
/// insert here?
///
/// Static specs say `git checkout` takes a branch; only the shell's completion
/// system knows *which* branches, because `_git` goes and looks — and `_make`
/// reads the Makefile, `_ssh` reads known_hosts. This asks that system without
/// touching the user's shell: a second interactive zsh, started with the same
/// environment and rc files (so the same aliases, compdefs and plugins), is
/// turned into a completion oracle by `Resources/Shell/diffterm.complete.zsh`.
///
/// The shell sits at a real command prompt — the only place zsh does
/// *command-line* completion rather than filename completion — and per request
/// the app types a line and a Tab and reads back what Tab would insert. A
/// per-request watchdog in the shell abandons any completion that runs long,
/// so one slow generator cannot wedge it; the app times each request out and,
/// after a few misses, gives up for the session. Everything stays on device.
final class ShellCompletionServer {

    static let shared = ShellCompletionServer()

    static let zshPath = "/var/jb/usr/bin/zsh"

    /// Overridden by the tests to point at the checked-in script.
    var scriptPathOverride: String?

    private var scriptPath: String? {
        if let scriptPathOverride { return scriptPathOverride }
        let bundled = Bundle.main.bundlePath + "/shell/diffterm.complete.zsh"
        return FileManager.default.fileExists(atPath: bundled) ? bundled : nil
    }

    var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: ShellCompletionServer.zshPath) && scriptPath != nil
    }

    private typealias Reply = (String?) -> Void

    private var pty: Pty?
    private var ready = false
    private var incoming: [UInt8] = []
    private var nextID = 1
    private var inFlight: (id: Int, line: String, reply: Reply)?
    private var queued: (line: String, cwd: String, reply: Reply)?
    private var consecutiveTimeouts = 0
    private var starts = 0

    /// Above the shell's own watchdog plus the cd round-trip, so an answer
    /// the shell actually produces is not thrown away by the app.
    private let replyTimeout: TimeInterval = 0.7
    /// The in-shell completion watchdog, in centiseconds. 400 ms keeps live
    /// typing responsive; a slow completion (git on a big repo) is abandoned
    /// rather than shown late. The tests raise it to prove branch awareness
    /// works when there is time for it.
    var watchdogCentiseconds = 40
    /// Reading the rc files and running compinit can take a while on a slow
    /// device; give startup room before deciding the server is not coming.
    private let startupTimeout: TimeInterval = 20
    /// After a few starts in one run, stop: something about this machine's
    /// shell setup does not suit it, and every further fork is waste.
    private let maxStarts = 3

    /// Temp ZDOTDIR: an rc file that sources the user's config, then the
    /// capture script. Removed on stop.
    private var zdotdir: String?

    init() {}

    // MARK: - Asking

    /// Asks for `line` completed against `cwd`. `reply` runs on the main queue
    /// with the completed line, or nil for no answer — including a request
    /// superseded by a newer one, or timed out.
    func request(line: String, cwd: String, reply: @escaping (String?) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard isAvailable, starts <= maxStarts else { reply(nil); return }
        ensureStarted()

        if inFlight != nil || !ready {
            queued?.reply(nil)      // overtaken; answered "nothing" now, not never
            queued = (line, cwd, reply)
            return
        }
        send(line: line, cwd: cwd, reply: reply)
    }

    private func send(line: String, cwd: String, reply: @escaping Reply) {
        guard let pty else { reply(nil); return }
        let id = nextID
        nextID += 1
        inFlight = (id, clean(line), reply)

        // Ctrl-U clears any line a timed-out request left half-typed. Then a
        // cd that also tags the reply id (executed, hence the return). Then the
        // line itself, typed, and a Tab — never an Enter, so it completes and
        // never runs.
        var bytes: [UInt8] = [0x15]
        bytes += Array("cd -- '\(singleQuoted(cwd))' 2>/dev/null;_DTC_ID=\(id)\r".utf8)
        bytes += Array(clean(line).utf8)
        bytes.append(0x09)
        pty.write(bytes)

        DispatchQueue.main.asyncAfter(deadline: .now() + replyTimeout) { [weak self] in
            self?.timedOut(id: id)
        }
    }

    /// Single-quote a path for the cd, escaping any quote it contains.
    private func singleQuoted(_ path: String) -> String {
        clean(path).replacingOccurrences(of: "'", with: "'\\''")
    }

    /// Strip the framing and control bytes. The line is untrusted, and a
    /// newline in it would submit a command rather than complete it.
    private func clean(_ s: String) -> String {
        String(s.unicodeScalars.filter { $0.value >= 0x20 && $0 != "\u{7F}" })
    }

    private func timedOut(id: Int) {
        guard let current = inFlight, current.id == id else { return }
        inFlight = nil
        current.reply(nil)
        consecutiveTimeouts += 1
        // Several misses in a row is a wedged shell. Restart once; if it keeps
        // happening `maxStarts` will stop it for the session.
        if consecutiveTimeouts >= 5 {
            restart()
        } else {
            flushQueued()
        }
    }

    private func flushQueued() {
        guard ready, inFlight == nil, let next = queued else { return }
        queued = nil
        send(line: next.line, cwd: next.cwd, reply: next.reply)
    }

    // MARK: - Replies

    /// Replies are `NUL id US text NUL`, in amongst whatever the prompt drew.
    private func received(_ bytes: [UInt8]) {
        incoming.append(contentsOf: bytes)
        while let frame = nextFrame() {
            let parts = frame.split(separator: 0x1F, maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2,
                  let id = Int(String(decoding: parts[0], as: UTF8.self)) else { continue }
            let text = String(decoding: parts[1], as: UTF8.self)

            if id == 0 {
                ready = true            // rc files done, widget live
                consecutiveTimeouts = 0
                flushQueued()
                continue
            }
            guard let current = inFlight, current.id == id else { continue }  // stale
            inFlight = nil
            consecutiveTimeouts = 0
            // BUFFER unchanged means the shell completed nothing — a no-op,
            // not a suggestion. The reply is the completed line, so equality
            // with what was asked is exactly that case.
            let answer = (text.isEmpty || text == current.line) ? nil : text
            current.reply(answer)
            flushQueued()
        }
        if incoming.count > 16_384 { incoming.removeFirst(incoming.count - 4_096) }
    }

    private func nextFrame() -> [UInt8]? {
        guard let start = incoming.firstIndex(of: 0) else { return nil }
        guard let end = incoming[(start + 1)...].firstIndex(of: 0) else {
            // No closing NUL yet. Drop anything before the opener so the
            // buffer cannot grow without bound waiting for one.
            if start > 0 { incoming.removeFirst(start) }
            return nil
        }
        let frame = Array(incoming[(start + 1)..<end])
        incoming.removeFirst(end + 1)
        return frame
    }

    // MARK: - Lifecycle

    private func ensureStarted() {
        guard pty == nil, let script = scriptPath else { return }
        starts += 1
        let pty = Pty()
        self.pty = pty
        ready = false
        incoming.removeAll()

        pty.onRead = { [weak self] chunk in
            DispatchQueue.main.async { self?.received(chunk) }
        }
        pty.onExit = { [weak self] _ in
            DispatchQueue.main.async { self?.exited() }
        }

        // An rc file that loads the user's config, then the capture script.
        // Pointing ZDOTDIR at it is what makes the capture run *at startup*,
        // as an rc file — the only way its Tab binding takes effect for the
        // line editor. A manual `source` at the prompt does not.
        guard let dir = makeZDotDir(script: script) else { self.pty = nil; return }
        zdotdir = dir

        var env = TerminalSession.environment()
        env["DIFFTERM_COMPLETION_SERVER"] = "1"
        env["DIFFTERM_COMPLETION_WATCHDOG"] = String(watchdogCentiseconds)
        env["ZDOTDIR"] = dir
        // A terminal with no capabilities: the less the prompt draws, the less
        // there is to scan past for a frame.
        env["TERM"] = "dumb"

        do {
            try pty.start(executable: ShellCompletionServer.zshPath,
                          arguments: ["-i"],
                          environment: env,
                          workingDirectory: UserEnvironment.home,
                          cols: 400, rows: 24)
        } catch {
            self.pty = nil
            starts = maxStarts + 1
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + startupTimeout) { [weak self] in
            guard let self, self.pty === pty, !self.ready else { return }
            self.restart()
        }
    }

    private func makeZDotDir(script: String) -> String? {
        let dir = NSTemporaryDirectory() + "diffterm-complete-\(getpid())"
        let fm = FileManager.default
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let rc = """
        [ -f "$HOME/.zshrc" ] && source "$HOME/.zshrc"
        source '\(script.replacingOccurrences(of: "'", with: "'\\''"))'
        """
        do {
            try rc.write(toFile: dir + "/.zshrc", atomically: true, encoding: .utf8)
            return dir
        } catch {
            return nil
        }
    }

    private func exited() {
        pty = nil
        ready = false
        inFlight?.reply(nil)
        inFlight = nil
        queued?.reply(nil)
        queued = nil
        if let zdotdir { try? FileManager.default.removeItem(atPath: zdotdir) }
        zdotdir = nil
    }

    private func restart() {
        pty?.terminate()
        exited()
        consecutiveTimeouts = 0
    }

    /// Stops the server. It restarts itself on the next request, until the
    /// per-run start budget runs out.
    func stop() {
        pty?.terminate()
        exited()
    }
}
