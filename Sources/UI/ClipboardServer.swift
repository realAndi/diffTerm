import UIKit

/// Serves the `pbcopy` / `pbpaste` helpers shipped in the app bundle over a
/// per-launch unix socket, whose path is handed to child processes as
/// `DIFFTERM_CLIPBOARD`.
///
/// This exists because the bootstrap's own pbcopy cannot reach the pasteboard
/// from a command-line process on a rootless jailbreak — and, worse, exits 0
/// while failing, so every tool that copies believes it worked. The app is a
/// UIKit process and can touch `UIPasteboard` perfectly well, so it does the
/// job on the helper's behalf.
///
/// Writes are unconditional: a program that can already print to the terminal
/// can set the clipboard through OSC 52 anyway, so gating them would buy
/// nothing. **Reads are gated**, because they are the direction that leaks.
/// The socket is the only way to read the clipboard here — OSC 52 reads stay
/// refused — which means a read always comes from a local process this app
/// started, never from the far end of an ssh connection, and the user is asked
/// the first time unless they have said otherwise.
final class ClipboardServer {

    static let shared = ClipboardServer()

    /// Path handed to children as `DIFFTERM_CLIPBOARD`; nil until `start()`
    /// succeeds, and children are then launched without the variable.
    private(set) var socketPath: String?

    private var listenFD: Int32 = -1
    private var directory: String?
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "dev.diffterm.clipboard")

    /// Answered once per launch when the policy is `.ask`, so a shell script
    /// in a loop cannot bury the user in alerts. Connections are served
    /// concurrently, so the answer is behind a lock.
    private var readAllowedThisLaunch: Bool?
    private let gateLock = NSLock()

    private init() {}

    // MARK: - Lifecycle

    @discardableResult
    func start() -> Bool {
        guard listenFD < 0 else { return true }
        guard let dir = makeDirectory() else { return false }

        let path = dir + "/clip.sock"
        // sun_path is 104 bytes on Darwin, and a path that does not fit would
        // otherwise be silently truncated into a socket nobody can reach.
        guard path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            try? FileManager.default.removeItem(atPath: dir)
            return false
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            try? FileManager.default.removeItem(atPath: dir)
            return false
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let sunPathCapacity = MemoryLayout.size(ofValue: addr.sun_path)
        withUnsafeMutablePointer(to: &addr.sun_path) { raw in
            raw.withMemoryRebound(to: CChar.self, capacity: sunPathCapacity) { dst in
                _ = strlcpy(dst, path, sunPathCapacity)
            }
        }

        unlink(path)
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            close(fd)
            try? FileManager.default.removeItem(atPath: dir)
            return false
        }
        chmod(path, 0o600)

        // Non-blocking, so the accept loop below can drain every pending
        // connection and stop on EAGAIN rather than parking the source's
        // queue on the next accept().
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        listenFD = fd
        directory = dir
        socketPath = path

        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.acceptOne() }
        src.resume()
        source = src
        return true
    }

    func stop() {
        source?.cancel()
        source = nil
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        if let dir = directory { try? FileManager.default.removeItem(atPath: dir) }
        directory = nil
        socketPath = nil
    }

    /// A private 0700 directory to hold the socket. The random name matters:
    /// the parent is world-readable, so an unguessable path is what keeps
    /// another process on the device from finding the socket to connect to.
    private func makeDirectory() -> String? {
        var candidates = [NSTemporaryDirectory(), "/var/tmp", NSHomeDirectory() + "/Library/Caches"]
        candidates = candidates.map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }

        var random = [UInt8](repeating: 0, count: 8)
        for i in random.indices { random[i] = UInt8.random(in: 0...255) }
        let suffix = random.map { String(format: "%02x", $0) }.joined()

        for parent in candidates {
            let dir = "\(parent)/diffterm-\(getuid())-\(suffix)"
            do {
                try FileManager.default.createDirectory(
                    atPath: dir, withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700])
                return dir
            } catch {
                continue
            }
        }
        return nil
    }

    // MARK: - Connections

    private func acceptOne() {
        // Drain: a script calling pbcopy in a loop can leave more than one
        // connection queued behind a single readable event.
        while true {
            let fd = accept(listenFD, nil, nil)
            guard fd >= 0 else { return }
            // One short-lived connection per invocation of the helper; handling
            // it off the accept queue keeps a read prompt, which can sit on
            // screen for a minute, from blocking the listener.
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.serve(fd)
                close(fd)
            }
        }
    }

    private func serve(_ fd: Int32) {
        guard let request = readLine(fd, limit: 64) else { return }

        if request == "PASTE" {
            guard readIsPermitted() else {
                _ = write(fd, "ERR clipboard reads are turned off in diffTerm's settings\n", 57)
                return
            }
            let text = DispatchQueue.main.sync { UIPasteboard.general.string ?? "" }
            let bytes = Array(text.utf8)
            reply(fd, "DATA \(bytes.count)\n")
            bytes.withUnsafeBufferPointer { _ = writeAll(fd, $0.baseAddress, bytes.count) }
            return
        }

        guard request.hasPrefix("COPY "),
              let count = Int(request.dropFirst(5)), count >= 0, count <= 1 << 20 else {
            reply(fd, "ERR malformed request\n")
            return
        }

        guard let payload = readExactly(fd, count: count) else {
            reply(fd, "ERR short write\n")
            return
        }
        guard let text = String(data: Data(payload), encoding: .utf8) else {
            reply(fd, "ERR clipboard text must be UTF-8\n")
            return
        }
        DispatchQueue.main.sync { UIPasteboard.general.string = text }
        reply(fd, "OK\n")
    }

    private func reply(_ fd: Int32, _ line: String) {
        let bytes = Array(line.utf8)
        bytes.withUnsafeBufferPointer { _ = writeAll(fd, $0.baseAddress, bytes.count) }
    }

    // MARK: - The read gate

    private func readIsPermitted() -> Bool {
        switch Preferences.shared.clipboardReadAccess {
        case .allow: return true
        case .deny:  return false
        case .ask:   break
        }
        gateLock.lock()
        let answered = readAllowedThisLaunch
        gateLock.unlock()
        if let answered { return answered }

        let semaphore = DispatchSemaphore(value: 0)
        var allowed = false
        DispatchQueue.main.async {
            guard let presenter = Self.topViewController() else {
                semaphore.signal()
                return
            }
            let alert = UIAlertController(
                title: "Read the clipboard?",
                message: "A program running in this terminal is asking to read what is on your clipboard. "
                       + "Allow it only if you expected it — `pbpaste` and editors do, most things do not.",
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Don't Allow", style: .cancel) { _ in
                allowed = false
                semaphore.signal()
            })
            alert.addAction(UIAlertAction(title: "Allow", style: .default) { _ in
                allowed = true
                semaphore.signal()
            })
            presenter.present(alert, animated: true)
        }

        // If nothing answers — the app went to the background mid-prompt —
        // the safe default is the one that reveals nothing.
        if semaphore.wait(timeout: .now() + 60) == .timedOut { return false }
        gateLock.lock()
        readAllowedThisLaunch = allowed
        gateLock.unlock()
        return allowed
    }

    private static func topViewController() -> UIViewController? {
        var top = UIApplication.shared.windows.first(where: { $0.isKeyWindow })?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }

    // MARK: - Framing

    private func readLine(_ fd: Int32, limit: Int) -> String? {
        var bytes: [UInt8] = []
        var c: UInt8 = 0
        while bytes.count < limit {
            let n = read(fd, &c, 1)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return nil }
            if c == UInt8(ascii: "\n") { return String(decoding: bytes, as: UTF8.self) }
            bytes.append(c)
        }
        return nil
    }

    private func readExactly(_ fd: Int32, count: Int) -> [UInt8]? {
        guard count > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: count)
        var filled = 0
        while filled < count {
            let n = buffer.withUnsafeMutableBytes { raw -> Int in
                read(fd, raw.baseAddress!.advanced(by: filled), count - filled)
            }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return nil }
            filled += n
        }
        return buffer
    }

    private func writeAll(_ fd: Int32, _ base: UnsafeRawPointer?, _ count: Int) -> Bool {
        guard let base = base, count > 0 else { return true }
        var written = 0
        while written < count {
            let n = write(fd, base.advanced(by: written), count - written)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return false }
            written += n
        }
        return true
    }
}
