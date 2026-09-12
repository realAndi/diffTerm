import Foundation

/// Works out who the shell should think it is running as.
///
/// This is subtler than it looks on a rootless jailbreak. There are two
/// passwd databases: the system one at `/etc/passwd`, which says mobile's home
/// is `/var/mobile`, and the bootstrap's at `/var/jb/etc/passwd`, which says
/// `/var/jb/var/mobile`. They are genuinely different directories, and every
/// command-line tool installed by the package manager — along with the user's
/// own dotfiles, ssh keys and git config — lives under the bootstrap one.
///
/// `/var/jb/usr/bin/login`, which other terminals exec, reads the bootstrap
/// database. Matching that is what makes a shell here behave the way the rest
/// of the system expects.
enum UserEnvironment {

    struct Entry {
        var name: String
        var uid: uid_t
        var gid: gid_t
        var home: String
        var shell: String
    }

    /// Passwd files consulted in order of authority for this environment.
    private static let passwdPaths = ["/var/jb/etc/passwd", "/etc/passwd"]

    private static let cached: Entry = resolve()

    static var entry: Entry { cached }
    static var home: String { cached.home }

    /// The folder the app keeps its state in: history, sessions, the daemon
    /// socket. Named after the bundle rather than hard-coded, so a second
    /// build installed alongside the first keeps its own state instead of
    /// writing over the first's. Falls back to the product name outside an
    /// app bundle, which is where the test harness runs.
    static var supportFolderName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "diffTerm"
    }

    static var supportDirectory: String {
        NSHomeDirectory() + "/Library/Application Support/" + supportFolderName
    }
    static var userName: String { cached.name }
    static var loginShell: String { cached.shell }

    /// The home directory the *system's* passwd database gives, which is
    /// deliberately not the one above.
    ///
    /// `home` is the bootstrap's `/var/jb/var/mobile`, and that is the right
    /// answer for dotfiles, ssh keys, and everything else a shell reads. It is
    /// the wrong place to keep work: `/var/jb` is a link into
    /// `/private/preboot/<UUID>/...`, which reinstalling or updating the
    /// jailbreak replaces wholesale, taking anything stored under it. The
    /// device's own `/var/mobile` survives that, so it is where a terminal
    /// should drop you.
    static var deviceHome: String { cachedDeviceHome }

    private static let cachedDeviceHome: String = {
        if let parsed = parse(path: "/etc/passwd", uid: getuid()),
           isDirectory(parsed.home),
           logicalPath(parsed.home) == parsed.home {
            return parsed.home
        }
        return isDirectory("/var/mobile") ? "/var/mobile" : home
    }()

    private static func resolve() -> Entry {
        let uid = getuid()

        for path in passwdPaths {
            guard let parsed = parse(path: path, uid: uid) else { continue }
            // A home directory that isn't there is worse than no answer; fall
            // through to the next database rather than dropping the user into
            // a directory that does not exist.
            if isDirectory(parsed.home) { return parsed }
        }

        // Fall back to whatever libc reports, then to the conventional path.
        if let pw = getpwuid(uid) {
            let home = String(cString: pw.pointee.pw_dir)
            let shell = String(cString: pw.pointee.pw_shell)
            let name = String(cString: pw.pointee.pw_name)
            if isDirectory(home) {
                return Entry(name: name, uid: uid, gid: getgid(), home: home, shell: shell)
            }
        }

        let fallback = isDirectory("/var/jb/var/mobile") ? "/var/jb/var/mobile" : "/var/mobile"
        return Entry(name: "mobile", uid: uid, gid: getgid(),
                     home: fallback, shell: "/var/jb/usr/bin/zsh")
    }

    private static func parse(path: String, uid: uid_t) -> Entry? {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        for line in contents.split(separator: "\n") {
            guard !line.hasPrefix("#") else { continue }
            let fields = line.split(separator: ":", omittingEmptySubsequences: false)
            guard fields.count >= 7,
                  let entryUID = uid_t(fields[2]),
                  entryUID == uid else { continue }
            let gid = gid_t(fields[3]) ?? getgid()
            return Entry(name: String(fields[0]),
                         uid: entryUID,
                         gid: gid,
                         home: String(fields[5]),
                         shell: String(fields[6]))
        }
        return nil
    }

    /// The physical path `/var/jb` resolves to — e.g. on a Dopamine jailbreak,
    /// `/private/preboot/<UUID>/<name>/procursus`. Computed once.
    private static let jailbreakPhysicalRoot: String? = {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath("/var/jb", &buffer) != nil else { return nil }
        let resolved = String(cString: buffer)
        // Only meaningful if `/var/jb` is actually a link to somewhere else.
        return resolved == "/var/jb" ? nil : resolved
    }()

    /// Rewrites a fully-resolved path back to its logical `/var/jb/...` form.
    ///
    /// The shell's own `$PWD` is logical, so `%~` condenses it to `~`. But a
    /// path that came from `getcwd()` — or from a snapshot captured before
    /// this was fixed — is physical (`/private/preboot/.../procursus/...`),
    /// which does not start with `$HOME` and so shows in full. Mapping the
    /// physical jailbreak root back to `/var/jb` restores the condensed form,
    /// and — because `/var/jb` is a stable link while the physical root's name
    /// can change between boots — makes a restored directory survive a reboot.
    static func logicalPath(_ path: String) -> String {
        guard let root = jailbreakPhysicalRoot else { return path }
        if path == root { return "/var/jb" }
        if path.hasPrefix(root + "/") { return "/var/jb" + path.dropFirst(root.count) }
        return path
    }

    private static func isDirectory(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }
}
