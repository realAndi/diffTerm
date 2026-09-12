import Foundation
import Compression

/// The static shape of one command, as far as completion needs it: what
/// subcommands it has, what options they take, what kind of thing each
/// argument is.
///
/// Read from the compact JSON `Tools/SpecConverter.swift` produces out of
/// Fig's specs. The keys are one letter each because the files ship in the
/// app; the property names here are the readable ones.
struct CompletionSpec: Decodable {

    var names: [String]
    var subcommands: [CompletionSpec]
    var options: [Option]
    var args: [Arg]
    var hidden: Bool
    var deprecated: Bool
    var priority: Double?

    struct Option: Decodable {
        var names: [String]
        var args: [Arg]
        var isRepeatable: Bool
        /// `=` or similar when the value must be joined to the flag.
        var requiresSeparator: String?
        var hidden: Bool
        var deprecated: Bool
        var priority: Double?

        private enum Keys: String, CodingKey { case n, a, r, q, h, d, p }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            names = try c.decodeIfPresent([String].self, forKey: .n) ?? []
            args = try c.decodeIfPresent([Arg].self, forKey: .a) ?? []
            isRepeatable = (try c.decodeIfPresent(Int.self, forKey: .r) ?? 0) != 0
            requiresSeparator = try c.decodeIfPresent(String.self, forKey: .q)
            hidden = (try c.decodeIfPresent(Int.self, forKey: .h) ?? 0) != 0
            deprecated = (try c.decodeIfPresent(Int.self, forKey: .d) ?? 0) != 0
            priority = try c.decodeIfPresent(Double.self, forKey: .p)
        }
    }

    struct Arg: Decodable {
        var name: String?
        var isOptional: Bool
        var isVariadic: Bool
        /// The argument is itself a command — `sudo`, `time`, `xargs`.
        var isCommand: Bool
        /// Fig's templates: `filepaths`, `folders`, `history`, `help`.
        var templates: [String]
        /// Fixed values the spec lists outright.
        var suggestions: [String]

        private enum Keys: String, CodingKey { case n, o, v, c, t, g }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            name = try c.decodeIfPresent(String.self, forKey: .n)
            isOptional = (try c.decodeIfPresent(Int.self, forKey: .o) ?? 0) != 0
            isVariadic = (try c.decodeIfPresent(Int.self, forKey: .v) ?? 0) != 0
            isCommand = (try c.decodeIfPresent(Int.self, forKey: .c) ?? 0) != 0
            templates = try c.decodeIfPresent([String].self, forKey: .t) ?? []
            suggestions = try c.decodeIfPresent([String].self, forKey: .g) ?? []
        }

        var wantsFolders: Bool { templates.contains("folders") }
        var wantsFiles: Bool { templates.contains("filepaths") }
    }

    private enum Keys: String, CodingKey { case n, s, o, a, h, d, p }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        names = try c.decodeIfPresent([String].self, forKey: .n) ?? []
        subcommands = try c.decodeIfPresent([CompletionSpec].self, forKey: .s) ?? []
        options = try c.decodeIfPresent([Option].self, forKey: .o) ?? []
        args = try c.decodeIfPresent([Arg].self, forKey: .a) ?? []
        hidden = (try c.decodeIfPresent(Int.self, forKey: .h) ?? 0) != 0
        deprecated = (try c.decodeIfPresent(Int.self, forKey: .d) ?? 0) != 0
        priority = try c.decodeIfPresent(Double.self, forKey: .p)
    }

    /// The subcommand a token names, by any of its aliases.
    func subcommand(named token: String) -> CompletionSpec? {
        subcommands.first { $0.names.contains(token) }
    }

    /// The option a token names — `--force`, `-f` — by any of its aliases.
    func option(named token: String) -> Option? {
        options.first { $0.names.contains(token) }
    }
}

/// Loads specs from the bundle on demand and keeps the recent ones.
///
/// One file per command, read the first time that command is typed. A
/// session touches a handful of commands, and `git`'s spec alone is tens of
/// kilobytes of JSON, so loading all seven hundred up front would be memory
/// spent on tools that are never run.
final class SpecStore {

    static let shared = SpecStore()

    /// Where the JSON lives. The app's is inside the bundle; the tests point
    /// this at the checked-in `Resources/Specs`.
    var directory: String

    private var cache: [String: CompletionSpec?] = [:]
    private let lock = NSLock()

    init(directory: String? = nil) {
        self.directory = directory ?? (Bundle.main.bundlePath + "/specs")
    }

    /// The spec for a command, or nil when there is none — cached either way,
    /// so an unknown command costs one failed `stat` per session rather than
    /// one per keystroke.
    func spec(for command: String) -> CompletionSpec? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[command] { return cached }

        let loaded = load(command)
        if cache.count > 48 { cache.removeAll(keepingCapacity: true) }
        cache[command] = loaded
        return loaded
    }

    private func load(_ command: String) -> CompletionSpec? {
        // A command name is a path component and nothing else. `../x` is not
        // going to find a spec, and must not be allowed to try.
        guard !command.isEmpty, !command.contains("/"), !command.hasPrefix(".") else { return nil }
        let fm = FileManager.default
        let base = directory + "/" + command
        let data: Data?
        if let packed = fm.contents(atPath: base + ".z") {
            data = SpecStore.unpack(packed)
        } else {
            data = fm.contents(atPath: base + ".json")
        }
        guard let data else { return nil }
        return try? JSONDecoder().decode(CompletionSpec.self, from: data)
    }

    // MARK: - Packing

    /// Deflates a spec for the bundle: four bytes of little-endian original
    /// length, then a raw zlib stream. libcompression wants to be told the
    /// output size up front, which is what the prefix is for.
    static func pack(_ json: String) -> Data? {
        let source = Array(json.utf8)
        guard !source.isEmpty, source.count < 64 << 20 else { return nil }
        var destination = [UInt8](repeating: 0, count: source.count + 64)
        let produced = compression_encode_buffer(&destination, destination.count,
                                                 source, source.count, nil, COMPRESSION_ZLIB)
        guard produced > 0 else { return nil }
        let length = UInt32(source.count)
        var out = Data([UInt8(length & 0xFF), UInt8((length >> 8) & 0xFF),
                        UInt8((length >> 16) & 0xFF), UInt8((length >> 24) & 0xFF)])
        out.append(contentsOf: destination[0..<produced])
        return out
    }

    static func unpack(_ packed: Data) -> Data? {
        guard packed.count > 4 else { return nil }
        let bytes = [UInt8](packed)
        let length = Int(bytes[0]) | Int(bytes[1]) << 8 | Int(bytes[2]) << 16 | Int(bytes[3]) << 24
        // A spec is tens of kilobytes at most; a length claiming otherwise is
        // a corrupt file, not a big spec.
        guard length > 0, length < 16 << 20 else { return nil }
        var destination = [UInt8](repeating: 0, count: length)
        let produced = bytes.withUnsafeBufferPointer { buffer -> Int in
            compression_decode_buffer(&destination, length,
                                      buffer.baseAddress! + 4, buffer.count - 4,
                                      nil, COMPRESSION_ZLIB)
        }
        guard produced == length else { return nil }
        return Data(destination)
    }

    var isAvailable: Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: directory, isDirectory: &isDir) && isDir.boolValue
    }
}
