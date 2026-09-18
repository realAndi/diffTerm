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
///
/// On roothide the bootstrap's database is written for the bootstrap's own
/// tools, so the paths in it are in the shell's spelling (`/var/mobile` meaning
/// the bootstrap's copy) and are translated on the way in. Everything this type
/// hands out is in the app's spelling; see `JailbreakRoot`.
enum UserEnvironment {

    struct Entry {
        var name: String
        var uid: uid_t
        var gid: gid_t
        var home: String
        var shell: String
    }

    /// Passwd files consulted in order of authority for this environment, and
    /// whether each is written in the shell's spelling. The bootstrap's is; the
    /// system's is not.
    private static let passwdSources: [(path: String, shellSpelling: Bool)] = [
        (JailbreakRoot.jb("/etc/passwd"), true),
        ("/etc/passwd", false),
    ]

    private static let cached: Entry = resolve()

    static var entry: Entry { cached }
    static var home: String { cached.home }

    /// The folder the app keeps its state in: history and saved sessions.
    /// Named after the bundle rather than hard-coded, so a second build
    /// installed alongside the first keeps its own state instead of writing
    /// over the first's. Falls back to the product name outside an app
    /// bundle, which is where the test harness runs.
    static var supportFolderName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "diffTerm"
    }

    static var supportDirectory: String {
        NSHomeDirectory() + "/Library/Application Support/" + supportFolderName
    }
    static var userName: String { cached.name }
    static var loginShell: String { cached.shell }

    /// What to hand the shell as `$LC_CTYPE`, or nil if nothing on this device
    /// gives a UTF-8 character type.
    ///
    /// Terminals conventionally export `en_US.UTF-8`, and on iOS that is not a
    /// cosmetic mistake but a crash. The system ships exactly one compiled
    /// locale — `/usr/share/locale/UTF-8`, named after the bare codeset — so
    /// `setlocale(LC_CTYPE, "en_US.UTF-8")` returns NULL here. readline 8.2
    /// dereferences that NULL inside `_rl_init_locale`, which means bash dies
    /// with SIGSEGV in `rl_initialize` before printing its first prompt: an
    /// interactive bash was impossible in diffTerm, and is impossible in any
    /// other terminal that exports the conventional value. zsh never showed
    /// it because it uses ZLE rather than readline.
    ///
    /// So ask the system rather than assuming, through the C bridge — see
    /// `dt_locale_is_utf8` for why the question cannot be asked from Swift.
    static let ctypeLocale: String? = {
        // Conventional names first, so an iOS that does ship them is used the
        // way it would be anywhere else; the bare codeset is the fallback that
        // actually resolves today.
        for name in ["en_US.UTF-8", "C.UTF-8", "UTF-8"] where dt_locale_is_utf8(name) != 0 {
            return name
        }
        return nil
    }()

    /// Whether `name` names a locale complete enough for `$LANG` or `$LC_ALL`,
    /// which stand in for every category rather than just the character type.
    ///
    /// The distinction is the whole reason a terminal has to treat those two
    /// differently from `LC_CTYPE`: `UTF-8` is a perfectly good character type
    /// here and not a locale, so using it for `$LANG` makes
    /// `setlocale(LC_ALL, "")` fail and takes the character type down with it.
    static func isCompleteLocale(_ name: String) -> Bool {
        // An empty value means "consult the environment", which is harmless.
        guard !name.isEmpty else { return true }
        return dt_locale_is_complete(name) != 0
    }

    /// The home directory the *system's* passwd database gives, which is
    /// deliberately not the one above.
    ///
    /// `home` is the bootstrap's `/var/jb/var/mobile`, and that is the right
    /// answer for dotfiles, ssh keys, and everything else a shell reads. It is
    /// the wrong place to keep work: `/var/jb` is a link into
    /// `/private/preboot/<UUID>/...`, which reinstalling or updating the
    /// jailbreak replaces wholesale, taking anything stored under it. The
    /// device's own `/var/mobile` survives that, so it is where a terminal
    /// should drop you. On roothide the whole bootstrap is replaced on every
    /// install, which makes this matter more, not less.
    static var deviceHome: String { cachedDeviceHome }

    private static let cachedDeviceHome: String = {
        if let parsed = parse(path: "/etc/passwd", uid: getuid(), shellSpelling: false),
           isDirectory(parsed.home),
           !JailbreakRoot.current.contains(parsed.home) {
            return parsed.home
        }
        return isDirectory("/var/mobile") ? "/var/mobile" : home
    }()

    private static func resolve() -> Entry {
        let uid = getuid()

        for source in passwdSources {
            guard let parsed = parse(path: source.path, uid: uid,
                                     shellSpelling: source.shellSpelling) else { continue }
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

        let bootstrapHome = JailbreakRoot.jb("/var/mobile")
        let fallback = isDirectory(bootstrapHome) ? bootstrapHome : "/var/mobile"
        return Entry(name: "mobile", uid: uid, gid: getgid(),
                     home: fallback, shell: JailbreakRoot.jb("/usr/bin/zsh"))
    }

    private static func parse(path: String, uid: uid_t, shellSpelling: Bool) -> Entry? {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        for line in contents.split(separator: "\n") {
            guard !line.hasPrefix("#") else { continue }
            let fields = line.split(separator: ":", omittingEmptySubsequences: false)
            guard fields.count >= 7,
                  let entryUID = uid_t(fields[2]),
                  entryUID == uid else { continue }
            let gid = gid_t(fields[3]) ?? getgid()
            let spell: (Substring) -> String = { field in
                shellSpelling ? JailbreakRoot.fromShell(String(field)) : String(field)
            }
            return Entry(name: String(fields[0]),
                         uid: entryUID,
                         gid: gid,
                         home: spell(fields[5]),
                         shell: spell(fields[6]))
        }
        return nil
    }

    /// Rewrites a fully-resolved path back to its logical `/var/jb/...` form —
    /// or, on roothide, to the `.jbroot-…` name. See `JailbreakRoot.canonical`.
    ///
    /// The shell's own `$PWD` is logical, so `%~` condenses it to `~`. But a
    /// path that came from `getcwd()` — or from a snapshot captured before
    /// this was fixed — is physical (`/private/preboot/.../procursus/...`),
    /// which does not start with `$HOME` and so shows in full. Mapping the
    /// physical jailbreak root back to `/var/jb` restores the condensed form,
    /// and — because `/var/jb` is a stable link while the physical root's name
    /// can change between boots — makes a restored directory survive a reboot.
    static func logicalPath(_ path: String) -> String {
        JailbreakRoot.current.canonical(path)
    }

    private static func isDirectory(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }
}
