import Foundation

/// One command the user ran, with enough context to ask "what did I do after
/// this last time?".
///
/// The fields are the ones the prediction actually keys on. Exit code is in
/// that key deliberately: what you do after a build that failed is not what
/// you do after one that succeeded, and a predictor that ignores the
/// difference suggests running the tests on a tree that does not compile.
struct CommandRecord: Codable, Equatable {
    /// Monotonic across the store, so "the command after this one" is a
    /// comparison rather than a timestamp race.
    var id: Int
    var command: String
    var exitCode: Int?
    var startedAt: Date
    var finishedAt: Date?
    var pwd: String
    var shell: String
    var hostname: String
    /// One shell session — a tab or a pane. Sequences are only meaningful
    /// within one; interleaved commands from two tabs are not a sequence.
    var session: String

    enum CodingKeys: String, CodingKey {
        case id = "i", command = "c", exitCode = "x", startedAt = "s"
        case finishedAt = "f", pwd = "p", shell = "sh", hostname = "h", session = "n"
    }
}

/// What followed a past run of the same command in the same place: the
/// evidence a prediction is built from.
struct CommandEpisode {
    /// The command that ran next, in the same session.
    var next: String
    /// The two commands before the match, kept for context.
    var preceding: [String]
    var pwd: String
}

/// The command history, on disk.
///
/// Warp keeps this in SQLite. At the sizes involved — ten thousand rows, a
/// scan per finished command — a plain array in memory answers every query in
/// well under a millisecond, so this is a JSON Lines file loaded once at
/// launch instead: no C interop, no schema migrations, and the file can be
/// read with `tail` when something looks wrong.
///
/// Nothing here leaves the device.
final class CommandHistoryStore {

    static let shared = CommandHistoryStore()

    /// Matches Warp's cap. Old rows are dropped from the front.
    private let limit = 10_000

    /// How many past runs of the same command to draw episodes from. Warp's
    /// comment on this number is worth keeping: "the number of commands from
    /// history affects how quickly we learn new patterns, the lower the
    /// faster." It is a learning rate, not a correctness knob.
    private let maxSimilarContexts = 25

    private var records: [CommandRecord] = []
    private var nextID = 1
    private var dirty = false
    private let queue = DispatchQueue(label: "dev.diffterm.history")

    private var directory: String { UserEnvironment.supportDirectory }
    private var path: String { directory + "/history.jsonl" }

    /// Whether this store is backed by a file at all. The tests build stores
    /// that must not touch, or be influenced by, the real history.
    private let isPersistent: Bool

    private init() {
        isPersistent = true
        load()
    }

    init(inMemory: Bool) {
        isPersistent = !inMemory
        if isPersistent { load() }
    }

    // MARK: - Recording

    /// Records a command as it starts. Returns the id to close it out with.
    @discardableResult
    func begin(command: String, pwd: String, shell: String,
               hostname: String, session: String) -> Int {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = nextID
        nextID += 1
        // Empty commands are recorded so that ids stay dense and "the next
        // command" cannot silently skip a bare Enter, but every query filters
        // them out.
        records.append(CommandRecord(id: id, command: trimmed, exitCode: nil,
                                     startedAt: Date(), finishedAt: nil,
                                     pwd: pwd, shell: shell,
                                     hostname: hostname, session: session))
        if records.count > limit { records.removeFirst(records.count - limit) }
        dirty = true
        return id
    }

    /// Closes out a command with the status the shell reported.
    func finish(id: Int, exitCode: Int?) {
        guard let index = records.lastIndex(where: { $0.id == id }) else { return }
        records[index].exitCode = exitCode
        records[index].finishedAt = Date()
        dirty = true
        scheduleSave()
    }

    // MARK: - Queries

    /// Episodes for a command that just finished: past runs in the same
    /// directory, on the same host and shell, that *ended the same way*, and
    /// whatever the user ran next each time.
    func episodes(after command: String, pwd: String, exitCode: Int?,
                  shell: String, hostname: String) -> [CommandEpisode] {
        let key = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return [] }

        var episodes: [CommandEpisode] = []
        // Walk by index, newest first. Locating a match and then locating the
        // command after it are both index arithmetic; looking either up by id
        // would make this quadratic in the size of the history, which is felt
        // on every keystroke once the file is full.
        var i = records.count - 1
        while i >= 0, episodes.count < maxSimilarContexts {
            defer { i -= 1 }
            let record = records[i]
            guard record.command == key,
                  record.pwd == pwd,
                  record.exitCode == exitCode,
                  record.shell == shell,
                  record.hostname == hostname else { continue }
            guard let next = firstCommand(afterIndex: i, session: record.session) else { continue }
            episodes.append(CommandEpisode(next: next,
                                           preceding: commands(beforeIndex: i,
                                                               session: record.session,
                                                               limit: 2),
                                           pwd: record.pwd))
        }
        return episodes
    }

    /// The next non-empty command in the same session.
    private func firstCommand(afterIndex index: Int, session: String) -> String? {
        var i = index + 1
        while i < records.count {
            let candidate = records[i]
            if candidate.session == session && !candidate.command.isEmpty { return candidate.command }
            i += 1
        }
        return nil
    }

    private func commands(beforeIndex index: Int, session: String, limit: Int) -> [String] {
        var out: [String] = []
        var i = index - 1
        while i >= 0, out.count < limit {
            let candidate = records[i]
            if candidate.session == session && !candidate.command.isEmpty {
                out.append(candidate.command)
            }
            i -= 1
        }
        return out.reversed()
    }

    /// Past commands starting with `prefix`, most recent first, with ones run
    /// in the same directory ahead of the rest.
    ///
    /// Same-directory-first is what makes this feel like it knows the project
    /// rather than the machine: `make` in one checkout should not suggest the
    /// flags you use in another.
    func recent(matching prefix: String, pwd: String, limit: Int = 8) -> [String] {
        guard !prefix.isEmpty else { return [] }
        var here: [String] = []
        var elsewhere: [String] = []
        var seen = Set<String>()

        for record in records.reversed() {
            let command = record.command
            guard command.hasPrefix(prefix), command != prefix,
                  !seen.contains(command) else { continue }
            seen.insert(command)
            if record.pwd == pwd { here.append(command) } else { elsewhere.append(command) }
            if here.count >= limit { break }
        }
        return Array((here + elsewhere).prefix(limit))
    }

    /// Every distinct command ever run, newest first — the fallback when
    /// there is a prefix but no episode and no same-directory match.
    func allCommands(limit: Int = 400) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for record in records.reversed() where !record.command.isEmpty {
            guard !seen.contains(record.command) else { continue }
            seen.insert(record.command)
            out.append(record.command)
            if out.count == limit { break }
        }
        return out
    }

    /// One record by id, for callers holding an id from `begin`.
    func record(id: Int) -> CommandRecord? {
        records.last(where: { $0.id == id })
    }

    var count: Int { records.count }

    func removeAll() {
        records.removeAll()
        dirty = true
        if isPersistent { try? FileManager.default.removeItem(atPath: path) }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        var loaded: [CommandRecord] = []
        loaded.reserveCapacity(min(limit, 1024))
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            // One malformed line — a half-written record from a kill mid-append
            // — must not cost the whole history.
            guard let lineData = line.data(using: .utf8),
                  let record = try? decoder.decode(CommandRecord.self, from: lineData) else { continue }
            loaded.append(record)
        }
        if loaded.count > limit { loaded.removeFirst(loaded.count - limit) }
        records = loaded
        nextID = (records.map(\.id).max() ?? 0) + 1
    }

    private var saveScheduled = false

    /// Coalesces writes. A command finishing is the only thing that dirties
    /// the store, so this is rare, but a burst of short commands should not
    /// mean a burst of whole-file rewrites.
    private func scheduleSave() {
        guard isPersistent, !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.saveScheduled = false
            self?.save()
        }
    }

    func save() {
        guard isPersistent, dirty else { return }
        dirty = false
        let snapshot = records
        let target = path
        let dir = directory
        queue.async {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            var out = Data()
            for record in snapshot {
                guard let line = try? encoder.encode(record) else { continue }
                out.append(line)
                out.append(0x0A)
            }
            try? FileManager.default.createDirectory(
                atPath: dir, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try? out.write(to: URL(fileURLWithPath: target), options: .atomic)
        }
    }
}
