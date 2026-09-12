import Foundation

/// A tab's screen, saved to disk so that being killed in the background costs
/// you the running processes but not what was on screen.
///
/// iOS suspends an app seconds after you leave it and reclaims it whenever it
/// likes; a terminal that keeps nothing has you staring at a fresh prompt with
/// no idea what the last command said. There is no pretence that the shell
/// survives — it does not, and the restored screen says so — but the output is
/// usually the part you wanted back.
struct SessionSnapshot: Codable {
    var title: String
    var workingDirectory: String
    var lines: [SnapshotLine]
    var savedAt: Date
    /// The daemon session this tab was attached to, so a relaunch can reattach
    /// to the still-running shell rather than restoring a dead screen. Zero
    /// for a snapshot saved before the daemon existed, or a local session.
    var daemonSessionID: UInt32 = 0

    enum CodingKeys: String, CodingKey {
        case title, workingDirectory, lines, savedAt
        case daemonSessionID = "d"
    }

    /// Kept deliberately small. This is the tail you would scroll back through,
    /// not an archive, and it is written on the way into the background where
    /// there is a fixed and short budget.
    static let maxLines = 1000
    static let maxTabs = 12
}

/// A line as a run-length encoded sequence of same-attribute spans, which is
/// what terminal output actually looks like — long stretches of one colour.
struct SnapshotLine: Codable {
    var runs: [SnapshotRun]
    var wrapped: Bool

    enum CodingKeys: String, CodingKey {
        case runs = "r", wrapped = "w"
    }
}

struct SnapshotRun: Codable {
    var text: String
    /// Colours are packed into an Int rather than encoded as an enum: it keeps
    /// the file compact, and it avoids depending on synthesised Codable for
    /// enums with associated values.
    var fg: Int
    var bg: Int
    var underline: Int
    var flags: UInt16

    enum CodingKeys: String, CodingKey {
        case text = "t", fg = "f", bg = "b", underline = "u", flags = "l"
    }
}

// MARK: - Colour packing

extension TermColor {
    /// `-1` default, `0...255` indexed, otherwise `0x1000000 | rgb`.
    var packed: Int {
        switch self {
        case .default:            return -1
        case .indexed(let i):     return Int(i)
        case .rgb(let r, let g, let b):
            return 0x100_0000 | (Int(r) << 16) | (Int(g) << 8) | Int(b)
        }
    }

    init(packed: Int) {
        if packed < 0 { self = .default }
        else if packed <= 255 { self = .indexed(UInt8(packed)) }
        else if packed & 0x100_0000 != 0 {
            self = .rgb(UInt8((packed >> 16) & 0xFF),
                        UInt8((packed >> 8) & 0xFF),
                        UInt8(packed & 0xFF))
        } else {
            self = .default
        }
    }
}

// MARK: - Building and applying

extension SnapshotLine {

    init(_ line: Line) {
        var runs: [SnapshotRun] = []
        let end = line.trimmedLength
        var index = 0
        while index < end {
            let attrs = line[index].attrs
            var text = String()
            while index < end, line[index].attrs == attrs {
                // The trailing half of a wide glyph carries no character of
                // its own; re-measuring on restore puts it back.
                if !line[index].attrs.flags.contains(.wideTrailer) {
                    text.append(line[index].ch)
                }
                index += 1
            }
            guard !text.isEmpty else { continue }
            runs.append(SnapshotRun(text: text,
                                    fg: attrs.fg.packed,
                                    bg: attrs.bg.packed,
                                    underline: attrs.underlineColor.packed,
                                    // linkID is deliberately dropped: the
                                    // hyperlink table is not restored, and a
                                    // dangling id would point at nothing.
                                    flags: attrs.flags.rawValue))
        }
        self.init(runs: runs, wrapped: line.wrapped)
    }

    /// The width the content actually needs — the sum of every character's
    /// display width. Reconstructing at less than this silently drops the
    /// tail, which is exactly the bug that turned restored prompts into single
    /// letters when restore ran before the real column count was known.
    var contentWidth: Int {
        var width = 0
        for run in runs {
            for character in run.text { width += max(1, CharWidth.width(of: character)) }
        }
        return width
    }

    /// Rebuilds a `Line` of the given width.
    func line(width: Int) -> Line {
        var line = Line(width: width)
        var column = 0
        for run in runs {
            let attrs = CellAttributes(fg: TermColor(packed: run.fg),
                                       bg: TermColor(packed: run.bg),
                                       underlineColor: TermColor(packed: run.underline),
                                       flags: CellFlags(rawValue: run.flags),
                                       linkID: 0)
            for character in run.text {
                guard column < width else { break }
                line[column] = Cell(ch: character, attrs: attrs)
                column += 1
                // Restore the placeholder cell a double-width glyph occupies,
                // or everything after it on the line sits one column left.
                if CharWidth.width(of: character) == 2, column < width {
                    var trailer = attrs
                    trailer.flags.insert(.wideTrailer)
                    line[column] = Cell(ch: " ", attrs: trailer)
                    column += 1
                }
            }
        }
        line.wrapped = wrapped
        return line
    }
}

extension SessionSnapshot {

    /// The rule drawn between restored output and the new shell's first prompt.
    /// Faint, so it reads as chrome rather than as something a program printed.
    static func markerLine(for date: Date, width: Int) -> Line {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM HH:mm"
        let label = " session restored — saved \(formatter.string(from: date)) — earlier processes are gone "

        var line = Line(width: width)
        var attrs = CellAttributes.blank
        attrs.flags = [.faint]

        let dashes = max(0, width - label.count)
        let leading = dashes / 2
        var characters = Array(repeating: Character("─"), count: leading)
        characters.append(contentsOf: label)
        while characters.count < width { characters.append("─") }

        for (index, character) in characters.enumerated() where index < width {
            line[index] = Cell(ch: character, attrs: attrs)
        }
        return line
    }
}

// MARK: - Storage

/// Reads and writes the snapshots. One file for every tab, because they are
/// saved and restored together and a partial set is worse than none.
enum SessionStore {

    private static var directory: String { UserEnvironment.supportDirectory }

    private static var path: String { directory + "/sessions.json" }

    static func save(_ snapshots: [SessionSnapshot]) {
        guard !snapshots.isEmpty else {
            clear()
            return
        }
        do {
            try FileManager.default.createDirectory(
                atPath: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder()
            let data = try encoder.encode(Array(snapshots.prefix(SessionSnapshot.maxTabs)))
            // Atomic: a snapshot half-written when the app is killed would be
            // unreadable, and this runs precisely when that is likeliest.
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            // Losing a snapshot is not worth interrupting anyone over.
        }
    }

    static func load() -> [SessionSnapshot] {
        guard let data = FileManager.default.contents(atPath: path) else { return [] }
        return (try? JSONDecoder().decode([SessionSnapshot].self, from: data)) ?? []
    }

    static func clear() {
        try? FileManager.default.removeItem(atPath: path)
    }
}
