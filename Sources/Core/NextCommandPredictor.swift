import Foundation

/// Predicts the next command, locally.
///
/// The shape is Warp's: count what followed this exact command in this exact
/// place last time, and if one follow-up dominates, offer it. Warp falls back
/// to a server-side model when history has nothing to say; this does not.
/// There is no backend to call, and "a terminal renders bytes you did not
/// write" is a claim that gets weaker the moment the contents of your prompt
/// and your build output start leaving the device. Everything here runs
/// against the on-device history file and nothing else.
///
/// Implemented from a description of the behaviour — the thresholds, the
/// cascade order and the validation rules — rather than from Warp's source,
/// which is AGPL.
struct NextCommandPredictor {

    enum Source: Equatable {
        /// What you did after this command last time.
        case episode(count: Int, total: Int)
        /// A past command starting with what you have typed.
        case history
        /// Something that exists: a command on PATH, or a file here.
        case completion
        /// What the shell's own completion system would insert on Tab.
        case shell
    }

    struct Prediction: Equatable {
        var command: String
        var source: Source
    }

    /// Everything a prediction is made against.
    struct Context {
        /// The command that just finished, if the shell is sitting at a fresh
        /// prompt. Nil while a command is running.
        var lastCommand: String?
        var lastExitCode: Int?
        var pwd: String
        var shell: String
        var hostname: String
        /// What the user has typed on the current line so far.
        var prefix: String
    }

    /// Thresholds, verbatim from the behaviour being copied.
    ///
    /// Zero-state is stricter because there is nothing on screen to justify
    /// the guess: with an empty prompt, ghost text that is usually wrong is
    /// just noise. Once the user has typed, a wrong suggestion costs almost
    /// nothing — it disappears on the next keystroke — and latency matters
    /// more than precision, so one sample is enough.
    private static let zeroStateMinSamples = 2
    private static let zeroStateMinShare = 0.25
    private static let prefixMinSamples = 1
    private static let prefixMinShare = 0.10

    var store: CommandHistoryStore
    var validator: CommandValidating
    var completer: CommandCompleting
    /// Suggestions the user dismissed. Never offered again until they run one.
    var ignored: Set<String>

    init(store: CommandHistoryStore = .shared,
         validator: CommandValidating = CommandValidator(),
         completer: CommandCompleting = CommandCompleter(),
         ignored: Set<String> = []) {
        self.store = store
        self.validator = validator
        self.completer = completer
        self.ignored = ignored
    }

    /// The cascade. Returns nil rather than a bad guess — silence is the
    /// correct failure mode for a suggestion.
    func predict(_ context: Context) -> Prediction? {
        let prefix = context.prefix

        // 1. What followed this command last time it ended this way, here.
        if let last = context.lastCommand, !last.isEmpty {
            let episodes = store.episodes(after: last,
                                          pwd: context.pwd,
                                          exitCode: context.lastExitCode,
                                          shell: context.shell,
                                          hostname: context.hostname)
            if let hit = shortcut(episodes: episodes, prefix: prefix, cwd: context.pwd) { return hit }
        }

        guard !prefix.isEmpty else { return nil }

        // 2. The most recent thing you ran that starts this way, this
        //    directory first.
        for candidate in store.recent(matching: prefix, pwd: context.pwd) {
            guard !ignored.contains(candidate), validator.isValid(candidate, cwd: context.pwd) else { continue }
            return Prediction(command: candidate, source: .history)
        }

        // 3. Anywhere in history.
        for candidate in store.allCommands() {
            guard candidate.hasPrefix(prefix), candidate != prefix,
                  !ignored.contains(candidate), validator.isValid(candidate, cwd: context.pwd) else { continue }
            return Prediction(command: candidate, source: .history)
        }

        // 4. Something that exists. Not validated: a completion is right by
        //    construction, and this is the step that keeps ghost text alive
        //    on a machine with no history yet.
        if let completed = completer.complete(line: prefix, cwd: context.pwd),
           completed != prefix, !ignored.contains(completed) {
            return Prediction(command: completed, source: .completion)
        }

        return nil
    }

    /// Counts follow-ups and takes the leader if it clears the bar.
    ///
    /// A candidate that fails validation is removed from the denominator as
    /// well as the running: if two of three past runs were followed by a
    /// command whose file no longer exists, the remaining one should be judged
    /// on its own, not scored 1/3.
    private func shortcut(episodes: [CommandEpisode], prefix: String, cwd: String) -> Prediction? {
        var pool = episodes
        if !prefix.isEmpty {
            pool = pool.filter { $0.next.hasPrefix(prefix) && $0.next != prefix }
        }
        guard !pool.isEmpty else { return nil }

        var counts: [String: Int] = [:]
        for episode in pool { counts[episode.next, default: 0] += 1 }

        let minSamples = prefix.isEmpty
            ? NextCommandPredictor.zeroStateMinSamples : NextCommandPredictor.prefixMinSamples
        let minShare = prefix.isEmpty
            ? NextCommandPredictor.zeroStateMinShare : NextCommandPredictor.prefixMinShare

        var total = pool.count
        let ranked = counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(5)

        for (candidate, count) in ranked {
            if ignored.contains(candidate) || !validator.isValid(candidate, cwd: cwd) {
                total -= count
                continue
            }
            guard total >= minSamples else { continue }
            let share = Double(count) / Double(total)
            if share >= minShare {
                return Prediction(command: candidate, source: .episode(count: count, total: total))
            }
        }
        return nil
    }
}

/// Decides whether a suggestion is worth offering. A protocol so that the
/// tests can measure the cascade without the answer depending on which
/// binaries happen to be installed on the machine running them.
protocol CommandValidating {
    /// `cwd` is the *shell's* working directory. A relative path in a
    /// suggestion means nothing without it.
    func isValid(_ command: String, cwd: String) -> Bool
}

/// Accepts everything. Test seam, and the honest fallback if validation ever
/// turns out to cost more than it saves.
struct AlwaysValid: CommandValidating {
    func isValid(_ command: String, cwd: String) -> Bool { !command.isEmpty }
}

/// Rejects suggestions that cannot possibly work.
///
/// The rule that matters more than any single check: **an unknown command is
/// valid.** The point of validating is to drop a suggestion whose file was
/// deleted last week, not to second-guess the user's own shell. Anything this
/// cannot parse confidently passes.
///
/// The check that earns its keep is the path one. History is deliberately
/// allowed to cross directories — the `make install` you run in one checkout
/// is a fine guess in another — but that means a `cd proj/foo` from last
/// week's directory would be offered in this one, where no such folder
/// exists. So every argument the spec calls a file or folder, and every
/// argument of a command like `cd` that takes nothing else, is resolved
/// against the shell's real working directory and must be there.
struct CommandValidator: CommandValidating {

    /// Directories on the child's PATH, resolved once. A suggestion is
    /// checked against the same PATH the shell will use, not the app's.
    private static let searchPaths: [String] = PathCompleter.directories

    /// Shell words that are never files. Without these, every `cd`, `if` and
    /// `export` would be looked up on PATH and fail.
    private static let builtins: Set<String> = [
        "cd", "export", "alias", "unalias", "source", ".", "set", "unset", "echo",
        "exit", "return", "eval", "exec", "read", "test", "true", "false", "let",
        "local", "declare", "typeset", "shift", "trap", "wait", "jobs", "fg", "bg",
        "kill", "umask", "ulimit", "hash", "type", "command", "builtin", "pushd",
        "popd", "dirs", "history", "bind", "printf", "pwd", "if", "then", "else",
        "elif", "fi", "for", "while", "until", "do", "done", "case", "esac",
        "function", "select", "time", "sudo", "env", "clear",
    ]

    private static let wrappers: Set<String> = ["sudo", "time", "env", "exec", "nohup", "nice", "command"]

    /// Commands whose positional arguments are existing paths by definition,
    /// spec or no spec. `true` means directories only. Commands that *create*
    /// their argument — `mkdir`, `touch`, the last operand of `cp` — are
    /// deliberately absent: rejecting `mkdir newdir` because `newdir` does
    /// not exist yet would be exactly backwards.
    private static let pathTakers: [String: Bool] = [
        "cd": true, "pushd": true, "rmdir": true,
        "ls": false, "cat": false, "less": false, "more": false, "head": false,
        "tail": false, "wc": false, "rm": false, "stat": false, "file": false,
        "du": false, "vim": false, "vi": false, "nano": false, "source": false,
        ".": false, "bat": false, "open": false,
    ]

    /// Commands — or command+subcommand pairs — whose argument is something
    /// they *create*. Fig templates `mkdir`'s argument as `folders` so it can
    /// suggest a parent, and read as "must exist" that rejects `mkdir
    /// newdir`, which is exactly backwards. Their spec-declared paths are not
    /// checked; the explicit-path check (`./`, `~/`) still is.
    private static let creators: Set<String> = [
        "mkdir", "touch", "mkfifo", "mktemp", "tee", "ln", "cp", "mv", "install",
        "rsync", "scp", "curl", "wget", "dd", "unzip", "tar",
        "git clone", "git init", "git worktree", "cargo new", "cargo init",
        "npm init", "yarn init", "pnpm init",
    ]

    var fileManager: FileManager = .default
    var specs = SpecCompleter()

    func isValid(_ command: String, cwd: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        // A single line, always. A suggestion that would run two things
        // because a newline slipped into history is not one to offer.
        guard !trimmed.contains("\n") else { return false }

        // Anything with shell syntax in it is past what this can reason
        // about — pipelines, redirects, subshells, variables, globs. Assume
        // valid.
        if trimmed.contains(where: { "|&;><$`(){}*?[]".contains($0) }) { return true }

        var words = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        while let first = words.first, CommandValidator.wrappers.contains(first) { words.removeFirst() }
        guard let first = words.first else { return false }
        guard resolves(first) else { return false }

        // Every argument that has to be there.
        var paths: [(value: String, directoriesOnly: Bool)] = []
        let creates = CommandValidator.creators.contains(first)
            || (words.count > 1 && CommandValidator.creators.contains(first + " " + words[1]))
        if !creates, let declared = specs.pathArguments(line: trimmed) { paths += declared }
        if let directoriesOnly = CommandValidator.pathTakers[first] {
            for argument in words.dropFirst() where !argument.hasPrefix("-") {
                paths.append((argument, directoriesOnly))
            }
        }
        for argument in words.dropFirst() where looksLikePath(argument) {
            paths.append((argument, false))
        }

        for (value, directoriesOnly) in paths {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: resolve(value, cwd: cwd), isDirectory: &isDirectory) else {
                return false
            }
            if directoriesOnly && !isDirectory.boolValue { return false }
        }
        return true
    }

    private func resolves(_ word: String) -> Bool {
        if CommandValidator.builtins.contains(word) { return true }
        // A path was written out in full; it either exists or it does not.
        if word.contains("/") { return fileManager.isExecutableFile(atPath: resolve(word, cwd: "/")) }
        for directory in CommandValidator.searchPaths
        where fileManager.isExecutableFile(atPath: directory + "/" + word) {
            return true
        }
        return false
    }

    /// Only arguments that are unambiguously paths. A bare word like `main`
    /// is a branch far more often than a missing file, and rejecting those
    /// would gut the suggestion list.
    private func looksLikePath(_ argument: String) -> Bool {
        guard !argument.hasPrefix("-") else { return false }
        return argument.hasPrefix("./") || argument.hasPrefix("../")
            || argument.hasPrefix("/") || argument.hasPrefix("~/")
    }

    /// Where a path argument points from the shell's point of view.
    private func resolve(_ path: String, cwd: String) -> String {
        if path.hasPrefix("~") { return UserEnvironment.home + String(path.dropFirst()) }
        if path.hasPrefix("/") { return path }
        return cwd + "/" + path
    }
}
