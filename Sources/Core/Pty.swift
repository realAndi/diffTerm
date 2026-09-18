import Foundation

enum PtyError: LocalizedError {
    case spawnFailed(Int32)
    case notRunning

    var errorDescription: String? {
        switch self {
        case .spawnFailed(let code):
            // dt_spawn_pty fails before exec only when it cannot get a
            // pseudo-terminal or fork; an exec failure is reported by the
            // child itself, on the terminal.
            return "Couldn't open a terminal for the shell: \(String(cString: strerror(code))) (errno \(code))."
        case .notRunning:
            return "The shell is not running."
        }
    }
}

/// Owns one pseudo-terminal and the process on the far end of it.
///
/// Reads run on a private serial queue and are handed up in whatever chunk
/// size the kernel gives us; batching for the sake of the UI is the session's
/// job, not this class's.
final class Pty {

    private(set) var masterFD: Int32 = -1
    private(set) var pid: pid_t = -1
    private(set) var isRunning = false

    /// Called on `ioQueue` with each chunk read from the child.
    var onRead: (([UInt8]) -> Void)?
    /// Called on the main queue once the child has been reaped.
    var onExit: ((Int32) -> Void)?

    private let ioQueue = DispatchQueue(label: "dev.diffterm.pty.io", qos: .userInitiated)
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var processSource: DispatchSourceProcess?

    /// Bytes accepted from the UI that the pty was not ready to take yet.
    /// Everything before `writeOffset` has already gone out.
    private var pendingWrites: [UInt8] = []
    private var writeOffset = 0
    private let pendingLock = NSLock()

    private var readBuffer = [UInt8](repeating: 0, count: 1 << 16)

    deinit {
        tearDownWriteSource()
        processSource?.cancel()
        if let readSource {
            readSource.cancel()       // its cancel handler closes the descriptor
        } else if masterFD >= 0 {
            close(masterFD)
        }
        // Closing a tab with something still running drops the Pty straight
        // after `terminate()`. Nothing here would ever call waitpid again, so
        // the child was left a zombie; hand it to something that outlives us.
        if pid > 0, !didFinish { Pty.reapWhenExited(pid) }
    }

    // MARK: - Lifecycle

    func start(executable: String,
               arguments: [String],
               environment: [String: String],
               workingDirectory: String,
               cols: Int,
               rows: Int) throws {
        precondition(!isRunning, "pty already started")

        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
        argv.append(nil)
        var envp: [UnsafeMutablePointer<CChar>?] = environment
            .map { strdup("\($0.key)=\($0.value)") }
        envp.append(nil)
        defer {
            for p in argv where p != nil { free(p) }
            for p in envp where p != nil { free(p) }
        }

        var master: Int32 = -1
        var childPid: pid_t = -1
        let rc = executable.withCString { pathPtr -> Int32 in
            workingDirectory.withCString { cwdPtr in
                dt_spawn_pty(pathPtr, &argv, &envp, cwdPtr,
                             UInt16(clamping: cols), UInt16(clamping: rows),
                             &master, &childPid)
            }
        }

        guard rc == 0 else { throw PtyError.spawnFailed(-rc) }

        masterFD = master
        pid = childPid
        isRunning = true

        startReading()
        watchForExit()
    }

    private func startReading() {
        let source = DispatchSource.makeReadSource(fileDescriptor: masterFD, queue: ioQueue)
        source.setEventHandler { [weak self] in self?.handleReadable() }
        // The descriptor, not `self`: this also runs when the source is
        // cancelled from `deinit`, where a weak reference is already nil and
        // the close would never happen.
        let fd = masterFD
        source.setCancelHandler { close(fd) }
        readSource = source
        source.resume()
    }

    private func handleReadable() {
        guard masterFD >= 0 else { return }
        while true {
            let n = readBuffer.withUnsafeMutableBytes { buf -> Int in
                read(masterFD, buf.baseAddress, buf.count)
            }
            if n > 0 {
                onRead?(Array(readBuffer[0..<n]))
                // A full buffer means there is probably more waiting; loop
                // rather than waiting for another source event, which keeps
                // throughput up on bulk output like `cat` of a large file.
                if n < readBuffer.count { return }
                continue
            }
            if n == 0 {
                // EOF: the child closed the slave side.
                finish()
                return
            }
            let err = errno
            if err == EAGAIN || err == EWOULDBLOCK { return }
            if err == EINTR { continue }
            finish()
            return
        }
    }

    private func watchForExit() {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: ioQueue)
        source.setEventHandler { [weak self] in self?.finish() }
        processSource = source
        source.resume()
    }

    private var didFinish = false

    private func finish() {
        // `finish` can be reached from both the read source (EOF) and the
        // process source (exit); only the first one through does the work.
        if didFinish { return }
        didFinish = true
        isRunning = false

        var status: Int32 = 0
        var exitCode: Int32 = 0
        if pid > 0 {
            // The process source can fire before the child is reapable.
            var attempts = 0
            while attempts < 50 {
                let r = dt_try_reap(pid, &status)
                if r == 1 { break }
                if r < 0 { break }
                usleep(2000)
                attempts += 1
            }
            if status & 0x7F == 0 {
                exitCode = (status >> 8) & 0xFF
            } else {
                exitCode = 128 + (status & 0x7F)
            }
        }

        let readSrc = readSource
        readSource = nil
        tearDownWriteSource()
        processSource?.cancel()
        processSource = nil

        if let readSrc {
            readSrc.cancel()      // cancel handler closes the descriptor
        } else if masterFD >= 0 {
            close(masterFD)
        }
        masterFD = -1

        let code = exitCode
        DispatchQueue.main.async { [weak self] in
            self?.onExit?(code)
        }
    }

    /// Asks the child to quit, escalating if it ignores the request.
    func terminate() {
        guard isRunning, pid > 0 else { return }
        _ = dt_signal_foreground(masterFD, pid, SIGHUP)
        // Captured now, while the descriptor is still ours to ask.
        let target = pid
        let group = dt_foreground_pid(masterFD)
        // No `self` in here: closing a tab releases the Pty right after this
        // call, and a weak reference made the escalation a no-op for exactly
        // the case it exists for. `dt_child_running` never reaps, and an
        // unreaped pid cannot be reused, so the kill cannot hit a stranger.
        ioQueue.asyncAfter(deadline: .now() + 1.5) {
            guard dt_child_running(target) == 1 else { return }
            if group > 0, group != target { _ = killpg(group, SIGKILL) }
            _ = kill(target, SIGKILL)
        }
    }

    // MARK: - Orphan reaping

    private static let reaperQueue = DispatchQueue(label: "dev.diffterm.pty.reaper")
    /// Sources for children whose Pty is gone, kept alive until they fire.
    private static var orphanSources: [pid_t: DispatchSourceProcess] = [:]

    /// Waits for `pid` to exit and reaps it, independent of any Pty.
    private static func reapWhenExited(_ pid: pid_t) {
        reaperQueue.async {
            func reap() -> Bool {
                var status: Int32 = 0
                let r = waitpid(pid, &status, WNOHANG)
                return r == pid || (r < 0 && errno == ECHILD)
            }
            guard orphanSources[pid] == nil, !reap() else { return }
            let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit,
                                                          queue: reaperQueue)
            source.setEventHandler {
                guard reap() else { return }
                orphanSources[pid]?.cancel()
                orphanSources[pid] = nil
            }
            orphanSources[pid] = source
            source.resume()
            // The child may have exited between the first check and the
            // source being armed, in which case no event is coming.
            if reap() {
                source.cancel()
                orphanSources[pid] = nil
            }
        }
    }

    func sendSignal(_ signal: Int32) {
        guard isRunning else { return }
        _ = dt_signal_foreground(masterFD, pid, signal)
    }

    /// Name of the process currently in the foreground, for the tab title.
    func foregroundProcessName() -> String? {
        guard isRunning, masterFD >= 0 else { return nil }
        let fg = dt_foreground_pid(masterFD)
        guard fg > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, fg]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let rc = sysctl(&mib, 4, &info, &size, nil, 0)
        guard rc == 0, size > 0 else { return nil }
        return withUnsafePointer(to: &info.kp_proc.p_comm) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 17) {
                String(cString: $0)
            }
        }
    }

    // MARK: - Writing

    func write(_ bytes: [UInt8]) {
        guard isRunning, !bytes.isEmpty else { return }
        pendingLock.lock()
        // Bound the backlog: if a program has stopped reading (^S, or a
        // stopped job) we must not let paste data grow without limit.
        if pendingWrites.count - writeOffset + bytes.count > 1 << 22 {
            pendingLock.unlock()
            return
        }
        pendingWrites.append(contentsOf: bytes)
        pendingLock.unlock()
        ioQueue.async { [weak self] in self?.drainWrites() }
    }

    func write(_ string: String) {
        write(Array(string.utf8))
    }

    /// Everything here runs on `ioQueue`, so the source's suspend/resume
    /// balance needs no locking — but it does need to be exact: an unbalanced
    /// suspend traps when the source is released.
    ///
    /// A pty takes about a kilobyte per write. Copying the whole backlog out
    /// and shifting it down after each of those made a large paste quadratic,
    /// so writes go straight from the buffer and only an offset moves; the
    /// written prefix is reclaimed once it is most of the buffer. The lock is
    /// held across the writes, which never block on this descriptor.
    private func drainWrites() {
        guard masterFD >= 0 else { return }
        pendingLock.lock()
        defer { pendingLock.unlock() }
        while writeOffset < pendingWrites.count {
            let written = pendingWrites.withUnsafeBytes { buf -> Int in
                Darwin.write(masterFD, buf.baseAddress! + writeOffset, buf.count - writeOffset)
            }
            if written > 0 {
                writeOffset += written
                continue
            }
            let err = errno
            if err == EINTR { continue }
            if err == EAGAIN || err == EWOULDBLOCK {
                if writeOffset > pendingWrites.count / 2 {
                    pendingWrites.removeFirst(writeOffset)
                    writeOffset = 0
                }
                resumeWriteSource()
                return
            }
            // Anything else means the pty is gone; drop the backlog rather
            // than spinning on a dead descriptor.
            break
        }
        pendingWrites.removeAll(keepingCapacity: pendingWrites.count <= 1 << 16)
        writeOffset = 0
        suspendWriteSource()
    }

    private var writeSourceActive = false

    private func resumeWriteSource() {
        guard masterFD >= 0 else { return }
        if writeSource == nil {
            let source = DispatchSource.makeWriteSource(fileDescriptor: masterFD, queue: ioQueue)
            source.setEventHandler { [weak self] in
                guard let self else { return }
                self.suspendWriteSource()
                self.drainWrites()
            }
            writeSource = source
        }
        if !writeSourceActive {
            writeSourceActive = true
            writeSource?.resume()
        }
    }

    private func suspendWriteSource() {
        if writeSourceActive {
            writeSourceActive = false
            writeSource?.suspend()
        }
    }

    private func tearDownWriteSource() {
        guard let source = writeSource else { return }
        // A suspended source must be resumed before it can be cancelled and
        // released, otherwise GCD traps on deallocation.
        if !writeSourceActive {
            writeSourceActive = true
            source.resume()
        }
        source.setEventHandler {}
        source.cancel()
        writeSource = nil
        writeSourceActive = false
    }

    // MARK: - Geometry

    func resize(cols: Int, rows: Int, pixelWidth: Int = 0, pixelHeight: Int = 0) {
        guard masterFD >= 0 else { return }
        _ = dt_set_winsize(masterFD,
                           UInt16(clamping: cols), UInt16(clamping: rows),
                           UInt16(clamping: pixelWidth), UInt16(clamping: pixelHeight))
    }
}
