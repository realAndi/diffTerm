import Foundation

/// Completes a command line against its spec: `git ch` → `git checkout`,
/// `git remote ad` → `git remote add`, `npm i` → `npm install`, `ls --al` →
/// `ls --all`, and `git add Make` → `git add Makefile` because the spec says
/// `add` takes file paths.
///
/// The walk is the part that is ours. Tokens before the cursor are consumed
/// left to right — subcommands descend, options are matched and swallow the
/// arguments they declare, anything else is a positional — and the partial
/// last token is completed against whatever the walk says belongs at that
/// position. Ghost text wants one answer, so candidates are ranked rather
/// than listed: a short table of what people actually run first, then the
/// spec's own priority, then the shortest, then alphabetical.
///
/// Generators — the shell commands Fig runs for branch names, container ids
/// and the like — are not here and cannot be: this is a read of a JSON file,
/// not a subprocess per keystroke. An argument that only a generator could
/// fill is left alone rather than guessed at.
struct SpecCompleter {

    var store: SpecStore = .shared
    var files = FileCompleter()
    var commands: PathCompleter = .shared

    enum Outcome: Equatable {
        /// No spec for this command; the caller should fall back.
        case noSpec
        /// The spec knows this position and nothing fits — do not fall back
        /// to guessing a file where the spec expects a subcommand.
        case nothing
        case completed(String)
    }

    /// Commands that run another command: the real command is the next word.
    private static let wrappers: Set<String> = ["sudo", "time", "env", "exec", "nohup", "nice", "command", "builtin"]

    /// What people run first, per command, from experience rather than any
    /// spec. This is what makes `git co` complete to `commit` rather than the
    /// alphabetically earlier `column`, on a machine with no history yet.
    /// Once a subcommand has been run once, history outranks all of this.
    private static let popular: [String: [String]] = [
        "git": ["status", "commit", "push", "pull", "checkout", "add", "log", "diff", "branch",
                "merge", "rebase", "stash", "clone", "fetch", "reset", "switch", "restore",
                "remote", "tag", "init", "show", "cherry-pick", "revert", "blame"],
        "npm": ["install", "run", "start", "test", "init", "update", "uninstall", "publish",
                "build", "ci", "list"],
        "yarn": ["install", "add", "run", "build", "start", "test", "remove", "init", "upgrade"],
        "pnpm": ["install", "add", "run", "dev", "build", "test", "remove", "update"],
        "cargo": ["build", "run", "test", "check", "add", "new", "install", "update", "clippy",
                  "fmt", "doc", "publish", "clean"],
        "docker": ["run", "ps", "build", "exec", "images", "pull", "push", "stop", "start",
                   "logs", "compose", "rm", "rmi", "restart"],
        "kubectl": ["get", "apply", "describe", "logs", "exec", "delete", "create", "config", "port-forward"],
        "brew": ["install", "update", "upgrade", "list", "search", "uninstall", "info", "services"],
        "apt": ["install", "update", "upgrade", "remove", "search", "list", "show", "purge"],
        "apt-get": ["install", "update", "upgrade", "remove", "purge", "autoremove"],
        "pip": ["install", "uninstall", "list", "show", "freeze", "download"],
        "pip3": ["install", "uninstall", "list", "show", "freeze", "download"],
        "go": ["run", "build", "test", "mod", "get", "install", "fmt", "vet", "version"],
        "swift": ["build", "run", "test", "package"],
        "gh": ["pr", "repo", "issue", "auth", "run", "release", "gist"],
        "systemctl": ["status", "start", "stop", "restart", "enable", "disable", "reload"],
        "tmux": ["new", "attach", "ls", "kill-session", "new-session", "attach-session"],
        "ssh-keygen": [], "make": [],
    ]

    func complete(line: String, cwd: String) -> Outcome {
        guard !line.contains("\""), !line.contains("'") else { return .noSpec }

        let endsWithSpace = line.hasSuffix(" ")
        var tokens = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let partial = endsWithSpace ? "" : (tokens.popLast() ?? "")
        let head = String(line.dropLast(partial.count))

        // Peel wrappers: `sudo git ch` completes against git.
        var commandIndex = 0
        while commandIndex < tokens.count, SpecCompleter.wrappers.contains(tokens[commandIndex]) {
            commandIndex += 1
        }
        guard commandIndex < tokens.count else { return .noSpec }
        let command = (tokens[commandIndex] as NSString).lastPathComponent
        guard let root = store.spec(for: command) else { return .noSpec }

        // Walk everything between the command and the partial token.
        var node = root
        var positionals = 0
        var pendingOptionArgs: [CompletionSpec.Arg] = []
        var usedOptions = Set<String>()

        for token in tokens[(commandIndex + 1)...] {
            if let arg = pendingOptionArgs.first {
                // The previous option is still collecting its values.
                if !arg.isVariadic { pendingOptionArgs.removeFirst() }
                else if token.hasPrefix("-") { pendingOptionArgs.removeAll() }
                continue
            }
            if token.hasPrefix("-"), token != "-" {
                let flag = token.split(separator: "=", maxSplits: 1).first.map(String.init) ?? token
                if let option = node.option(named: flag) {
                    usedOptions.insert(flag)
                    if !token.contains("=") {
                        pendingOptionArgs = option.args.filter { !$0.isOptional }
                    }
                }
                continue
            }
            if positionals == 0, let sub = node.subcommand(named: token) {
                node = sub
                usedOptions.removeAll()
                continue
            }
            positionals += 1
        }

        // The partial token is whatever the walk says this position holds.
        if let arg = pendingOptionArgs.first {
            return outcome(complete(arg: arg, prefix: partial, cwd: cwd), for: arg, head: head)
        }

        if partial.hasPrefix("-") {
            return outcome(completeOption(in: node, prefix: partial, used: usedOptions), head: head)
        }

        if positionals == 0, !node.subcommands.isEmpty {
            if let name = completeSubcommand(in: node, prefix: partial, command: command) {
                return .completed(head + name)
            }
            // A command whose spec has subcommands *and* no positional
            // arguments takes nothing else here.
            if node.args.isEmpty { return .nothing }
        }

        guard !node.args.isEmpty else {
            // The spec has nothing to say about this position at all; let
            // the caller try the filesystem.
            return .noSpec
        }
        let index = min(positionals, node.args.count - 1)
        let arg = node.args[index]
        if positionals >= node.args.count, !arg.isVariadic { return .nothing }
        return outcome(complete(arg: arg, prefix: partial, cwd: cwd), for: arg, head: head)
    }

    /// Every argument in a complete line that the spec declares to be a file
    /// or folder — for validating a suggestion, not completing one. Nil when
    /// there is no spec.
    ///
    /// Only real templates count. The name hint that lets `git checkout Sou`
    /// *offer* `Sources/` must not be used to *reject* `git checkout main`:
    /// offering a file is a harmless guess, refusing a branch is not.
    func pathArguments(line: String) -> [(value: String, directoriesOnly: Bool)]? {
        guard !line.contains("\""), !line.contains("'") else { return nil }
        let tokens = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        var commandIndex = 0
        while commandIndex < tokens.count, SpecCompleter.wrappers.contains(tokens[commandIndex]) {
            commandIndex += 1
        }
        guard commandIndex < tokens.count,
              let root = store.spec(for: (tokens[commandIndex] as NSString).lastPathComponent) else { return nil }

        var node = root
        var positionals = 0
        var pending: [CompletionSpec.Arg] = []
        var out: [(value: String, directoriesOnly: Bool)] = []

        func note(_ token: String, _ arg: CompletionSpec.Arg) {
            if arg.wantsFolders { out.append((token, true)) }
            else if arg.wantsFiles { out.append((token, false)) }
        }

        for token in tokens[(commandIndex + 1)...] {
            if let arg = pending.first {
                if !arg.isVariadic { pending.removeFirst() }
                else if token.hasPrefix("-") { pending.removeAll(); continue }
                note(token, arg)
                continue
            }
            if token.hasPrefix("-"), token != "-" {
                let parts = token.split(separator: "=", maxSplits: 1).map(String.init)
                if let option = node.option(named: parts[0]) {
                    if parts.count == 2, let arg = option.args.first { note(parts[1], arg) }
                    else { pending = option.args.filter { !$0.isOptional } }
                }
                continue
            }
            if positionals == 0, let sub = node.subcommand(named: token) {
                node = sub
                continue
            }
            if !node.args.isEmpty {
                let arg = node.args[min(positionals, node.args.count - 1)]
                if positionals < node.args.count || arg.isVariadic { note(token, arg) }
            }
            positionals += 1
        }
        return out
    }

    /// Nothing matched for an argument — but did the spec actually know what
    /// belongs here? Fig's `cd` declares an unnamed, untemplated argument
    /// with `-` and `~` as static extras and leaves the real values to a
    /// generator. Answering "nothing" for that would veto the directory
    /// completion the caller can do perfectly well itself. Only an argument
    /// the spec has described — a template, or a name like `image` — earns
    /// a final "nothing".
    private func outcome(_ completed: String?, for arg: CompletionSpec.Arg, head: String) -> Outcome {
        if let completed { return .completed(head + completed) }
        let described = !arg.templates.isEmpty || arg.isCommand || !(arg.name ?? "").isEmpty
        return described ? .nothing : .noSpec
    }

    private func outcome(_ completed: String?, head: String) -> Outcome {
        guard let completed else { return .nothing }
        return .completed(head + completed)
    }

    // MARK: - Candidates

    private func completeSubcommand(in node: CompletionSpec, prefix: String, command: String) -> String? {
        guard !prefix.isEmpty else { return nil }
        let ranked = SpecCompleter.popular[command] ?? []
        var best: (name: String, rank: (Int, Double, Int, String))?

        for sub in node.subcommands where !sub.hidden && !sub.deprecated {
            for name in sub.names where name.hasPrefix(prefix) && name != prefix {
                // Lower is better on every axis: popularity index, then
                // negated priority, then length, then the name itself.
                let popularity = ranked.firstIndex(of: name) ?? ranked.count
                let rank = (popularity, -(sub.priority ?? 0), name.count, name)
                if best == nil || rank < best!.rank { best = (name, rank) }
            }
        }
        return best?.name
    }

    private func completeOption(in node: CompletionSpec, prefix: String, used: Set<String>) -> String? {
        // A lone dash is every option at once; there is no single answer.
        guard prefix.count >= 2 else { return nil }
        var best: (name: String, rank: (Double, Int, String))?
        for option in node.options where !option.hidden && !option.deprecated {
            for name in option.names where name.hasPrefix(prefix) && name != prefix {
                if !option.isRepeatable, used.contains(name) { continue }
                let rank = (-(option.priority ?? 0), name.count, name)
                if best == nil || rank < best!.rank { best = (name, rank) }
            }
        }
        guard let best else { return nil }
        // An option that takes a joined value is completed up to the joint,
        // so the next keystroke is the value.
        if let separator = node.option(named: best.name)?.requiresSeparator,
           !(node.option(named: best.name)?.args.isEmpty ?? true) {
            return best.name + separator
        }
        return best.name
    }

    private func complete(arg: CompletionSpec.Arg, prefix: String, cwd: String) -> String? {
        guard !prefix.isEmpty else { return nil }
        if !arg.suggestions.isEmpty,
           let hit = arg.suggestions
               .filter({ $0.hasPrefix(prefix) && $0 != prefix })
               .min(by: { ($0.count, $0) < ($1.count, $1) }) {
            return hit
        }
        if arg.wantsFolders {
            return files.complete(word: prefix, cwd: cwd, directoriesOnly: true)
        }
        if arg.wantsFiles {
            return files.complete(word: prefix, cwd: cwd, directoriesOnly: false)
        }
        if arg.isCommand {
            return commands.complete(prefix: prefix)
        }
        // Only a generator could fill this — `git add`'s pathspec, `git
        // checkout`'s "branch, file, tag or commit", `docker run`'s image.
        // The name is the one clue left: when it says path or file, the
        // filesystem is a fair answer, and `git add Make` should still
        // complete. When it says image, guessing a file would be wrong.
        let hint = (arg.name ?? "").lowercased()
        if hint.contains("path") || hint.contains("file") || hint.contains("dir") || hint.contains("folder") {
            let directoriesOnly = (hint.contains("dir") || hint.contains("folder")) && !hint.contains("file")
            return files.complete(word: prefix, cwd: cwd, directoriesOnly: directoriesOnly)
        }
        return nil
    }
}
