import Foundation

/// Gets the OSC 133 marks flowing.
///
/// Blocks and next-command suggestions both rest entirely on those marks, and
/// a stock shell emits none of them: the zsh this device ships with has an
/// eleven-line `.zshrc` and no prompt framework. Without this, turning either
/// feature on would appear to do nothing at all, which is the worst way for a
/// feature to fail.
///
/// So the script is bundled, and installing it is one line appended to the
/// user's rc file. The line is guarded and idempotent, the script does nothing
/// outside diffTerm, and both are easy to read before agreeing to them —
/// editing someone's shell configuration is not something to do quietly.
enum ShellIntegrationInstaller {

    enum Shell: String, CaseIterable {
        case zsh, bash, fish

        var displayName: String {
            switch self {
            case .zsh:  return "zsh"
            case .bash: return "bash"
            case .fish: return "fish"
            }
        }

        /// The file to append to. `.zshrc` rather than `.zprofile`: rc files
        /// run for interactive shells and, importantly, run *after* the
        /// bootstrap's `zprofile` — which opens with an unconditional
        /// `export PATH=...` that would clobber anything set earlier.
        var rcPath: String {
            switch self {
            case .zsh:  return UserEnvironment.home + "/.zshrc"
            case .bash: return UserEnvironment.home + "/.bashrc"
            case .fish: return UserEnvironment.home + "/.config/fish/config.fish"
            }
        }

        var scriptName: String { "diffterm." + rawValue }
    }

    /// The shell the terminal will actually launch.
    static var currentShell: Shell {
        let name = (TerminalSession.resolvedShell() as NSString).lastPathComponent
        return Shell.allCases.first { name.contains($0.rawValue) } ?? .zsh
    }

    /// Where the bundled script lives once installed.
    ///
    /// It is copied out of the bundle rather than sourced from it: the app
    /// bundle path changes when the app is reinstalled, and a stale `source`
    /// line in someone's `.zshrc` that prints an error on every new shell is
    /// a bad thing to leave behind.
    static var installDirectory: String {
        UserEnvironment.home + "/.config/diffterm"
    }

    static func scriptPath(for shell: Shell) -> String {
        installDirectory + "/" + shell.scriptName
    }

    private static func bundledScript(for shell: Shell) -> String? {
        let path = Bundle.main.bundlePath + "/shell/" + shell.scriptName
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    /// The line appended to the rc file.
    static func sourceLine(for shell: Shell) -> String {
        let path = scriptPath(for: shell)
        switch shell {
        case .fish:
            return "test -f \(path); and source \(path)"
        case .zsh, .bash:
            return "[ -f \(path) ] && . \(path)"
        }
    }

    private static let marker = "# diffTerm shell integration"

    // MARK: - State

    static func isInstalled(for shell: Shell) -> Bool {
        guard FileManager.default.fileExists(atPath: scriptPath(for: shell)),
              let rc = FileManager.default.contents(atPath: shell.rcPath) else { return false }
        return rc.range(of: Data(marker.utf8)) != nil
    }

    /// What the script contains, so it can be read before it is installed.
    static func scriptContents(for shell: Shell) -> String? {
        guard let path = bundledScript(for: shell) else { return nil }
        return try? String(contentsOfFile: path, encoding: .utf8)
    }

    // MARK: - Install

    enum InstallError: LocalizedError {
        case scriptMissing
        case writeFailed(String)
        case readFailed(String)

        var errorDescription: String? {
            switch self {
            case .scriptMissing:
                return "The integration script is missing from the app bundle."
            case .writeFailed(let path):
                return "Could not write to \(path)."
            case .readFailed(let path):
                return "Could not read \(path), so it was left untouched."
            }
        }
    }

    /// Copies the script out and adds the source line, once.
    ///
    /// The rc file is someone's own configuration, so it is never rewritten
    /// here: the two lines are appended in place. Bytes, not a String, because
    /// a file that is not valid UTF-8 — one Latin-1 character in a comment is
    /// enough — used to decode as nothing and be replaced wholesale by those
    /// two lines. Appending also keeps a symlinked rc (stow, chezmoi) a link.
    static func install(for shell: Shell) throws {
        guard let source = bundledScript(for: shell) else { throw InstallError.scriptMissing }
        let fm = FileManager.default

        try? fm.createDirectory(atPath: installDirectory,
                                withIntermediateDirectories: true, attributes: nil)
        let destination = scriptPath(for: shell)
        // Always refresh: an upgrade should bring a fixed script with it.
        try? fm.removeItem(atPath: destination)
        do {
            try fm.copyItem(atPath: source, toPath: destination)
        } catch {
            throw InstallError.writeFailed(destination)
        }

        let rc = shell.rcPath
        var addition = Data("\n\(marker)\n\(sourceLine(for: shell))\n".utf8)

        guard fm.fileExists(atPath: rc) else {
            try? fm.createDirectory(atPath: (rc as NSString).deletingLastPathComponent,
                                    withIntermediateDirectories: true, attributes: nil)
            guard fm.createFile(atPath: rc, contents: addition) else {
                throw InstallError.writeFailed(rc)
            }
            return
        }

        // A file that exists but cannot be read is not an empty file.
        guard let contents = fm.contents(atPath: rc) else { throw InstallError.readFailed(rc) }
        guard contents.range(of: Data(marker.utf8)) == nil else { return }
        if let last = contents.last, last != UInt8(ascii: "\n") {
            addition.insert(UInt8(ascii: "\n"), at: 0)
        }
        do {
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: rc))
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: addition)
        } catch {
            throw InstallError.writeFailed(rc)
        }
    }

    /// Takes both the line and the script back out again.
    ///
    /// Only what `install` added goes: the marker, the source line under it,
    /// and the blank line above it. Everything else in the file is written
    /// back byte for byte, through any symlink, keeping its permissions.
    static func uninstall(for shell: Shell) {
        try? FileManager.default.removeItem(atPath: scriptPath(for: shell))
        guard let contents = FileManager.default.contents(atPath: shell.rcPath) else { return }

        let markerBytes = Array(marker.utf8)
        let scriptBytes = Array("diffterm.".utf8)
        func trimmed(_ line: ArraySlice<UInt8>) -> ArraySlice<UInt8> {
            var line = line
            while let first = line.first, first == 0x20 || first == 0x09 { line.removeFirst() }
            while let last = line.last, last == 0x20 || last == 0x09 || last == 0x0D { line.removeLast() }
            return line
        }
        // `firstRange(of:)` would do, but needs iOS 16.
        func contains(_ line: ArraySlice<UInt8>, _ needle: [UInt8]) -> Bool {
            guard line.count >= needle.count else { return false }
            return (line.startIndex...(line.endIndex - needle.count)).contains {
                line[$0..<($0 + needle.count)].elementsEqual(needle)
            }
        }

        let lines = Array(contents).split(separator: UInt8(ascii: "\n"),
                                          omittingEmptySubsequences: false)
        var kept: [ArraySlice<UInt8>] = []
        var skipNext = false
        var changed = false
        for line in lines {
            if trimmed(line).elementsEqual(markerBytes) {
                // The blank line install put above the marker.
                if let previous = kept.last, previous.isEmpty { kept.removeLast() }
                skipNext = true
                changed = true
                continue
            }
            if skipNext {
                skipNext = false
                // Only drop the line if it is the one we wrote.
                if contains(line, scriptBytes) { continue }
            }
            kept.append(line)
        }
        guard changed else { return }

        let cleaned = Data(kept.joined(separator: [UInt8(ascii: "\n")]))
        // Not atomic: an atomic write replaces a symlink with a plain file and
        // resets the mode. rc files are small enough to go in a single write.
        try? cleaned.write(to: URL(fileURLWithPath: shell.rcPath))
    }
}
