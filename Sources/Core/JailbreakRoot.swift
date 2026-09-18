import Foundation

/// Where the jailbreak's bootstrap is, and how to spell a path for whoever is
/// going to read it.
///
/// On a rootless jailbreak the bootstrap is at `/var/jb`, and there is only
/// one name for any file: the app and every shell it starts agree. On roothide
/// (Relaxin, RootHide Bootstrap) it is at a random
/// `/var/containers/Bundle/Application/.jbroot-<16 hex>`, and every program
/// the bootstrap ships is built against a shim that makes that directory its
/// `/` — to them the real root is `/rootfs`. This app is built outside that
/// toolchain and is not shimmed. So the same file has two names:
///
///     the app:    /var/containers/Bundle/Application/.jbroot-…/usr/bin/zsh
///     the shell:  /usr/bin/zsh
///     the app:    /var/mobile/Documents
///     the shell:  /rootfs/var/mobile/Documents
///
/// The rule the rest of the app follows:
///
/// - A path the app holds, stats, opens, execs or chdirs to is in the app's
///   spelling. `jb("/usr/bin/zsh")` is how a fixed bootstrap path is written.
/// - A path a shell will read — an environment variable, an argument to a
///   bootstrap tool, text typed at a prompt, a line in an rc file — goes
///   through `toShell` on the way out.
/// - A path a shell produced — OSC 7, a word on the command line — comes back
///   through `fromShell`.
/// - A path that is stored — preferences, snapshots, history — is kept in the
///   shell's spelling. It has no random part in it, so it survives the
///   jailbreak being reinstalled, and it is what the user saw and typed.
///
/// On rootless and rootful both translations are the identity, which is what
/// lets each call site be written once rather than branching on the scheme.
enum JailbreakRoot {

    enum Scheme: String {
        case rootless, roothide, rootful
    }

    struct Layout: Equatable {
        var scheme: Scheme
        /// The bootstrap's location in the app's spelling: `/var/jb`, the
        /// `.jbroot-…` directory, or `""` when there is no separate bootstrap.
        var prefix: String
        /// What `prefix` resolves to, when that is a different string. `/var/jb`
        /// is a link into `/private/preboot/<UUID>/...`, and `getcwd` hands back
        /// the resolved form, so both spellings have to be recognised.
        var physical: String?

        /// A fixed bootstrap path, spelled for the app. The replacement for
        /// every `"/var/jb" + path` this codebase used to write out by hand.
        func jb(_ path: String) -> String {
            if path == "/" { return prefix.isEmpty ? "/" : prefix }
            return prefix + path
        }

        /// A physical path mapped back to the stable `prefix` spelling. The
        /// physical name can change between installs; the prefix is what the
        /// rest of the system uses.
        func canonical(_ path: String) -> String {
            guard let physical, let rest = Layout.remainder(of: path, under: physical) else { return path }
            return prefix + rest
        }

        /// Whether a path is inside the bootstrap, under either spelling.
        func contains(_ path: String) -> Bool {
            guard !prefix.isEmpty else { return false }
            return Layout.remainder(of: path, under: prefix) != nil
                || physical.flatMap { Layout.remainder(of: path, under: $0) } != nil
        }

        /// A path the shell produced, spelled for the app.
        ///
        /// Idempotent: a path that is already in the app's spelling — under
        /// the prefix — is left alone, so translating twice is harmless. That
        /// is safe because the shell never sees the prefix; to it there is no
        /// such directory.
        func fromShell(_ path: String) -> String {
            guard scheme == .roothide, path.hasPrefix("/") else { return path }
            if let rest = Layout.remainder(of: path, under: "/rootfs") {
                return rest.isEmpty ? "/" : rest
            }
            if contains(path) { return canonical(path) }
            return jb(path)
        }

        /// A path the app holds, spelled for a shell.
        ///
        /// Not idempotent, and it cannot be: `/usr/bin/zsh` is a real path in
        /// both spellings and they name different files. Convert once, at the
        /// point the path leaves the app. The one courtesy is `/rootfs/...`,
        /// which does not exist on the real root and so can only already be
        /// in the shell's spelling.
        func toShell(_ path: String) -> String {
            guard scheme == .roothide, path.hasPrefix("/") else { return path }
            if let rest = Layout.remainder(of: path, under: prefix)
                ?? physical.flatMap({ Layout.remainder(of: path, under: $0) }) {
                return rest.isEmpty ? "/" : rest
            }
            if Layout.remainder(of: path, under: "/rootfs") != nil { return path }
            return path == "/" ? "/rootfs" : "/rootfs" + path
        }

        /// The part of `path` after `root`, including its leading slash; `""`
        /// for the root itself; nil if `path` is not under it. A name that
        /// merely starts with the same characters (`/var/jbx`) is not under it.
        static func remainder(of path: String, under root: String) -> String? {
            guard !root.isEmpty else { return nil }
            if path == root { return "" }
            let base = root.hasSuffix("/") ? String(root.dropLast()) : root
            guard path.hasPrefix(base + "/") else { return nil }
            return String(path.dropFirst(base.count))
        }
    }

    /// This device's layout, worked out once at launch. Never cached anywhere
    /// longer-lived than the process: the roothide name changes every time the
    /// jailbreak is installed.
    static let current: Layout = discover()

    static var scheme: Scheme { current.scheme }
    static func jb(_ path: String) -> String { current.jb(path) }
    static func fromShell(_ path: String) -> String { current.fromShell(path) }
    static func toShell(_ path: String) -> String { current.toShell(path) }

    // MARK: - Discovery

    static let roothideContainers = "/var/containers/Bundle/Application"
    static let roothideNamePrefix = ".jbroot-"

    /// In order, stopping at the first that answers:
    ///
    /// 1. A `.jbroot` link beside our own executable. roothide makes one in
    ///    every directory that holds a Mach-O — dpkg at install time, the
    ///    jailbreak when it loads a binary — so its presence says how *this*
    ///    copy of the app was installed, which outranks anything else on disk.
    /// 2. `/var/jb`. Rootless (Dopamine, palera1n rootless) — unless it is
    ///    only a compatibility link to `/`, which some rootful setups
    ///    (palera1n rootful) carry. That is not a separate bootstrap, and
    ///    treating it as one would put every path on the device inside it.
    /// 3. A `.jbroot-<16 hex>` directory with a bootstrap in it. roothide, for
    ///    the case where the link is missing: a hand-copied bundle, or the
    ///    test harness, which does not live in a bundle at all.
    /// 4. Nothing: a rootful jailbreak or none. Every translation is then the
    ///    identity and fixed paths are used as written.
    static func discover(bundlePath: String = Bundle.main.bundlePath,
                         containers: String = roothideContainers,
                         rootless: String = "/var/jb") -> Layout {
        let fm = FileManager.default

        let link = bundlePath + "/.jbroot"
        if (try? fm.destinationOfSymbolicLink(atPath: link)) != nil,
           let resolved = realPath(link), isDirectory(resolved) {
            // Prefer the `.jbroot-…` name for the prefix, when one resolves to
            // the same place: it is the spelling the rest of the system uses.
            let named = roothideCandidates(in: containers).first { realPath($0) == resolved }
            let prefix = named ?? resolved
            return Layout(scheme: .roothide, prefix: prefix,
                          physical: resolved == prefix ? nil : resolved)
        }

        if isDirectory(rootless), realPath(rootless) != "/" {
            let resolved = realPath(rootless)
            return Layout(scheme: .rootless, prefix: rootless,
                          physical: resolved == rootless ? nil : resolved)
        }

        let candidates = roothideCandidates(in: containers)
        if let newest = candidates.max(by: { modified($0) < modified($1) }) {
            let resolved = realPath(newest)
            return Layout(scheme: .roothide, prefix: newest,
                          physical: resolved == newest ? nil : resolved)
        }

        return Layout(scheme: .rootful, prefix: "", physical: nil)
    }

    /// Whether a directory name has the shape roothide gives its root:
    /// `.jbroot-` and sixteen hex digits. libroothide also checksums the
    /// digits, but a directory of that name holding a bootstrap is evidence
    /// enough, and it keeps this from depending on a detail that could change.
    static func isRoothideName(_ name: String) -> Bool {
        guard name.hasPrefix(roothideNamePrefix) else { return false }
        let digits = name.dropFirst(roothideNamePrefix.count)
        return digits.count == 16 && digits.allSatisfy(\.isHexDigit)
    }

    /// `.jbroot-…` directories under `containers` that contain a bootstrap —
    /// more than one only if an old install was left behind.
    private static func roothideCandidates(in containers: String) -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: containers) else { return [] }
        return names.filter(isRoothideName)
            .map { containers + "/" + $0 }
            .filter { isDirectory($0 + "/usr/bin") }
    }

    private static func realPath(_ path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(path, &buffer) != nil else { return nil }
        return String(cString: buffer)
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    private static func modified(_ path: String) -> Date {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return attributes?[.modificationDate] as? Date ?? .distantPast
    }
}
