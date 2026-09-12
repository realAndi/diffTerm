import Foundation

/// Completes the word under the cursor from things that actually exist.
///
/// History alone cannot make ghost text feel alive: a fresh install has none,
/// and even a full one is silent for anything you have not typed before. What
/// makes Warp — and fish — feel fluid is that there is *always* a source that
/// knows something: the commands on PATH for the first word, the files in the
/// directory for the rest. Both are cheap, both are local, and both are right
/// far more often than they are wrong, because they only ever offer things
/// that are really there.
///
/// This is the last step of the cascade, after history, so a command you have
/// run before still wins over one that merely exists.
protocol CommandCompleting {
    /// The whole line with its last word completed, or nil.
    func complete(line: String, cwd: String) -> String?
}

struct CommandCompleter: CommandCompleting {

    var commands: PathCompleter = .shared
    var files = FileCompleter()
    var specs = SpecCompleter()
    var gitRefs = GitRefCompleter()

    /// Commands whose arguments can only be directories. A file offered after
    /// `cd` is a suggestion that cannot possibly be right.
    private static let directoryOnly: Set<String> = ["cd", "pushd", "rmdir", "mkdir"]

    func complete(line: String, cwd: String) -> String? {
        guard !line.isEmpty, !line.hasSuffix(" ") else { return nil }
        // Quoting is past what a word-splitter can follow. Better to offer
        // nothing than to complete the wrong half of a quoted path.
        guard !line.contains("\""), !line.contains("'") else { return nil }

        let words = line.split(separator: " ", omittingEmptySubsequences: false)
        guard let last = words.last, !last.isEmpty else { return nil }
        let word = String(last)
        let head = line.dropLast(word.count)

        // Pipelines and separators start a new command: `ls | gr` completes
        // `gr` as a command, not as a file.
        let isCommandPosition: Bool = {
            let before = head.trimmingCharacters(in: .whitespaces)
            if before.isEmpty { return true }
            return before.hasSuffix("|") || before.hasSuffix("&&") || before.hasSuffix("||")
                || before.hasSuffix(";") || before.hasSuffix("sudo") || before.hasSuffix("exec")
                || before.hasSuffix("time") || before.hasSuffix("$(") || before.hasSuffix("(")
        }()

        if isCommandPosition && !word.contains("/") {
            guard let name = commands.complete(prefix: word) else { return nil }
            return head + name
        }

        // Branch names come from the repo on disk, ahead of the spec: the
        // spec calls `git checkout`'s argument "branch, file, tag or commit"
        // and would complete it as a file, when a branch is what is meant.
        if let branch = gitRefs.complete(line: line, cwd: cwd) { return branch }

        // A command with a spec knows what belongs at this position —
        // subcommand, flag, file — and its answer is final either way: when
        // the spec expects a subcommand, a file that happens to share the
        // prefix is not a fallback, it is a wrong answer.
        switch specs.complete(line: line, cwd: cwd) {
        case .completed(let completed): return completed
        case .nothing: return nil
        case .noSpec: break
        }

        // Without a spec, flags are opaque and never files.
        guard !word.hasPrefix("-") else { return nil }

        let command = words.first.map(String.init) ?? ""
        let directoriesOnly = CommandCompleter.directoryOnly.contains(command)
        guard let completed = files.complete(word: word, cwd: cwd,
                                             directoriesOnly: directoriesOnly) else { return nil }
        return head + completed
    }
}

/// Executables on the shell's PATH.
///
/// Enumerated once and cached: PATH almost never changes within a session,
/// and a stat of every directory on it per keystroke is not free. Refreshed
/// after a few minutes so a freshly installed tool still turns up.
final class PathCompleter {

    static let shared = PathCompleter()

    private var names: [String] = []
    private var builtAt: Date?
    private let lifetime: TimeInterval = 300
    private let lock = NSLock()

    /// Directories searched, in order. The bootstrap's own list is the
    /// fallback, because the app's environment is not the shell's: the
    /// login `zprofile` replaces PATH outright.
    static var directories: [String] {
        var dirs: [String] = []
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            dirs += path.split(separator: ":").map(String.init)
        }
        dirs += ["/var/jb/usr/local/bin", "/var/jb/usr/bin", "/var/jb/bin",
                 "/var/jb/usr/local/sbin", "/var/jb/usr/sbin", "/var/jb/sbin",
                 "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var seen = Set<String>()
        return dirs.filter { seen.insert($0).inserted }
    }

    /// Builtins and keywords that are typed as commands but are not files
    /// anywhere on PATH.
    private static let builtins = [
        "alias", "bg", "bind", "builtin", "cd", "command", "declare", "dirs",
        "disown", "echo", "eval", "exec", "exit", "export", "fg", "hash",
        "history", "jobs", "kill", "let", "local", "popd", "printf", "pushd",
        "pwd", "read", "return", "set", "shift", "source", "test", "time",
        "trap", "type", "typeset", "ulimit", "umask", "unalias", "unset",
        "wait", "which", "sudo", "clear",
    ]

    private init() {}

    func complete(prefix: String) -> String? {
        guard !prefix.isEmpty else { return nil }
        lock.lock()
        if builtAt == nil || Date().timeIntervalSince(builtAt!) > lifetime { rebuild() }
        let candidates = names
        lock.unlock()

        // Shortest first: `gi` should become `git`, not `gitk` or
        // `git-upload-pack`. Ties break alphabetically, which is at least
        // predictable.
        return candidates
            .filter { $0.hasPrefix(prefix) && $0 != prefix }
            .min { ($0.count, $0) < ($1.count, $1) }
    }

    private func rebuild() {
        let fm = FileManager.default
        var found = Set(PathCompleter.builtins)
        for directory in PathCompleter.directories {
            guard let entries = try? fm.contentsOfDirectory(atPath: directory) else { continue }
            for entry in entries where !entry.hasPrefix(".") {
                // One stat per entry, once every five minutes. Fine.
                if fm.isExecutableFile(atPath: directory + "/" + entry) { found.insert(entry) }
            }
        }
        names = Array(found)
        builtAt = Date()
    }

    /// Forces the next lookup to re-scan. For tests, and for the installer
    /// once it has put something new on PATH.
    func invalidate() {
        lock.lock(); builtAt = nil; lock.unlock()
    }
}

/// Files and directories under a path prefix.
///
/// Listings are cached against the directory's modification time, so typing
/// through a name costs one `stat` per keystroke rather than a re-read, and a
/// file created since the last keystroke still appears.
struct FileCompleter {

    private final class Cache {
        var entries: [String: (mtime: Date, names: [String])] = [:]
        let lock = NSLock()
    }
    private static let cache = Cache()

    var fileManager: FileManager = .default

    /// Completes `word` — which may include directory components — relative
    /// to `cwd`. Returns the whole word completed, with a trailing `/` on a
    /// directory so the next keystroke continues into it.
    func complete(word: String, cwd: String, directoriesOnly: Bool) -> String? {
        guard !word.isEmpty else { return nil }

        // Split into "the part to keep" and "the name to complete".
        let slash = word.lastIndex(of: "/")
        let keep = slash.map { String(word[...$0]) } ?? ""
        let prefix = slash.map { String(word[word.index(after: $0)...]) } ?? word

        let directory: String
        if keep.isEmpty {
            directory = cwd
        } else if keep.hasPrefix("/") {
            directory = keep
        } else if keep.hasPrefix("~") {
            directory = UserEnvironment.home + String(keep.dropFirst())
        } else {
            directory = cwd + "/" + keep
        }

        guard let names = listing(of: directory) else { return nil }

        // Dotfiles only when asked for, the same way every shell does it.
        let wantHidden = prefix.hasPrefix(".")
        let candidates = names.filter { name in
            guard name.hasPrefix(prefix), name != prefix else { return false }
            if !wantHidden && name.hasPrefix(".") { return false }
            if directoriesOnly && !isDirectory(directory + "/" + name) { return false }
            return true
        }
        // Shortest first, for the same reason as commands.
        guard let match = candidates.min(by: { ($0.count, $0) < ($1.count, $1) }) else { return nil }

        let suffix = isDirectory(directory + "/" + match) ? "/" : ""
        return keep + escaped(match) + suffix
    }

    private func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    /// A completed name with a space in it has to be escaped, or accepting
    /// the suggestion produces a command that does not do what it shows.
    private func escaped(_ name: String) -> String {
        var out = ""
        for ch in name {
            if " \t()[]{}$&|;<>'\"`\\*?".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    private func listing(of directory: String) -> [String]? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: directory),
              let mtime = attributes[.modificationDate] as? Date else { return nil }

        let cache = FileCompleter.cache
        cache.lock.lock()
        defer { cache.lock.unlock() }
        if let hit = cache.entries[directory], hit.mtime == mtime { return hit.names }

        guard let names = try? fileManager.contentsOfDirectory(atPath: directory) else { return nil }
        // A handful of directories is all a session ever touches; do not let
        // a `find /` in the history keep every listing it ever saw.
        if cache.entries.count > 16 { cache.entries.removeAll() }
        cache.entries[directory] = (mtime, names)
        return names
    }
}
