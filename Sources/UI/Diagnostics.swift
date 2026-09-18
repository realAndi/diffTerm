import Foundation

/// What to show when the terminal itself goes wrong, and where to send people.
///
/// A user once reported only "error 127": their shell could not be found, and
/// the screen said nothing more than "exited with status 127", which told
/// neither them nor us why. Every failure the app shows now carries the facts
/// that decide whether a shell can start, and a link to report it with those
/// facts already filled in.
enum Diagnostics {

    static let issuesURL = "https://github.com/realAndi/diffTerm/issues"

    /// The facts about this device and this launch, one `(label, value)` per
    /// line. `shell` is the path the app tried to run, in its own spelling.
    static func facts(shell: String?, workingDirectory: String?) -> [(String, String)] {
        let fm = FileManager.default
        var facts: [(String, String)] = [
            ("version", DiffTermVersion.full),
            ("system", systemDescription()),
            ("jailbreak", describe(JailbreakRoot.current)),
        ]
        if let shell {
            let state: String
            if fm.isExecutableFile(atPath: shell) {
                state = "found"
            } else if fm.fileExists(atPath: shell) {
                state = "present, but not executable"
            } else {
                state = "missing"
            }
            facts.append(("shell", "\(shell) (\(state))"))
        }
        let configured = Preferences.shared.shellPath.trimmingCharacters(in: .whitespaces)
        facts.append(("shell setting", configured.isEmpty ? "Automatic" : configured))
        facts.append(("passwd shell", UserEnvironment.loginShell.isEmpty ? "none" : UserEnvironment.loginShell))
        facts.append(("home", UserEnvironment.home))
        if let workingDirectory { facts.append(("directory", workingDirectory)) }
        return facts
    }

    /// A failure laid out for the terminal: the headline in red, the facts
    /// dimmed beneath it, and a link to report it. Also written to the system
    /// log, which is where anyone reading `oslog` or Console will look.
    static func terminalReport(headline: String, facts: [(String, String)]) -> String {
        log(headline: headline, facts: facts)

        let width = facts.map { $0.0.count }.max() ?? 0
        var text = "\r\n\u{1B}[1;31mdiffTerm:\u{1B}[0m \(headline)\r\n\r\n\u{1B}[2m"
        for (label, value) in facts {
            let pad = String(repeating: " ", count: width - label.count)
            text += "  \(label)\(pad)  \(value)\r\n"
        }
        text += "\u{1B}[0m\r\n"
        text += "  If this looks wrong, please open an issue on GitHub with the\r\n"
        text += "  lines above. Tap the link to start one with them filled in:\r\n"
        // OSC 8: the text reads as the issues page, and a tap offers the new
        // issue with the report in it. The URI is percent-encoded down to
        // unreserved characters, so nothing in it can end the sequence early.
        let target = newIssueURL(headline: headline, facts: facts)
        text += "  \u{1B}]8;;\(target)\u{1B}\\\(issuesURL)\u{1B}]8;;\u{1B}\\\r\n"
        return text
    }

    /// A new-issue page with the headline as its title and the facts in its
    /// body, so a report arrives with what is needed to act on it.
    static func newIssueURL(headline: String, facts: [(String, String)]) -> String {
        let body = "**What happened**\n\n\(headline)\n\n**Details**\n\n```\n"
            + facts.map { "\($0.0): \($0.1)" }.joined(separator: "\n")
            + "\n```\n\n**What I was doing**\n\n"
        let url = issuesURL + "/new?title=" + encode(headline) + "&body=" + encode(body)
        // The parser drops an OSC longer than 8 KB, and with it the link.
        return url.utf8.count < 7000 ? url : issuesURL + "/new?title=" + encode(headline)
    }

    /// What an exit status means, for a shell that stopped as soon as it
    /// started. Nil when the number alone says nothing useful.
    static func meaning(ofExitStatus code: Int32) -> String? {
        switch code {
        case 126:
            return "found, but not allowed to run"
        case 127:
            return "a program could not be found or started"
        case 129...192:
            let signal = code - 128
            var text = "killed by signal \(signal)"
            if let name = strsignal(signal) { text += " (\(String(cString: name)))" }
            if signal == SIGKILL {
                text += "; on a jailbroken device this is often iOS rejecting a program's code signature"
            }
            return text
        default:
            return nil
        }
    }

    // MARK: - Pieces

    private static func log(headline: String, facts: [(String, String)]) {
        let lines = facts.map { "  \($0.0): \($0.1)" }.joined(separator: "\n")
        NSLog("diffTerm: %@\n%@", headline, lines)
    }

    static func describe(_ layout: JailbreakRoot.Layout) -> String {
        switch layout.scheme {
        case .rootless:
            var text = "rootless, bootstrap at \(layout.prefix)"
            if let physical = layout.physical { text += " → \(physical)" }
            return text
        case .roothide:
            var text = "roothide, bootstrap at \(layout.prefix)"
            if let physical = layout.physical { text += " → \(physical)" }
            return text
        case .rootful:
            return "rootful or none: no /var/jb and no roothide root found"
        }
    }

    private static func systemDescription() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        var version = "\(v.majorVersion).\(v.minorVersion)"
        if v.patchVersion != 0 { version += ".\(v.patchVersion)" }
        var text = "iOS \(version)"
        if let build = sysctlString("kern.osversion") { text += " (\(build))" }
        if let machine = sysctlString("hw.machine") { text += ", \(machine)" }
        return text
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    /// ASCII unreserved characters only: `.alphanumerics` would let accented
    /// letters in a path through unencoded, and `URL(string:)` rejects those.
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func encode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }
}
