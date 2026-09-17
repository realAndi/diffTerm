import Foundation
#if canImport(UIKit)
import UIKit

private let didEnterBackground = UIApplication.didEnterBackgroundNotification
#else
// The same notification by name, so this file still builds, and can be
// tested, where there is no UIKit.
private let didEnterBackground = Notification.Name("UIApplicationDidEnterBackgroundNotification")
#endif

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
/// Decoding a full file is not free, though, and the first use is on the main
/// thread in the middle of opening a pane. So the file is read on `queue`, and
/// until it arrives every query answers from whatever has been recorded since
/// launch. Nothing waits for it.
///
/// Thread-safe: state lives behind `lock`, which is only ever held for a copy
/// or a short scan, never for file work. File work happens on `queue`, which
/// is serial, so a load, a save and a delete can never overtake each other.
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

    /// The history file, or nil for a store that lives only in memory. The
    /// tests build stores that must not touch, or be influenced by, the real
    /// history.
    private let path: String?
    private var backgroundObserver: NSObjectProtocol?

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "dev.diffterm.history")

    // Everything from here to the initialisers is guarded by `lock`.
    private var records: [CommandRecord] = []
    private var nextID = 1
    private var dirty = false
    private var saveScheduled = false
    /// False until the file has been read. A save before then would replace
    /// ten thousand commands with the handful recorded since launch.
    private var loaded = false
    /// Bumped by `removeAll`. A save whose snapshot predates the bump is
    /// stale, and a load that started before it must not bring the old
    /// history back.
    private var generation = 0
    /// Bumped by every change to what the queries would answer.
    private var changes = 0
    /// Ids handed out before the file was loaded, and what they became once
    /// the loaded records were put in front of them. Callers keep the id
    /// `begin` returned, so the old one has to keep working.
    private var renumbered: [Int: Int] = [:]

    private convenience init() {
        self.init(path: UserEnvironment.supportDirectory + "/history.jsonl")
    }

    convenience init(inMemory: Bool) {
        self.init(path: inMemory ? nil : UserEnvironment.supportDirectory + "/history.jsonl")
    }

    /// A store backed by the file at `path`, or by nothing if it is nil.
    init(path: String?) {
        self.path = path
        guard let path = path else {
            loaded = true
            return
        }
        // Captured now rather than when the block runs: a `removeAll` that
        // gets in between must win over the file it was meant to delete.
        let startGeneration = generation
        queue.async { [weak self] in self?.load(from: path, generation: startGeneration) }

        // Saves are coalesced for two seconds, and a backgrounded app can be
        // suspended or killed well inside that.
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: didEnterBackground, object: nil, queue: nil) { [weak self] _ in
            self?.flush()
        }
    }

    deinit {
        if let observer = backgroundObserver { NotificationCenter.default.removeObserver(observer) }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    // MARK: - Recording

    /// Records a command as it starts. Returns the id to close it out with.
    @discardableResult
    func begin(command: String, pwd: String, shell: String,
               hostname: String, session: String) -> Int {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        return locked {
            let id = nextID
            nextID += 1
            // Empty commands are recorded so that ids stay dense and "the
            // next command" cannot silently skip a bare Enter, but every
            // query filters them out.
            records.append(CommandRecord(id: id, command: trimmed, exitCode: nil,
                                         startedAt: Date(), finishedAt: nil,
                                         pwd: pwd, shell: shell,
                                         hostname: hostname, session: session))
            if records.count > limit { records.removeFirst(records.count - limit) }
            dirty = true
            changes += 1
            return id
        }
    }

    /// Closes out a command with the status the shell reported.
    func finish(id: Int, exitCode: Int?) {
        let found: Bool = locked {
            let id = renumbered[id] ?? id
            guard let index = records.lastIndex(where: { $0.id == id }) else { return false }
            records[index].exitCode = exitCode
            records[index].finishedAt = Date()
            dirty = true
            changes += 1
            return true
        }
        if found { scheduleSave() }
    }

    // MARK: - Queries

    /// Episodes for a command that just finished: past runs in the same
    /// directory, on the same host and shell, that *ended the same way*, and
    /// whatever the user ran next each time.
    func episodes(after command: String, pwd: String, exitCode: Int?,
                  shell: String, hostname: String) -> [CommandEpisode] {
        let key = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return [] }
        // A copy is a retain, not a copy of the rows: the scan runs without
        // holding the lock, and a `begin` meanwhile does not disturb it.
        let records = locked { self.records }

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
            guard let next = CommandHistoryStore.firstCommand(in: records, afterIndex: i,
                                                              session: record.session) else { continue }
            episodes.append(CommandEpisode(next: next,
                                           preceding: CommandHistoryStore.commands(
                                               in: records, beforeIndex: i,
                                               session: record.session, limit: 2),
                                           pwd: record.pwd))
        }
        return episodes
    }

    /// The next non-empty command in the same session.
    private static func firstCommand(in records: [CommandRecord], afterIndex index: Int,
                                     session: String) -> String? {
        var i = index + 1
        while i < records.count {
            let candidate = records[i]
            if candidate.session == session && !candidate.command.isEmpty { return candidate.command }
            i += 1
        }
        return nil
    }

    private static func commands(in records: [CommandRecord], beforeIndex index: Int,
                                 session: String, limit: Int) -> [String] {
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
        let records = locked { self.records }
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
        let records = locked { self.records }
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
        locked {
            let id = renumbered[id] ?? id
            return records.last(where: { $0.id == id })
        }
    }

    var count: Int { locked { records.count } }

    /// Changes whenever the answer to a query might have. Callers that cache
    /// a prediction compare this rather than re-running it.
    var revision: Int { locked { changes } }

    /// Whether the file has been read yet. Until it has, queries answer from
    /// the commands recorded since launch alone.
    var isLoaded: Bool { locked { loaded } }

    func removeAll() {
        locked {
            records.removeAll()
            renumbered.removeAll()
            // Nothing is left to write; the file is going instead.
            dirty = false
            generation += 1
            changes += 1
        }
        guard let target = path else { return }
        // Through the queue, behind any save already on it. Deleting from the
        // caller's thread let a save that was already queued write the old
        // history straight back.
        queue.async { try? FileManager.default.removeItem(atPath: target) }
    }

    // MARK: - Persistence

    /// Runs on `queue`.
    private func load(from path: String, generation startGeneration: Int) {
        var decoded: [CommandRecord] = []
        if let data = FileManager.default.contents(atPath: path),
           let text = String(data: data, encoding: .utf8) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            decoded.reserveCapacity(min(limit, 1024))
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                // One malformed line — a half-written record from a kill
                // mid-append — must not cost the whole history.
                guard let lineData = line.data(using: .utf8),
                      let record = try? decoder.decode(CommandRecord.self, from: lineData) else { continue }
                decoded.append(record)
            }
        }

        locked {
            loaded = true
            // Cleared while this was reading. The delete is queued behind
            // this block; what was read is exactly what the user threw away.
            guard generation == startGeneration else { return }
            // No file yet: what has been recorded since launch is all there is.
            guard !decoded.isEmpty else { return }

            // Commands recorded while the file was being read are newer than
            // anything in it, so they go after it, renumbered to follow on.
            var nextLoadedID = (decoded.map(\.id).max() ?? 0) + 1
            var merged = decoded
            merged.reserveCapacity(decoded.count + records.count)
            for var record in records {
                if record.id != nextLoadedID { renumbered[record.id] = nextLoadedID }
                record.id = nextLoadedID
                nextLoadedID += 1
                merged.append(record)
            }
            if merged.count > limit { merged.removeFirst(merged.count - limit) }
            records = merged
            // Past every id handed out so far, as well as every id now in
            // the store, so an id from before the merge can never name a
            // command recorded after it.
            nextID = max(nextID, nextLoadedID)
            changes += 1
        }
    }

    /// Coalesces writes. A command finishing is the only thing that dirties
    /// the store, so this is rare, but a burst of short commands should not
    /// mean a burst of whole-file rewrites.
    private func scheduleSave() {
        guard path != nil else { return }
        let alreadyScheduled: Bool = locked {
            let was = saveScheduled
            saveScheduled = true
            return was
        }
        guard !alreadyScheduled else { return }
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self = self else { return }
            self.locked { self.saveScheduled = false }
            self.write()
        }
    }

    /// Writes any unsaved changes, in the background.
    func save() {
        guard path != nil else { return }
        queue.async { [weak self] in self?.write() }
    }

    /// Writes any unsaved changes and returns once they are on disk.
    ///
    /// Blocks until whatever is ahead of it on the queue has finished, a load
    /// included. That is the point when the app is going to the background:
    /// an asynchronous write can be suspended halfway, and although the
    /// atomic rename keeps the old file intact, every command since the last
    /// save would be lost.
    func flush() {
        guard path != nil else { return }
        queue.sync { write() }
    }

    /// Runs on `queue`.
    private func write() {
        guard let target = path else { return }
        let pending: (records: [CommandRecord], generation: Int)? = locked {
            guard loaded, dirty else { return nil }
            dirty = false
            return (records, generation)
        }
        guard let (snapshot, snapshotGeneration) = pending else { return }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        var out = Data()
        for record in snapshot {
            guard let line = try? encoder.encode(record) else { continue }
            out.append(line)
            out.append(0x0A)
        }

        // Cleared while this was encoding. Its delete is queued behind this
        // block, so writing would only be undone, but there is no reason to.
        guard locked({ generation == snapshotGeneration }) else { return }

        let directory = (target as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try? out.write(to: URL(fileURLWithPath: target), options: .atomic)
    }
}
