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
              let rc = try? String(contentsOfFile: shell.rcPath, encoding: .utf8) else { return false }
        return rc.contains(marker)
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

        var errorDescription: String? {
            switch self {
            case .scriptMissing:
                return "The integration script is missing from the app bundle."
            case .writeFailed(let path):
                return "Could not write to \(path)."
            }
        }
    }

    /// Copies the script out and adds the source line, once.
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
        var contents = (try? String(contentsOfFile: rc, encoding: .utf8)) ?? ""
        guard !contents.contains(marker) else { return }

        try? fm.createDirectory(atPath: (rc as NSString).deletingLastPathComponent,
                                withIntermediateDirectories: true, attributes: nil)
        if !contents.isEmpty && !contents.hasSuffix("\n") { contents += "\n" }
        contents += "\n\(marker)\n\(sourceLine(for: shell))\n"
        do {
            try contents.write(toFile: rc, atomically: true, encoding: .utf8)
        } catch {
            throw InstallError.writeFailed(rc)
        }
    }

    /// Takes both the line and the script back out again.
    static func uninstall(for shell: Shell) {
        try? FileManager.default.removeItem(atPath: scriptPath(for: shell))
        guard let contents = try? String(contentsOfFile: shell.rcPath, encoding: .utf8) else { return }

        var kept: [String] = []
        var skipNext = false
        for line in contents.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces) == marker {
                skipNext = true
                continue
            }
            if skipNext {
                skipNext = false
                // Only drop the line if it is the one we wrote.
                if line.contains("diffterm.") { continue }
            }
            kept.append(line)
        }
        // Collapse the blank line the install left behind.
        let cleaned = kept.joined(separator: "\n")
            .replacingOccurrences(of: "\n\n\n", with: "\n\n")
        try? cleaned.write(toFile: shell.rcPath, atomically: true, encoding: .utf8)
    }
}
