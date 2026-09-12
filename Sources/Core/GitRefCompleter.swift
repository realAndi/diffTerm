import Foundation

/// Completes a git branch name by reading the repository's refs directly.
///
/// `git checkout <branch>` is the single most wanted contextual completion,
/// and the one the shell oracle handles worst here: `_git` shells out and runs
/// 5–20 seconds on this device, far past the watchdog. But a branch list is
/// just files under `.git/refs/heads` plus a line each in `.git/packed-refs` —
/// reading them is instant and needs no subprocess. So the common ref-taking
/// subcommands are completed from the repo on disk, and the shell is left to
/// answer only the things this cannot.
struct GitRefCompleter {

    var fileManager: FileManager = .default

    /// Subcommands whose first positional argument is an existing branch.
    /// `branch` is handled separately — bare `git branch foo` *creates* foo,
    /// so it only completes an existing name behind a delete/rename flag.
    private static let refSubcommands: Set<String> = ["checkout", "switch", "merge", "rebase"]

    /// Flags that mean "make a new branch", so an existing one must not be
    /// offered: `git switch -c foo` is naming something that does not exist.
    private static let createFlags: Set<String> = ["-b", "-B", "-c", "-C", "--orphan"]

    func complete(line: String, cwd: String) -> String? {
        guard !line.contains("\""), !line.contains("'") else { return nil }
        let endsWithSpace = line.hasSuffix(" ")
        var tokens = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let partial = endsWithSpace ? "" : (tokens.popLast() ?? "")
        guard !partial.isEmpty, !partial.hasPrefix("-") else { return nil }

        var i = 0
        let wrappers: Set<String> = ["sudo", "time", "env", "exec", "nohup", "nice", "command"]
        while i < tokens.count, wrappers.contains(tokens[i]) { i += 1 }
        guard i < tokens.count, (tokens[i] as NSString).lastPathComponent == "git" else { return nil }

        let rest = Array(tokens[(i + 1)...])
        guard let subcommand = rest.first(where: { !$0.hasPrefix("-") }) else { return nil }

        let wantsRef: Bool
        if GitRefCompleter.refSubcommands.contains(subcommand) {
            // Not while creating a branch.
            wantsRef = !rest.contains(where: { GitRefCompleter.createFlags.contains($0) })
        } else if subcommand == "branch" {
            wantsRef = rest.contains(where: { ["-d", "-D", "--delete", "-m", "-M", "--move", "--edit-description"].contains($0) })
        } else {
            wantsRef = false
        }
        guard wantsRef else { return nil }

        guard let dir = gitDirectory(startingAt: cwd) else { return nil }
        let names = branches(in: dir)
        // Shortest matching branch first, then alphabetical — the same rule
        // the other completers use, so behaviour is predictable.
        guard let match = names
            .filter({ $0.hasPrefix(partial) && $0 != partial })
            .min(by: { ($0.count, $0) < ($1.count, $1) }) else { return nil }

        return String(line.dropLast(partial.count)) + match
    }

    // MARK: - Reading the repo

    /// The `.git` directory for `cwd`, walking up parents, and following the
    /// `gitdir:` pointer a worktree or submodule leaves in a `.git` file.
    private func gitDirectory(startingAt cwd: String) -> String? {
        var dir = cwd
        var guardCount = 0
        while guardCount < 64 {
            guardCount += 1
            let dot = dir + "/.git"
            var isDir: ObjCBool = false
            if fileManager.fileExists(atPath: dot, isDirectory: &isDir) {
                if isDir.boolValue { return dot }
                // A `.git` *file* points elsewhere: `gitdir: <path>`.
                if let contents = try? String(contentsOfFile: dot, encoding: .utf8),
                   let line = contents.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) {
                    let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                    let resolved = path.hasPrefix("/") ? path : dir + "/" + path
                    return resolved
                }
            }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir || parent.isEmpty { break }
            dir = parent
        }
        return nil
    }

    /// Local branch names, from loose refs and the packed-refs file.
    func branches(in gitDir: String) -> [String] {
        var names = Set<String>()

        // Loose refs: every file under refs/heads, nested names included
        // (refs/heads/feature/x → feature/x).
        let headsRoot = gitDir + "/refs/heads"
        if let enumerator = fileManager.enumerator(atPath: headsRoot) {
            for case let relative as String in enumerator {
                var isDir: ObjCBool = false
                let full = headsRoot + "/" + relative
                if fileManager.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue {
                    names.insert(relative)
                }
            }
        }

        // Packed refs: lines like `<sha> refs/heads/<name>`.
        if let packed = try? String(contentsOfFile: gitDir + "/packed-refs", encoding: .utf8) {
            for line in packed.split(separator: "\n") {
                guard !line.hasPrefix("#"), !line.hasPrefix("^") else { continue }
                let parts = line.split(separator: " ", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let ref = parts[1].trimmingCharacters(in: .whitespaces)
                if ref.hasPrefix("refs/heads/") {
                    names.insert(String(ref.dropFirst("refs/heads/".count)))
                }
            }
        }
        return Array(names)
    }
}
