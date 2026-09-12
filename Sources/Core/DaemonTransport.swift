import Foundation
import Darwin

/// Wire protocol shared with `Sources/Daemon/sessiond.c`. Keep in step.
enum DaemonWire {
    static var socketPath = UserEnvironment.home + "/Library/Application Support/"
        + UserEnvironment.supportFolderName + "/sessiond.sock"

    // client -> daemon
    static let list: UInt8 = 0x01, create: UInt8 = 0x02, attach: UInt8 = 0x03
    static let data: UInt8 = 0x04, resize: UInt8 = 0x05, detach: UInt8 = 0x06
    static let close: UInt8 = 0x07, ping: UInt8 = 0x08
    // daemon -> client
    static let output: UInt8 = 0x81, exit: UInt8 = 0x82, sessions: UInt8 = 0x83
    static let ok: UInt8 = 0x84, err: UInt8 = 0x85, pong: UInt8 = 0x86

    static func putU16(_ a: inout [UInt8], _ v: UInt16) {
        a.append(UInt8(v & 0xFF)); a.append(UInt8((v >> 8) & 0xFF))
    }
    static func putU32(_ a: inout [UInt8], _ v: UInt32) {
        a.append(UInt8(v & 0xFF)); a.append(UInt8((v >> 8) & 0xFF))
        a.append(UInt8((v >> 16) & 0xFF)); a.append(UInt8((v >> 24) & 0xFF))
    }
    static func u32(_ b: ArraySlice<UInt8>) -> UInt32 {
        let a = Array(b)
        return UInt32(a[0]) | (UInt32(a[1]) << 8) | (UInt32(a[2]) << 16) | (UInt32(a[3]) << 24)
    }

    /// Blocking connect to the daemon's socket. Nil if it is not listening —
    /// which is the normal "daemon not installed / not loaded" case, and the
    /// caller falls back to a local pty.
    static func connect() -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let ok = socketPath.withCString { src -> Bool in
            withUnsafeMutableBytes(of: &addr.sun_path) { raw -> Bool in
                let dst = raw.baseAddress!.assumingMemoryBound(to: CChar.self)
                let cap = raw.count
                if strlen(src) >= cap { return false }
                strncpy(dst, src, cap - 1)
                return true
            }
        }
        guard ok else { Darwin.close(fd); return nil }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, len) }
        }
        if rc != 0 { Darwin.close(fd); return nil }
        return fd
    }

    static func writeAll(_ fd: Int32, _ bytes: [UInt8]) {
        var off = 0
        bytes.withUnsafeBytes { raw in
            let base = raw.baseAddress!
            while off < bytes.count {
                let n = Darwin.write(fd, base + off, bytes.count - off)
                if n > 0 { off += n; continue }
                if n < 0 && errno == EINTR { continue }
                break
            }
        }
    }

    static func frame(_ type: UInt8, _ session: UInt32, _ payload: [UInt8] = []) -> [UInt8] {
        var f: [UInt8] = [type]
        putU32(&f, session)
        putU32(&f, UInt32(payload.count))
        f += payload
        return f
    }
}

/// Decides whether the daemon is usable and answers "which sessions are still
/// alive" at launch, so a restored tab can reattach to a live shell rather
/// than restoring a dead snapshot.
final class DaemonSessionManager {

    static let shared = DaemonSessionManager()
    private init() {}

    private var cachedAvailable: Bool?
    private var cachedAt = Date.distantPast

    /// Whether the daemon is running and reachable. Cached briefly so a burst
    /// of new sessions does not each pay a connect.
    var isAvailable: Bool {
        if let cachedAvailable, Date().timeIntervalSince(cachedAt) < 5 { return cachedAvailable }
        let fd = DaemonWire.connect()
        let up = fd != nil
        if let fd { Darwin.close(fd) }
        cachedAvailable = up
        cachedAt = Date()
        return up
    }

    /// The ids of sessions the daemon still has alive. Empty if the daemon is
    /// not reachable.
    func liveSessionIDs() -> Set<UInt32> {
        guard let fd = DaemonWire.connect() else { return [] }
        defer { Darwin.close(fd) }
        DaemonWire.writeAll(fd, DaemonWire.frame(DaemonWire.list, 0))

        // A receive timeout keeps a missing reply from hanging the launch.
        var tv = timeval(tv_sec: 0, tv_usec: 300_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var buf = [UInt8]()
        var tmp = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline {
            let n = tmp.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n <= 0 { break }
            buf.append(contentsOf: tmp[0..<n])
            // Parse frames.
            var off = 0
            while buf.count - off >= 9 {
                let type = buf[off]
                let plen = Int(DaemonWire.u32(buf[(off + 5)..<(off + 9)]))
                if buf.count - off - 9 < plen { break }
                let payload = Array(buf[(off + 9)..<(off + 9 + plen)])
                off += 9 + plen
                if type == DaemonWire.sessions {
                    var ids = Set<UInt32>()
                    guard payload.count >= 4 else { return ids }
                    let count = Int(DaemonWire.u32(payload[0..<4]))
                    var p = 4
                    for _ in 0..<count where p + 9 <= payload.count {
                        let id = DaemonWire.u32(payload[p..<(p + 4)])
                        let alive = payload[p + 8] != 0
                        if alive { ids.insert(id) }
                        p += 9
                    }
                    return ids
                }
            }
            if off > 0 { buf.removeFirst(off) }
        }
        return []
    }
}

/// A session whose shell lives in the daemon. The app is a client: it CREATEs
/// (or, for an id the daemon already has, transparently reattaches to) a
/// session and streams bytes. Killing the app leaves the shell running.
final class DaemonTransport: SessionTransport {

    var onRead: (([UInt8]) -> Void)?
    var onExit: ((Int32) -> Void)?

    private let sessionID: UInt32
    private var fd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "dev.diffterm.daemon.session")
    private var inbuf: [UInt8] = []

    init(sessionID: UInt32) { self.sessionID = sessionID }

    func start(executable: String, arguments: [String], environment: [String: String],
               workingDirectory: String, cols: Int, rows: Int) throws {
        guard let connected = DaemonWire.connect() else {
            throw NSError(domain: "diffTerm", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "session daemon is not reachable"])
        }
        fd = connected

        // CREATE payload: cols, rows, cwd, exe, argv..., \0, env..., \0.
        // The daemon treats a CREATE for an id it already has as a reattach,
        // so the same message both starts a new shell and rejoins a live one.
        var p = [UInt8]()
        DaemonWire.putU16(&p, UInt16(clamping: cols))
        DaemonWire.putU16(&p, UInt16(clamping: rows))
        func str(_ s: String) { p += Array(s.utf8); p.append(0) }
        str(workingDirectory)
        str(executable)
        for a in arguments { str(a) }
        p.append(0)
        for (k, v) in environment { str("\(k)=\(v)") }
        p.append(0)
        DaemonWire.writeAll(fd, DaemonWire.frame(DaemonWire.create, sessionID, p))

        startReading()
    }

    private func startReading() {
        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.setCancelHandler { [weak self] in
            guard let self, self.fd >= 0 else { return }
            Darwin.close(self.fd); self.fd = -1
        }
        readSource = source
        source.resume()
    }

    private func readAvailable() {
        var tmp = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = tmp.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n > 0 { inbuf.append(contentsOf: tmp[0..<n]); continue }
            if n == 0 { handleDisconnect(); return }
            if errno == EAGAIN || errno == EWOULDBLOCK { break }
            if errno == EINTR { continue }
            handleDisconnect(); return
        }
        consumeFrames()
    }

    private func consumeFrames() {
        var off = 0
        while inbuf.count - off >= 9 {
            let type = inbuf[off]
            let plen = Int(DaemonWire.u32(inbuf[(off + 5)..<(off + 9)]))
            if inbuf.count - off - 9 < plen { break }
            let payload = Array(inbuf[(off + 9)..<(off + 9 + plen)])
            off += 9 + plen
            switch type {
            case DaemonWire.output:
                onRead?(payload)
            case DaemonWire.exit:
                let code = payload.count >= 4 ? Int32(bitPattern: DaemonWire.u32(payload[0..<4])) : 0
                onExit?(code)
            default:
                break   // OK/ERR/PONG are not acted on
            }
        }
        if off > 0 { inbuf.removeFirst(off) }
    }

    private func handleDisconnect() {
        // The socket closed under us — the daemon died or was killed. Treat it
        // as an exit so the pane shows a dead session rather than hanging.
        readSource?.cancel(); readSource = nil
        DispatchQueue.main.async { [weak self] in self?.onExit?(1) }
    }

    func write(_ bytes: [UInt8]) {
        guard fd >= 0, !bytes.isEmpty else { return }
        queue.async { [weak self] in
            guard let self, self.fd >= 0 else { return }
            DaemonWire.writeAll(self.fd, DaemonWire.frame(DaemonWire.data, self.sessionID, bytes))
        }
    }

    func resize(cols: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) {
        guard fd >= 0 else { return }
        var p = [UInt8]()
        DaemonWire.putU16(&p, UInt16(clamping: cols))
        DaemonWire.putU16(&p, UInt16(clamping: rows))
        DaemonWire.putU16(&p, UInt16(clamping: pixelWidth))
        DaemonWire.putU16(&p, UInt16(clamping: pixelHeight))
        queue.async { [weak self] in
            guard let self, self.fd >= 0 else { return }
            DaemonWire.writeAll(self.fd, DaemonWire.frame(DaemonWire.resize, self.sessionID, p))
        }
    }

    /// Ends the session for good — the shell is hung up, not just detached.
    func terminate() {
        guard fd >= 0 else { return }
        let id = sessionID
        queue.async { [weak self] in
            guard let self, self.fd >= 0 else { return }
            DaemonWire.writeAll(self.fd, DaemonWire.frame(DaemonWire.close, id))
        }
        readSource?.cancel(); readSource = nil
    }

    /// Detaches without killing — the shell keeps running in the daemon. Used
    /// when the app is going away but the session should live on.
    func detach() {
        guard fd >= 0 else { return }
        let id = sessionID
        DaemonWire.writeAll(fd, DaemonWire.frame(DaemonWire.detach, id))
        readSource?.cancel(); readSource = nil
    }

    func sendSignal(_ signal: Int32) {
        // The only in-app signal is the hangup used to end a session; the
        // interactive interrupt travels as a byte through the pty.
        if signal == SIGHUP || signal == SIGTERM || signal == SIGKILL { terminate() }
    }

    /// The daemon owns the pty, so the app cannot read the foreground process
    /// name locally. Titles fall back to the shell name and OSC titles, which
    /// most programs set anyway.
    func foregroundProcessName() -> String? { nil }
}
