import UIKit

/// The project root. `make` runs the harness from the project directory, so
/// the working directory is it. This used to be an absolute path baked into
/// the file, which broke the moment the tree moved.
private let projectRoot = FileManager.default.currentDirectoryPath

/// Headless checks for the emulator and the renderer.
///
/// There is no simulator or test runner on the device, so this is a plain
/// executable: it drives the same types the app uses, asserts on the grid,
/// and renders a reference PNG that can be looked at directly.
@main
struct Harness {

    static var failures = 0
    static var checks = 0

    static func main() {
        if let at = CommandLine.arguments.firstIndex(of: "--specs") {
            let args = CommandLine.arguments
            guard args.count > at + 2 else {
                print("usage: harness --specs <fig-build-dir> <out-dir>")
                exit(2)
            }
            let result = SpecConverter.convert(from: args[at + 1], to: args[at + 2])
            print("  wrote \(result.written.count) specs, \(result.bytes / 1024) KB json, \(result.packedBytes / 1024) KB packed")
            if !result.failed.isEmpty {
                print("  \(result.failed.count) failed:")
                for (name, reason) in result.failed.prefix(25) {
                    print("    \(name): \(reason.prefix(90))")
                }
            }
            return
        }
        if CommandLine.arguments.contains("--icons") {
            let root = "\(projectRoot)"
            let out = IconRenderer.generate(iconDirectory: "\(root)/Resources/Icons",
                                            infoPlistPath: "\(root)/Resources/Info.plist")
            print("  wrote \(out.written.count) icon files, \(out.alternates.count) alternates")
            return
        }
        emulatorTests()
        shellIntegrationTests()
        sessionRestoreTests()
        logicalPathTests()
        startDirectoryTests()
        iconTests()
        keyRowTests()
        keyRepeatTests()
        floatingCursorTests()
        cursorRepaintTests()
        menuAndSplitTests()
        scrollTests()
        suggestionTests()
        blockPaneTests()
        blockLayoutTests()
        ghostTextPathTests()
        ghostContrastTests()
        ghostFillTests()
        ghostWrapCaptureTests()
        realShellWrapTests()
        wrappedSpaceCaptureTests()
        ghostWrapTests()
        completerTests()
        specCompleterTests()
        gitRefTests()
        colorSchemeTests()
        pathValidationTests()
        shellCompletionTests()
        daemonTransportTests()
        tmuxControlTests()
        tmuxTransportTests()
        restoreMarkTests()
        liveSnapshotProbe()
        glyphPresentationTests()
        bundledFontTests()
        tabBarContrastTests()
        tabTitleTests()
        displayTests()
        systemImageTests()
        themeTests()
        inlineImageTests()
        renderSample()

        print("")
        if failures == 0 {
            print("\u{1B}[32mall \(checks) checks passed\u{1B}[0m")
        } else {
            print("\u{1B}[31m\(failures) of \(checks) checks FAILED\u{1B}[0m")
            exit(1)
        }
    }

    // MARK: - Assertions

    static func expect(_ condition: Bool, _ label: String, _ detail: @autoclosure () -> String = "") {
        checks += 1
        if condition {
            print("  \u{1B}[32m✓\u{1B}[0m \(label)")
        } else {
            failures += 1
            let extra = detail()
            print("  \u{1B}[31m✗ \(label)\u{1B}[0m\(extra.isEmpty ? "" : " — \(extra)")")
        }
    }

    static func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
        expect(actual == expected, label, "got \(actual), expected \(expected)")
    }

    // MARK: - Emulator behaviour

    /// A row in the terminal's absolute space — scrollback first, then the
    /// live grid — which is what a shell integration mark resolves to.
    static func historyLine(_ e: Emulator, _ row: Int) -> String {
        let l = e.buffer.row(at: row)
        var s = l.text(to: l.trimmedLength)
        while s.hasSuffix(" ") { s.removeLast() }
        return s
    }

    static func line(_ e: Emulator, _ row: Int) -> String {
        let l = e.buffer.lines[row]
        var s = l.text(to: l.trimmedLength)
        while s.hasSuffix(" ") { s.removeLast() }
        return s
    }

    static func emulatorTests() {
        print("emulator")

        // Plain text and wrapping.
        do {
            let e = Emulator(cols: 10, rows: 4)
            e.feed("hello")
            expectEqual(line(e, 0), "hello", "prints text")
            expectEqual(e.buffer.cursorX, 5, "cursor advances")

            e.feed("\r\n")
            expectEqual(e.buffer.cursorY, 1, "CR/LF moves down")
            expectEqual(e.buffer.cursorX, 0, "CR returns to column 0")

            e.feed("0123456789ABC")
            expectEqual(line(e, 1), "0123456789", "fills the row exactly")
            expectEqual(line(e, 2), "ABC", "autowraps to the next row")
            expect(e.buffer.lines[1].wrapped, "wrapped flag is set on the broken line")
        }

        // Deferred wrap: writing exactly `cols` characters must not scroll.
        do {
            let e = Emulator(cols: 5, rows: 2)
            e.feed("abcde")
            expectEqual(e.buffer.cursorY, 0, "cursor stays on row 0 after exactly cols chars")
            e.feed("f")
            expectEqual(e.buffer.cursorY, 1, "the next character triggers the wrap")
        }

        // Cursor addressing and erase.
        do {
            let e = Emulator(cols: 20, rows: 5)
            e.feed("\u{1B}[3;5Hxy")
            expectEqual(e.buffer.cursorY, 2, "CUP row is 1-based")
            expectEqual(line(e, 2), "    xy", "CUP column is 1-based")

            e.feed("\u{1B}[2J\u{1B}[H")
            expectEqual(line(e, 2), "", "ED 2 clears the screen")
            expectEqual(e.buffer.cursorX + e.buffer.cursorY, 0, "CUP with no params homes the cursor")
        }

        // Scroll regions.
        do {
            let e = Emulator(cols: 8, rows: 5)
            e.feed("1\r\n2\r\n3\r\n4\r\n5")
            e.feed("\u{1B}[2;4r")            // region = rows 2..4
            e.feed("\u{1B}[4;1H")            // bottom of region
            e.feed("\n")
            expectEqual(line(e, 0), "1", "line above the scroll region is untouched")
            expectEqual(line(e, 1), "3", "region scrolled up")
            expectEqual(line(e, 2), "4", "region scrolled up")
            expectEqual(line(e, 3), "", "region gained a blank line")
            expectEqual(line(e, 4), "5", "line below the scroll region is untouched")
        }

        // Scrollback only accumulates from full-screen scrolls.
        do {
            let e = Emulator(cols: 8, rows: 3, scrollbackLimit: 100)
            for i in 1...6 { e.feed("row\(i)\r\n") }
            expect(e.buffer.scrollbackCount > 0, "output scrolls into scrollback")
            expectEqual(e.buffer.scrollback[0].text(to: 4), "row1", "oldest line is first in scrollback")
        }

        // SGR: both the semicolon and colon forms of truecolor.
        do {
            let e = Emulator(cols: 20, rows: 2)
            e.feed("\u{1B}[38;2;10;20;30mA")
            expectEqual(e.buffer.lines[0][0].attrs.fg, TermColor.rgb(10, 20, 30), "SGR 38;2 truecolor")

            e.feed("\u{1B}[0m\u{1B}[38:2::40:50:60mB")
            expectEqual(e.buffer.lines[0][1].attrs.fg, TermColor.rgb(40, 50, 60), "SGR 38:2 colon truecolor")

            e.feed("\u{1B}[0m\u{1B}[48;5;123mC")
            expectEqual(e.buffer.lines[0][2].attrs.bg, TermColor.indexed(123), "SGR 48;5 indexed")

            e.feed("\u{1B}[0m\u{1B}[1;3;4mD")
            let flags = e.buffer.lines[0][3].attrs.flags
            expect(flags.contains(.bold) && flags.contains(.italic) && flags.contains(.underline),
                   "SGR combines bold/italic/underline")

            e.feed("\u{1B}[0mE")
            expectEqual(e.buffer.lines[0][4].attrs.flags, CellFlags(), "SGR 0 resets attributes")
        }

        // Erase paints the current background, not the default one.
        do {
            let e = Emulator(cols: 10, rows: 2)
            e.feed("\u{1B}[44m\u{1B}[2J")
            expectEqual(e.buffer.lines[0][3].attrs.bg, TermColor.indexed(4), "ED fills with the active background")
        }

        // Insert/delete characters and lines.
        do {
            let e = Emulator(cols: 10, rows: 3)
            e.feed("abcdef\u{1B}[1;3H\u{1B}[2@")
            expectEqual(line(e, 0), "ab  cdef", "ICH inserts blanks")
            e.feed("\u{1B}[1;3H\u{1B}[2P")
            expectEqual(line(e, 0), "abcdef", "DCH deletes characters")

            e.feed("\u{1B}[2;1Hsecond\u{1B}[3;1Hthird")
            e.feed("\u{1B}[2;1H\u{1B}[M")
            expectEqual(line(e, 1), "third", "DL removes a line and pulls the rest up")
        }

        // Alternate screen leaves the normal buffer intact.
        do {
            let e = Emulator(cols: 10, rows: 3)
            e.feed("normal")
            e.feed("\u{1B}[?1049h")
            expect(e.modes.altScreen, "DECSET 1049 enters the alternate screen")
            expectEqual(line(e, 0), "", "alternate screen starts empty")
            e.feed("alt")
            e.feed("\u{1B}[?1049l")
            expect(!e.modes.altScreen, "DECRST 1049 leaves the alternate screen")
            expectEqual(line(e, 0), "normal", "normal buffer survived the round trip")
        }

        // UTF-8, including a sequence split across two feeds.
        do {
            let e = Emulator(cols: 20, rows: 2)
            e.feed("héllo→")
            expectEqual(line(e, 0), "héllo→", "decodes multi-byte UTF-8")

            let e2 = Emulator(cols: 20, rows: 2)
            let bytes = Array("→".utf8)
            e2.feed([bytes[0]])
            e2.feed([bytes[1], bytes[2]])
            expectEqual(line(e2, 0), "→", "decodes UTF-8 split across reads")
        }

        // Double-width characters occupy two cells.
        do {
            let e = Emulator(cols: 10, rows: 2)
            e.feed("日本")
            expectEqual(e.buffer.cursorX, 4, "CJK advances two columns per glyph")
            expect(e.buffer.lines[0][1].attrs.flags.contains(.wideTrailer), "wide glyph reserves a trailer cell")
        }

        // Combining marks attach to the preceding cell.
        do {
            let e = Emulator(cols: 10, rows: 2)
            e.feed("e\u{0301}")
            expectEqual(e.buffer.cursorX, 1, "combining mark does not advance the cursor")
            expectEqual(String(e.buffer.lines[0][0].ch), "é", "combining mark merges into the cell")
        }

        // A split escape sequence must not leak its bytes onto the screen.
        do {
            let e = Emulator(cols: 20, rows: 2)
            e.feed(Array("\u{1B}[3".utf8))
            e.feed(Array("1mX".utf8))
            expectEqual(line(e, 0), "X", "escape sequence split across reads is not printed")
            expectEqual(e.buffer.lines[0][0].attrs.fg, TermColor.indexed(1), "split sequence still applies")
        }

        // Replies the shell depends on.
        do {
            let e = Emulator(cols: 80, rows: 24)
            let recorder = ReplyRecorder()
            e.delegate = recorder
            e.feed("\u{1B}[6n")
            expectEqual(recorder.text, "\u{1B}[1;1R", "DSR 6 reports the cursor position")

            recorder.text = ""
            e.feed("\u{1B}[18t")
            expectEqual(recorder.text, "\u{1B}[8;24;80t", "window op 18 reports the grid size")

            recorder.text = ""
            e.feed("\u{1B}[c")
            expect(recorder.text.hasPrefix("\u{1B}[?6"), "DA1 answers with a VT-class response")
        }

        // OSC handling.
        do {
            let e = Emulator(cols: 20, rows: 2)
            let recorder = ReplyRecorder()
            e.delegate = recorder
            e.feed("\u{1B}]0;my title\u{07}")
            expectEqual(e.title, "my title", "OSC 0 sets the title")

            e.feed("\u{1B}]0;bad\u{1B}[31mtitle\u{07}")
            expect(!e.title.contains("\u{1B}"), "control bytes are stripped from titles")

            // OSC 52 read requests must never be answered.
            recorder.text = ""
            e.feed("\u{1B}]52;c;?\u{07}")
            expectEqual(recorder.text, "", "OSC 52 clipboard reads are refused")
            expect(recorder.clipboard == nil, "OSC 52 read does not leak the clipboard")

            e.feed("\u{1B}]52;c;aGVsbG8=\u{07}")
            expectEqual(recorder.clipboard, "hello", "OSC 52 write is honoured")

            // Unpadded base64: some senders leave the '=' off, and
            // Data(base64Encoded:) rejects it outright.
            recorder.clipboard = nil
            e.feed("\u{1B}]52;c;aGVsbG8\u{07}")
            expectEqual(recorder.clipboard, "hello", "unpadded base64 still decodes")

            // A copy well past the 8 KiB ceiling that used to apply to every
            // OSC. It was truncated mid-base64 and then silently dropped.
            recorder.clipboard = nil
            let big = String(repeating: "diffTerm ", count: 8000)   // 72 KB
            let encoded = Data(big.utf8).base64EncodedString()
            e.feed("\u{1B}]52;c;\(encoded)\u{07}")
            expectEqual(recorder.clipboard, big, "a 72 KB clipboard write survives")

            // Past the ceiling the payload is a fragment, and half a clipboard
            // is worse than none: it must be dropped, not truncated.
            recorder.clipboard = nil
            let huge = String(repeating: "x", count: (1 << 20) + 4096)
            e.feed("\u{1B}]52;c;\(Data(huge.utf8).base64EncodedString())\u{07}")
            expect(recorder.clipboard == nil, "an oversized clipboard write is dropped, not truncated")

            // The parser must recover: the sequence after an overflow still runs.
            e.feed("\u{1B}]52;c;aGVsbG8=\u{07}")
            expectEqual(recorder.clipboard, "hello", "the parser recovers after an oversized OSC")

            // An over-long title is a fragment too.
            e.feed("\u{1B}]0;short\u{07}")
            e.feed("\u{1B}]0;\(String(repeating: "t", count: 9000))\u{07}")
            expectEqual(e.title, "short", "an over-long title is dropped rather than truncated")
        }

        // Hyperlinks are limited to schemes worth handing to the system.
        do {
            let e = Emulator(cols: 20, rows: 2)
            e.feed("\u{1B}]8;;https://example.com\u{1B}\\A\u{1B}]8;;\u{1B}\\")
            let id = e.buffer.lines[0][0].attrs.linkID
            expect(id != 0, "OSC 8 records a link id")
            expectEqual(e.hyperlinks[id], "https://example.com", "OSC 8 stores the target")

            e.feed("\u{1B}]8;;javascript:alert(1)\u{1B}\\B")
            expectEqual(e.buffer.lines[0][1].attrs.linkID, UInt32(0), "unsafe link schemes are rejected")
        }

        // Resize keeps the cursor and content sane.
        do {
            let e = Emulator(cols: 20, rows: 5)
            e.feed("hello\r\nworld")
            e.resize(cols: 10, rows: 3)
            expectEqual(e.cols, 10, "resize applies the new width")
            expectEqual(e.rows, 3, "resize applies the new height")
            expect(e.buffer.cursorY < 3, "cursor stays inside the grid after resize")
        }

        // Home resolution. On a rootless jailbreak the bootstrap's passwd
        // database is the one that matters; landing in the system /var/mobile
        // means no rc files, no ssh keys and no git config.
        do {
            let home = UserEnvironment.home
            var isDir: ObjCBool = false
            expect(FileManager.default.fileExists(atPath: home, isDirectory: &isDir) && isDir.boolValue,
                   "resolved home exists", home)

            let env = TerminalSession.environment()
            expectEqual(env["HOME"], home, "HOME matches the resolved home")
            expect(env["PATH"]?.contains("/var/jb/usr/bin") == true, "PATH includes the bootstrap bin")
            expectEqual(env["TERM"], "xterm-256color", "TERM is xterm-256color")
            expect(env["CFFIXED_USER_HOME"] == nil, "the app's own container vars are not leaked")

            // If the bootstrap declares a home, that is where we must land.
            if let passwd = try? String(contentsOfFile: "/var/jb/etc/passwd", encoding: .utf8),
               let line = passwd.split(separator: "\n").first(where: { $0.hasPrefix("\(UserEnvironment.userName):") }) {
                let fields = line.split(separator: ":", omittingEmptySubsequences: false)
                if fields.count >= 7, !fields[5].isEmpty {
                    expectEqual(home, String(fields[5]), "home follows the bootstrap passwd entry")
                }
            }
        }

        // Key encoding.
        do {
            expectEqual(KeyEncoder.bytes(for: .up, modifiers: [], applicationCursorKeys: false, applicationKeypad: false),
                        Array("\u{1B}[A".utf8), "up arrow, normal mode")
            expectEqual(KeyEncoder.bytes(for: .up, modifiers: [], applicationCursorKeys: true, applicationKeypad: false),
                        Array("\u{1B}OA".utf8), "up arrow, application mode")
            expectEqual(KeyEncoder.bytes(for: .up, modifiers: [.shift], applicationCursorKeys: true, applicationKeypad: false),
                        Array("\u{1B}[1;2A".utf8), "modified arrows always use the CSI form")
            expectEqual(KeyEncoder.bytes(for: "c", modifiers: [.control]), [3], "ctrl-c is ETX")
            expectEqual(KeyEncoder.bytes(for: "a", modifiers: [.alt]), [0x1B, 0x61], "alt prefixes with ESC")
            expectEqual(KeyEncoder.bytes(for: .f(5), modifiers: [], applicationCursorKeys: false, applicationKeypad: false),
                        Array("\u{1B}[15~".utf8), "F5 uses the tilde form")
        }

        // Paste sanitising.
        do {
            let pasted = KeyEncoder.paste("ok\u{1B}[201~evil\nnext", bracketed: true)
            let text = String(decoding: pasted, as: UTF8.self)
            expect(!text.contains("\u{1B}[201~evil"), "paste cannot forge the bracketed-paste terminator")
            expect(text.hasPrefix("\u{1B}[200~") && text.hasSuffix("\u{1B}[201~"), "paste is bracketed")
            expect(text.contains("\r"), "newlines become carriage returns")
        }

        print("")
    }

    // MARK: - Icons

    /// Guards the failure mode where a theme is added but `make icons` is not
    /// run: the app would try to select an icon that does not exist.
    /// OSC 133. The marks record where a command's output begins and ends,
    /// which is what "copy the output of that command" and jump-to-prompt are
    /// built on — so what matters is that the rows stay pointed at the right
    /// text as scrollback churns underneath them.
    static func shellIntegrationTests() {
        print("")
        print("shell integration")

        // A whole command, start to finish.
        do {
            let e = Emulator(cols: 20, rows: 6)
            e.feed("\u{1B}]133;A\u{07}$ ")
            e.feed("\u{1B}]133;B\u{07}echo hi\r\n")
            e.feed("\u{1B}]133;C\u{07}hi\r\n")
            e.feed("\u{1B}]133;D;0\u{07}")

            expectEqual(e.shellIntegration.blocks.count, 1, "one command recorded")
            let block = e.shellIntegration.blocks[0]
            expectEqual(block.promptStart, 0, "prompt starts on the first row")
            expectEqual(block.commandStart?.col, 2, "command starts after the prompt text")
            expectEqual(block.outputStart, 1, "output starts on the row after the command")
            expectEqual(block.outputEnd, 2, "output ends where the next prompt will go")
            expectEqual(block.exitCode, 0, "exit status is recorded")
            expect(!block.isRunning, "a command with a D mark is not running")
        }

        // `D;aborted=1` and bare `D` both turn up in the wild.
        do {
            let e = Emulator(cols: 20, rows: 6)
            e.feed("\u{1B}]133;A\u{07}\u{1B}]133;C\u{07}\u{1B}]133;D;aborted=1\u{07}")
            expectEqual(e.shellIntegration.blocks.first?.exitCode, 1, "D;aborted=1 yields an exit code")

            let f = Emulator(cols: 20, rows: 6)
            f.feed("\u{1B}]133;A\u{07}\u{1B}]133;C\u{07}\u{1B}]133;D\u{07}")
            expect(f.shellIntegration.blocks.first?.exitCode == nil, "bare D records no exit code")
            expect(!(f.shellIntegration.blocks.first?.isRunning ?? true), "bare D still ends the command")
        }

        // A command interrupted before it reported D is closed by the prompt
        // that follows, rather than swallowing everything after it.
        do {
            let e = Emulator(cols: 20, rows: 8)
            e.feed("\u{1B}]133;A\u{07}$ \u{1B}]133;C\u{07}output\r\n")
            expect(e.shellIntegration.blocks[0].isRunning, "a command without D is still running")
            e.feed("\u{1B}]133;A\u{07}$ ")
            expectEqual(e.shellIntegration.blocks.count, 2, "the next prompt opens a second block")
            expect(!e.shellIntegration.blocks[0].isRunning, "and closes the first")
            expectEqual(e.shellIntegration.blocks[0].outputEnd, 1, "closed at the new prompt's row")
        }

        // Marks are in stable coordinates, so they keep naming the same text
        // after the lines they point at have moved down the ring.
        do {
            let e = Emulator(cols: 20, rows: 4, scrollbackLimit: 100)
            e.feed("\u{1B}]133;A\u{07}$ \u{1B}]133;B\u{07}cmd\r\n")
            e.feed("\u{1B}]133;C\u{07}marked output\r\n\u{1B}]133;D;0\u{07}")
            let outputStart = e.shellIntegration.blocks[0].outputStart!
            expectEqual(historyLine(e, e.absoluteRow(for: outputStart)!), "marked output",
                        "the mark names the output row")

            for i in 0..<20 { e.feed("filler \(i)\r\n") }
            expect(e.buffer.scrollbackCount > 0, "the output has scrolled into scrollback")
            expectEqual(historyLine(e, e.absoluteRow(for: outputStart)!), "marked output",
                        "and still names it after scrolling")
        }

        // Once the text is genuinely gone the mark reports so rather than
        // pointing at whatever moved into its place.
        do {
            let e = Emulator(cols: 20, rows: 4, scrollbackLimit: 5)
            e.feed("\u{1B}]133;A\u{07}$ \u{1B}]133;B\u{07}cmd\r\n")
            e.feed("\u{1B}]133;C\u{07}doomed\r\n\u{1B}]133;D;0\u{07}")
            let outputStart = e.shellIntegration.blocks[0].outputStart!
            for i in 0..<40 { e.feed("filler \(i)\r\n") }
            expect(e.absoluteRow(for: outputStart) == nil, "a mark past the end of scrollback resolves to nil")
        }

        // Clearing the scrollback must take the marks with it: those rows are
        // reused, and a stale mark would point at unrelated text.
        do {
            let e = Emulator(cols: 20, rows: 4, scrollbackLimit: 100)
            for i in 0..<10 { e.feed("line \(i)\r\n") }
            e.feed("\u{1B}]133;A\u{07}$ \u{1B}]133;B\u{07}cmd\r\n")
            e.feed("\u{1B}]133;C\u{07}distinctive\r\n\u{1B}]133;D;0\u{07}")
            let mark = e.shellIntegration.blocks.last!.outputStart!
            expectEqual(historyLine(e, e.absoluteRow(for: mark)!), "distinctive", "the mark names its output")

            e.feed("\u{1B}[3J")
            if let row = e.absoluteRow(for: mark) {
                expectEqual(historyLine(e, row), "distinctive",
                            "a mark surviving CSI 3J still names the same line")
            } else {
                expect(true, "a mark surviving CSI 3J still names the same line")
            }

            // Now push the marked line out of history entirely — past the
            // 100-line scrollback this emulator was given.
            for i in 0..<200 { e.feed("after \(i)\r\n") }
            expect(e.absoluteRow(for: mark) == nil, "and resolves to nil once that line is gone")
        }

        // Nothing is recorded on the alternate screen: a full-screen program
        // has no prompts, and its rows vanish when it exits.
        do {
            let e = Emulator(cols: 20, rows: 4)
            e.feed("\u{1B}[?1049h")
            e.feed("\u{1B}]133;A\u{07}\u{1B}]133;C\u{07}\u{1B}]133;D;0\u{07}")
            expect(e.shellIntegration.isEmpty, "alternate-screen marks are ignored")
            e.feed("\u{1B}[?1049l")
            e.feed("\u{1B}]133;A\u{07}")
            expectEqual(e.shellIntegration.blocks.count, 1, "and recording resumes afterwards")
        }

        // Navigation.
        do {
            let e = Emulator(cols: 20, rows: 4, scrollbackLimit: 100)
            for _ in 0..<3 {
                e.feed("\u{1B}]133;A\u{07}$ \u{1B}]133;C\u{07}out\r\n\u{1B}]133;D;0\u{07}")
            }
            let prompts = e.shellIntegration.blocks.map { $0.promptStart }
            expectEqual(prompts.count, 3, "three prompts recorded")
            expectEqual(e.shellIntegration.promptRow(before: prompts[2]), prompts[1],
                        "previous-prompt steps back one command")
            expectEqual(e.shellIntegration.promptRow(after: prompts[0]), prompts[1],
                        "next-prompt steps forward one command")
            expect(e.shellIntegration.promptRow(before: prompts[0]) == nil,
                   "there is nothing before the first prompt")
            expectEqual(e.shellIntegration.block(containing: prompts[1])?.promptStart, prompts[1],
                        "a row inside a command finds that command")
            expectEqual(e.shellIntegration.lastWithOutput?.promptStart, prompts[2],
                        "the last command with output is the most recent one")
        }

        // Re-drawn prompts — a resize, or zsh redrawing after a completion
        // menu — must not each open a block of their own.
        do {
            let e = Emulator(cols: 20, rows: 4)
            e.feed("\u{1B}]133;A\u{07}$ ")
            e.feed("\r\u{1B}]133;A\u{07}$ ")
            expectEqual(e.shellIntegration.blocks.count, 1, "a repeated prompt mark reuses its block")
        }
    }

    /// Snapshots exist so that being killed in the background costs the
    /// processes and not the screen, which only holds if a restored line is
    /// indistinguishable from the one that was saved.
    static func sessionRestoreTests() {
        print("")
        print("session restore")

        func roundTrip(_ line: Line, width: Int) -> Line {
            SnapshotLine(line).line(width: width)
        }

        // Colour and attributes, both indexed and 24-bit.
        do {
            let e = Emulator(cols: 40, rows: 3)
            e.feed("\u{1B}[1;31mred bold\u{1B}[0m plain \u{1B}[38;2;10;20;30mrgb\u{1B}[0m")
            let original = e.buffer.lines[0]
            let restored = roundTrip(original, width: 40)

            expectEqual(restored.text(to: restored.trimmedLength),
                        original.text(to: original.trimmedLength), "text survives the round trip")
            var identical = true
            for i in 0..<original.trimmedLength where restored[i].ch != original[i].ch
                || restored[i].attrs != original[i].attrs {
                identical = false
            }
            expect(identical, "every cell round-trips with its attributes")
            expectEqual(restored.trimmedLength, original.trimmedLength, "trimmed length matches")
        }

        // Every colour form packs and unpacks to itself.
        do {
            let colors: [TermColor] = [.default, .indexed(0), .indexed(1), .indexed(255),
                                       .rgb(0, 0, 0), .rgb(10, 20, 30), .rgb(255, 255, 255)]
            var ok = true
            for color in colors where TermColor(packed: color.packed) != color { ok = false }
            expect(ok, "colours survive packing")
        }

        // A double-width glyph occupies two cells; losing the trailer would
        // shift everything after it one column left.
        do {
            let e = Emulator(cols: 20, rows: 2)
            e.feed("你好x")
            let original = e.buffer.lines[0]
            let restored = roundTrip(original, width: 20)
            expectEqual(restored.text(to: restored.trimmedLength), "你好x", "wide glyphs survive")
            expect(restored[1].attrs.flags.contains(.wideTrailer), "the wide trailer cell is restored")
            expectEqual(String(restored[4].ch), "x", "and the following text keeps its column")
        }

        // A hyperlink id is deliberately dropped: the table is not saved, so a
        // surviving id would point at nothing.
        do {
            let e = Emulator(cols: 20, rows: 2)
            e.feed("\u{1B}]8;;https://example.com\u{1B}\\A\u{1B}]8;;\u{1B}\\")
            expect(e.buffer.lines[0][0].attrs.linkID != 0, "the original cell carries a link id")
            let restored = roundTrip(e.buffer.lines[0], width: 20)
            expectEqual(restored[0].attrs.linkID, 0, "the restored cell does not")
        }

        // The snapshot has to survive the encoder it is actually written with.
        do {
            let e = Emulator(cols: 30, rows: 3)
            e.feed("\u{1B}[32mgreen\u{1B}[0m and plain")
            let snapshot = SessionSnapshot(title: "zsh",
                                           workingDirectory: "/var/jb/var/mobile",
                                           lines: [SnapshotLine(e.buffer.lines[0])],
                                           savedAt: Date())
            guard let data = try? JSONEncoder().encode([snapshot]),
                  let decoded = try? JSONDecoder().decode([SessionSnapshot].self, from: data),
                  let first = decoded.first else {
                expect(false, "a snapshot encodes and decodes as JSON")
                return
            }
            expect(true, "a snapshot encodes and decodes as JSON")
            expectEqual(first.title, "zsh", "the title survives")
            expectEqual(first.workingDirectory, "/var/jb/var/mobile", "the directory survives")
            let line = first.lines[0].line(width: 30)
            expectEqual(line.text(to: line.trimmedLength), "green and plain", "the text survives")
            expectEqual(line[0].attrs.fg, e.buffer.lines[0][0].attrs.fg, "so does the colour")
        }

        // A blank line encodes to nothing, which is what lets the tail be
        // trimmed rather than restoring a screen of empty rows.
        do {
            expect(SnapshotLine(Line(width: 40)).runs.isEmpty, "a blank line has no runs")
        }

        // The marker is exactly one row wide, whatever the terminal is.
        do {
            for width in [20, 40, 120] {
                let marker = SessionSnapshot.markerLine(for: Date(), width: width)
                expectEqual(marker.count, width, "the restore marker fills a \(width)-column row")
            }
        }

        // Tab status: running and failed are worth showing, success is not.
        do {
            let e = Emulator(cols: 20, rows: 4)
            expectEqual(CommandStatus.from(e.shellIntegration), CommandStatus.none,
                        "no marks means no dot")

            e.feed("\u{1B}]133;A\u{07}$ \u{1B}]133;C\u{07}")
            expectEqual(CommandStatus.from(e.shellIntegration), CommandStatus.running,
                        "a started command shows as running")

            e.feed("\u{1B}]133;D;0\u{07}")
            expectEqual(CommandStatus.from(e.shellIntegration), CommandStatus.none,
                        "success clears the dot rather than colouring it")

            e.feed("\u{1B}]133;A\u{07}$ \u{1B}]133;C\u{07}\u{1B}]133;D;1\u{07}")
            expectEqual(CommandStatus.from(e.shellIntegration), CommandStatus.failed,
                        "a non-zero exit shows as failed")
        }

        // The notifier needs a duration, so the marks have to carry timing.
        do {
            let e = Emulator(cols: 20, rows: 4)
            e.feed("\u{1B}]133;A\u{07}$ \u{1B}]133;C\u{07}")
            expect(e.shellIntegration.last?.startedAt != nil, "a running command records when it started")
            expect(e.shellIntegration.last?.duration == nil, "and has no duration until it ends")
            e.feed("\u{1B}]133;D;0\u{07}")
            expect(e.shellIntegration.last?.duration != nil, "a finished command has a duration")
        }
    }

    static func iconTests() {
        print("icons")

        let root = "\(projectRoot)"
        let plistPath = "\(root)/Resources/Info.plist"
        let iconDir = "\(root)/Resources/Icons"

        guard let data = FileManager.default.contents(atPath: plistPath),
              let plist = (try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil)) as? [String: Any],
              let icons = plist["CFBundleIcons"] as? [String: Any],
              let alternates = icons["CFBundleAlternateIcons"] as? [String: Any] else {
            expect(false, "Info.plist declares alternate icons")
            print("")
            return
        }

        for theme in Theme.builtIn {
            expect(alternates[theme.id] != nil,
                   "\(theme.name) has an alternate icon declared")

            guard let entry = alternates[theme.id] as? [String: Any],
                  let files = entry["CFBundleIconFiles"] as? [String],
                  let base = files.first else { continue }

            // iOS resolves the base name against @2x/@3x on disk; both have to
            // be there or the icon silently fails to apply.
            for suffix in ["@2x.png", "@3x.png"] {
                let path = "\(iconDir)/\(base)\(suffix)"
                expect(FileManager.default.fileExists(atPath: path),
                       "\(theme.name) icon \(base)\(suffix) exists")
            }
        }

        // The mark must stand off its own background in every theme.
        for theme in Theme.builtIn {
            let accent = IconRenderer.accentColor(for: theme)
            let ratio = accent.contrastRatio(with: theme.background)
            expect(ratio >= 2.0, "\(theme.name): icon mark is visible",
                   String(format: "%.2f:1", ratio))
        }

        print("")
    }

    // MARK: - Menus and splits

    /// Collects every action title reachable from a set of menu elements.
    static func actionTitles(_ elements: [UIMenuElement]) -> [String] {
        var titles: [String] = []
        for element in elements {
            if let action = element as? UIAction {
                titles.append(action.title)
            } else if let menu = element as? UIMenu {
                titles.append(contentsOf: actionTitles(menu.children))
            }
        }
        return titles
    }

    static func menuAndSplitTests() {
        print("menus and splits")

        let root = RootViewController()
        root.loadViewIfNeeded()
        root.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        root.view.layoutIfNeeded()

        let bar = TabBarView()
        bar.delegate = root

        // Everything the ⋯ button shows has to be an action or an inline
        // section. A plain UIMenu among them renders as a row you must expand
        // into, which is not what a nine-item menu should do.
        let elements = bar.resolvedMenuElements()
        expect(!elements.isEmpty, "the overflow menu has contents")
        var allInline = true
        for element in elements {
            if let submenu = element as? UIMenu, !submenu.options.contains(.displayInline) {
                allInline = false
            }
        }
        expect(allInline, "menu shows flat sections, not a submenu to expand into")

        // Pane management only makes sense once a tab is split, and it has to
        // appear then — it is the only way to close a pane by touch.
        let beforeSplit = actionTitles(bar.resolvedMenuElements())
        expect(beforeSplit.contains("Split Right"), "unsplit menu offers Split Right")
        expect(!beforeSplit.contains("Close Pane"), "unsplit menu hides Close Pane")

        guard let tab = root.activeTab else {
            expect(false, "root has an active tab")
            print("")
            return
        }
        expectEqual(tab.panes.count, 1, "a new tab starts with one pane")

        tab.split(pane: tab.activePane, vertical: true)
        expectEqual(tab.panes.count, 2, "splitting adds a pane")

        let afterSplit = actionTitles(bar.resolvedMenuElements())
        expect(afterSplit.contains("Close Pane"), "split menu offers Close Pane")
        expect(afterSplit.contains("Close Other Panes"), "split menu offers Close Other Panes")

        // Nested splits, then unwind them. This is the tree surgery that
        // promotes a sibling into its parent's place; getting it wrong strands
        // panes or drops the wrong one.
        let first = tab.panes[0]
        tab.split(pane: tab.activePane, vertical: false)
        expectEqual(tab.panes.count, 3, "a pane can be split again")

        tab.closeActivePane()
        expectEqual(tab.panes.count, 2, "closing a pane collapses the split")
        expect(tab.panes.contains(first), "closing a pane leaves its siblings alone")

        tab.setActive(first)
        tab.split(pane: first, vertical: true)
        expectEqual(tab.panes.count, 3, "split again for the collapse check")

        tab.setActive(first)
        tab.closeOtherPanes()
        expectEqual(tab.panes.count, 1, "Close Other Panes collapses to one")
        expect(tab.panes.first === first, "Close Other Panes keeps the active pane")

        // A shell exiting closes its pane when there is a sibling to fall back
        // to, and holds the terminal open when there is not.
        tab.split(pane: tab.activePane, vertical: true)
        expectEqual(tab.panes.count, 2, "split for the exit check")
        let doomed = tab.activePane
        tab.paneDidFinish(doomed, exitCode: 0)
        expectEqual(tab.panes.count, 1, "exiting closes a pane when it has siblings")

        let lastOne = tab.panes[0]
        tab.paneDidFinish(lastOne, exitCode: 0)
        expectEqual(tab.panes.count, 1, "exiting the last pane keeps it on screen")

        print("")
    }

    // MARK: - Key row

    static func keyRowTests() {
        print("key row")

        let row = KeyRowView()
        let actions = row.orderedActions

        // Anything the iOS keyboard can already produce does not belong here;
        // it only pushes the keys that have no other home off-screen.
        let literals: [String] = actions.compactMap {
            if case .text(let t) = $0 { return t }
            return nil
        }
        expect(literals.isEmpty, "no keyboard-reachable characters on the row",
               literals.isEmpty ? "" : "found \(literals)")

        let required: [(String, KeyRowAction)] = [
            ("esc", .special(.escape)), ("tab", .special(.tab)),
            ("ctrl", .modifier(.control)), ("alt", .modifier(.alt)),
            ("home", .special(.home)), ("end", .special(.end)),
            ("page up", .special(.pageUp)), ("page down", .special(.pageDown)),
            ("forward delete", .special(.delete)),
        ]
        for (name, action) in required {
            expect(actions.contains(action), "row has \(name)")
        }

        // The arrows have to be reachable without scrolling, which in practice
        // means near the front of the row.
        let arrows: [KeyRowAction] = [.special(.left), .special(.down),
                                      .special(.up), .special(.right)]
        let positions = arrows.compactMap { actions.firstIndex(of: $0) }
        expectEqual(positions.count, 4, "all four arrow keys are present")
        if let last = positions.max() {
            expect(last < 10, "arrows sit near the front of the row", "last at index \(last)")
        }
        if positions.count == 4 {
            expect(positions.max()! - positions.min()! == 3, "arrows are contiguous")
        }

        expect(actions.contains(.snippets), "snippets are reachable")

        // Settings lists these keys so you can switch them off, and a list in
        // a different order from the row it describes is one you have to read
        // twice to use. They drifted apart over shift and the arrows.
        let settingsOrder = KeyRowView.toggleableKeys.map(\.id)
        let rowOrder = KeyRowView().orderedItemIDs
        for id in settingsOrder {
            expect(rowOrder.contains(id), "Settings lists \(id), and the row has it")
        }
        expectEqual(rowOrder.filter { settingsOrder.contains($0) }, settingsOrder,
                    "Settings lists the keys in the order the row draws them")

        // Shift, and back-tab as one press rather than a latch-then-hunt.
        expect(actions.contains(.modifier(.shift)), "row has shift")
        expect(actions.contains(.combo(.shift, .special(.tab))), "row has ⇧tab")
        expectEqual(String(decoding: KeyEncoder.bytes(for: .tab, modifiers: .shift,
                                                     applicationCursorKeys: false,
                                                     applicationKeypad: false), as: UTF8.self),
                    "\u{1B}[Z", "⇧tab sends back-tab")

        // Turning a key off has to actually take it out of the row, and
        // turning it back on has to restore it — the preference stores the
        // exceptions, so a stale id must not strand a key.
        let hiddenBefore = Preferences.shared.hiddenKeyRowKeys
        Preferences.shared.hiddenKeyRowKeys = ["homeend", "snippets"]
        let trimmed = KeyRowView().orderedActions
        expect(!trimmed.contains(.special(.home)), "a key switched off leaves the row")
        expect(!trimmed.contains(.snippets), "and so does a cluster's worth")
        expect(trimmed.contains(.special(.escape)), "the rest of the row is untouched")

        // A custom combination becomes a button that sends the whole thing.
        let customBefore = Preferences.shared.customKeys
        Preferences.shared.hiddenKeyRowKeys = []
        Preferences.shared.customKeys = [
            CustomKey(title: "^C", modifiers: .control, special: nil, character: "c"),
        ]
        expect(KeyRowView().orderedActions.contains(.combo(.control, .character("c"))),
               "a custom combination reaches the row")

        Preferences.shared.customKeys = customBefore
        Preferences.shared.hiddenKeyRowKeys = hiddenBefore

        // Parsing is forgiving about how people write modifiers and strict
        // about the key, because a combination that sends nothing is a dead
        // button someone has to discover for themselves.
        let parsed = KeyRowSettingsViewController.makeKey(label: "^C", modifiers: "ctrl", key: "c")
        expectEqual(parsed?.modifiers, .control, "ctrl parses")
        expectEqual(parsed?.character, "c", "and keeps the character")
        expectEqual(KeyRowSettingsViewController.makeKey(label: "", modifiers: "Control + Alt",
                                                        key: "tab")?.modifiers,
                    [.control, .alt], "spelled-out and plus-separated modifiers parse")
        expectEqual(KeyRowSettingsViewController.makeKey(label: "", modifiers: "", key: "f5")?.special,
                    .f5, "named keys parse")
        expect(KeyRowSettingsViewController.makeKey(label: "", modifiers: "hyper", key: "c") == nil,
               "an unknown modifier is refused")
        expect(KeyRowSettingsViewController.makeKey(label: "", modifiers: "ctrl", key: "nope") == nil,
               "so is a key that is neither a character nor a named key")
        expect(KeyRowSettingsViewController.makeKey(label: "", modifiers: "ctrl", key: "") == nil,
               "and an empty key")

        // Round-trips through preferences, since it is stored as a dictionary.
        let key = CustomKey(title: "alt.", modifiers: .alt, special: nil, character: ".")
        expectEqual(CustomKey(dictionary: key.dictionary), key, "a custom key round-trips")

        renderKeyRow(row)

        // The point of the rework: everything up to the last arrow has to be
        // on screen at iPhone width, with no scrolling.
        if let rightArrow = row.frame(for: .special(.right)) {
            expect(rightArrow.maxX <= row.visibleScrollWidth,
                   "arrows fit on screen without scrolling",
                   String(format: "arrows end at %.0fpt, %.0fpt available",
                          rightArrow.maxX, row.visibleScrollWidth))
        } else {
            expect(false, "right arrow has a frame")
        }
        // Dismiss is pinned outside the scroll view, so it is deliberately
        // absent from the scrolling set.
        expect(!actions.contains(.dismissKeyboard), "dismiss is pinned, not scrolled")

        print("")
    }

    // MARK: - Key repeat

    static func keyRepeatTests() {
        print("key repeat")

        // One long wait before the first repeat, then a rate that accelerates
        // to a floor and stays there.
        expectEqual(KeyRepeater.interval(beforeRepeat: 1), KeyRepeater.initialDelay,
                    "the first repeat waits out the hold delay")
        expectEqual(KeyRepeater.interval(beforeRepeat: 2), KeyRepeater.slowInterval,
                    "the second starts at the slow rate")
        expect(KeyRepeater.interval(beforeRepeat: 6) < KeyRepeater.slowInterval,
               "and the rate accelerates while the key stays down")
        expectEqual(KeyRepeater.interval(beforeRepeat: 500), KeyRepeater.fastInterval,
                    "acceleration stops at the floor")

        // Holding a key means "keep going" only where going on makes sense.
        expect(SpecialKey.left.repeatsWhenHeld, "arrows repeat")
        expect(SpecialKey.backspace.repeatsWhenHeld, "backspace repeats")
        expect(SpecialKey.delete.repeatsWhenHeld, "forward delete repeats")
        expect(SpecialKey.pageUp.repeatsWhenHeld, "page up repeats")
        expect(!SpecialKey.enter.repeatsWhenHeld, "enter does not")
        expect(!SpecialKey.escape.repeatsWhenHeld, "nor escape")
        expect(!SpecialKey.tab.repeatsWhenHeld, "nor tab")
        expect(!SpecialKey.f(5).repeatsWhenHeld, "nor a function key")
        expect(KeyRowAction.special(.right).repeatsWhenHeld, "a row arrow repeats")
        expect(KeyRowAction.combo(.alt, .special(.left)).repeatsWhenHeld,
               "so does a custom combination that ends on one")
        expect(!KeyRowAction.modifier(.control).repeatsWhenHeld, "a modifier latch does not")
        expect(!KeyRowAction.snippets.repeatsWhenHeld, "nor does the snippets key")

        func settle(_ seconds: TimeInterval) {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        }

        let recorder = KeyRowRecorder()
        let row = KeyRowView()
        row.delegate = recorder
        let left = KeyRowAction.special(.left)

        // A tap is still one press, and still commits on release.
        row.simulate(.touchDown, on: left)
        row.simulate(.touchUpInside, on: left)
        expectEqual(recorder.actions.count, 1, "a tap sends one press")

        // The bug this exists to fix: a held arrow moved exactly one cell.
        recorder.actions.removeAll()
        row.simulate(.touchDown, on: left)
        settle(KeyRepeater.initialDelay + 0.5)
        let duringHold = recorder.actions.count
        row.simulate(.touchUpInside, on: left)
        expect(duringHold >= 3, "holding an arrow keeps moving the cursor",
               "\(duringHold) presses in \(KeyRepeater.initialDelay + 0.5)s")
        expectEqual(recorder.actions.count, duringHold,
                    "and the release that ends a hold adds nothing on top")
        expect(recorder.actions.allSatisfy { $0 == left },
               "every repeat is the key that was held")

        // Released before the delay, it is a tap however deliberate.
        recorder.actions.removeAll()
        row.simulate(.touchDown, on: left)
        settle(KeyRepeater.initialDelay - 0.15)
        row.simulate(.touchUpInside, on: left)
        settle(0.3)
        expectEqual(recorder.actions.count, 1, "a slow tap is still one press")

        // Dragging turns the touch into a scroll, which must send nothing.
        recorder.actions.removeAll()
        row.simulate(.touchDown, on: left)
        row.simulate(.touchCancel, on: left)
        settle(KeyRepeater.initialDelay + 0.2)
        expect(recorder.actions.isEmpty, "a touch the scroll view steals sends nothing")

        // And the scroll view has to be willing to steal it in the first
        // place. A scroll view leaves a touch that landed on a control alone
        // by default, which left the row scrolling only from the slivers of
        // gap between the keys.
        let stuck = row.orderedActions.filter { !row.scrollCancelsTouch(on: $0) }
        expect(stuck.isEmpty, "a drag that starts on a key scrolls the row",
               stuck.isEmpty ? "" : "\(stuck.count) keys swallow the drag")

        // Arming applies to the press that uses it, and a hold is one press.
        recorder.actions.removeAll()
        recorder.armed = .alt
        row.simulate(.touchDown, on: left)
        settle(KeyRepeater.initialDelay + 0.3)
        row.simulate(.touchUpInside, on: left)
        recorder.armed = []
        expect(recorder.actions.count >= 2 &&
               recorder.actions.allSatisfy { $0 == .combo(.alt, .special(.left)) },
               "a modifier armed at the press stays armed for the whole hold",
               "\(recorder.actions)")

        // A key that means exactly one thing stays one thing.
        recorder.actions.removeAll()
        row.simulate(.touchDown, on: .special(.escape))
        settle(KeyRepeater.initialDelay + 0.3)
        row.simulate(.touchUpInside, on: .special(.escape))
        expectEqual(recorder.actions.count, 1, "holding escape sends one escape")

        // The software keyboard's delete key repeats only for a responder that
        // claims to be a text input; UIKeyInput on its own gets one delete
        // however long the key is held. The conformance is the whole fix, so
        // losing it silently would put the bug straight back.
        let host = TerminalHostView()
        expect(host is UITextInput, "the host view is a text input, so delete repeats")
        expect(host.hasText, "and always has text, or the repeat stops after one")

        // Inert in every direction that would put UIKit's own caret, selection
        // or loupe on top of the terminal's.
        let start = host.beginningOfDocument
        expectEqual(host.caretRect(for: start), .zero, "it draws no caret of its own")
        expectEqual(host.selectionRects(for: TerminalTextRange(
            from: TerminalTextPosition(offset: 0))).count, 0, "and no selection rects")
        expect(host.text(in: TerminalTextRange(
            from: TerminalTextPosition(offset: 0))) == nil, "and holds no text")
        expectEqual(host.offset(from: start, to: host.endOfDocument), 0,
                    "the document it pretends to have is empty")
        expectEqual(host.compare(TerminalTextPosition(offset: 1),
                                 to: TerminalTextPosition(offset: 2)), .orderedAscending,
                    "positions compare in the order UIKit expects")
        expectEqual((host.position(from: start, offset: 3) as? TerminalTextPosition)?.offset, 3,
                    "and offset from one another consistently")

        print("")
    }

    // MARK: - Floating cursor

    static func floatingCursorTests() {
        print("floating cursor")

        // Sensitivity is counted in character cells, not points, so the
        // gesture means the same thing at every font size.
        expectEqual(TrackpadSensitivity.medium.cellsPerStep, 1.0,
                    "medium puts the caret under the fingertip")
        expect(TrackpadSensitivity.off.cellsPerStep == nil, "off does nothing")
        expect(TrackpadSensitivity.low.cellsPerStep! > TrackpadSensitivity.medium.cellsPerStep!,
               "low reaches further for the same drag")
        expect(TrackpadSensitivity.high.cellsPerStep! < TrackpadSensitivity.medium.cellsPerStep!,
               "high gives finer control")
        for level in TrackpadSensitivity.allCases {
            expect(level.detail?.isEmpty == false, "\(level.rawValue) explains itself")
        }

        // The arithmetic: a drag is spent in whole characters, and the change
        // left over stays on the clock. Rounding it away would lose a fraction
        // of a cell per touch update and leave the caret behind the finger.
        let step: CGFloat = 10
        expectEqual(TerminalHostView.floatingCursorSteps(travelled: 34, step: step).steps, 3,
                    "a drag right is spent in whole characters")
        expectEqual(TerminalHostView.floatingCursorSteps(travelled: 34, step: step).consumed, 30,
                    "and only the part it spent is consumed")
        expectEqual(TerminalHostView.floatingCursorSteps(travelled: -34, step: step).steps, -3,
                    "a drag left goes the other way")
        expectEqual(TerminalHostView.floatingCursorSteps(travelled: 9.9, step: step).steps, 0,
                    "a drag shorter than a character moves nothing")
        expectEqual(TerminalHostView.floatingCursorSteps(travelled: 0, step: step).steps, 0,
                    "and neither does no drag at all")
        expectEqual(TerminalHostView.floatingCursorSteps(travelled: 500, step: 0).steps, 0,
                    "a step of zero cannot divide by it")

        // Carrying the remainder is the whole point: twelve drags of 6pt each
        // must cover the same ground as one drag of 72pt.
        var anchor: CGFloat = 0
        var total = 0
        for i in 1...12 {
            let (steps, consumed) = TerminalHostView.floatingCursorSteps(
                travelled: CGFloat(i) * 6 - anchor, step: step)
            total += steps
            anchor += consumed
        }
        expectEqual(total, 7, "a slow drag keeps pace with a fast one")

        // iOS calls these through the Objective-C runtime as optional members
        // of UITextInput. If the bridging is ever lost the gesture silently
        // stops happening, with nothing to see in Swift.
        let host = TerminalHostView()
        for selector in [#selector(TerminalHostView.beginFloatingCursor(at:)),
                         #selector(TerminalHostView.updateFloatingCursor(at:)),
                         #selector(TerminalHostView.endFloatingCursor)] {
            expect(host.responds(to: selector),
                   "iOS can reach \(NSStringFromSelector(selector))")
        }

        // End to end against a real pane, which is where the step size comes
        // from and where a nil terminal view would crash.
        let root = RootViewController()
        root.loadViewIfNeeded()
        root.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        root.view.layoutIfNeeded()
        if let pane = root.activeTab?.activePane {
            let defaults = UserDefaults.standard
            let previous = defaults.object(forKey: "trackpadSensitivity")
            defaults.set(TrackpadSensitivity.medium.rawValue, forKey: "trackpadSensitivity")
            let cell = pane.terminalView?.cellSize.width ?? 0
            expect(cell > 0, "the pane knows its cell width", "\(cell)")
            expectEqual(pane.trackpadStep, max(3, cell), "one cell per character at medium")
            defaults.set(TrackpadSensitivity.off.rawValue, forKey: "trackpadSensitivity")
            expect(pane.trackpadStep == nil, "and nothing at all when switched off")
            defaults.set(previous, forKey: "trackpadSensitivity")
        } else {
            expect(false, "root has a pane to measure")
        }

        print("")
    }

    // MARK: - Cursor repaint

    static func cursorRepaintTests() {
        print("cursor repaint")

        let emulator = Emulator(cols: 40, rows: 8)
        let font = TerminalFont(familyName: "Menlo", pointSize: 13,
                                lineHeightScale: 1.0, scale: 3)
        let view = TerminalView(font: font, palette: TerminalPalette(theme: Theme.theme(withID: "diffterm-dark")))
        view.emulator = emulator
        view.frame = CGRect(x: 0, y: 0,
                            width: font.cellSize.width * 40,
                            height: font.cellSize.height * 8)
        view.layoutIfNeeded()

        emulator.feed(Array("hello".utf8))
        emulator.clearDirty()
        view.invalidateCursorIfMoved()
        expect(!view.invalidateCursorIfMoved(),
               "a cursor that has not moved asks for nothing")

        // The whole reason a held arrow used to look frozen: moving the cursor
        // changes no cell, so nothing marks a row dirty and nothing repaints.
        emulator.feed(Array("\u{1B}[D".utf8))
        expect(!emulator.allDirty && emulator.dirtyRows.isEmpty,
               "a bare cursor move dirties no row")
        expect(view.invalidateCursorIfMoved(),
               "so the caret asks for its own repaint instead")
        expect(!view.invalidateCursorIfMoved(),
               "and only once until it moves again")

        // Hiding the caret has to repaint it away, not leave it behind.
        emulator.feed(Array("\u{1B}[?25l".utf8))
        expect(view.invalidateCursorIfMoved(), "hiding the cursor repaints it too")

        print("")
    }

    /// Draws the row at iPhone width so it is obvious whether the keys that
    /// matter fit without scrolling.
    static func renderKeyRow(_ row: KeyRowView) {
        let width: CGFloat = 393        // iPhone 15 Pro, portrait
        row.frame = CGRect(x: 0, y: 0, width: width, height: 44)
        row.setNeedsLayout()
        row.layoutIfNeeded()

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 3
        let renderer = UIGraphicsImageRenderer(bounds: row.bounds, format: format)
        let image = renderer.image { context in
            // drawHierarchy needs a real window; layer rendering works
            // offscreen. The blur backing does not survive it, so paint a
            // stand-in ground first.
            UIColor.systemGray5.setFill()
            context.fill(row.bounds)
            row.layer.render(in: context.cgContext)
        }
        guard let data = image.pngData() else { return }
        let path = "\(projectRoot)/build/render-keyrow.png"
        try? data.write(to: URL(fileURLWithPath: path))
        print("  wrote render-keyrow.png (\(Int(width))pt wide)")
        print("  content width: \(Int(row.contentWidth))pt, visible: \(Int(row.visibleScrollWidth))pt")
    }

    // MARK: - Themes

    /// Every built-in theme has to be readable, not just pretty. The slots
    /// that are background-ish by convention are exempt: ANSI 0/8 on dark
    /// themes, 7/15 on light ones — programs use those as fills, not text.
    /// Output is the only thing that makes a session longer, and it does not
    /// invalidate layout. diffTerm 1.0 shipped with the scroll view's content
    /// height set only from layout passes, so at launch it equalled the
    /// viewport and stayed there: nothing printed could be scrolled back to.
    /// A TUI that never triggers a layout pass — Claude Code, say — made that
    /// look like scrolling was simply broken.
    static func scrollTests() {
        print("scrolling")

        SessionStore.clear()
        let root = RootViewController()
        root.loadViewIfNeeded()
        root.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        root.view.layoutIfNeeded()

        guard let pane = root.activeTab?.activePane else {
            expect(false, "root has a pane to scroll")
            print("")
            return
        }

        let viewport = pane.scrollViewHeight
        expect(viewport > 0, "the pane has a viewport", "\(viewport)pt")
        expect(abs(pane.scrollContentHeight - viewport) < 1,
               "a fresh session has nothing to scroll through",
               "content \(Int(pane.scrollContentHeight))pt, viewport \(Int(viewport))pt")

        // Deliberately no layout pass between here and the assertions: that is
        // the whole point. Only `syncAfterOutput` runs, exactly as it does when
        // the pty pump drains a batch.
        for i in 0..<500 {
            pane.session.emulator.feed("line \(i)\r\n")
        }
        pane.syncAfterOutput()

        expect(pane.scrollContentHeight > viewport,
               "output the user cannot see yet extends the scrollable content",
               "content \(Int(pane.scrollContentHeight))pt, viewport \(Int(viewport))pt")

        let scrollback = pane.session.emulator.buffer.scrollbackCount
        expect(scrollback > 0, "lines scrolled into the scrollback", "\(scrollback) lines")

        // Content height is the whole buffer: scrollback plus the live screen.
        let cellHeight = pane.terminalView.cellSize.height
        let expected = CGFloat(pane.session.emulator.buffer.totalRows) * cellHeight
        expect(abs(pane.scrollContentHeight - expected) < 1,
               "content height covers the whole buffer",
               "\(Int(pane.scrollContentHeight))pt vs \(Int(expected))pt")

        // Following output means sitting at the bottom, not merely being able
        // to reach it.
        expect(abs(pane.scrollOffsetY - (pane.scrollContentHeight - viewport)) < 1,
               "a pinned pane follows new output to the bottom",
               "offset \(Int(pane.scrollOffsetY))pt")

        // Fullscreen TUIs — Claude Code's fullscreen renderer among them —
        // take the alternate screen and turn on mouse tracking, then scroll
        // their own view when a wheel event arrives. diffTerm 1.0 could encode
        // wheel buttons but never sent one: the two-finger drag went out as a
        // left-button press/drag/release, which such a program reads as a
        // click and drag, so scrolling selected text instead of scrolling.
        let emulator = pane.session.emulator
        let onScreen = GridPosition(row: emulator.buffer.scrollbackCount + 5, col: 3)

        emulator.modes.mouseTracking = .anyEvent
        emulator.modes.mouseEncoding = .sgr
        let wheelUp = String(decoding: pane.scrollStepBytes(up: true, at: onScreen), as: UTF8.self)
        let wheelDown = String(decoding: pane.scrollStepBytes(up: false, at: onScreen), as: UTF8.self)
        expectEqual(wheelUp, "\u{1B}[<64;4;6M", "a tracking program gets wheel up, not a click")
        expectEqual(wheelDown, "\u{1B}[<65;4;6M", "a tracking program gets wheel down")

        // With no program watching, the alternate screen has no scrollback to
        // move, so the arrow keys are the honest translation.
        emulator.modes.mouseTracking = .none
        emulator.feed("\u{1B}[?1049h")
        let arrowUp = String(decoding: pane.scrollStepBytes(up: true, at: GridPosition(row: 5, col: 3)),
                             as: UTF8.self)
        expectEqual(arrowUp, "\u{1B}[A", "the bare alternate screen gets arrow keys")

        // The normal screen scrolls itself; nothing should go to the program.
        emulator.feed("\u{1B}[?1049l")
        expect(pane.scrollStepBytes(up: true, at: onScreen).isEmpty,
               "the normal screen sends the program nothing")

        print("")
    }

    /// Unicode splits emoji-capable characters into colour-by-default (✅) and
    /// text-by-default (⏺, the bullet Claude Code prints for every tool call).
    /// CoreText ignores that distinction when it hunts for a missing glyph and
    /// reaches Apple Color Emoji first, so diffTerm 1.0 drew ⏺ as a red record
    /// button 17pt wide inside a 7.8pt cell.
    static func glyphPresentationTests() {
        print("glyph presentation")

        // Width: a real emoji is square and takes two columns; a
        // text-presentation symbol is one, and stays one.
        expectEqual(CharWidth.width(of: "✅" as Character), 2, "an emoji-presentation character is two columns")
        expectEqual(CharWidth.width(of: "⭐" as Character), 2, "so is one outside the old hard-coded table")
        expectEqual(CharWidth.width(of: "⏺" as Character), 1, "a text-presentation symbol stays one column")
        expectEqual(CharWidth.width(of: "⚠" as Character), 1, "and so does the warning sign")
        expectEqual(CharWidth.width(of: "⚠\u{FE0F}" as Character), 2, "unless the program asks for emoji with VS16")
        expectEqual(CharWidth.width(of: "字" as Character), 2, "CJK is still two columns")
        expectEqual(CharWidth.width(of: "a" as Character), 1, "and ASCII is still one")

        // Presentation: the character the terminal font is missing must not
        // come back from Apple Color Emoji.
        let font = TerminalFont(familyName: "Menlo", pointSize: 13, lineHeightScale: 1, scale: 3)
        let cache = GlyphCache(font: font)
        let white = Theme.RGB(255, 255, 255)

        switch cache.entry(for: "⏺", style: .regular, color: white) {
        case .line(let line, let width):
            var family = "<none>"
            if let runs = CTLineGetGlyphRuns(line) as? [CTRun], let run = runs.first,
               let raw = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] {
                family = CTFontCopyFamilyName(raw as! CTFont) as String
            }
            expect(family != "Apple Color Emoji",
                   "a text-presentation symbol is not drawn as colour emoji", family)
            expect(width <= font.cellSize.width * 1.5,
                   "and it fits the cell it was given",
                   String(format: "%.1fpt glyph, %.1fpt cell", width, font.cellSize.width))
        case .glyph:
            expect(true, "the terminal font has ⏺ itself")
        case .blank:
            expect(false, "⏺ produced nothing")
        }

        // A character that really is emoji keeps its colour.
        switch cache.entry(for: "✅", style: .regular, color: white) {
        case .line(let line, _):
            var family = "<none>"
            if let runs = CTLineGetGlyphRuns(line) as? [CTRun], let run = runs.first,
               let raw = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] {
                family = CTFontCopyFamilyName(raw as! CTFont) as String
            }
            expect(family.contains("Emoji"), "a real emoji is still drawn as one", family)
        default:
            expect(false, "✅ should need fallback")
        }

        print("")
    }

    /// iOS ships no font with the private-use glyphs that starship,
    /// powerlevel10k, eza and lazygit draw with, so before this they all came
    /// out of `.LastResort` as tofu. JetBrains Mono Nerd Font Mono is bundled
    /// to fix that, which only works if every face Info.plist names is
    /// actually in the bundle.
    static func bundledFontTests() {
        print("bundled font")

        let root = "\(projectRoot)"
        let plist = (try? PropertyListSerialization.propertyList(
            from: Data(contentsOf: URL(fileURLWithPath: "\(root)/Resources/Info.plist")),
            options: [], format: nil)) as? [String: Any]
        let declared = plist?["UIAppFonts"] as? [String] ?? []
        expect(!declared.isEmpty, "Info.plist declares bundled fonts", "\(declared.count) faces")

        for name in declared {
            let path = "\(root)/Resources/Fonts/\(name)"
            expect(FileManager.default.fileExists(atPath: path),
                   "\(name) is shipped, not just declared")
            var err: Unmanaged<CFError>?
            _ = CTFontManagerRegisterFontsForURL(URL(fileURLWithPath: path) as CFURL, .process, &err)
        }

        // The licence travels with the font, or we cannot ship it at all.
        expect(FileManager.default.fileExists(atPath: "\(root)/Resources/Fonts/OFL.txt"),
               "the SIL Open Font License is included")

        // The name the app asks for has to be the name the font answers to.
        let wanted = Preferences.shared.fontName
        guard let face = UIFont(name: wanted, size: 13) else {
            expect(false, "the default font resolves", wanted)
            print("")
            return
        }
        expect(true, "the default font resolves", "\(wanted) -> \(face.fontName)")

        let ct = face as CTFont
        for (cp, what) in [(0xE0B0, "powerline separator"), (0xE0B2, "powerline separator (left)"),
                           (0xF09B, "git branch"), (0xE706, "language icon"),
                           (0x2500, "box drawing"), (0x256D, "rounded box corner")] {
            var glyph = CGGlyph(0)
            var unit = Array(String(Unicode.Scalar(UInt32(cp))!).utf16)[0]
            let has = CTFontGetGlyphsForCharacters(ct, &unit, &glyph, 1) && glyph != 0
            expect(has, String(format: "U+%04X %@ is in the bundled face", cp, what))
        }

        // A prompt's glyphs must occupy one cell, or the grid tears.
        let font = TerminalFont(familyName: wanted, pointSize: 13, lineHeightScale: 1, scale: 3)
        let cache = GlyphCache(font: font)
        if case .glyph = cache.entry(for: "\u{E0B0}", style: .regular, color: Theme.RGB(255, 255, 255)) {
            expect(true, "powerline glyphs take the fast path, no fallback")
        } else {
            expect(false, "powerline glyphs take the fast path, no fallback")
        }
        expectEqual(CharWidth.width(of: Character("\u{E0B0}")), 1,
                    "and are one column wide")

        print("")
    }

    /// The same UI has to hold up from a 4.7-inch iPhone SE to a 12.9-inch
    /// iPad, in both orientations, and in a Stage Manager window that can be
    /// very nearly any size. Nothing in the layout is idiom-aware, so the only
    /// honest way to know it holds is to build it at each size and measure.
    /// The tab strip is painted from the palette now, so it inherits the same
    /// obligation the themes have: the text on it has to be readable. It also
    /// has to be readable on the published palettes we reproduce faithfully
    /// and do not correct, which is why the floor here is the secondary-text
    /// floor rather than the 7:1 we hold our own foregrounds to.
    static func tabBarContrastTests() {
        print("tab bar")

        var worstSelected: (String, CGFloat) = ("", 21)
        var worstDimmed: (String, CGFloat) = ("", 21)

        for theme in Theme.builtIn {
            let raised = TabBarView.activeChipBackground(for: theme)
            let dimmed = TabBarView.inactiveChipText(for: theme)

            let selected = theme.foreground.contrastRatio(with: raised)
            let unselected = dimmed.contrastRatio(with: theme.background)

            if selected < worstSelected.1 { worstSelected = (theme.name, selected) }
            if unselected < worstDimmed.1 { worstDimmed = (theme.name, unselected) }

            // A chip cannot be more legible than the palette it is drawn
            // from, and Solarized Light gives its own foreground only 4.1:1.
            // So the rule is a share of what the palette actually has, capped
            // at the 4.5:1 that would be the goal if it had it to give.
            let available = theme.foreground.contrastRatio(with: theme.background)
            let floor = min(4.5, available * 0.9)
            expect(selected >= floor,
                   "\(theme.name): the active tab's title keeps the palette's legibility",
                   String(format: "%.1f:1, palette has %.1f:1", selected, available))
            expect(unselected >= 2.5,
                   "\(theme.name): an inactive tab's title is legible",
                   String(format: "%.1f:1", unselected))

            // What actually says which tab you are on.
            let indicator = TabBarView.activeChipIndicator(for: theme)
                .contrastRatio(with: theme.background)
            expect(indicator >= 2.5,
                   "\(theme.name): the active tab's marker is visible",
                   String(format: "%.1f:1", indicator))
        }

        print(String(format: "  worst active %@ %.1f:1, worst inactive %@ %.1f:1",
                     worstSelected.0, worstSelected.1, worstDimmed.0, worstDimmed.1))

        // The whole point of painting it from the palette: a dark theme on a
        // phone set to light mode used to put system-black text on it.
        let dark = Theme.theme(withID: "diffterm-dark")
        let bar = TabBarView()
        bar.apply(theme: dark)
        expectEqual(bar.backgroundColor, dark.background.uiColor,
                    "the strip takes the theme's background, not a system material")

        print("")
    }

    static func displayTests() {
        print("displays")

        func pad(_ s: String, _ n: Int) -> String {
            s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
        }

        let devices: [(String, CGSize)] = [
            ("iPhone SE",         CGSize(width: 375, height: 667)),
            ("iPhone 13 mini",    CGSize(width: 375, height: 812)),
            ("iPhone 15 Pro",     CGSize(width: 393, height: 852)),
            ("iPhone 15 Pro Max", CGSize(width: 430, height: 932)),
            ("iPad mini",         CGSize(width: 744, height: 1133)),
            ("iPad 10.9",         CGSize(width: 820, height: 1180)),
            ("iPad Pro 12.9",     CGSize(width: 1024, height: 1366)),
            ("Stage Manager",     CGSize(width: 375, height: 500)),
        ]

        for (name, portrait) in devices {
            let sizes = [("portrait", portrait),
                         ("landscape", CGSize(width: portrait.height, height: portrait.width))]
            for (orientation, size) in sizes {
                let root = RootViewController()
                root.loadViewIfNeeded()
                root.view.frame = CGRect(origin: .zero, size: size)
                root.view.layoutIfNeeded()

                guard let pane = root.activeTab?.activePane, let grid = pane.terminalView else {
                    expect(false, "\(name) \(orientation): builds a pane")
                    continue
                }
                let cols = grid.visibleCols, rows = grid.visibleRows
                print("  " + pad(name, 18) + pad(orientation, 10)
                      + pad("\(Int(size.width))x\(Int(size.height))pt", 12)
                      + pad("\(cols) x \(rows) cells", 16))

                // 80 columns is the old contract, and nothing here is anywhere
                // near a terminal if it cannot manage 20 by 8.
                expect(cols >= 20 && rows >= 8,
                       "\(name) \(orientation) has a usable grid", "\(cols)x\(rows)")
                expect(pane.scrollViewHeight > 0,
                       "\(name) \(orientation) gives the grid a viewport")
            }
        }

        // The iPad default has to land somewhere a person can actually read.
        // The harness runs on a phone, so the idiom is passed in rather than
        // read off the device.
        let phonePt = DeviceMetrics.defaultFontSize(for: .phone)
        let padPt = DeviceMetrics.defaultFontSize(for: .pad)
        expect(padPt > phonePt, "the iPad default font is larger than the phone's",
               "\(phonePt)pt vs \(padPt)pt")
        expect(DeviceMetrics.keyRowHeight(for: .pad) > DeviceMetrics.keyRowHeight(for: .phone),
               "and the key row is taller to match iPad's keyboard")

        let padFont = TerminalFont(familyName: Preferences.shared.fontName,
                                   pointSize: CGFloat(padPt), lineHeightScale: 1, scale: 2)
        let padCols = Int(1366 / padFont.cellSize.width)
        print("  iPad Pro 12.9 landscape at the iPad default: \(padCols) columns")
        expect(padCols >= 80 && padCols <= 150,
               "the iPad default gives a column count a person can read", "\(padCols)")

        // The status bar and home indicator strips sit outside the safe area,
        // so nothing is laid out in them — but they are still the app, and
        // black there letterboxed the terminal inside its own window.
        let themed = RootViewController()
        themed.loadViewIfNeeded()
        themed.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        themed.view.layoutIfNeeded()
        let theme = Preferences.shared.theme(for: themed.traitCollection.userInterfaceStyle)
        let background = themed.view.backgroundColor ?? .clear
        expectEqual(background, theme.background.uiColor,
                    "the safe-area strips carry the theme background, not black")
        if let tab = themed.activeTab {
            expectEqual(tab.view.backgroundColor ?? .clear, theme.background.uiColor,
                        "and so does what shows between split panes")
        }

        // Splitting is where a small screen actually runs out of room.
        let root = RootViewController()
        root.loadViewIfNeeded()
        root.view.frame = CGRect(x: 0, y: 0, width: 667, height: 375)   // SE, landscape
        root.view.layoutIfNeeded()
        if let tab = root.activeTab {
            tab.split(pane: tab.activePane, vertical: true)
            tab.split(pane: tab.activePane, vertical: false)
            root.view.layoutIfNeeded()
            expectEqual(tab.panes.count, 3, "three panes fit on the smallest screen")
            var worstCols = Int.max, worstRows = Int.max
            for p in tab.panes {
                p.view.layoutIfNeeded()
                worstCols = min(worstCols, p.terminalView.visibleCols)
                worstRows = min(worstRows, p.terminalView.visibleRows)
            }
            print("  smallest pane after two splits: \(worstCols) x \(worstRows) cells")
            expect(worstCols >= 8 && worstRows >= 2,
                   "every pane is still a terminal after two splits",
                   "\(worstCols)x\(worstRows)")
        } else {
            expect(false, "root has a tab to split")
        }

        print("")
    }

    /// SF Symbol names are strings, so the compiler cannot tell us that one
    /// of them needs a newer iOS than we target — a missing symbol is simply a
    /// nil image and a button with nothing in it. The names are scraped from
    /// the source rather than listed here, so this cannot fall out of date;
    /// run the harness on the oldest system you support and it names anything
    /// that will come up blank there.
    static func systemImageTests() {
        print("system images")

        let sources = "\(projectRoot)/Sources"
        var names: Set<String> = []
        let marker = "systemName: \""

        if let walker = FileManager.default.enumerator(atPath: sources) {
            for case let relative as String in walker where relative.hasSuffix(".swift") {
                guard let text = try? String(contentsOfFile: "\(sources)/\(relative)",
                                             encoding: .utf8) else { continue }
                var rest = Substring(text)
                while let start = rest.range(of: marker) {
                    let after = rest[start.upperBound...]
                    guard let end = after.firstIndex(of: "\"") else { break }
                    names.insert(String(after[..<end]))
                    rest = after[after.index(after: end)...]
                }
            }
        }

        expect(!names.isEmpty, "found the system image names in the source", "\(names.count)")

        let missing = names.sorted().filter { UIImage(systemName: $0) == nil }
        expect(missing.isEmpty,
               "every system image resolves on iOS \(UIDevice.current.systemVersion)",
               missing.joined(separator: ", "))

        print("  \(names.count) symbols checked")
        print("")
    }

    // MARK: - Suggestions

    /// The prediction cascade and its thresholds.
    ///
    /// The numbers here are the interesting part: two samples and a quarter
    /// share with an empty prompt, one sample and a tenth once something has
    /// been typed. They are asymmetric on purpose — ghost text on an empty
    /// prompt has nothing on screen justifying it, so it has to be right more
    /// often than one that is merely completing what you are already typing.
    static func suggestionTests() {
        print("suggestions")

        func store(_ pairs: [(String, Int?, String)], session: String = "s1",
                   pwd: String = "/work") -> CommandHistoryStore {
            let store = CommandHistoryStore(inMemory: true)
            for (command, exit, dir) in pairs {
                let id = store.begin(command: command, pwd: dir, shell: "zsh",
                                     hostname: "test", session: session)
                store.finish(id: id, exitCode: exit)
            }
            return store
        }

        // Three past runs of `cargo build` that failed; two were followed by
        // the same command. 2/3 = 0.67, clears 0.25 with 3 >= 2 samples.
        let dominant = store([
            ("cargo build", 101, "/work"), ("cargo build 2>&1 | head -40", 0, "/work"),
            ("cargo build", 101, "/work"), ("cargo build 2>&1 | head -40", 0, "/work"),
            ("cargo build", 101, "/work"), ("ls", 0, "/work"),
            ("cargo build", 101, "/work"),
        ])
        var predictor = NextCommandPredictor(store: dominant, validator: AlwaysValid())
        var context = NextCommandPredictor.Context(
            lastCommand: "cargo build", lastExitCode: 101, pwd: "/work",
            shell: "zsh", hostname: "test", prefix: "")
        expectEqual(predictor.predict(context)?.command, "cargo build 2>&1 | head -40",
                    "the dominant follow-up wins at zero state")

        // The same history, but asked about a *successful* build. Exit code is
        // part of the key, so none of those episodes apply.
        context.lastExitCode = 0
        expectEqual(predictor.predict(context)?.command, nil,
                    "a different exit code is a different question")

        // One sample is below the zero-state floor of two.
        let thin = store([("make", 0, "/work"), ("make install", 0, "/work"), ("make", 0, "/work")])
        predictor = NextCommandPredictor(store: thin, validator: AlwaysValid())
        context = NextCommandPredictor.Context(
            lastCommand: "make", lastExitCode: 0, pwd: "/work",
            shell: "zsh", hostname: "test", prefix: "")
        expectEqual(predictor.predict(context)?.command, nil,
                    "one sample is not enough with an empty prompt")

        // The same single sample is enough once the user has started typing.
        context.prefix = "make i"
        expectEqual(predictor.predict(context)?.command, "make install",
                    "one sample is enough with a prefix")

        // A different directory is a different question too. Asked at zero
        // state, where only the episode path can answer, the same history in
        // another directory says nothing. (The *prefix* fallback further down
        // the cascade is directory-agnostic on purpose — typing `make i` and
        // being offered the `make install` you run in another checkout is
        // useful, not a leak.)
        predictor = NextCommandPredictor(store: dominant, validator: AlwaysValid())
        expectEqual(predictor.predict(NextCommandPredictor.Context(
            lastCommand: "cargo build", lastExitCode: 101, pwd: "/elsewhere",
            shell: "zsh", hostname: "test", prefix: ""))?.command, nil,
                    "episodes do not cross directories")

        // Falling through to plain history: no episode, but the prefix has
        // been typed here before.
        let typed = store([("git status", 0, "/work"), ("git push origin main", 0, "/work")])
        predictor = NextCommandPredictor(store: typed, validator: AlwaysValid())
        context = NextCommandPredictor.Context(
            lastCommand: nil, lastExitCode: nil, pwd: "/work",
            shell: "zsh", hostname: "test", prefix: "git p")
        expectEqual(predictor.predict(context)?.command, "git push origin main",
                    "a typed prefix falls through to history")

        // Same-directory matches outrank older ones from anywhere else.
        let mixed = CommandHistoryStore(inMemory: true)
        for (command, dir) in [("make release", "/other"), ("make debug", "/work")] {
            let id = mixed.begin(command: command, pwd: dir, shell: "zsh",
                                 hostname: "test", session: "s1")
            mixed.finish(id: id, exitCode: 0)
        }
        expectEqual(mixed.recent(matching: "make", pwd: "/work").first, "make debug",
                    "this directory's history comes first")

        // Marks must leave nothing visible on screen. A stray "A" at the top
        // of a fresh terminal is what a half-consumed OSC 133;A looks like.
        do {
            let e = Emulator(cols: 40, rows: 6)
            e.feed("\u{1B}]133;A\u{07}$ \u{1B}]133;B\u{07}")
            let row0 = e.buffer.row(at: e.buffer.scrollbackCount)
            let text = row0.text(to: row0.trimmedLength)
            expectEqual(text, "$", "OSC 133 marks leave no visible text")

            // Split across feeds, the way a pty delivers them.
            let f = Emulator(cols: 40, rows: 6)
            for chunk in ["\u{1B}", "]133", ";A", "\u{07}", "$ "] { f.feed(chunk) }
            let frow = f.buffer.row(at: f.buffer.scrollbackCount)
            expectEqual(frow.text(to: frow.trimmedLength), "$",
                        "and still nothing when split across reads")

            // ST-terminated rather than BEL.
            let g = Emulator(cols: 40, rows: 6)
            g.feed("\u{1B}]133;A\u{1B}\\$ ")
            let grow = g.buffer.row(at: g.buffer.scrollbackCount)
            expectEqual(grow.text(to: grow.trimmedLength), "$",
                        "and nothing with an ST terminator")
        }

        // The seam between the shell script and the app: feed exactly the
        // bytes Resources/Shell/diffterm.zsh emits, and check that what comes
        // out the other end is a block with the right outcome and an input
        // line that can be read back off the grid.
        do {
            let e = Emulator(cols: 40, rows: 8)
            func prompt() { e.feed("\u{1B}]133;A\u{07}$ \u{1B}]133;B\u{07}") }

            prompt()
            e.feed("cargo build\r\n\u{1B}]133;C\u{07}error\r\n\u{1B}]133;D;101\u{07}")
            prompt()

            expectEqual(e.shellIntegration.blocks.count, 2, "a finished command and a fresh prompt")
            let finished = e.shellIntegration.blocks[0]
            expect(finished.outcome == .failed, "a non-zero exit is a failed block")
            expectEqual(finished.exitCode, 101, "the exit status survives the round trip")

            // Nothing typed yet: an empty line, not nil — the shell *is* at a
            // prompt, there is simply nothing on it.
            expectEqual(e.currentInputLine, "", "a fresh prompt reads as an empty input line")

            e.feed("cargo b")
            expectEqual(e.currentInputLine, "cargo b", "typing is read back off the grid")

            // While a command runs there is no input line to complete.
            e.feed("\r\n\u{1B}]133;C\u{07}")
            expect(e.currentInputLine == nil, "no input line while a command runs")
            expect(!e.isAtPrompt, "and the shell is not at a prompt")

            // The alternate screen has no prompt at all.
            e.feed("\u{1B}]133;D;0\u{07}")
            prompt()
            e.feed("vim")
            e.feed("\u{1B}[?1049h")
            expect(e.currentInputLine == nil, "no input line on the alternate screen")
            e.feed("\u{1B}[?1049l")
            expectEqual(e.currentInputLine, "vim", "and it comes back when the program exits")
        }

        // Ghost text state machine.
        var ghost = Autosuggestion(full: "git push origin main", buffer: "git p",
                                   source: .history)
        expectEqual(ghost?.suffix, "ush origin main", "only the unwritten part is drawn")
        expect(ghost?.update(buffer: "git pu") == true, "typing along keeps it")
        expectEqual(ghost?.suffix, "sh origin main", "typing along shrinks it")
        _ = ghost?.update(buffer: "git pl")
        expectEqual(ghost?.suffix, "", "diverging hides it")
        expect(ghost?.update(buffer: "git p") == true, "backing up brings it back")
        expectEqual(ghost?.suffix, "ush origin main", "and it is the same suggestion")
        expect(ghost?.update(buffer: "git push origin main") == false,
               "typing it out in full retires it")

        ghost = Autosuggestion(full: "ls", buffer: "ls", source: .history)
        expect(ghost == nil, "a suggestion equal to the line is no suggestion")

        // The validator's most important property: it must not over-reach.
        let validator = CommandValidator()
        expect(validator.isValid("git status", cwd: "/"), "a real command validates")
        expect(validator.isValid("frobnicate --wat | tee /tmp/x", cwd: "/"),
               "shell syntax is past what it can judge, so it passes")
        expect(!validator.isValid("cat /nonexistent/path/xyzzy", cwd: "/"),
               "an argument that is plainly a missing path fails")
        expect(validator.isValid("git checkout some-branch", cwd: "/"),
               "a bare word is a branch, not a missing file")

        print("")
    }

    /// End to end, through a real pane: the preferences, the marks, the rails
    /// and the ghost text.
    ///
    /// Written after shipping a version where both features were invisible on
    /// a device that had them switched on. Every piece had a passing unit test
    /// and the whole was still dead, because `rebuildAppearance` applied the
    /// view's preferences before the view existed. Nothing below would have
    /// caught that except assembling the real thing.
    static func blockPaneTests() {
        print("blocks end to end")

        let defaults = UserDefaults.standard
        let previousBlocks = defaults.object(forKey: "blockMode")
        let previousSuggest = defaults.object(forKey: "commandSuggestions")
        defaults.set(true, forKey: "blockMode")
        defaults.set(true, forKey: "commandSuggestions")
        defer {
            defaults.set(previousBlocks, forKey: "blockMode")
            defaults.set(previousSuggest, forKey: "commandSuggestions")
        }

        SessionStore.clear()
        let root = RootViewController()
        root.loadViewIfNeeded()
        root.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        root.view.layoutIfNeeded()

        guard let pane = root.activeTab?.activePane, let view = pane.terminalView else {
            expect(false, "root has a pane")
            print("")
            return
        }

        // The bug itself: on with the preference on, at launch, with nobody
        // having touched a setting.
        expect(view.blockMode, "a pane built with blocks on has them on")
        expect(view.gutterWidth > 0, "and reserves the gutter for the rail")

        let cols = view.visibleCols
        expect(cols > 0, "the grid still measures", "\(cols) cols")

        // Feed exactly what the bundled zsh script emits.
        let e = pane.session.emulator
        e.feed("\u{1B}]133;A\u{07}$ \u{1B}]133;B\u{07}")
        e.feed("false\r\n\u{1B}]133;C\u{07}\u{1B}]133;D;1\u{07}")
        e.feed("\u{1B}]133;A\u{07}$ \u{1B}]133;B\u{07}")

        expectEqual(e.shellIntegration.blocks.count, 2, "two blocks recorded")

        // The renderer's own query, over the rows actually on screen — this is
        // what decides whether a rail is drawn at all.
        let evicted = e.oldestStableRow
        let lastRow = max(0, e.buffer.totalRows - 1)
        let visible = e.shellIntegration.blocks(
            overlapping: (evicted)...(lastRow + evicted),
            liveEnd: e.stableCursorRow)
        expect(!visible.isEmpty, "the renderer finds blocks for the visible rows",
               "\(visible.count) of \(e.shellIntegration.blocks.count)")
        expect(visible.contains { $0.outcome == .failed }, "the failed command is one of them")

        // Ghost text, with one command of history behind it.
        let store = CommandHistoryStore(inMemory: true)
        let id = store.begin(command: "cargo build", pwd: "/work", shell: "zsh",
                             hostname: "test", session: "s1")
        store.finish(id: id, exitCode: 0)
        let predictor = NextCommandPredictor(store: store, validator: AlwaysValid())
        let hit = predictor.predict(NextCommandPredictor.Context(
            lastCommand: nil, lastExitCode: nil, pwd: "/work",
            shell: "zsh", hostname: "test", prefix: "car"))
        expectEqual(hit?.command, "cargo build",
                    "a single past command is enough to complete a prefix")

        // And that it reaches the view as drawable text.
        view.ghostText = "go build"
        view.setNeedsDisplay()
        view.layoutIfNeeded()
        UIGraphicsBeginImageContextWithOptions(view.bounds.size, true, 1)
        view.layer.render(in: UIGraphicsGetCurrentContext()!)
        UIGraphicsEndImageContext()
        expect(!view.ghostRects.isEmpty, "ghost text lays out into rects a tap can hit",
               "\(view.ghostRects.count) rects")
        // A picture with several blocks, one collapsed, so the Warp card look
        // is answerable by looking.
        let e2 = pane.session.emulator
        func cmd(_ line: String, _ out: [String], exit: Int) {
            e2.feed("\u{1B}]133;A\u{07}$ \u{1B}]133;B\u{07}\(line)\r\n\u{1B}]133;C\u{07}")
            for o in out { e2.feed(o + "\r\n") }
            e2.feed("\u{1B}]133;D;\(exit)\u{07}")
        }
        cmd("git status", ["On branch main", "nothing to commit"], exit: 0)
        cmd("make build", ["cc main.c", "cc util.c", "linking", "error: undefined ref", "make: *** [build] Error 1"], exit: 2)
        cmd("ls", ["Makefile  README.md  Sources"], exit: 0)
        e2.feed("\u{1B}]133;A\u{07}$ \u{1B}]133;B\u{07}")
        // Collapse the middle (failed) block.
        if pane.session.emulator.shellIntegration.blocks.count >= 2 {
            let mid = pane.session.emulator.shellIntegration.blocks[1]
            pane.terminalView.collapsedBlocks = [mid.promptStart]
        }
        pane.recomputeTerminalSizeFromView()
        view.setNeedsDisplay()
        view.layoutIfNeeded()
        UIGraphicsBeginImageContextWithOptions(view.bounds.size, true, 2)
        view.layer.render(in: UIGraphicsGetCurrentContext()!)
        if let png = UIGraphicsGetImageFromCurrentImageContext()?.pngData() {
            try? png.write(to: URL(fileURLWithPath: "\(projectRoot)/build/render-cards.png"))
            print("  wrote render-cards.png")
        }
        UIGraphicsEndImageContext()

        view.ghostText = " --release"
        e.feed("cargo build")
        view.setNeedsDisplay()
        UIGraphicsBeginImageContextWithOptions(view.bounds.size, true, 2)
        view.layer.render(in: UIGraphicsGetCurrentContext()!)
        let image = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        if let png = image?.pngData() {
            let out = "\(projectRoot)/build/render-blocks.png"
            try? png.write(to: URL(fileURLWithPath: out))
            print("  wrote render-blocks.png")
        }

        // The same view on the theme that was worst for ghost contrast.
        view.update(palette: TerminalPalette(theme: Theme.theme(withID: "solarized-light")))
        view.ghostText = " --release"
        view.setNeedsDisplay()
        UIGraphicsBeginImageContextWithOptions(view.bounds.size, true, 2)
        view.layer.render(in: UIGraphicsGetCurrentContext()!)
        let light = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        if let png = light?.pngData() {
            try? png.write(to: URL(fileURLWithPath:
                "\(projectRoot)/build/render-blocks-light.png"))
            print("  wrote render-blocks-light.png")
        }
        view.ghostText = ""

        print("")
    }

    /// Starts a real shell through the app's own session class and dumps what
    /// lands on the grid.
    ///
    /// A stray capital "A" was turning up at the top of every new terminal and
    /// then being restored from the snapshot forever after. The shell's bytes
    /// were clean when captured over a bare pty, and the emulator was clean
    /// when fed those bytes by hand, so the fault had to be in how the two are
    /// wired together — which is exactly what this exercises.
    /// The ghost-text path exactly as the app runs it: marks in, typed
    /// prefix on the grid, `refreshSuggestion()`, text on the view.
    ///
    /// Every piece of this had a unit test and the feature still looked dead
    /// on a real phone, so this drives the seam rather than the parts.
    static func ghostTextPathTests() {
        print("ghost text path")

        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "commandSuggestions")
        defaults.set(true, forKey: "commandSuggestions")
        defer { defaults.set(previous, forKey: "commandSuggestions") }

        let session = TerminalSession(cols: 60, rows: 12)
        let pane = TerminalPaneController(session: session)
        pane.loadViewIfNeeded()
        pane.view.frame = CGRect(x: 0, y: 0, width: 400, height: 600)
        pane.view.layoutIfNeeded()
        guard let view = pane.terminalView else {
            expect(false, "pane has a view"); print(""); return
        }

        let e = session.emulator
        func prompt() { e.feed("\u{1B}]133;A\u{07}$ \u{1B}]133;B\u{07}") }

        // Run a command so there is something to learn from.
        prompt()
        e.feed("git status\r\n\u{1B}]133;C\u{07}clean\r\n\u{1B}]133;D;0\u{07}")
        pane.refreshSuggestion()

        // Back at a prompt, type a prefix of it.
        prompt()
        expectEqual(e.currentInputLine, "", "the fresh prompt reads as empty")
        e.feed("git s")
        expectEqual(e.currentInputLine, "git s", "the typed prefix is readable")

        pane.refreshSuggestion()
        expectEqual(view.ghostText, "tatus",
                    "refreshSuggestion puts the remainder on the view")
        expect(pane.hasSuggestion, "and the pane reports a live suggestion")

        // Accepting writes the remainder to the pty and clears the ghost.
        expect(pane.acceptSuggestion(), "the suggestion can be accepted")
        expectEqual(view.ghostText, "", "accepting clears the ghost")

        print("")
    }

    /// Ghost text has to clear a contrast floor on every theme.
    ///
    /// It shipped as a fixed 55% blend toward the background, which reads
    /// fine on diffTerm Dark (3.5:1) and is *invisible* on Solarized Light
    /// (1.74:1) — the bug being that themes start from very different
    /// foreground contrasts, so a fixed fraction cannot work. The colour is
    /// now solved per theme, and this is the gate that keeps it solved.
    static func ghostContrastTests() {
        print("ghost text contrast")

        var worst = (id: "", ratio: CGFloat.greatestFiniteMagnitude)
        for theme in Theme.builtIn {
            let palette = TerminalPalette(theme: theme)
            let ghost = palette.secondaryForeground()
            let ratio = ghost.contrastRatio(with: palette.defaultBackground)
            if ratio < worst.ratio { worst = (theme.id, ratio) }

            // 3.0 is the WCAG large-text floor. Ghost text is secondary by
            // design, so it is not held to the 4.5 body-text bar the themes
            // themselves are — but it must be readable.
            expect(ratio >= 3.0,
                   "\(theme.name): ghost text is legible",
                   String(format: "%.2f:1", ratio))

            // And it must actually be dimmer than normal text, or it stops
            // reading as a suggestion and starts reading as something typed.
            let normal = palette.defaultForeground.contrastRatio(with: palette.defaultBackground)
            expect(ratio <= normal,
                   "\(theme.name): ghost text is dimmer than real text",
                   String(format: "%.2f vs %.2f", ratio, normal))
        }
        print(String(format: "  · weakest: %@ at %.2f:1", worst.id, worst.ratio))

        print("")
    }

    /// The completion sources that keep ghost text alive without history,
    /// and the cascade order that keeps history ahead of them.
    static func completerTests() {
        print("completers")

        // A real directory with known contents, so the file completer is
        // tested against the filesystem it will actually run on.
        let root = NSTemporaryDirectory() + "diffterm-completer-\(getpid())"
        let fm = FileManager.default
        try? fm.removeItem(atPath: root)
        try? fm.createDirectory(atPath: root + "/Sources/Core", withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: root + "/build", withIntermediateDirectories: true)
        for name in ["Makefile", "README.md", "Make it so.txt", ".zshrc", "main.swift"] {
            fm.createFile(atPath: root + "/" + name, contents: Data())
        }
        defer { try? fm.removeItem(atPath: root) }

        let files = FileCompleter()
        expectEqual(files.complete(word: "Make", cwd: root, directoriesOnly: false), "Makefile",
                    "a file completes from its prefix, shortest first")
        expectEqual(files.complete(word: "So", cwd: root, directoriesOnly: false), "Sources/",
                    "a directory completes with a trailing slash")
        expectEqual(files.complete(word: "Sources/Co", cwd: root, directoriesOnly: false), "Sources/Core/",
                    "a path with directory components completes its last part")
        expectEqual(files.complete(word: "\(root)/bu", cwd: "/", directoriesOnly: false), "\(root)/build/",
                    "an absolute path resolves without cwd")
        expect(files.complete(word: "z", cwd: root, directoriesOnly: false) == nil,
               "dotfiles are hidden unless asked for")
        expectEqual(files.complete(word: ".z", cwd: root, directoriesOnly: false), ".zshrc",
                    "and offered once the prefix starts with a dot")
        expectEqual(files.complete(word: "m", cwd: root, directoriesOnly: true), nil,
                    "directories-only skips a file")
        expectEqual(files.complete(word: "b", cwd: root, directoriesOnly: true), "build/",
                    "and finds a directory")
        expectEqual(files.complete(word: "R", cwd: root, directoriesOnly: false), "README.md",
                    "matching is by prefix, not by fuzzy search")

        // Names with shell-special characters come back escaped, or
        // accepting the suggestion runs something other than what it shows.
        fm.createFile(atPath: root + "/odd name.txt", contents: Data())
        expectEqual(files.complete(word: "odd", cwd: root, directoriesOnly: false), "odd\\ name.txt",
                    "a space in a completed name is escaped")

        // Commands on PATH.
        let commands = PathCompleter.shared
        commands.invalidate()
        expectEqual(commands.complete(prefix: "zs"), "zsh", "a binary on PATH completes")
        expectEqual(commands.complete(prefix: "expor"), "export", "a shell builtin completes")
        expect(commands.complete(prefix: "zzqxv") == nil, "an unknown prefix offers nothing")

        // The façade: which source applies where in the line.
        let completer = CommandCompleter()
        expectEqual(completer.complete(line: "zs", cwd: root), "zsh",
                    "the first word is a command")
        expectEqual(completer.complete(line: "cat Make", cwd: root), "cat Makefile",
                    "later words are files")
        expectEqual(completer.complete(line: "cat Makefile | zs", cwd: root), "cat Makefile | zsh",
                    "a pipe starts a new command")
        expectEqual(completer.complete(line: "cd Ma", cwd: root), nil,
                    "cd is offered no files")
        expectEqual(completer.complete(line: "cd So", cwd: root), "cd Sources/",
                    "only directories")
        expectEqual(completer.complete(line: "ls -l", cwd: root), nil, "flags are never files")
        expectEqual(completer.complete(line: "ls ", cwd: root), nil, "nothing after a trailing space")
        expectEqual(completer.complete(line: "cat \"Ma", cwd: root), nil, "quoting is left alone")

        // Cascade order: history first, then what exists.
        let store = CommandHistoryStore(inMemory: true)
        let id = store.begin(command: "make install", pwd: root, shell: "zsh",
                             hostname: "test", session: "s1")
        store.finish(id: id, exitCode: 0)
        var predictor = NextCommandPredictor(store: store, validator: AlwaysValid(), completer: completer)
        var context = NextCommandPredictor.Context(
            lastCommand: nil, lastExitCode: nil, pwd: root, shell: "zsh", hostname: "test", prefix: "ma")
        expectEqual(predictor.predict(context)?.command, "make install",
                    "a command from history beats a file that merely exists")
        expect(predictor.predict(context)?.source == .history, "and says so")

        context.prefix = "cat Make"
        let hit = predictor.predict(context)
        expectEqual(hit?.command, "cat Makefile", "with no history, a completion is offered")
        expect(hit?.source == .completion, "and says so")

        predictor = NextCommandPredictor(store: CommandHistoryStore(inMemory: true),
                                         validator: AlwaysValid(), completer: completer)
        context.prefix = "zs"
        expectEqual(predictor.predict(context)?.command, "zsh",
                    "a completion is offered with an empty history — the cold-start case")

        // Accept-through-word.
        let engine = SuggestionEngine(sessionKey: "t")
        func seed(_ full: String, buffer: String) -> SuggestionEngine {
            let e = SuggestionEngine(sessionKey: "t")
            e.seed(Autosuggestion(full: full, buffer: buffer, source: .history)!)
            return e
        }
        let defaults = UserDefaults.standard
        let prev = defaults.object(forKey: "commandSuggestions")
        defaults.set(true, forKey: "commandSuggestions")
        defer { defaults.set(prev, forKey: "commandSuggestions") }

        var e = seed("git push origin main", buffer: "git ")
        expectEqual(e.visibleSuffix, "push origin main", "seeded suffix")
        expectEqual(e.accept(throughCharacter: 0), "push", "tapping the first word takes it")
        expectEqual(e.visibleSuffix, " origin main", "and the rest is still offered")
        expectEqual(e.accept(throughCharacter: 2), " origin", "a tap inside the next word takes through it")
        expectEqual(e.accept(throughCharacter: 3), " main", "the last word takes the remainder")
        expectEqual(e.visibleSuffix, "", "nothing left")

        e = seed("git push origin main", buffer: "git ")
        expectEqual(e.accept(throughCharacter: 99), "push origin main",
                    "past the end takes everything")
        expectEqual(e.acceptWord(), nil, "and nothing remains")
        _ = engine

        print("")
    }

    /// The spec-driven completer against the specs that actually ship.
    static func specCompleterTests() {
        print("spec completion")

        let repo = "\(projectRoot)/Resources/Specs/packed"
        let root = NSTemporaryDirectory() + "diffterm-spec-\(getpid())"
        let fm = FileManager.default
        try? fm.removeItem(atPath: root)
        try? fm.createDirectory(atPath: root + "/Sources", withIntermediateDirectories: true)
        for name in ["Makefile", "chores.txt", "zzz.txt"] {
            fm.createFile(atPath: root + "/" + name, contents: Data())
        }
        defer { try? fm.removeItem(atPath: root) }

        let store = SpecStore(directory: repo)
        expect(store.spec(for: "git") != nil, "the git spec loads from the checked-in JSON")
        expect(store.spec(for: "npm") != nil, "npm — one of the five the first converter missed — loads")
        expect(store.spec(for: "frobnicate") == nil, "an unknown command has no spec")
        expect(store.spec(for: "../git") == nil, "a path is not a command name")

        var completer = SpecCompleter()
        completer.store = store
        typealias O = SpecCompleter.Outcome

        // Subcommands, ranked by what people run rather than the alphabet.
        expectEqual(completer.complete(line: "git ch", cwd: root), O.completed("git checkout"),
                    "git ch → checkout")
        expectEqual(completer.complete(line: "git co", cwd: root), O.completed("git commit"),
                    "git co → commit, not column or config")
        expectEqual(completer.complete(line: "git st", cwd: root), O.completed("git status"),
                    "git st → status, not stash or stage")
        expectEqual(completer.complete(line: "git remote ad", cwd: root), O.completed("git remote add"),
                    "nested subcommands descend")
        expectEqual(completer.complete(line: "npm i", cwd: root), O.completed("npm install"),
                    "npm i → install, not init")
        expectEqual(completer.complete(line: "sudo git ch", cwd: root), O.completed("sudo git checkout"),
                    "wrappers are peeled")

        // Options, at the root and inside a subcommand.
        expectEqual(completer.complete(line: "git --no-pa", cwd: root), O.completed("git --no-pager"),
                    "a root option completes")
        expectEqual(completer.complete(line: "git commit --amen", cwd: root), O.completed("git commit --amend"),
                    "a subcommand option completes")
        expectEqual(completer.complete(line: "git -", cwd: root), O.nothing,
                    "a lone dash is every option at once, so none")

        // Arguments: templates, and the path hint for generator-only ones.
        expectEqual(completer.complete(line: "git add Make", cwd: root), O.completed("git add Makefile"),
                    "git add's pathspec completes files")
        expectEqual(completer.complete(line: "git checkout Sou", cwd: root), O.completed("git checkout Sources/"),
                    "an argument that may be a file gets one")
        expectEqual(completer.complete(line: "docker run x", cwd: root), O.nothing,
                    "an image name is not guessed from the filesystem")

        // The spec's answer is final: no file fallback where it expects a subcommand.
        expectEqual(completer.complete(line: "npm zz", cwd: root), O.nothing,
                    "no subcommand matches, and zzz.txt is not offered instead")
        expectEqual(completer.complete(line: "frobnicate --x", cwd: root), O.noSpec,
                    "no spec means the caller falls back")

        // Packed specs decode to the same thing as the JSON.
        let packed = SpecStore(directory: repo + "/packed")
        expectEqual(packed.spec(for: "git")?.subcommands.count, store.spec(for: "git")?.subcommands.count,
                    "the packed git spec unpacks to the same subcommands")
        expectEqual(packed.spec(for: "git")?.options.count, store.spec(for: "git")?.options.count,
                    "and the same options")
        let bad = SpecStore.unpack(Data([1, 0, 0, 0, 0xFF, 0xFF]))
        expect(bad == nil, "a corrupt packed file is rejected, not trusted")

        // Through the façade the app actually calls.
        var façade = CommandCompleter()
        façade.specs.store = store
        expectEqual(façade.complete(line: "git ch", cwd: root), "git checkout",
                    "the spec outranks chores.txt in the working directory")
        expectEqual(façade.complete(line: "npm zz", cwd: root), nil,
                    "and its 'nothing' is honoured over zzz.txt")
        expectEqual(façade.complete(line: "frobnicate Make", cwd: root), "frobnicate Makefile",
                    "a command with no spec still gets file completion")
        expectEqual(façade.complete(line: "git commit --amen", cwd: root), "git commit --amend",
                    "flags complete through the façade now that specs exist")

        print("")
    }

    /// Suggestions are validated against the shell's real directory.
    ///
    /// The bug: history crosses directories on purpose, so a `cd proj/foo`
    /// run last week somewhere else was being offered in a fresh shell where
    /// no such folder exists. The validator only knew about arguments that
    /// *looked* like paths, and resolved even those against the app's own
    /// cwd rather than the shell's.
    static func pathValidationTests() {
        print("path validation")

        let root = NSTemporaryDirectory() + "diffterm-validate-\(getpid())"
        let fm = FileManager.default
        try? fm.removeItem(atPath: root)
        try? fm.createDirectory(atPath: root + "/Sources", withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: root + "/elsewhere/Scripts", withIntermediateDirectories: true)
        fm.createFile(atPath: root + "/Makefile", contents: Data())
        defer { try? fm.removeItem(atPath: root) }

        var validator = CommandValidator()
        validator.specs.store = SpecStore(directory: "\(projectRoot)/Resources/Specs/packed")

        // The bug itself.
        expect(validator.isValid("cd Sources", cwd: root), "cd into a folder that is here")
        expect(!validator.isValid("cd Scripts", cwd: root),
               "cd into a folder that is only in some other directory is rejected")
        expect(validator.isValid("cd Scripts", cwd: root + "/elsewhere"),
               "and accepted where it does exist")
        expect(!validator.isValid("cd Makefile", cwd: root), "cd into a file is rejected")
        expect(validator.isValid("cd", cwd: root), "bare cd is fine")
        expect(validator.isValid("cd -", cwd: root), "cd - is fine")
        expect(validator.isValid("cd ~", cwd: root), "cd ~ resolves the home directory")

        // Files, by table and by spec.
        expect(validator.isValid("cat Makefile", cwd: root), "cat a file that is here")
        expect(!validator.isValid("cat README.md", cwd: root), "cat a file that is not")
        expect(validator.isValid("ls -la Sources", cwd: root), "flags are skipped, the path is checked")

        // What must *not* be rejected.
        expect(validator.isValid("mkdir newthing", cwd: root), "mkdir creates its argument")
        expect(validator.isValid("git checkout main", cwd: root), "a branch is not a file")
        expect(validator.isValid("git add nope.txt", cwd: root),
               "an argument only a generator could check passes — no over-reach")
        expect(validator.isValid("cd Sources && make", cwd: root),
               "shell syntax is left alone, as before")

        // The whole cascade, from a history that would have produced the bug.
        let store = CommandHistoryStore(inMemory: true)
        let id = store.begin(command: "cd Scripts", pwd: root + "/elsewhere", shell: "zsh",
                             hostname: "test", session: "s1")
        store.finish(id: id, exitCode: 0)
        var completer = CommandCompleter()
        completer.specs.store = validator.specs.store
        let predictor = NextCommandPredictor(store: store, validator: validator, completer: completer)
        let context = NextCommandPredictor.Context(
            lastCommand: nil, lastExitCode: nil, pwd: root, shell: "zsh", hostname: "test", prefix: "cd S")
        expectEqual(predictor.predict(context)?.command, "cd Sources/",
                    "in a fresh directory, cd completes from what is actually here")

        print("")
    }

    /// The completion server: a real zsh, the real rc files, real compsys.
    static func shellCompletionTests() {
        print("shell completion")

        let repo = "\(projectRoot)"
        let server = ShellCompletionServer()
        server.scriptPathOverride = repo + "/Resources/Shell/diffterm.complete.zsh"
        // _git on this device can take several seconds; the default 400 ms
        // watchdog would abandon it. The test is proving the mechanism finds
        // branches, not that this machine's git is fast, so give it room.
        server.watchdogCentiseconds = 2000
        guard server.isAvailable else {
            expect(false, "zsh and the server script are present"); print(""); return
        }
        defer { server.stop() }

        // A git repository with a branch in it: the thing no static spec can
        // know and the reason the server exists.
        let root = NSTemporaryDirectory() + "diffterm-shell-\(getpid())"
        let fm = FileManager.default
        try? fm.removeItem(atPath: root)
        try? fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        fm.createFile(atPath: root + "/Makefile",
                      contents: Data("icons:\n\ttrue\nrelease:\n\ttrue\n".utf8))
        defer { try? fm.removeItem(atPath: root) }
        // No `Process` on iOS; one posix_spawn of a shell does the setup.
        func shell(_ script: String) -> Int32 {
            var pid: pid_t = 0
            let argv = ["/var/jb/usr/bin/zsh", "-c", script]
            var cargv: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
            defer { cargv.forEach { free($0) } }
            guard posix_spawn(&pid, argv[0], nil, nil, &cargv, environ) == 0 else { return -1 }
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            return (status >> 8) & 0xFF
        }
        let g = "git -c user.name=t -c user.email=t@t -c init.defaultBranch=main"
        let haveBranch = shell("cd '\(root)' && \(g) init -q && \(g) commit -q --allow-empty -m x "
                               + "&& \(g) branch feature-x") == 0

        func ask(_ line: String, cwd: String, wait: TimeInterval = 4) -> String? {
            var answer: String?? = nil
            server.request(line: line, cwd: cwd) { answer = .some($0) }
            let deadline = Date().addingTimeInterval(wait)
            while answer == nil, Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
            return answer ?? nil
        }

        // The first answer pays for startup: rc files, compinit.
        let started = Date()
        expectEqual(ask("cd /var/j", cwd: "/", wait: 20), "cd /var/jb/",
                    "the shell completes a directory, with the slash compsys adds")
        print(String(format: "  · server up in %.1fs", Date().timeIntervalSince(started)))

        // The loop must survive a request. This is the bug that shipped:
        // send-break aborted the loop and every later request went nowhere.
        expectEqual(ask("cat Make", cwd: root), "cat Makefile", "a second request is answered")
        expectEqual(ask("frobnicatezz", cwd: root), nil, "no match is no answer, not the line echoed")
        expectEqual(ask("cat Make", cwd: root), "cat Makefile", "and the loop is still alive after it")
        expectEqual(ask("cat Make", cwd: root + "/.git"), nil, "the cwd it is told about is the one used")

        // The proof that this reaches knowledge no static spec has, on
        // something fast enough to assert: make targets, read out of the
        // Makefile in this directory.
        expectEqual(ask("make ic", cwd: root, wait: 6), "make icons",
                    "it reads targets out of this Makefile — no spec can")
        expectEqual(ask("make rel", cwd: root, wait: 6), "make release",
                    "and the other one")

        // Git branch completion is the same mechanism, but `_git` on this
        // device runs for several seconds and erratically, so it is observed
        // rather than asserted: it must never return garbage, and when it is
        // quick enough it is the branch. This is the honest limit — the
        // server delivers fast completions live and lets slow ones go.
        if haveBranch {
            let branch = ask("git checkout feat", cwd: root, wait: 12)
            expect(branch == nil || branch == "git checkout feature-x",
                   "git branch completion is the branch or nothing, never wrong",
                   branch ?? "(too slow, abandoned)")
        }

        // Coalescing: only the newest of a burst is answered.
        var first: String?? = nil, second: String?? = nil
        server.request(line: "cat Ma", cwd: root) { first = .some($0) }
        server.request(line: "cat Mak", cwd: root) { second = .some($0) }
        let deadline = Date().addingTimeInterval(4)
        while second == nil, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        expectEqual(second ?? nil, "cat Makefile", "the newest request is answered")
        expect(first != nil, "and the overtaken one was told so rather than left hanging")

        print("")
    }

    /// A stray mark letter at the top of a restored session, reported as
    /// "A A A F C A". Snapshots capture grid cells and restore feeds them back
    /// as scrollback, so a letter written wrongly once is re-captured every
    /// relaunch and accumulates. This feeds the exact bytes a login zsh with
    /// our integration emits and checks nothing bare survives — then round
    /// trips a restore to prove it does not accumulate.
    static func restoreMarkTests() {
        print("restore marks")

        // As captured from a real login shell: partial-line %, OSC 133 A,
        // OSC 7, the prompt, OSC 133 B, bracketed-paste on. Fed in one go and
        // split across chunk boundaries, since the pty delivers it in pieces.
        let prompt = "\u{1B}[1m\u{1B}[7m%\u{1B}[27m\u{1B}[0m   \r \r" +
                     "\u{1B}]133;A\u{07}\u{1B}]7;file://host/var/mobile\u{07}" +
                     "\u{1B}[0m\u{1B}[Jhost:~ mobile% \u{1B}]133;B\u{07}\u{1B}[K\u{1B}[?2004h"

        func gridText(_ e: Emulator) -> [String] {
            var out: [String] = []
            for r in 0..<e.normal.totalRows {
                let line = e.normal.row(at: r)
                let t = line.text(to: line.trimmedLength)
                if !t.isEmpty { out.append(t) }
            }
            return out
        }

        let e = Emulator(cols: 40, rows: 8)
        e.feed(prompt)
        e.feed("ls\r\n\u{1B}]133;C\u{07}file1  file2\r\n\u{1B}]133;D;0\u{07}")
        e.feed(prompt)   // second prompt

        let rows = gridText(e)
        for (i, r) in rows.enumerated() { print("    grid \(i): \(r.debugDescription)") }
        let strays = rows.filter { "ABCDEF".contains($0) && $0.count == 1 }
        expect(strays.isEmpty, "no bare mark letter is left on the grid",
               strays.joined(separator: " "))

        // Split every sequence one byte in, to catch a chunk-boundary bug.
        let f = Emulator(cols: 40, rows: 8)
        let bytes = Array(prompt.utf8)
        for b in bytes { f.feed([b]) }
        let split = gridText(f).filter { $0.count == 1 && "ABCDEF".contains($0) }
        expect(split.isEmpty, "and none when fed one byte at a time", split.joined(separator: " "))

        print("")
    }

    /// Reproduces the "A A A F C A" bug with a real shell in a real pane,
    /// then snapshots it exactly as backgrounding does and dumps what would
    /// be restored. If a stray letter is on the grid, it is in the snapshot.
    static func liveSnapshotProbe() {
        print("relaunch cycle")

        let prefs = Preferences.shared
        let pv = (prefs.blockMode, prefs.commandSuggestions, prefs.restoreSessions)
        prefs.blockMode = true; prefs.commandSuggestions = true; prefs.restoreSessions = true
        defer { (prefs.blockMode, prefs.commandSuggestions, prefs.restoreSessions) = pv }

        SessionStore.clear()

        func settle(_ s: TimeInterval) {
            let end = Date().addingTimeInterval(s)
            while Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        }

        func topStrays(_ snap: SessionSnapshot) -> [String] {
            snap.lines.compactMap { line in
                let t = line.runs.map(\.text).joined().trimmingCharacters(in: .whitespaces)
                return (t.count == 1 && "ABCDEF".contains(t)) ? t : nil
            }
        }

        // Three launch cycles: each restores the prior snapshot, runs a
        // command, saves. If a stray letter is generated per launch, it
        // accumulates across cycles — exactly the reported "A A A F C A".
        var lastStray = 0
        for cycle in 1...3 {
            let root = RootViewController()
            root.loadViewIfNeeded()
            root.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
            root.view.layoutIfNeeded()
            guard let pane = root.activeTab?.activePane else { expect(false, "pane"); print(""); return }
            pane.viewDidAppear(false)
            settle(3.5)
            pane.session.send(text: "echo cycle\(cycle)\n")
            settle(2.5)
            root.saveSessionState()

            let snap = pane.session.snapshot()
            let strays = topStrays(snap)
            print("    cycle \(cycle): \(snap.lines.count) lines, strays=[\(strays.joined(separator: " "))] cwd=\((snap.workingDirectory as NSString).lastPathComponent)")
            if cycle == 3 {
                let sample = snap.lines.prefix(3).map { $0.runs.map(\.text).joined() }
                for (i, t) in sample.enumerated() { print("      L\(i): \(t.debugDescription)") }
                // Faithful restore keeps whole lines, not truncated fragments.
                expect(sample.contains { $0.count > 5 },
                       "restored lines keep their full content, not one letter each")
            }
            lastStray = strays.count
        }
        expect(lastStray == 0, "no stray mark letters accumulate across relaunches", "\(lastStray)")
        SessionStore.clear()
        print("")
    }

    /// Typing out a suggestion character by character must *consume* the
    /// ghost, not sit a full copy of it after the freshly typed text. Drives
    /// the real refresh pipeline: seed a suggestion, then echo the command one
    /// character at a time the way the shell would, and check the drawn ghost
    /// shrinks by exactly one each time and never repeats what was typed.
    static func ghostFillTests() {
        print("ghost fill-in")

        let prefs = Preferences.shared
        let prev = prefs.commandSuggestions
        prefs.commandSuggestions = true
        defer { prefs.commandSuggestions = prev }

        let session = TerminalSession(cols: 60, rows: 10)
        let pane = TerminalPaneController(session: session)
        pane.loadViewIfNeeded()
        pane.view.frame = CGRect(x: 0, y: 0, width: 480, height: 640)
        pane.view.layoutIfNeeded()
        guard let view = pane.terminalView else { expect(false, "view"); print(""); return }

        let e = session.emulator
        // A prompt with a command already run, so history has "git status".
        e.feed("\u{1B}]133;A\u{07}$ \u{1B}]133;B\u{07}git status\r\n\u{1B}]133;C\u{07}ok\r\n\u{1B}]133;D;0\u{07}")
        pane.refreshSuggestion()
        // Fresh prompt.
        e.feed("\u{1B}]133;A\u{07}$ \u{1B}]133;B\u{07}")
        pane.refreshSuggestion()
        // Type "gi" so history offers "git status".
        e.feed("gi")
        pane.refreshSuggestion()
        expectEqual(view.ghostText, "t status", "the ghost is the unwritten remainder")

        // Now type the rest one character at a time, echoing as the shell
        // does, and watch it fill in.
        let remainder = Array("t status")
        var typed = "gi"
        var ok = true
        var trace: [String] = []
        for ch in remainder {
            e.feed(String(ch))                 // shell echoes the character
            typed.append(ch)
            pane.refreshSuggestion()
            let want = String("git status".dropFirst(typed.count))
            trace.append("\(view.ghostText.debugDescription)")
            if view.ghostText != want { ok = false }
            // The cardinal sin: the ghost still showing text the user has
            // already typed — that is the "append" the report describes.
            if view.ghostText.hasPrefix(String(ch)) && want.hasPrefix(String(ch)) == false { ok = false }
        }
        expect(ok, "typing consumes the ghost one character at a time", trace.joined(separator: " "))
        expectEqual(view.ghostText, "", "and nothing is left once fully typed")

        print("")
    }

    /// The tab title strips a leading status glyph so a program's animated
    /// spinner or star does not render as a colour emoji in the chip.
    static func tabTitleTests() {
        print("tab titles")
        func c(_ s: String) -> String { s.strippingLeadingStatusGlyphs }
        expectEqual(c("\u{2733}\u{FE0F} Building"), "Building", "a star prefix is stripped")
        expectEqual(c("\u{25D1} iOS terminal block layout"), "iOS terminal block layout", "a spinner prefix is stripped")
        expectEqual(c("\u{23FA} recording"), "recording", "a record dot is stripped")
        expectEqual(c("~/proj"), "~/proj", "an ordinary path is untouched")
        expectEqual(c("-zsh"), "-zsh", "a login shell name is untouched")
        expectEqual(c("vim file.c"), "vim file.c", "a normal title is untouched")
        expectEqual(c("\u{2733}\u{2733}"), "", "a title of only glyphs strips to empty")
        expectEqual(c("npm run build"), "npm run build", "no false positives mid-title")
        expectEqual(c("git: ✳ status"), "git: ✳ status", "a glyph that is not leading stays")
        print("")
    }

    /// Branch completion straight from the repo on disk — instant, and the
    /// answer the slow shell oracle could not give in time.
    static func gitRefTests() {
        print("git refs")

        let root = NSTemporaryDirectory() + "diffterm-gitref-\(getpid())"
        let fm = FileManager.default
        try? fm.removeItem(atPath: root)
        try? fm.createDirectory(atPath: root + "/sub", withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: root) }

        func sh(_ script: String) -> Int32 {
            var pid: pid_t = 0
            let argv = ["/var/jb/usr/bin/zsh", "-c", script]
            var cargv: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
            defer { cargv.forEach { free($0) } }
            guard posix_spawn(&pid, argv[0], nil, nil, &cargv, environ) == 0 else { return -1 }
            var st: Int32 = 0; waitpid(pid, &st, 0); return (st >> 8) & 0xFF
        }
        let g = "git -c user.name=t -c user.email=t@t -c init.defaultBranch=main"
        let ok = sh("cd '\(root)' && \(g) init -q && \(g) commit -q --allow-empty -m x "
                    + "&& \(g) branch feature-login && \(g) branch feature-logout && \(g) branch release/1.2") == 0
        expect(ok, "a repo with branches was created")

        let c = GitRefCompleter()
        let dir = root + "/.git"
        let names = Set(c.branches(in: dir))
        expect(names.isSuperset(of: ["main", "feature-login", "feature-logout", "release/1.2"]),
               "reads loose refs including nested names", names.sorted().joined(separator: ","))

        // Complete through the façade the predictor uses.
        var completer = CommandCompleter()
        completer.specs.store = SpecStore(directory: "\(projectRoot)/Resources/Specs/packed")

        expectEqual(completer.complete(line: "git checkout main", cwd: root), nil,
                    "an exact branch name offers nothing more")
        expectEqual(completer.complete(line: "git checkout rel", cwd: root), "git checkout release/1.2",
                    "checkout completes a branch")
        expectEqual(completer.complete(line: "git switch feature-logi", cwd: root), "git switch feature-login",
                    "switch too, disambiguating a shared prefix")
        expectEqual(completer.complete(line: "git merge rel", cwd: root), "git merge release/1.2",
                    "merge takes a branch")
        expectEqual(completer.complete(line: "git checkout -b rel", cwd: root), nil,
                    "creating a branch (-b) is not completed against existing ones")
        expectEqual(completer.complete(line: "git branch -d feature-logi", cwd: root), "git branch -d feature-login",
                    "branch -d completes an existing branch")
        // From a subdirectory, the repo is still found by walking up.
        expectEqual(completer.complete(line: "git checkout rel", cwd: root + "/sub"), "git checkout release/1.2",
                    "the repo is found from a subdirectory")
        // Ambiguous prefix picks the shortest, deterministically.
        expectEqual(completer.complete(line: "git checkout feature-log", cwd: root), "git checkout feature-login",
                    "a shared prefix resolves to the shortest match")

        // Instant — the whole point versus the shell oracle.
        let start = Date()
        for _ in 0..<200 { _ = completer.complete(line: "git checkout fea", cwd: root) }
        let ms = Date().timeIntervalSince(start) * 1000 / 200
        expect(ms < 5, "branch completion is effectively instant", String(format: "%.2f ms/call", ms))

        print("")
    }

    /// DEC 2031: a program can ask which colour scheme is active and be told
    /// live when the user switches between a light and a dark theme. Claude
    /// Code sets `?2031h` at startup for exactly this.
    static func colorSchemeTests() {
        print("colour scheme (DEC 2031)")

        let e = Emulator(cols: 20, rows: 4)
        let rec = ReplyRecorder()
        e.delegate = rec
        e.appearanceIsDark = true

        // Query before enabling: still answered, reporting the current scheme.
        e.feed("\u{1B}[?996n")
        expectEqual(rec.text, "\u{1B}[?997;1n", "the 996 query reports dark")
        rec.text = ""

        // A scheme change with 2031 off sends nothing.
        e.colorSchemeChanged(isDark: false)
        expectEqual(rec.text, "", "no unsolicited report while 2031 is off")

        // Enable 2031, then flip to dark: an unsolicited report arrives.
        e.feed("\u{1B}[?2031h")
        e.colorSchemeChanged(isDark: true)
        expectEqual(rec.text, "\u{1B}[?997;1n", "switching to dark reports 1")
        rec.text = ""
        e.colorSchemeChanged(isDark: false)
        expectEqual(rec.text, "\u{1B}[?997;2n", "switching to light reports 2")
        rec.text = ""

        // No report when the polarity does not actually change.
        e.colorSchemeChanged(isDark: false)
        expectEqual(rec.text, "", "no report when the scheme is unchanged")

        // Query now reflects the light scheme.
        e.feed("\u{1B}[?996n")
        expectEqual(rec.text, "\u{1B}[?997;2n", "the query now reports light")
        rec.text = ""

        // Disabling stops the unsolicited reports; the query still works.
        e.feed("\u{1B}[?2031l")
        e.colorSchemeChanged(isDark: true)
        expectEqual(rec.text, "", "disabling 2031 stops unsolicited reports")

        print("")
    }

    /// The piecewise row-to-y map that makes padded, collapsible blocks
    /// possible. Everything visual rests on this being exact, so it is tested
    /// as a pure value before any of it is drawn.
    static func blockLayoutTests() {
        print("block layout")

        let h: CGFloat = 10

        // Identity: with no blocks it is exactly row * cellHeight.
        let flat = BlockLayout(rows: 100, cellHeight: h)
        expectEqual(flat.y(forRow: 0), 0, "identity row 0")
        expectEqual(flat.y(forRow: 42), 420, "identity row 42")
        expectEqual(flat.row(atY: 425), 42, "identity hit test")
        expectEqual(flat.totalHeight, 1000, "identity height")
        expect(!flat.isHidden(row: 10), "identity hides nothing")

        // Two blocks with an 8pt gap above each after the first. Block A rows
        // 0..3, block B prompt at row 3.
        let gap: CGFloat = 8
        let spans = [
            BlockLayout.Span(promptRow: 0, outputRow: 1, endRow: 3, collapsed: false),
            BlockLayout.Span(promptRow: 3, outputRow: 4, endRow: 6, collapsed: false),
        ]
        let padded = BlockLayout(rows: 10, cellHeight: h, gap: gap, summaryHeight: h, spans: spans)
        // Block A (no gap, it is first): rows 0,1,2 at 0,10,20.
        expectEqual(padded.y(forRow: 0), 0, "first block starts at 0")
        expectEqual(padded.y(forRow: 2), 20, "within first block")
        // Block B: a gap is inserted above row 3, so row 3 sits at 30 + 8.
        expectEqual(padded.y(forRow: 3), 38, "gap pushes the second block down")
        expectEqual(padded.y(forRow: 5), 58, "and everything after it")
        // Trailing rows after the last block keep the accumulated offset.
        expectEqual(padded.y(forRow: 6), 68, "trailing rows carry the gap")
        expectEqual(padded.totalHeight, CGFloat(10) * h + gap, "height includes one gap")
        // Hit testing inverts it, including inside the gap (maps to the row
        // whose top follows the gap).
        expectEqual(padded.row(atY: 38), 3, "hit test after the gap")
        expectEqual(padded.row(atY: 20), 2, "hit test before the gap")

        // Collapse: block B (rows 3..6, output at 4) collapsed. Its prompt+
        // command row (3) stays; output rows 4,5 become one summary strip.
        let collapsedSpans = [
            BlockLayout.Span(promptRow: 0, outputRow: 1, endRow: 3, collapsed: false),
            BlockLayout.Span(promptRow: 3, outputRow: 4, endRow: 6, collapsed: true),
        ]
        let collapsed = BlockLayout(rows: 10, cellHeight: h, gap: gap, summaryHeight: 6, spans: collapsedSpans)
        expectEqual(collapsed.y(forRow: 3), 38, "collapsed block's command row still shows")
        expect(collapsed.isHidden(row: 4), "output row 4 is hidden")
        expect(collapsed.isHidden(row: 5), "output row 5 is hidden")
        expect(!collapsed.isHidden(row: 3), "the command row is not hidden")
        // Output collapses to a 6pt strip at y=48 (row 3 top 38 + 10).
        if let sum = collapsed.summary(forRow: 4) {
            expectEqual(sum.top, 48, "summary strip sits under the command")
            expectEqual(sum.hiddenRows, 2, "and stands in for two rows")
        } else { expect(false, "row 4 has a summary strip") }
        // Row 6 (trailing) now sits at 38 + 10 + 6 = 54, not 68 — collapse
        // reclaimed 20 - 6 = 14 points.
        expectEqual(collapsed.y(forRow: 6), 54, "collapse reclaims the output height")
        // A tap in the strip resolves to the hidden block, not to nothing.
        expectEqual(collapsed.row(atY: 50), 4, "a tap in the strip maps into the block")
        // The map stays monotonic across every row.
        var last = -CGFloat.infinity
        for r in 0...10 { let y = collapsed.y(forRow: r); expect(y >= last, "monotonic at \(r)", "\(y)"); last = y }

        print("")
    }

    /// Ghost text must continue onto a second row when it runs past the
    /// right edge — reported as it "cutting off in the 2nd line".
    static func ghostWrapTests() {
        print("ghost wrap")

        let prefs = Preferences.shared
        let prev = prefs.commandSuggestions
        prefs.commandSuggestions = true
        defer { prefs.commandSuggestions = prev }

        let session = TerminalSession(cols: 20, rows: 10)
        let pane = TerminalPaneController(session: session)
        pane.loadViewIfNeeded()
        pane.view.frame = CGRect(x: 0, y: 0, width: 20 * 30, height: 10 * 40)
        pane.view.layoutIfNeeded()
        guard let view = pane.terminalView else { expect(false, "view"); print(""); return }

        let e = session.emulator
        let cols = e.cols
        expect(cols >= 8, "the grid has a sensible width", "\(cols)")
        // A prompt near the TOP (row 0), so the continuation row is on-screen —
        // this isolates the wrap logic from the bottom-of-viewport case. Fill
        // the line to three columns short of the edge, then a ghost long
        // enough to spill well past it.
        e.feed("\u{1B}]133;A\u{07}\u{1B}]133;B\u{07}")
        e.feed(String(repeating: "x", count: cols - 3))
        let cursorRowBefore = e.buffer.scrollbackCount + e.buffer.cursorY

        view.ghostText = String(repeating: "g", count: cols + 5)
        view.setNeedsDisplay()
        UIGraphicsBeginImageContextWithOptions(view.bounds.size, true, 1)
        view.layer.render(in: UIGraphicsGetCurrentContext()!)
        UIGraphicsEndImageContext()

        let rows = Set(view.ghostRects.map { Int(($0.minY).rounded()) })
        print("    cursorRow=\(cursorRowBefore) ghostRects=\(view.ghostRects.count) distinctRows=\(rows.count)")
        expect(view.ghostRects.count == cols + 5,
               "every ghost character gets a rect", "\(view.ghostRects.count) of \(cols + 5)")
        expect(rows.count >= 2, "the ghost wraps onto a second row", "\(rows.count) rows")

        // The reported bug: the prompt at the very bottom of the viewport, so
        // the wrapped continuation would fall below the fold. Reserving space
        // must float it up so the second row still shows.
        let prefs2 = Preferences.shared
        let pv = (prefs2.commandSuggestions, prefs2.restoreSessions)
        prefs2.commandSuggestions = true; prefs2.restoreSessions = false
        defer { (prefs2.commandSuggestions, prefs2.restoreSessions) = pv }
        SessionStore.clear()

        let root = RootViewController()
        root.loadViewIfNeeded()
        root.view.frame = CGRect(x: 0, y: 0, width: 360, height: 300)   // short: few rows
        root.view.layoutIfNeeded()
        guard let pane = root.activeTab?.activePane, let pview = pane.terminalView else {
            expect(false, "pane"); print(""); return
        }
        pane.viewDidAppear(false)
        let pe = pane.session.emulator
        let pcols = pe.cols, prows = pe.rows
        // Push the prompt to the very last row: feed prows-1 newlines of output,
        // then a prompt whose command fills to near the right edge.
        pe.feed("\u{1B}]133;A\u{07}\u{1B}]133;B\u{07}\u{1B}]133;C\u{07}")
        for _ in 0..<(prows - 1) { pe.feed("out\r\n") }
        pe.feed("\u{1B}]133;D;0\u{07}\u{1B}]133;A\u{07}\u{1B}]133;B\u{07}")
        pe.feed(String(repeating: "x", count: pcols - 2))
        pane.recomputeTerminalSizeFromView()
        pane.scrollToBottom(animated: false)
        let cursorAtBottom = pe.buffer.cursorY >= prows - 2
        expect(cursorAtBottom, "the prompt sits at the bottom of the viewport",
               "cursorY=\(pe.buffer.cursorY) rows=\(prows)")

        // A ghost that must wrap onto a new row below the current last row.
        pane.setGhostText(String(repeating: "g", count: pcols + 6))
        pview.setNeedsDisplay()
        pview.layoutIfNeeded()
        UIGraphicsBeginImageContextWithOptions(pview.bounds.size, true, 1)
        pview.layer.render(in: UIGraphicsGetCurrentContext()!)
        UIGraphicsEndImageContext()

        let bottomRows = Set(pview.ghostRects.map { Int(($0.minY).rounded()) })
        let onScreen = pview.ghostRects.filter { $0.minY >= 0 && $0.maxY <= pview.bounds.height }
        print("    bottom case: rects=\(pview.ghostRects.count) rows=\(bottomRows.count) onScreen=\(onScreen.count)")
        expect(bottomRows.count >= 2, "the wrapped continuation is not clipped at the bottom",
               "\(bottomRows.count) rows visible")
        expect(onScreen.count == pview.ghostRects.count,
               "every ghost cell is within the viewport", "\(onScreen.count)/\(pview.ghostRects.count)")
        SessionStore.clear()

        print("")
    }

    /// Physical jailbreak paths are mapped back to their logical `/var/jb`
    /// form, so a restored prompt condenses to `~` instead of showing the
    /// full `/private/preboot/.../procursus/...` resolution.
    static func logicalPathTests() {
        print("logical paths")

        // The physical path /var/jb resolves to on this device.
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let root = realpath("/var/jb", &buffer) != nil ? String(cString: buffer) : "/var/jb"

        if root != "/var/jb" {
            expectEqual(UserEnvironment.logicalPath(root + "/var/mobile/proj/diffTerm"),
                        "/var/jb/var/mobile/proj/diffTerm",
                        "a physical jailbreak path maps back to /var/jb")
            expectEqual(UserEnvironment.logicalPath(root), "/var/jb",
                        "the physical root itself maps to /var/jb")
        } else {
            print("  · /var/jb is not a link here; mapping is a no-op")
        }
        // Paths that are not under the jailbreak root are untouched.
        expectEqual(UserEnvironment.logicalPath("/var/jb/var/mobile/proj"),
                    "/var/jb/var/mobile/proj", "an already-logical path is unchanged")
        expectEqual(UserEnvironment.logicalPath("/tmp/somewhere"),
                    "/tmp/somewhere", "an unrelated path is unchanged")
        // A prefix that only partially matches must not be rewritten.
        if root != "/var/jb" {
            expectEqual(UserEnvironment.logicalPath(root + "extra/x"),
                        root + "extra/x", "a partial prefix match is left alone")
        }

        print("")
    }

    // MARK: - Where a shell starts

    static func startDirectoryTests() {
        print("start directory")

        let fm = FileManager.default
        func isDir(_ p: String) -> Bool {
            var d: ObjCBool = false
            return fm.fileExists(atPath: p, isDirectory: &d) && d.boolValue
        }

        // The whole point: work kept under /var/jb lives inside the bootstrap,
        // which reinstalling the jailbreak replaces. A terminal must not drop
        // people there by default.
        let device = UserEnvironment.deviceHome
        expect(isDir(device), "the device home exists", device)
        expect(!device.hasPrefix("/var/jb"), "and is not inside the bootstrap", device)
        expectEqual(UserEnvironment.logicalPath(device), device,
                    "nor is it the bootstrap under its physical name")
        expect(device != UserEnvironment.home,
               "it is a different place from the shell's own home",
               "device \(device), shell \(UserEnvironment.home)")

        expectEqual(StartDirectory.allCases.first, .deviceHome,
                    "and it leads the Start In list")
        for dir in [StartDirectory.deviceHome, .home] {
            expect(dir.detail?.isEmpty == false,
                   "\(dir.rawValue) explains itself, since the two homes look alike")
        }

        // Defaults, read with the stored values taken out of the way.
        let defaults = UserDefaults.standard
        let storedStart = defaults.object(forKey: "startDirectory")
        let storedInherit = defaults.object(forKey: "newTabInheritsDirectory")
        defaults.removeObject(forKey: "startDirectory")
        defaults.removeObject(forKey: "newTabInheritsDirectory")
        expectEqual(Preferences.shared.startDirectory, .deviceHome,
                    "a terminal starts outside the bootstrap unless told otherwise")
        expect(Preferences.shared.newTabInheritsDirectory,
               "and a new tab follows the tab it came from")
        expectEqual(TerminalSession.resolvedStartDirectory(), device,
                    "which is what a fresh session resolves to")
        if let storedStart { defaults.set(storedStart, forKey: "startDirectory") }
        if let storedInherit { defaults.set(storedInherit, forKey: "newTabInheritsDirectory") }

        // An inherited directory outranks the preference, but only if it is
        // really there — a pane split from one whose directory was deleted
        // still has to start a shell.
        expectEqual(TerminalSession.usableDirectory("/var/mobile"), "/var/mobile",
                    "a real directory can be inherited")
        expect(TerminalSession.usableDirectory("/var/mobile/no-such-thing-here") == nil,
               "a missing one cannot")
        expect(TerminalSession.usableDirectory("/etc/passwd") == nil,
               "and neither can a file")
        expect(TerminalSession.usableDirectory(nil) == nil, "nor nothing at all")

        let inherited = TerminalSession(cols: 40, rows: 8, inheriting: "/var/mobile/Documents")
        expectEqual(inherited.workingDirectory, "/var/mobile/Documents",
                    "a split pane starts where the pane it came from is")
        let stale = TerminalSession(cols: 40, rows: 8, inheriting: "/nowhere/at/all")
        expectEqual(stale.workingDirectory, TerminalSession.resolvedStartDirectory(),
                    "a directory that has gone falls back to the preference")

        print("")
    }

    /// The daemon client end to end: spawn the real sessiond binary, drive it
    /// through DaemonTransport (the same client the app uses), and prove a
    /// second transport with the same id reattaches to the still-running shell.
    // MARK: - tmux control mode

    /// The protocol parser, against bytes a real tmux 3.4 produced. Every
    /// literal below was captured from the binary on this device rather than
    /// written from the manual, because the two disagree in ways that matter:
    /// tmux escapes a backslash as `\134`, not `\\`, and a killed window is
    /// announced as `%unlinked-window-close`, not `%window-close`.
    static func tmuxControlTests() {
        print("tmux control mode")

        func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }
        func string(_ b: [UInt8]) -> String { String(decoding: b, as: UTF8.self) }

        // Unescaping. tmux writes every non-printable byte as three octal
        // digits, so this is the only form there is.
        expectEqual(string(TmuxControlParser.unescape(bytes(#"\033[1m"#))),
                    "\u{1B}[1m", "an octal escape becomes the byte it names")
        expectEqual(TmuxControlParser.unescape(bytes(#"a\000b"#)),
                    [0x61, 0x00, 0x62], "a NUL survives, which is why this works in bytes")
        expectEqual(string(TmuxControlParser.unescape(bytes(#"a\134b"#))),
                    #"a\b"#, "a backslash arrives as an octal escape, not doubled")
        expectEqual(TmuxControlParser.unescape(bytes(#"x\015\012y"#)),
                    [0x78, 0x0D, 0x0A, 0x79], "CR and LF come back as themselves")
        expectEqual(string(TmuxControlParser.unescape(bytes(#"\12"#))), #"\12"#,
                    "two digits is not an escape, and the bytes are kept rather than dropped")
        expectEqual(string(TmuxControlParser.unescape(bytes(#"end\"#))), #"end\"#,
                    "a trailing backslash is kept")
        expectEqual(string(TmuxControlParser.unescape(bytes(#"\400"#))), #"\400"#,
                    "three octal digits can exceed a byte; that is text, not an escape")
        expectEqual(TmuxControlParser.unescape(bytes("plain")), bytes("plain"),
                    "text with nothing to unescape is unchanged")

        // Framing.
        var parser = TmuxControlParser()
        var seen = parser.feed(bytes("%window-add @3\r\n"))
        expectEqual(seen.count, 1, "a CRLF line is one notification")
        expectEqual(seen.first, .windowAdd(window: "@3"), "and the CR is framing, not content")

        // A chunk can split anywhere, including mid-escape, because this
        // arrives over a pty in whatever size the kernel felt like.
        parser = TmuxControlParser()
        var pieces: [TmuxNotification] = []
        for byte in bytes("%output %2 a\\033[1mb\r\n") {
            pieces += parser.feed([byte])
        }
        expectEqual(pieces.count, 1, "a line split one byte at a time is still one notification")
        expectEqual(pieces.first, .output(pane: "%2", bytes: bytes("a\u{1B}[1mb")),
                    "and its payload is reassembled whole")

        // The payload runs to the end of the line and is full of spaces — a
        // prompt is mostly padding — so only the first separator separates.
        parser = TmuxControlParser()
        seen = parser.feed(bytes("%output %0 a b  c\r\n"))
        expectEqual(seen.first, .output(pane: "%0", bytes: bytes("a b  c")),
                    "spaces inside a payload are payload")

        // Command blocks.
        parser = TmuxControlParser()
        seen = parser.feed(bytes("%begin 1789006884 279 1\r\n%0 1\r\n%1 0\r\n%end 1789006884 279 1\r\n"))
        expectEqual(seen.count, 1, "a command block reports once, when it closes")
        expectEqual(seen.first, .reply(number: 279, lines: ["%0 1", "%1 0"], isError: false),
                    "a reply line starting with a percent is content, not a notification")

        parser = TmuxControlParser()
        seen = parser.feed(bytes("%begin 1 279 1\r\nparse error: unknown command: nope\r\n%error 1 279 1\r\n"))
        expectEqual(seen.first, .reply(number: 279, lines: ["parse error: unknown command: nope"],
                                       isError: true),
                    "an error closes a block as a failure")

        // Our own commands come back to us, because the pty echoes.
        parser = TmuxControlParser()
        seen = parser.feed(bytes("list-windows\r\n%sessions-changed\r\n"))
        expectEqual(seen.count, 1, "an echoed command is ignored")
        expectEqual(seen.first, .sessionsChanged, "and the notification after it still arrives")

        // The notifications the tab list is built from.
        parser = TmuxControlParser()
        seen = parser.feed(bytes("%unlinked-window-close @1\r\n"))
        expectEqual(seen.first, .windowClose(window: "@1"),
                    "a killed window is announced as unlinked-window-close")
        seen = parser.feed(bytes("%window-renamed @0 my shell\r\n"))
        expectEqual(seen.first, .windowRenamed(window: "@0", name: "my shell"),
                    "a window name may contain spaces")
        seen = parser.feed(bytes("%layout-change @0 a87d,100x30,0,0,0 a87d,100x30,0,0,0 *\r\n"))
        expectEqual(seen.first, .layoutChange(window: "@0",
                                              layout: "a87d,100x30,0,0,0 a87d,100x30,0,0,0 *"),
                    "a layout change keeps the whole layout")
        seen = parser.feed(bytes("%exit\r\n"))
        expectEqual(seen.first, .exit(reason: nil), "the server can leave without a reason")
        seen = parser.feed(bytes("%exit server exited\r\n"))
        expectEqual(seen.first, .exit(reason: "server exited"), "or with one")

        // Commands. send-keys carries bytes as hex because a literal string
        // would need every metacharacter of tmux's own parser escaped, and a
        // pasted newline would run as a second command.
        expectEqual(TmuxCommand.sendKeys(pane: "%0", bytes: [0x65, 0x0D]),
                    "send-keys -t %0 -H 65 0d", "input goes as hex byte values")
        expectEqual(TmuxCommand.refreshClient(cols: 100, rows: 30),
                    "refresh-client -C 100x30", "resize goes through the client, not the pty")
        expectEqual(TmuxCommand.refreshClient(cols: 0, rows: 0),
                    "refresh-client -C 1x1", "a zero-sized window is refused rather than sent")

        // A window has to start where the tab that asked for it is, or splits
        // and new tabs opening in the current directory quietly stop working
        // the moment tmux is switched on.
        let made = TmuxCommand.newWindow(named: "dt-1", directory: "/var/mobile/Documents")
        expect(made.contains("-c '/var/mobile/Documents'"),
               "a new window is told where to start", made)
        expect(!TmuxCommand.newWindow(named: "dt-1", directory: nil).contains(" -c "),
               "and is told nothing when there is nothing to tell it")
        expectEqual(TmuxCommand.quoted("a b"), "'a b'",
                    "a path with a space stays one word")
        expectEqual(TmuxCommand.quoted("it's"), "'it'\\''s'",
                    "and a quote in a name cannot end the quoting")

        // The exact opening bytes of a real attach, replayed.
        parser = TmuxControlParser()
        let opening = "%begin 1789006801 264 0\r\n%end 1789006801 264 0\r\n%window-add @0\r\n"
            + "%sessions-changed\r\n%session-changed $0 probe\r\n%window-renamed @0 tmux\r\n"
        let replayed = parser.feed(bytes(opening))
        expectEqual(replayed.count, 5, "the real attach handshake parses end to end")
        expectEqual(replayed.first, .reply(number: 264, lines: [], isError: false),
                    "starting with an empty command block")
        expect(replayed.contains(.sessionChanged(session: "$0", name: "probe")),
               "and naming the session it attached to")

        print("")
    }

    /// The transport against the tmux binary on this device. A parser that
    /// passes invented tests and fails against real tmux is worse than none,
    /// so this drives the real thing: attach, type, read it back, and prove a
    /// shell outlives the client that started it.
    static func tmuxTransportTests() {
        print("tmux transport")

        guard TmuxEnvironment.isInstalled else {
            print("  · tmux is not installed — skipping"); print(""); return
        }

        // A socket of our own, so a failing check cannot disturb whatever the
        // app itself has running. Short, because sun_path is 104 bytes and the
        // bootstrap's own tmpdir resolves to 166.
        let socket = "/private/var/tmp/diffterm-tmux-test-\(getpid()).sock"
        let session = "difftermtest\(getpid())"
        func killServer() {
            var pid: pid_t = 0
            let argv = [TmuxEnvironment.executable, "-S", socket, "kill-server"]
            var cargv: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
            var envp: [UnsafeMutablePointer<CChar>?] = [strdup("LC_CTYPE=UTF-8"), nil]
            // Tidying up before and after is expected to fail the first time —
            // there is no server yet — and tmux says so on stderr, in the
            // middle of the checks. Send it nowhere.
            var actions: posix_spawn_file_actions_t?
            posix_spawn_file_actions_init(&actions)
            posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
            posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
            if posix_spawn(&pid, TmuxEnvironment.executable, &actions, nil, &cargv, &envp) == 0 {
                var st: Int32 = 0; waitpid(pid, &st, 0)
            }
            posix_spawn_file_actions_destroy(&actions)
            cargv.forEach { free($0) }; envp.forEach { free($0) }
        }
        killServer()
        defer { killServer(); try? FileManager.default.removeItem(atPath: socket) }

        final class Sink { let lock = NSLock(); var bytes = [UInt8](); var exited: Int32? }
        func pump(_ secs: TimeInterval) {
            let end = Date().addingTimeInterval(secs)
            while Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        }

        let env = ["PATH": "/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin",
                   "HOME": UserEnvironment.home,
                   "TERM": "xterm-256color"]

        let sink = Sink()
        let transport = TmuxTransport(socket: socket, session: session, windowName: "dt-one")
        transport.onRead = { chunk in sink.lock.lock(); sink.bytes += chunk; sink.lock.unlock() }
        transport.onExit = { code in sink.lock.lock(); sink.exited = code; sink.lock.unlock() }
        do {
            try transport.start(executable: TerminalSession.resolvedShell(),
                                arguments: [], environment: env,
                                workingDirectory: UserEnvironment.deviceHome,
                                cols: 80, rows: 24)
        } catch {
            expect(false, "the transport attached", "\(error)"); print(""); return
        }
        func text() -> String {
            sink.lock.lock(); defer { sink.lock.unlock() }
            return String(decoding: sink.bytes, as: UTF8.self)
        }

        // The pane id has to arrive before anything can be sent anywhere.
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline, transport.paneID == nil { pump(0.1) }
        expect(transport.paneID?.hasPrefix("%") == true,
               "tmux named the pane this terminal is attached to",
               transport.paneID ?? "nil")
        guard transport.paneID != nil else { print(""); return }

        // A shell prompt is output produced by a program inside tmux, relayed
        // through control mode and unescaped — the whole path in one check.
        // It arrives after the pane id, not with it: tmux answers the command
        // that made the window before the shell in it has printed anything.
        let printed = Date().addingTimeInterval(8)
        while Date() < printed, text().isEmpty { pump(0.1) }
        expect(!text().isEmpty, "a shell inside tmux produces output through the transport")

        // Input goes in as hex and comes back as the command's result.
        transport.write(Array("echo difftermworks\r".utf8))
        let echoed = Date().addingTimeInterval(8)
        while Date() < echoed, !text().contains("difftermworks\r\n") { pump(0.1) }
        expect(text().contains("difftermworks"),
               "typing reaches the shell and its output comes back",
               String(text().suffix(60)).debugDescription)

        // Resizing goes through refresh-client; tmux ignores the pty's winsize
        // for a control-mode client, so this is the only thing that works.
        transport.resize(cols: 100, rows: 30, pixelWidth: 0, pixelHeight: 0)
        pump(0.8)
        transport.write(Array("echo W=$(tput cols)\r".utf8))
        let resized = Date().addingTimeInterval(8)
        while Date() < resized, !text().contains("W=100") { pump(0.1) }
        expect(text().contains("W=100"),
               "the shell sees the new width after a resize",
               String(text().suffix(80)).debugDescription)

        // The point of the whole feature: leave something behind, drop the
        // client, and find the same shell from a second one.
        let marker = "/private/var/tmp/dtmux-\(getpid())"
        transport.write(Array("touch \(marker); sleep 30\r".utf8))
        pump(1.2)
        transport.detach()
        pump(0.5)

        let sink2 = Sink()
        let second = TmuxTransport(socket: socket, session: session, windowName: "dt-one")
        second.onRead = { chunk in sink2.lock.lock(); sink2.bytes += chunk; sink2.lock.unlock() }
        do {
            try second.start(executable: TerminalSession.resolvedShell(),
                             arguments: [], environment: env,
                             workingDirectory: UserEnvironment.deviceHome,
                             cols: 80, rows: 24)
        } catch {
            expect(false, "a second client attached", "\(error)"); print(""); return
        }
        let reattached = Date().addingTimeInterval(8)
        while Date() < reattached, second.paneID == nil { pump(0.1) }
        expect(second.paneID != nil, "a second client reattaches after the first went away")
        expectEqual(second.paneID, transport.paneID,
                    "and lands on the pane the first one left, not a new shell")

        // The marker proves the command ran inside tmux, and the shell being
        // there for the second client proves it survived losing the first.
        expect(FileManager.default.fileExists(atPath: marker),
               "the command ran inside the tmux session")
        try? FileManager.default.removeItem(atPath: marker)

        // Every control-mode client attached to a session shares its current
        // window, so a transport that just asked "which pane is in front?"
        // would hand every tab the same shell. A window of its own per tab is
        // what prevents that.
        let sink3 = Sink()
        let other = TmuxTransport(socket: socket, session: session, windowName: "dt-two")
        other.onRead = { chunk in sink3.lock.lock(); sink3.bytes += chunk; sink3.lock.unlock() }
        try? other.start(executable: TerminalSession.resolvedShell(),
                         arguments: [], environment: env,
                         workingDirectory: UserEnvironment.deviceHome,
                         cols: 80, rows: 24)
        let separate = Date().addingTimeInterval(8)
        while Date() < separate, other.paneID == nil { pump(0.1) }
        expect(other.paneID != nil, "a second tab attaches too", other.paneID ?? "nil")
        expect(other.paneID != nil && other.paneID != second.paneID,
               "and gets a shell of its own rather than a second view of the first",
               "\(other.paneID ?? "nil") vs \(second.paneID ?? "nil")")

        other.terminate()
        second.terminate()
        pump(0.5)
        print("")
    }

    static func daemonTransportTests() {
        print("daemon transport")

        let bin = "\(projectRoot)/build/diffTerm.app/sessiond"
        guard FileManager.default.isExecutableFile(atPath: bin) else {
            print("  · sessiond not built; run `make all` first — skipping"); print(""); return
        }
        let sock = NSTemporaryDirectory() + "diffterm-sd-\(getpid()).sock"
        try? FileManager.default.removeItem(atPath: sock)

        // Spawn the daemon.
        var pid: pid_t = 0
        let argv = [bin, sock]
        var cargv: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        let spawned = posix_spawn(&pid, bin, nil, nil, &cargv, environ) == 0
        cargv.forEach { free($0) }
        expect(spawned, "the daemon spawned")
        guard spawned else { print(""); return }
        defer { kill(pid, SIGTERM); var st: Int32 = 0; waitpid(pid, &st, 0) }

        let previousSocket = DaemonWire.socketPath
        DaemonWire.socketPath = sock
        defer { DaemonWire.socketPath = previousSocket }

        // Wait for the socket to come up.
        let up = Date().addingTimeInterval(3)
        while Date() < up, !FileManager.default.fileExists(atPath: sock) { usleep(50_000) }
        expect(DaemonSessionManager.shared.isAvailable == false || FileManager.default.fileExists(atPath: sock),
               "the daemon is listening")

        // A thread-safe sink for output the transport delivers.
        final class Sink { let lock = NSLock(); var bytes = [UInt8](); var exited: Int32? = nil }
        let sink = Sink()

        let env = ["PATH=/var/jb/usr/bin:/usr/bin:/bin", "HOME=/var/jb/var/mobile"]
        let script = "echo hello; sleep 2; echo world; sleep 4"

        let t1 = DaemonTransport(sessionID: 7)
        t1.onRead = { chunk in sink.lock.lock(); sink.bytes += chunk; sink.lock.unlock() }
        do {
            try t1.start(executable: "/var/jb/usr/bin/zsh",
                         arguments: ["/var/jb/usr/bin/zsh", "-c", script],
                         environment: Dictionary(uniqueKeysWithValues: env.map {
                             let kv = $0.split(separator: "=", maxSplits: 1); return (String(kv[0]), String(kv[1])) }),
                         workingDirectory: "/var/jb/var/mobile", cols: 80, rows: 24)
        } catch { expect(false, "transport started", "\(error)"); print(""); return }

        func pump(_ secs: TimeInterval) {
            let end = Date().addingTimeInterval(secs)
            while Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        }
        func text() -> String { sink.lock.lock(); defer { sink.lock.unlock() }; return String(decoding: sink.bytes, as: UTF8.self) }

        pump(1.2)
        expect(text().contains("hello"), "output streams through the transport", text().debugDescription)

        // The daemon reports the session alive.
        expect(DaemonSessionManager.shared.liveSessionIDs().contains(7),
               "the session is listed as alive")

        // Detach — the shell keeps running in the daemon.
        t1.detach()
        pump(2.0)   // 'world' is printed during this window, with nobody attached

        // Reattach with the same id: the ring replay must include everything,
        // including 'world' produced while detached.
        let sink2 = Sink()
        let t2 = DaemonTransport(sessionID: 7)
        t2.onRead = { chunk in sink2.lock.lock(); sink2.bytes += chunk; sink2.lock.unlock() }
        try? t2.start(executable: "/var/jb/usr/bin/zsh",
                      arguments: ["/var/jb/usr/bin/zsh"], environment: [:],
                      workingDirectory: "/var/jb/var/mobile", cols: 80, rows: 24)
        pump(1.5)
        let replay = { () -> String in sink2.lock.lock(); defer { sink2.lock.unlock() }; return String(decoding: sink2.bytes, as: UTF8.self) }()
        expect(replay.contains("hello") && replay.contains("world"),
               "reattaching replays the transcript, including output produced while detached",
               replay.debugDescription.prefix(80).description)

        t2.terminate()
        print("")
    }

    /// A suggestion (and the typed input) that wraps across two rows. Reported
    /// as: the ghost cuts off at the end of the first line instead of
    /// continuing on the next.
    static func ghostWrapCaptureTests() {
        print("ghost wrap capture")

        let prefs = Preferences.shared
        let prev = prefs.commandSuggestions
        prefs.commandSuggestions = true
        defer { prefs.commandSuggestions = prev }

        let session = TerminalSession(cols: 20, rows: 8)
        let pane = TerminalPaneController(session: session)
        pane.loadViewIfNeeded()
        pane.view.frame = CGRect(x: 0, y: 0, width: 190, height: 320)   // narrow → few cols
        pane.view.layoutIfNeeded()
        guard let view = pane.terminalView else { expect(false, "view"); print(""); return }
        let e = session.emulator
        let cols = e.cols
        print("    cols=\(cols)")
        expect(cols < 40, "the terminal is genuinely narrow", "\(cols)")

        // Fresh prompt at top. Type a command long enough to wrap past the edge
        // (prompt "$ " is 2 cols, so cols+2 characters guarantees a wrap).
        e.feed("\u{1B}]133;A\u{07}$ \u{1B}]133;B\u{07}")
        let typed = "echo " + String(repeating: "x", count: cols)   // > one row
        e.feed(typed)

        // The capture must return the WHOLE typed line, across the wrap.
        let captured = e.currentInputLine
        print("    typed=\(typed.count) chars, currentInputLine=\(captured?.count ?? -1) chars")
        expectEqual(captured, typed, "the wrapped input is captured in full, not just the first row")

        // A suggestion long enough to itself wrap onto a further row.
        view.ghostText = String(repeating: "g", count: cols + 8)
        view.setNeedsDisplay()
        UIGraphicsBeginImageContextWithOptions(view.bounds.size, true, 1)
        view.layer.render(in: UIGraphicsGetCurrentContext()!)
        UIGraphicsEndImageContext()

        let rows = Set(view.ghostRects.map { Int(($0.minY).rounded()) })
        print("    ghostRects=\(view.ghostRects.count) distinctRows=\(rows.count)")
        expect(view.ghostRects.count == cols + 8,
               "every ghost character gets a rect", "\(view.ghostRects.count) of \(cols + 8)")
        expect(rows.count >= 2, "the ghost continues onto the next visual row", "\(rows.count)")
        view.ghostText = ""

        // Same, but with block mode ON — the gutter changes the width the ghost
        // wraps against, and the layout is piecewise. This is the likely real
        // configuration.
        view.blockMode = true
        let cols2 = view.visibleCols
        print("    blockMode cols=\(cols2) (was \(cols))")
        view.ghostText = String(repeating: "b", count: cols2 + 8)
        view.setNeedsDisplay()
        UIGraphicsBeginImageContextWithOptions(view.bounds.size, true, 1)
        view.layer.render(in: UIGraphicsGetCurrentContext()!)
        UIGraphicsEndImageContext()
        let bmRows = Set(view.ghostRects.map { Int(($0.minY).rounded()) })
        let inView = view.ghostRects.filter { $0.maxX <= view.bounds.width + 0.5 && $0.minX >= 0 }
        print("    blockMode ghostRects=\(view.ghostRects.count) rows=\(bmRows.count) inWidth=\(inView.count)")
        expect(bmRows.count >= 2, "with block mode on, the ghost still wraps to a second row", "\(bmRows.count)")
        expect(inView.count == view.ghostRects.count, "and no ghost cell spills past the right edge", "\(inView.count)/\(view.ghostRects.count)")
        view.ghostText = ""; view.blockMode = false

        // The real case: the prompt at the BOTTOM, the typed input already
        // wrapped onto the last row, and the ghost needing a further row that
        // is below the fold. This is what the user sees cut off.
        let root = RootViewController()
        root.loadViewIfNeeded()
        root.view.frame = CGRect(x: 0, y: 0, width: 190, height: 260)   // narrow + short
        root.view.layoutIfNeeded()
        SessionStore.clear()
        prefs.commandSuggestions = true
        guard let p2 = root.activeTab?.activePane, let v2 = p2.terminalView else {
            expect(false, "pane"); print(""); return
        }
        p2.viewDidAppear(false)
        let e2 = p2.session.emulator
        let c2 = e2.cols, r2 = e2.rows
        // Fill the screen so the prompt is on the last row.
        e2.feed("\u{1B}]133;A\u{07}\u{1B}]133;B\u{07}\u{1B}]133;C\u{07}")
        for _ in 0..<(r2 + 2) { e2.feed("out\r\n") }
        e2.feed("\u{1B}]133;D;0\u{07}\u{1B}]133;A\u{07}$ \u{1B}]133;B\u{07}")
        // Type an input that wraps onto a second row at the bottom.
        e2.feed("echo " + String(repeating: "y", count: c2))
        p2.recomputeTerminalSizeFromView()
        p2.scrollToBottom(animated: false)
        // A ghost that must wrap once more, below the last visible row.
        p2.setGhostText(String(repeating: "z", count: c2 + 6))
        v2.setNeedsDisplay(); v2.layoutIfNeeded()
        UIGraphicsBeginImageContextWithOptions(v2.bounds.size, true, 1)
        v2.layer.render(in: UIGraphicsGetCurrentContext()!)
        UIGraphicsEndImageContext()
        let onScreen = v2.ghostRects.filter { $0.minY >= -0.5 && $0.maxY <= v2.bounds.height + 0.5 }
        let visRows = Set(v2.ghostRects.map { Int(($0.minY / 5).rounded()) })
        print("    bottom+wrapped: rects=\(v2.ghostRects.count) onScreen=\(onScreen.count) rows=\(visRows.count)")
        expect(onScreen.count == v2.ghostRects.count,
               "the wrapped ghost is fully visible at the bottom, not cut off",
               "\(onScreen.count)/\(v2.ghostRects.count)")
        SessionStore.clear()

        print("")
    }

    /// Reproduce the wrapped-suggestion bug with a REAL shell, since a direct
    /// feed does not replicate how zsh's line editor lays out (and redraws) a
    /// line that wraps. Checks what currentInputLine actually returns.
    static func realShellWrapTests() {
        print("real shell wrap")

        let prefs = Preferences.shared
        let pv = (prefs.commandSuggestions, prefs.persistentSessions, prefs.restoreSessions)
        prefs.commandSuggestions = true; prefs.persistentSessions = false; prefs.restoreSessions = false
        defer { (prefs.commandSuggestions, prefs.persistentSessions, prefs.restoreSessions) = pv }
        SessionStore.clear()

        let root = RootViewController()
        root.loadViewIfNeeded()
        root.view.frame = CGRect(x: 0, y: 0, width: 210, height: 420)   // narrow → few cols
        root.view.layoutIfNeeded()
        guard let pane = root.activeTab?.activePane else { expect(false, "pane"); print(""); return }
        pane.viewDidAppear(false)

        func settle(_ s: TimeInterval) {
            let end = Date().addingTimeInterval(s)
            while Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        }
        // Wait until the shell is at a prompt with a command-start (B) mark.
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline, pane.session.emulator.shellIntegration.last?.commandStart == nil {
            settle(0.2)
        }
        let e = pane.session.emulator
        let cols = e.cols
        guard e.shellIntegration.last?.commandStart != nil else {
            print("    no B mark (shell integration not active?) — cols=\(cols); skipping"); print(""); return
        }
        print("    cols=\(cols), B mark present")

        // Type a command longer than one row, character by character (as a
        // user would), letting the shell echo/redraw between keystrokes.
        let typed = "echo " + String(repeating: "w", count: cols)
        for ch in typed { pane.session.send(text: String(ch)); settle(0.03) }
        settle(0.4)

        let captured = e.currentInputLine
        print("    typed \(typed.count) chars; currentInputLine = \(String(describing: captured.map { "\($0.count) chars: \($0.debugDescription)" }))")
        expectEqual(captured, typed,
                    "a real wrapped command line is captured in full")

        pane.resignPaneFirstResponder()
        SessionStore.clear()
        print("")
    }

    /// A wrapped input with a space exactly at the wrap boundary. The first
    /// visual row ends in a space the user typed; trimming it (trailing-space
    /// removal) silently drops a character from the captured command, so the
    /// suggestion stops matching and appears to cut off at the line break.
    static func wrappedSpaceCaptureTests() {
        print("wrapped space capture")

        // cols=10, prompt "$ " puts the command start at col 2. Type so a
        // space lands on the last column (9) and the next char wraps.
        let e = Emulator(cols: 10, rows: 6)
        e.feed("\u{1B}]133;A\u{07}$ \u{1B}]133;B\u{07}")
        e.feed("echo ab cd")   // "echo ab " fills cols 2..9 (col 9 = space), "cd" wraps

        expectEqual(e.currentInputLine, "echo ab cd",
                    "the space at the wrap boundary is kept, not trimmed away")

        // And a case with no boundary space still reads correctly (no regression).
        let f = Emulator(cols: 10, rows: 6)
        f.feed("\u{1B}]133;A\u{07}$ \u{1B}]133;B\u{07}")
        f.feed("echo abcdef")
        expectEqual(f.currentInputLine, "echo abcdef", "a wrap with no boundary space is unaffected")

        print("")
    }

    // MARK: - Inline images

    /// A real PNG of a solid colour, so the decode path is exercised against
    /// bytes ImageIO actually produced rather than a hand-written fixture.
    static func makePNG(width: Int, height: Int,
                        color: UIColor = .systemPink, noisy: Bool = false) -> [UInt8] {
        let size = CGSize(width: width, height: height)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            color.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            // A solid fill compresses to almost nothing, which is no use to a
            // check that needs a payload past the OSC ceiling. Noise does not.
            guard noisy else { return }
            var seed: UInt64 = 0x9E3779B97F4A7C15
            func random() -> CGFloat {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return CGFloat((seed >> 33) % 1000) / 1000
            }
            for x in stride(from: 0, to: size.width, by: 2) {
                for y in stride(from: 0, to: size.height, by: 2) {
                    UIColor(red: random(), green: random(), blue: random(), alpha: 1).setFill()
                    ctx.fill(CGRect(x: x, y: y, width: 2, height: 2))
                }
            }
        }
        return [UInt8](image.pngData() ?? Data())
    }

    /// The escape a program sends to draw one.
    static func itermImageSequence(_ png: [UInt8], keys: String) -> String {
        "\u{1B}]1337;File=\(keys):\(Data(png).base64EncodedString())\u{07}"
    }

    static func inlineImageTests() {
        print("inline images")

        // --- Sizes, as the protocols spell them ---
        typealias Dim = InlineImageGeometry.Dimension
        expectEqual(Dim("10"), .cells(10), "a bare number is cells")
        expectEqual(Dim("40px"), .pixels(40), "px is pixels")
        expectEqual(Dim("50%"), .percent(50), "a percentage is of the window")
        expectEqual(Dim("auto"), .auto, "auto asks the picture")
        expectEqual(Dim(""), .auto, "and so does nothing at all")
        expect(Dim("wide") == nil, "anything else is not a size")
        expect(Dim("0") == nil, "and neither is zero")
        expectEqual(Dim("200%"), .percent(100), "a percentage cannot exceed the window")

        let cell = CGSize(width: 8, height: 16)
        func span(_ w: Int, _ h: Int, width: Dim = .auto, height: Dim = .auto,
                  preserve: Bool = true, cols: Int = 80, rows: Int = 24) -> (cols: Int, rows: Int) {
            InlineImageGeometry.cellSpan(pixelWidth: w, pixelHeight: h,
                                         width: width, height: height,
                                         preserveAspectRatio: preserve,
                                         cellSize: cell, gridCols: cols, gridRows: rows)
        }

        expectEqual(span(80, 32).cols, 10, "a picture with no size asked for takes its own")
        expectEqual(span(80, 32).rows, 2, "in both directions")
        expectEqual(span(80, 33).rows, 3,
                    "a picture that overhangs a row gets the whole row, not most of it")
        expectEqual(span(100, 100, width: .cells(4)).cols, 4, "cells are taken literally")
        expectEqual(span(100, 100, width: .cells(4)).rows, 2,
                    "and the other side follows the aspect ratio")
        expectEqual(span(200, 100, width: .cells(10), height: .cells(10)).rows, 3,
                    "a box with an aspect ratio to keep is fitted inside, not filled")
        expectEqual(span(200, 100, width: .cells(10), height: .cells(10), preserve: false).rows, 10,
                    "unless the program said not to keep it")
        expectEqual(span(8000, 100).cols, 80,
                    "a picture wider than the window is squeezed to fit rather than clipped")
        expectEqual(span(100, 8000).rows, 500,
                    "but a tall one scrolls, exactly as tall output does")

        // --- The store, and its budget ---
        var store = InlineImageStore()
        let small = InlineImage.Source.bitmap(rgba: [UInt8](repeating: 0, count: 4 * 4 * 4),
                                              width: 4, height: 4)
        let id = store.insert(stableRow: 10, col: 0, cols: 2, rows: 2,
                              pixelWidth: 4, pixelHeight: 4, source: small)
        expect(id != nil, "a picture that fits is kept")
        expectEqual(store.images.count, 1, "and is the only one there")
        expectEqual(store.totalBytes, 64, "the budget counts what it actually holds")

        let huge = InlineImage.Source.bitmap(
            rgba: [UInt8](repeating: 0, count: InlineImageStore.maximumImageBytes + 4),
            width: 1, height: 1)
        expect(store.insert(stableRow: 0, col: 0, cols: 1, rows: 1,
                            pixelWidth: 1, pixelHeight: 1, source: huge) == nil,
               "one too big to keep at any price is refused rather than evicting everything")
        expectEqual(store.images.count, 1, "and leaves what was already there alone")

        expectEqual(store.images(intersecting: 11..<12).count, 1,
                    "a picture is found by any row it covers")
        expectEqual(store.images(intersecting: 12..<20).count, 0,
                    "and not by a row below it")
        store.discard(rows: 11..<12)
        expect(store.isEmpty, "erasing a row it covers takes the picture with it")
        expectEqual(store.totalBytes, 0, "and gives the bytes back")

        store.insert(stableRow: 5, col: 0, cols: 1, rows: 1,
                     pixelWidth: 4, pixelHeight: 4, source: small)
        store.discard(before: 4)
        expectEqual(store.images.count, 1, "a picture still in scrollback stays")
        store.discard(before: 6)
        expect(store.isEmpty, "one that has aged out does not")

        // --- Decoding real bytes ---
        let png = makePNG(width: 24, height: 12)
        expect(!png.isEmpty, "the checks can make a PNG to decode", "\(png.count) bytes")
        let size = InlineImageDecoder.pixelSize(ofEncoded: png)
        expectEqual(size?.width, 24, "ImageIO reads the width out of a real PNG")
        expectEqual(size?.height, 12, "and the height")
        expect(InlineImageDecoder.pixelSize(ofEncoded: [UInt8]("not a picture".utf8)) == nil,
               "bytes that are not a picture are refused before anything stores them")
        expect(InlineImageDecoder.pixelSize(ofEncoded: []) == nil, "and so is nothing at all")
        expect(InlineImageDecoder.decode(.encoded(png)) != nil, "and a real one decodes")

        // --- End to end through the emulator ---
        let e = Emulator(cols: 40, rows: 10)
        e.cellSize = cell
        e.feed(Array("hello\r\n".utf8))
        let rowBefore = e.stableCursorRow
        e.feed(Array(itermImageSequence(png, keys: "inline=1;width=6;height=3").utf8))
        expectEqual(e.images.images.count, 1, "imgcat puts a picture in the grid")
        if let placed = e.images.images.first {
            expectEqual(placed.stableRow, rowBefore, "anchored where the cursor was")
            expectEqual(placed.cols, 6, "as many columns as were asked for")
            expectEqual(placed.rows, 2,
                        "and as many rows as fitting inside that box needs")
            expectEqual(placed.pixelWidth, 24, "remembering its own width for drawing")
        }
        expectEqual(e.stableCursorRow, rowBefore + 2,
                    "the rows it covers are real rows, so the cursor is below it")
        expectEqual(e.buffer.cursorX, 0, "at the start of the line, ready to print")

        // Scrolling must not slide a picture off the text it belongs to.
        let anchored = e.images.images.first?.stableRow ?? -1
        for _ in 0..<50 { e.feed(Array("filler\r\n".utf8)) }
        expectEqual(e.images.images.first?.stableRow, anchored,
                    "a stable row survives the buffer scrolling under it")

        // --- What must not become a picture ---
        let e2 = Emulator(cols: 40, rows: 10)
        e2.cellSize = cell
        e2.feed(Array(itermImageSequence(png, keys: "inline=0;width=2").utf8))
        expect(e2.images.isEmpty, "inline=0 is a download, and a phone has nowhere to put it")
        e2.feed(Array("\u{1B}]1337;File=inline=1:bm90IGEgcGljdHVyZQ==\u{07}".utf8))
        expect(e2.images.isEmpty, "valid base64 that is not a picture draws nothing")
        e2.feed(Array("\u{1B}]1337;File=inline=1:!!!!\u{07}".utf8))
        expect(e2.images.isEmpty, "and neither does something that is not base64")
        e2.feed(Array("\u{1B}]1337;RequestAttention=true\u{07}".utf8))
        expect(e2.images.isEmpty, "OSC 1337 is not only about pictures; the rest is ignored")

        // Erasing the screen takes the pictures on it.
        let e3 = Emulator(cols: 40, rows: 10)
        e3.cellSize = cell
        e3.feed(Array(itermImageSequence(png, keys: "inline=1;width=4;height=2").utf8))
        expectEqual(e3.images.images.count, 1, "a picture is on screen")
        e3.feed(Array("\u{1B}[2J".utf8))
        expect(e3.images.isEmpty, "and clearing the screen takes it away")

        // The alternate screen has no scrollback to anchor to.
        let e4 = Emulator(cols: 40, rows: 10)
        e4.cellSize = cell
        e4.feed(Array("\u{1B}[?1049h".utf8))
        e4.feed(Array(itermImageSequence(png, keys: "inline=1;width=4;height=2").utf8))
        expect(e4.images.isEmpty, "a picture is refused on the alternate screen")

        // The regression this protocol would otherwise walk straight into: a
        // payload past the ordinary OSC ceiling used to be truncated and then
        // dropped, which reads as imgcat doing nothing on larger files.
        let big = makePNG(width: 400, height: 400, color: .systemIndigo, noisy: true)
        expect(big.count * 4 / 3 > Parser.defaultOSCLimit,
               "the check's picture is past the ordinary OSC ceiling",
               "\(big.count) bytes encodes to \(big.count * 4 / 3)")
        let e5 = Emulator(cols: 80, rows: 24)
        e5.cellSize = cell
        e5.feed(Array(itermImageSequence(big, keys: "inline=1;width=10;height=5").utf8))
        expectEqual(e5.images.images.count, 1,
                    "and it still arrives whole, rather than being silently dropped")

        sixelChecks()
        renderInlineImage()

        print("")
    }

    /// Sixel, the protocol that predates sending PNGs down a pty. `img2sixel`,
    /// `chafa -f sixel`, `lsix` and gnuplot all speak it.
    static func sixelChecks() {
        // Six vertical pixels per data character: `?` is all six off, `~` is
        // all six on, and the value is the character minus 0x3F.
        let twoWide = "#0;2;100;0;0#0~~"
        guard let red = SixelDecoder.decode(Array(twoWide.utf8)) else {
            expect(false, "a two-column Sixel decodes")
            return
        }
        expectEqual(red.width, 2, "one data character is one column wide")
        expectEqual(red.height, 6, "and one band is six pixels tall")
        expectEqual(red.rgba[0], 255, "a colour given as a percentage becomes a byte")
        expectEqual(red.rgba[1], 0, "with the other components where they belong")
        expectEqual(red.rgba[3], 255, "a pixel the payload set is opaque")

        // `?` sets nothing, so those pixels stay transparent rather than
        // becoming a black box over the terminal's own background.
        if let sparse = SixelDecoder.decode(Array("#0;2;0;100;0#0?~".utf8)) {
            expectEqual(sparse.rgba[3], 0, "a pixel the payload left alone stays transparent")
            expectEqual(sparse.rgba[4 + 3], 255, "and the one beside it does not")
            expectEqual(sparse.rgba[4 + 1], 255, "green at a hundred per cent is a full byte")
        } else {
            expect(false, "a partly-set Sixel decodes")
        }

        // `-` starts a new band six rows down; `$` returns to the left margin
        // without changing band.
        if let twoBands = SixelDecoder.decode(Array("#0;2;100;100;100#0~-~".utf8)) {
            expectEqual(twoBands.height, 12, "a second band is six more rows")
            expectEqual(twoBands.width, 1, "and starts back at the left margin")
        } else {
            expect(false, "a two-band Sixel decodes")
        }

        // Raster attributes declare a size; drawing past them must not clip.
        if let raster = SixelDecoder.decode(Array("\"1;1;20;12#0;2;0;0;100#0~".utf8)) {
            expectEqual(raster.width, 20, "raster attributes name the width")
            expectEqual(raster.height, 12, "and the height")
        } else {
            expect(false, "a Sixel with raster attributes decodes")
        }
        if let overdrawn = SixelDecoder.decode(Array("\"1;1;2;6#0;2;0;0;100#0~~~~".utf8)) {
            expectEqual(overdrawn.width, 4,
                        "a payload that draws past its own header is not clipped by it")
        } else {
            expect(false, "an overdrawn Sixel decodes")
        }

        // A repeat count is attacker-controlled and must not decide the width.
        if let repeated = SixelDecoder.decode(Array("#0;2;100;100;0!8~".utf8)) {
            expectEqual(repeated.width, 8, "a repeat introducer repeats the character after it")
        } else {
            expect(false, "a repeated Sixel decodes")
        }
        let absurd = SixelDecoder.decode(Array("#0;2;100;0;0!999999999~".utf8))
        expect(absurd == nil || absurd!.width <= InlineImageStore.maximumPixelSide,
               "a repeat of a billion cannot allocate a billion pixels")
        expect(SixelDecoder.decode([]) == nil, "an empty payload is not a picture")

        // End to end: DCS q … ST puts it in the grid.
        let e = Emulator(cols: 40, rows: 10)
        e.cellSize = CGSize(width: 8, height: 16)
        e.feed(Array("\u{1B}P0;1;0q#0;2;100;0;0#0~~~~~~~~\u{1B}\\".utf8))
        expectEqual(e.images.images.count, 1, "a Sixel reaches the grid")
        expectEqual(e.images.images.first?.pixelWidth, 8, "at the size the payload drew")

        // The two DCS sequences that both end in `q`, told apart by the
        // intermediate. DECRQSS used to claim the empty case, which meant it
        // never answered a real request and swallowed every Sixel.
        let r = ReplyRecorder()
        let e2 = Emulator(cols: 20, rows: 5)
        e2.delegate = r
        e2.feed(Array("\u{1B}P$qm\u{1B}\\".utf8))
        expect(r.text.contains("$r"), "DECRQSS answers a status request", r.text.debugDescription)
        expect(e2.images.isEmpty, "and is not mistaken for a picture")

        // And the reply that makes programs send Sixels at all.
        let r2 = ReplyRecorder()
        let e3 = Emulator(cols: 20, rows: 5)
        e3.delegate = r2
        e3.feed(Array("\u{1B}[c".utf8))
        expect(r2.text.contains(";4;"), "device attributes advertise Sixel support",
               r2.text.debugDescription)
    }

    /// Renders a terminal with a picture in it and reads the pixels back, so
    /// "it draws" is measured rather than asserted. Writes the result out too,
    /// because a picture is the one thing worth looking at by eye.
    static func renderInlineImage() {
        let cols = 40, rows = 12
        let font = TerminalFont(familyName: "Menlo", pointSize: 13,
                                lineHeightScale: 1.0, scale: 1)
        let palette = TerminalPalette(theme: Theme.theme(withID: "diffterm-dark"))

        let emulator = Emulator(cols: cols, rows: rows)
        emulator.cellSize = font.cellSize
        emulator.feed(Array("$ imgcat parrot.png\r\n".utf8))
        // A colour nothing in the theme uses, so a pixel of it in the output
        // can only have come from the picture.
        let png = makePNG(width: 64, height: 32, color: UIColor(red: 0, green: 1, blue: 0, alpha: 1))
        emulator.feed(Array(itermImageSequence(png, keys: "inline=1;width=10").utf8))
        emulator.feed(Array("$ img2sixel bars.png\r\n".utf8))
        emulator.feed(Array(sixelBars().utf8))
        emulator.feed(Array("$ \r\n".utf8))

        let view = TerminalView(font: font, palette: palette)
        view.emulator = emulator
        view.isInputFocused = true
        view.frame = CGRect(x: 0, y: 0,
                            width: font.cellSize.width * CGFloat(cols),
                            height: font.cellSize.height * CGFloat(rows))
        view.layoutIfNeeded()

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let rendered = UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { _ in
            view.draw(view.bounds)
        }

        guard let placed = emulator.images.images.first else {
            expect(false, "the sample has a picture to draw")
            return
        }
        expectEqual(placed.cols, 10, "the sample picture is ten cells wide")

        // Sample the middle of where the picture should be. Reading one pixel
        // is the whole check: if the draw is upside down, mis-clipped, or
        // never happens, this is the terminal's background instead.
        let point = CGPoint(x: view.gutterWidth + font.cellSize.width * 2,
                            y: font.cellSize.height * CGFloat(1) + 4)
        let sampled = pixel(in: rendered, at: point)
        expect(sampled.map { $0.green > 0.6 && $0.red < 0.4 } ?? false,
               "the picture is actually on screen where it was placed",
               sampled.map { String(format: "r%.2f g%.2f b%.2f", $0.red, $0.green, $0.blue) }
                 ?? "no pixel")

        // And nothing of it below the rows it reserved.
        let below = CGPoint(x: view.gutterWidth + font.cellSize.width * 2,
                            y: font.cellSize.height * CGFloat(1 + placed.rows) + 4)
        let after = pixel(in: rendered, at: below)
        expect(after.map { $0.green < 0.6 } ?? false,
               "and stops at the last row it reserved",
               after.map { String(format: "r%.2f g%.2f b%.2f", $0.red, $0.green, $0.blue) }
                 ?? "no pixel")

        // The Sixel below it, sampled in its first bar.
        expectEqual(emulator.images.images.count, 2, "the sample has a Sixel under the PNG")
        if let sixel = emulator.images.images.last,
           let top = emulator.absoluteRow(for: sixel.stableRow) {
            let inBar = CGPoint(x: view.gutterWidth + 4,
                                y: font.cellSize.height * CGFloat(top) + 4)
            let bar = pixel(in: rendered, at: inBar)
            expect(bar.map { $0.red > 0.6 && $0.blue < 0.4 } ?? false,
                   "the Sixel drew its first bar where it was placed",
                   bar.map { String(format: "r%.2f g%.2f b%.2f", $0.red, $0.green, $0.blue) }
                     ?? "no pixel")
        }

        if let data = rendered.pngData() {
            let path = "\(projectRoot)/build/render-inline-image.png"
            try? data.write(to: URL(fileURLWithPath: path))
            print("  wrote render-inline-image.png (\(Int(rendered.size.width))x\(Int(rendered.size.height)) pt)")
        }
    }

    /// Four colour bars as a Sixel, written by hand: a colour register per
    /// bar, eight columns each, four bands tall.
    static func sixelBars() -> String {
        var payload = "\u{1B}P0;1;0q\"1;1;32;24"
        let colours = [(100, 20, 20), (20, 100, 20), (20, 20, 100), (100, 100, 20)]
        for (index, rgb) in colours.enumerated() {
            payload += "#\(index);2;\(rgb.0);\(rgb.1);\(rgb.2)"
        }
        for _ in 0..<4 {
            for index in 0..<colours.count {
                payload += "#\(index)!8~"
            }
            payload += "-"
        }
        return payload + "\u{1B}\\"
    }

    /// One pixel out of a rendered image, as unpremultiplied components.
    static func pixel(in image: UIImage, at point: CGPoint)
        -> (red: CGFloat, green: CGFloat, blue: CGFloat)? {
        guard let cg = image.cgImage else { return nil }
        let x = Int(point.x * image.scale), y = Int(point.y * image.scale)
        guard x >= 0, y >= 0, x < cg.width, y < cg.height else { return nil }
        var bytes = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &bytes, width: 1, height: 1,
                                  bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.translateBy(x: CGFloat(-x), y: CGFloat(y - cg.height + 1))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: CGFloat(cg.width), height: CGFloat(cg.height)))
        return (CGFloat(bytes[0]) / 255, CGFloat(bytes[1]) / 255, CGFloat(bytes[2]) / 255)
    }

    static func themeTests() {
        print("themes")

        let names = ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white",
                     "br-black", "br-red", "br-green", "br-yellow", "br-blue", "br-magenta",
                     "br-cyan", "br-white"]

        // Solarized, Nord, Dracula and friends are published palettes. People
        // pick them because they want *that* palette, so they are reproduced
        // faithfully and only measured; the gate applies to our own.
        let ours: Set<String> = ["diffterm-dark", "diffterm-light",
                                 "sakura", "sakura-night", "basic-light"]

        for theme in Theme.builtIn {
            let bg = theme.background
            let strict = ours.contains(theme.id)
            var worst: (String, CGFloat) = ("", 99)

            let fgRatio = theme.foreground.contrastRatio(with: bg)
            let exempt: Set<Int> = theme.isDark ? [0, 8] : [7, 15]
            for (i, color) in theme.ansi.enumerated() where !exempt.contains(i) {
                let r = color.contrastRatio(with: bg)
                if r < worst.1 { worst = (names[i], r) }
            }
            let cursorRatio = theme.cursor.contrastRatio(with: bg)

            guard strict else {
                print(String(format: "  · %@ — fg %.1f:1, weakest %@ %.1f:1 (upstream palette)",
                             theme.name, fgRatio, worst.0, worst.1))
                continue
            }

            expect(fgRatio >= 7, "\(theme.name): foreground is legible",
                   String(format: "%.2f:1", fgRatio))
            expect(worst.1 >= 3, "\(theme.name): weakest colour is legible",
                   String(format: "%@ at %.2f:1", worst.0, worst.1))
            // A cursor that blends into the background is not a cursor.
            expect(cursorRatio >= 2.5, "\(theme.name): cursor stands out",
                   String(format: "%.2f:1", cursorRatio))
        }

        expect(Theme.builtIn.contains { $0.id == "sakura" }, "Sakura is available as a light theme")
        expect(Theme.builtIn.contains { $0.id == "sakura-night" }, "Sakura Night is available as a dark theme")

        // Ids must be unique or the picker's selected state is ambiguous.
        expectEqual(Set(Theme.builtIn.map(\.id)).count, Theme.builtIn.count, "theme ids are unique")

        print("")
    }

    // MARK: - Rendering

    static func renderSample() {
        print("renderer")
        // One sample per theme we care to eyeball; the checks run against the
        // first, the rest exist so a palette change can be seen, not guessed.
        for id in ["diffterm-dark", "sakura", "sakura-night"] {
            renderSample(themeID: id, assert: id == "diffterm-dark")
        }
    }

    static func renderSample(themeID: String, assert shouldAssert: Bool) {
        let cols = 74, rows = 26
        let emulator = Emulator(cols: cols, rows: rows)
        emulator.feed(sampleOutput())

        let prefs = Preferences.shared
        let font = TerminalFont(familyName: "Menlo", pointSize: 13,
                                lineHeightScale: 1.0, scale: 3)
        let palette = TerminalPalette(theme: Theme.theme(withID: themeID))

        let view = TerminalView(font: font, palette: palette)
        view.emulator = emulator
        view.isInputFocused = true
        view.boldIsBright = prefs.boldIsBright
        view.frame = CGRect(x: 0, y: 0,
                            width: font.cellSize.width * CGFloat(cols),
                            height: font.cellSize.height * CGFloat(rows))
        view.layoutIfNeeded()

        if shouldAssert {
            expectEqual(view.visibleCols, cols, "view measures the expected column count")
            expectEqual(view.visibleRows, rows, "view measures the expected row count")
        }

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 3
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(bounds: view.bounds, format: format)
        let image = renderer.image { context in
            view.draw(view.bounds)
            _ = context
        }

        guard let data = image.pngData() else {
            expect(false, "produced a PNG")
            return
        }
        let path = "\(projectRoot)/build/render-\(themeID).png"
        do {
            try data.write(to: URL(fileURLWithPath: path))
            if shouldAssert {
                expect(data.count > 5000, "rendered a non-trivial image", "\(data.count) bytes")
            }
            print("  wrote render-\(themeID).png (\(Int(image.size.width))x\(Int(image.size.height)) pt)")
        } catch {
            expect(false, "wrote the PNG", "\(error)")
        }

        guard shouldAssert else { return }

        // Selection text extraction, including the un-wrapping behaviour.
        do {
            let e = Emulator(cols: 8, rows: 4)
            e.feed("abcdefghijkl")
            let v = TerminalView(font: font, palette: palette)
            v.emulator = e
            let selection = TerminalSelection(anchor: GridPosition(row: 0, col: 0),
                                              head: GridPosition(row: 1, col: 4))
            expectEqual(v.text(for: selection), "abcdefghijkl", "wrapped lines join without a newline")
        }
    }

    static func sampleOutput() -> String {
        var s = ""
        s += "\u{1B}[1;38;5;39m diffTerm\u{1B}[0m \u{1B}[2m— terminal emulator for jailbroken iOS\u{1B}[0m\r\n"
        s += "\u{1B}[2m" + String(repeating: "─", count: 70) + "\u{1B}[0m\r\n"

        s += "\r\n\u{1B}[1m 16 colours\u{1B}[0m\r\n "
        for i in 0..<8 { s += "\u{1B}[4\(i)m  \u{1B}[0m" }
        for i in 0..<8 { s += "\u{1B}[10\(i)m  \u{1B}[0m" }
        s += "\r\n "
        for i in 0..<8 { s += "\u{1B}[3\(i)m██\u{1B}[0m" }
        for i in 0..<8 { s += "\u{1B}[9\(i)m██\u{1B}[0m" }

        s += "\r\n\r\n\u{1B}[1m 256 colours\u{1B}[0m\r\n "
        for i in 16..<88 { s += "\u{1B}[48;5;\(i)m \u{1B}[0m" }
        s += "\r\n "
        for i in 88..<160 { s += "\u{1B}[48;5;\(i)m \u{1B}[0m" }
        s += "\r\n "
        for i in 160..<232 { s += "\u{1B}[48;5;\(i)m \u{1B}[0m" }

        s += "\r\n\r\n\u{1B}[1m truecolor\u{1B}[0m\r\n "
        for i in 0..<70 {
            let t = Double(i) / 69.0
            let r = Int(255 * (1 - t)), g = Int(140 + 80 * t), b = Int(60 + 195 * t)
            s += "\u{1B}[48;2;\(r);\(g);\(b)m \u{1B}[0m"
        }

        s += "\r\n\r\n\u{1B}[1m attributes\u{1B}[0m\r\n"
        s += " \u{1B}[1mbold\u{1B}[0m  \u{1B}[2mfaint\u{1B}[0m  \u{1B}[3mitalic\u{1B}[0m  \u{1B}[4munderline\u{1B}[0m  "
        s += "\u{1B}[9mstrike\u{1B}[0m  \u{1B}[7minverse\u{1B}[0m  \u{1B}[4:3;58;5;203mcurly\u{1B}[0m\r\n"

        s += "\r\n\u{1B}[1m box drawing & unicode\u{1B}[0m\r\n"
        s += " ┌────────────┬───────────┐   日本語  한국어  中文\r\n"
        s += " │ \u{1B}[38;5;114m$ ls -la\u{1B}[0m   │ \u{1B}[38;5;215m1.4 MB\u{1B}[0m    │   αβγδε  ∑∫√∞  ✓ ✗ →\r\n"
        s += " ├────────────┼───────────┤   é ü ñ  Ω  ℃  ⌘ ⌥ ⇧\r\n"
        s += " │ \u{1B}[38;5;114m$ make\u{1B}[0m     │ \u{1B}[38;5;203mfailed\u{1B}[0m    │   \u{1B}[38;5;39m▁▂▃▄▅▆▇█\u{1B}[0m\r\n"
        s += " └────────────┴───────────┘\r\n"

        s += "\r\n \u{1B}[38;5;114mmobile@iPhone\u{1B}[0m:\u{1B}[38;5;39m~/proj/diffTerm\u{1B}[0m$ "
        return s
    }
}

/// Captures what the emulator tries to send back.
final class ReplyRecorder: EmulatorDelegate {
    var text = ""
    var clipboard: String?
    var rang = false
    var title = ""

    func emulatorWrite(_ emulator: Emulator, data: [UInt8]) {
        text += String(decoding: data, as: UTF8.self)
    }
    func emulatorRing(_ emulator: Emulator) { rang = true }
    func emulator(_ emulator: Emulator, didSetTitle title: String) { self.title = title }
    func emulator(_ emulator: Emulator, didSetWorkingDirectory path: String) {}
    func emulator(_ emulator: Emulator, didRequestClipboardWrite text: String) { clipboard = text }
    func emulator(_ emulator: Emulator, didPostNotification title: String, body: String) {}
    func emulator(_ emulator: Emulator, didScrollBy lines: Int) {}
    func emulatorPaletteDidChange(_ emulator: Emulator) {}
    func emulatorShellIntegrationDidChange(_ emulator: Emulator) {}
}

/// Collects what the key row sends, and reports whatever modifiers a check has
/// armed on its behalf.
final class KeyRowRecorder: KeyRowViewDelegate {
    var actions: [KeyRowAction] = []
    var armed: KeyModifiers = []
    var locked: KeyModifiers = []

    func keyRow(_ view: KeyRowView, didTrigger action: KeyRowAction) { actions.append(action) }
    func keyRowActiveModifiers(_ view: KeyRowView) -> KeyModifiers { armed }
    func keyRowLockedModifiers(_ view: KeyRowView) -> KeyModifiers { locked }
}
