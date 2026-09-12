import Foundation

/// One thing tmux said in control mode.
///
/// Window ids are `@N` and pane ids are `%N`, kept as strings including the
/// sigil: they are opaque handles that go straight back into commands, and
/// stripping the sigil only creates a chance to send `send-keys -t 0`, which
/// means the *first* pane rather than pane `%0`.
enum TmuxNotification: Equatable {
    /// Bytes a pane produced, already unescaped. The one notification that
    /// carries arbitrary binary, which is why it is `[UInt8]` and not `String`.
    case output(pane: String, bytes: [UInt8])
    case windowAdd(window: String)
    case windowClose(window: String)
    case windowRenamed(window: String, name: String)
    case windowPaneChanged(window: String, pane: String)
    case layoutChange(window: String, layout: String)
    case sessionChanged(session: String, name: String)
    case sessionsChanged
    case sessionWindowChanged(session: String, window: String)
    case subscriptionChanged(name: String)
    /// The server is going away. Carries tmux's reason when it gave one.
    case exit(reason: String?)
    /// A command's reply, gathered between `%begin` and its `%end` or
    /// `%error`. `number` is the command sequence tmux echoed back, which is
    /// how a reply is matched to the command that asked for it.
    case reply(number: Int, lines: [String], isError: Bool)
    /// A notification we have no case for. Kept rather than dropped so that a
    /// tmux newer than this code is visible in a log instead of silent.
    case unknown(line: String)
}

/// Turns the tmux control-mode byte stream into notifications.
///
/// Control mode is line-based, but it arrives over a pty, so lines end CRLF
/// and a chunk can split anywhere — including mid-line and mid-escape. The
/// parser therefore holds a partial line across feeds and never assumes a
/// chunk boundary is a line boundary.
///
/// Everything is done in bytes. Converting to `String` first would be lossy in
/// exactly the case that matters: `%output` carries whatever a program wrote,
/// and a UTF-8 sequence split across two tmux writes is not valid UTF-8 on its
/// own. The escaped form is pure ASCII, so unescaping to bytes and handing
/// those to the emulator keeps the stream byte-exact.
struct TmuxControlParser {

    /// Bytes of a line that has not ended yet.
    private var partial: [UInt8] = []

    /// The command block being gathered, if any: its sequence number and the
    /// reply lines so far. tmux guarantees a block is atomic — no notification
    /// is emitted between `%begin` and its `%end` — so anything arriving here
    /// belongs to the command.
    private var block: (number: Int, lines: [String])?

    /// How much unterminated input to hold before giving up on it. A pty read
    /// that never contains a newline would otherwise grow this without bound;
    /// a control-mode line is a screenful of escapes at worst.
    private static let maximumLine = 1 << 20

    mutating func feed(_ chunk: [UInt8]) -> [TmuxNotification] {
        var notifications: [TmuxNotification] = []
        for byte in chunk {
            if byte == 0x0A {
                // A pty writes CRLF; the CR is framing, not content.
                if partial.last == 0x0D { partial.removeLast() }
                if let notification = consume(line: partial) {
                    notifications.append(notification)
                }
                partial.removeAll(keepingCapacity: true)
            } else {
                partial.append(byte)
                if partial.count > TmuxControlParser.maximumLine {
                    partial.removeAll(keepingCapacity: true)
                }
            }
        }
        return notifications
    }

    private mutating func consume(line: [UInt8]) -> TmuxNotification? {
        // Inside a command block only `%end` and `%error` mean anything;
        // everything else is the reply, and a reply line may itself begin with
        // `%` — `list-panes` answers with pane ids.
        if var open = block {
            if let (kind, number) = TmuxControlParser.blockTerminator(line) {
                block = nil
                // A terminator for a different command means we lost sync;
                // report what we have rather than swallowing it for ever.
                return .reply(number: number == open.number ? open.number : number,
                              lines: open.lines, isError: kind)
            }
            open.lines.append(TmuxControlParser.text(line))
            block = open
            return nil
        }

        guard line.first == UInt8(ascii: "%") else {
            // Our own commands, echoed back by the pty, and anything else that
            // is not a notification. Silently ignored: turning echo off is not
            // ours to guarantee, so the parser simply does not care.
            return nil
        }

        let text = TmuxControlParser.text(line)
        let (verb, rest) = TmuxControlParser.split(text)

        switch verb {
        case "%begin":
            // `%begin <time> <number> <flags>`; the number is what `%end`
            // repeats back.
            let fields = rest.split(separator: " ", omittingEmptySubsequences: true)
            block = (number: fields.count > 1 ? Int(fields[1]) ?? 0 : 0, lines: [])
            return nil

        case "%output":
            // `%output %<pane> <escaped bytes>`. The payload runs to the end of
            // the line and may contain spaces, so only the first separator is
            // a separator.
            guard let space = line.dropFirst(verb.utf8.count + 1).firstIndex(of: UInt8(ascii: " ")) else {
                return .unknown(line: text)
            }
            let paneBytes = line[(verb.utf8.count + 1)..<space]
            let payload = Array(line[(space + 1)...])
            return .output(pane: TmuxControlParser.text(Array(paneBytes)),
                           bytes: TmuxControlParser.unescape(payload))

        case "%window-add":
            return .windowAdd(window: rest)
        // A window killed outright reports `%unlinked-window-close`; one that
        // merely left this session reports `%window-close`. Both mean the tab
        // for it has to go, so they are the same event here.
        case "%window-close", "%unlinked-window-close":
            return .windowClose(window: rest)
        case "%window-renamed", "%unlinked-window-renamed":
            let (window, name) = TmuxControlParser.split(rest)
            return .windowRenamed(window: window, name: name)
        case "%window-pane-changed":
            let (window, pane) = TmuxControlParser.split(rest)
            return .windowPaneChanged(window: window, pane: pane)
        case "%layout-change":
            let (window, layout) = TmuxControlParser.split(rest)
            return .layoutChange(window: window, layout: layout)
        case "%session-changed":
            let (session, name) = TmuxControlParser.split(rest)
            return .sessionChanged(session: session, name: name)
        case "%sessions-changed":
            return .sessionsChanged
        case "%session-window-changed":
            let (session, window) = TmuxControlParser.split(rest)
            return .sessionWindowChanged(session: session, window: window)
        case "%subscription-changed":
            return .subscriptionChanged(name: TmuxControlParser.split(rest).0)
        case "%exit":
            return .exit(reason: rest.isEmpty ? nil : rest)
        default:
            return .unknown(line: text)
        }
    }

    /// `%end` / `%error` and the command number they close, or nil for an
    /// ordinary reply line.
    private static func blockTerminator(_ line: [UInt8]) -> (isError: Bool, number: Int)? {
        let text = TmuxControlParser.text(line)
        let isError: Bool
        if text.hasPrefix("%end ") || text == "%end" { isError = false }
        else if text.hasPrefix("%error ") || text == "%error" { isError = true }
        else { return nil }
        let fields = text.split(separator: " ", omittingEmptySubsequences: true)
        return (isError, fields.count > 2 ? Int(fields[2]) ?? 0 : 0)
    }

    /// Control-mode metadata is ASCII by construction, so a lossy decode here
    /// cannot corrupt anything that matters — and it must not fail, or one odd
    /// byte in a window name would drop the notification carrying it.
    private static func text(_ bytes: [UInt8]) -> String {
        String(decoding: bytes, as: UTF8.self)
    }

    /// First word and the remainder, with no allocation of a full split.
    private static func split(_ s: String) -> (String, String) {
        guard let space = s.firstIndex(of: " ") else { return (s, "") }
        return (String(s[s.startIndex..<space]), String(s[s.index(after: space)...]))
    }

    /// Undoes tmux's escaping of `%output` payloads.
    ///
    /// tmux writes every byte it does not consider printable as a three-digit
    /// octal escape, and that includes the backslash itself, which arrives as
    /// `\134` rather than `\\`. So octal is the only form there is, and a
    /// backslash that is not followed by three octal digits is a literal
    /// backslash that some future tmux emitted differently — passed through
    /// rather than dropped, because losing a byte silently is worse than
    /// showing one too many.
    static func unescape(_ bytes: [UInt8]) -> [UInt8] {
        func isOctal(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x37 }

        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            if bytes[i] == UInt8(ascii: "\\"), i + 3 < bytes.count,
               isOctal(bytes[i + 1]), isOctal(bytes[i + 2]), isOctal(bytes[i + 3]) {
                let value = Int(bytes[i + 1] - 0x30) * 64
                          + Int(bytes[i + 2] - 0x30) * 8
                          + Int(bytes[i + 3] - 0x30)
                // Three octal digits reach 511; a value above a byte is not
                // something tmux emits, so leave it as the text it looks like.
                if value <= 0xFF {
                    out.append(UInt8(value))
                    i += 4
                    continue
                }
            }
            out.append(bytes[i])
            i += 1
        }
        return out
    }
}

// MARK: - Commands

/// The handful of control-mode commands diffTerm sends.
///
/// They are built here rather than interpolated at the call site so that the
/// quoting rules live in one place: a control-mode command is a line of tmux
/// command language, and a stray space or newline in a target would run
/// something other than what was meant.
enum TmuxCommand {

    /// Input for a pane, as hex. `send-keys -H` takes byte values, which is the
    /// only form that survives arbitrary input — a literal `-l` string would
    /// need every metacharacter of the tmux parser escaped, and a paste
    /// containing a newline would run as a second command.
    static func sendKeys(pane: String, bytes: [UInt8]) -> String {
        let hex = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
        return "send-keys -t \(pane) -H \(hex)"
    }

    /// tmux sizes a control-mode client's windows from what the client says it
    /// is, not from a pty winsize, so this is the only thing that resizes.
    static func refreshClient(cols: Int, rows: Int) -> String {
        "refresh-client -C \(max(1, cols))x\(max(1, rows))"
    }

    /// Asks for the panes of a window, one id per reply line.
    static func listPanes(window: String?) -> String {
        guard let window else { return "list-panes -F '#{pane_id}'" }
        return "list-panes -t \(window) -F '#{pane_id}'"
    }

    /// Window id and name per line, for building the tab list on attach.
    static func listWindows() -> String {
        "list-windows -F '#{window_id} #{window_name}'"
    }

    /// Creates a window under a known name and asks for the pane it made, so
    /// the caller does not have to guess which of the notifications that
    /// follow belongs to it.
    ///
    /// The directory is passed explicitly because tmux would otherwise start
    /// the window wherever the *session* last was, which is another tab's
    /// business entirely — and that would quietly undo splits and new tabs
    /// opening where the pane they came from is.
    static func newWindow(named name: String, directory: String?) -> String {
        var command = "new-window -n \(quoted(name))"
        if let directory, !directory.isEmpty {
            command += " -c \(quoted(directory))"
        }
        return command + " -P -F '#{pane_id}'"
    }

    /// A tmux command line is parsed by tmux, so anything that came from
    /// outside — a path with a space in it, a window name — has to survive
    /// that parse as one word.
    static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func killPane(_ pane: String) -> String { "kill-pane -t \(pane)" }

    static func killWindow(_ window: String) -> String { "kill-window -t \(window)" }
}
