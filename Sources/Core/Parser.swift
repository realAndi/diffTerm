import Foundation

/// Actions the parser hands to the emulator. Splitting them out this way keeps
/// the state machine free of any screen knowledge, which makes it testable on
/// its own and keeps the emulator free of byte-level bookkeeping.
protocol ParserDelegate: AnyObject {
    func parserPrint(_ ch: Character)
    /// A C0/C1 control that executes immediately (BEL, BS, LF, CR, ...).
    func parserExecute(_ byte: UInt8)
    /// ESC <intermediates> <final>
    func parserEscape(intermediates: [UInt8], final: UInt8)
    /// CSI <private> <params> <intermediates> <final>
    func parserCSI(private prefix: UInt8, params: ParamList, intermediates: [UInt8], final: UInt8)
    /// OSC payload, already split on the first ';'.
    func parserOSC(_ payload: [UInt8])
    func parserDCSHook(private prefix: UInt8, params: ParamList, intermediates: [UInt8], final: UInt8)
    func parserDCSPut(_ byte: UInt8)
    func parserDCSUnhook()
}

/// CSI parameters, including colon-separated sub-parameters (SGR 38:2::r:g:b).
struct ParamList {
    /// Each entry is a parameter with its sub-parameters; `nil` means omitted.
    private(set) var groups: [[Int?]] = [[nil]]

    var count: Int { groups.count }

    /// Primary value of parameter `i`, or `def` if absent/zero-length.
    func at(_ i: Int, default def: Int = 0) -> Int {
        guard i < groups.count, let v = groups[i].first ?? nil else { return def }
        return v
    }

    /// Like `at`, but treats an explicit 0 as "use the default" — the
    /// convention for most cursor-movement CSIs where 0 and 1 both mean one.
    func atNonZero(_ i: Int, default def: Int = 1) -> Int {
        let v = at(i, default: def)
        return v == 0 ? def : v
    }

    func sub(_ i: Int, _ j: Int, default def: Int = 0) -> Int {
        guard i < groups.count, j < groups[i].count, let v = groups[i][j] else { return def }
        return v
    }

    func subCount(_ i: Int) -> Int {
        i < groups.count ? groups[i].count : 0
    }

    var isEmpty: Bool { groups.count == 1 && (groups[0].first ?? nil) == nil }

    fileprivate mutating func reset() { groups = [[nil]] }

    fileprivate mutating func digit(_ d: Int) {
        let last = groups.count - 1
        let sub = groups[last].count - 1
        let cur = groups[last][sub] ?? 0
        // Clamp rather than overflow; xterm caps parameters at 65535.
        groups[last][sub] = min(cur &* 10 &+ d, 65535)
    }

    fileprivate mutating func nextParam() {
        guard groups.count < 32 else { return }
        groups.append([nil])
    }

    fileprivate mutating func nextSubParam() {
        let last = groups.count - 1
        guard groups[last].count < 32 else { return }
        groups[last].append(nil)
    }
}

/// Byte-level escape sequence parser modelled on the DEC VT500 state diagram
/// (the one Paul Williams published). UTF-8 decoding is folded into the ground
/// state so that a multi-byte character split across two reads still works.
final class Parser {
    enum State {
        case ground
        case escape
        case escapeIntermediate
        case csiEntry
        case csiParam
        case csiIntermediate
        case csiIgnore
        case oscString
        case dcsEntry
        case dcsParam
        case dcsIntermediate
        case dcsPassthrough
        case dcsIgnore
        case sosPmApcString
    }

    weak var delegate: ParserDelegate?

    private(set) var state: State = .ground
    private var params = ParamList()
    private var intermediates: [UInt8] = []
    private var privatePrefix: UInt8 = 0
    private var oscBuffer: [UInt8] = []
    /// How large the OSC payload currently being read is allowed to grow.
    /// Most OSCs are short and are held to `defaultOSCLimit`; OSC 52 carries
    /// a base64 clipboard payload and is raised to `clipboardOSCLimit` once
    /// its command number has been read.
    private var oscLimit = Parser.defaultOSCLimit
    private var oscOverflowed = false
    private var ignoring = false

    // Incremental UTF-8 decoding state.
    private var utf8Buf: [UInt8] = []
    private var utf8Needed = 0

    // Grapheme accumulation: a combining mark must attach to the character
    // before it, so we hold one pending cluster back until we know it's done.
    private var pendingCluster: String = ""

    init(delegate: ParserDelegate? = nil) {
        self.delegate = delegate
        intermediates.reserveCapacity(4)
        oscBuffer.reserveCapacity(256)
        utf8Buf.reserveCapacity(4)
    }

    func reset() {
        state = .ground
        params.reset()
        intermediates.removeAll(keepingCapacity: true)
        privatePrefix = 0
        oscBuffer.removeAll(keepingCapacity: true)
        oscLimit = Parser.defaultOSCLimit
        oscOverflowed = false
        utf8Buf.removeAll(keepingCapacity: true)
        utf8Needed = 0
        flushCluster()
        ignoring = false
    }

    func parse(_ bytes: UnsafeBufferPointer<UInt8>) {
        for b in bytes { step(b) }
        // Anything still pending at the end of a read is flushed so the user
        // sees it now; if a combining mark arrives in the next read it will
        // be applied to the cell via the emulator's combining path.
        flushCluster()
    }

    func parse(_ data: [UInt8]) {
        data.withUnsafeBufferPointer { parse($0) }
    }

    // MARK: - Grapheme buffering

    private func flushCluster() {
        guard !pendingCluster.isEmpty else { return }
        for ch in pendingCluster { delegate?.parserPrint(ch) }
        pendingCluster.removeAll(keepingCapacity: true)
    }

    private func emit(_ scalar: Unicode.Scalar) {
        pendingCluster.unicodeScalars.append(scalar)
        // Once the buffer holds more than one grapheme, the first is complete.
        if pendingCluster.count > 1 {
            let done = pendingCluster.removeFirst()
            delegate?.parserPrint(done)
        }
    }

    // MARK: - State machine

    private func step(_ b: UInt8) {
        // C1 8-bit controls are not honoured while decoding UTF-8, because
        // 0x80-0x9F are legitimate continuation bytes there.
        if utf8Needed > 0, state == .ground {
            decodeUTF8(b)
            return
        }

        // Anywhere transitions: these win over the current state.
        //
        // Note that 0x80-0x9F are deliberately *not* decoded as 8-bit C1
        // controls. diffTerm is always in UTF-8 mode, where those bytes are
        // continuation bytes; treating them as controls is how a terminal
        // ends up corrupting every non-ASCII character it is shown.
        switch b {
        case 0x18, 0x1A:                    // CAN, SUB — abort any sequence
            flushCluster()
            leaveState()
            state = .ground
            return
        case 0x1B:                          // ESC
            flushCluster()
            leaveState()
            enterEscape()
            return
        default:
            break
        }

        switch state {
        case .ground:             ground(b)
        case .escape:             escape(b)
        case .escapeIntermediate: escapeIntermediate(b)
        case .csiEntry:           csiEntry(b)
        case .csiParam:           csiParam(b)
        case .csiIntermediate:    csiIntermediate(b)
        case .csiIgnore:          csiIgnore(b)
        case .oscString:          osc(b)
        case .dcsEntry:           dcsEntry(b)
        case .dcsParam:           dcsParam(b)
        case .dcsIntermediate:    dcsIntermediate(b)
        case .dcsPassthrough:     dcsPassthrough(b)
        case .dcsIgnore:          dcsIgnoreState(b)
        case .sosPmApcString:     sosPmApc(b)
        }
    }

    private func leaveState() {
        if state == .dcsPassthrough { delegate?.parserDCSUnhook() }
        if state == .oscString { dispatchOSC() }
    }

    // MARK: Ground

    private func ground(_ b: UInt8) {
        if b < 0x20 {
            flushCluster()
            delegate?.parserExecute(b)
            return
        }
        if b == 0x7F {                       // DEL is discarded
            return
        }
        if b < 0x80 {
            emit(Unicode.Scalar(b))
            return
        }
        decodeUTF8Start(b)
    }

    private func decodeUTF8Start(_ b: UInt8) {
        utf8Buf.removeAll(keepingCapacity: true)
        switch b {
        case 0xC2...0xDF: utf8Needed = 1
        case 0xE0...0xEF: utf8Needed = 2
        case 0xF0...0xF4: utf8Needed = 3
        default:
            // Stray continuation byte or overlong lead — show the standard
            // replacement rather than dropping input silently.
            emit("\u{FFFD}")
            utf8Needed = 0
            return
        }
        utf8Buf.append(b)
    }

    private func decodeUTF8(_ b: UInt8) {
        guard b & 0xC0 == 0x80 else {
            // Truncated sequence: emit a replacement and reprocess this byte
            // from scratch so we don't lose a following ESC.
            emit("\u{FFFD}")
            utf8Buf.removeAll(keepingCapacity: true)
            utf8Needed = 0
            step(b)
            return
        }
        utf8Buf.append(b)
        utf8Needed -= 1
        guard utf8Needed == 0 else { return }
        let decoded = String(decoding: utf8Buf, as: UTF8.self)
        for s in decoded.unicodeScalars { emit(s) }
        utf8Buf.removeAll(keepingCapacity: true)
    }

    // MARK: ESC

    private func enterEscape() {
        params.reset()
        intermediates.removeAll(keepingCapacity: true)
        privatePrefix = 0
        ignoring = false
        state = .escape
    }

    private func escape(_ b: UInt8) {
        switch b {
        case 0x00...0x17, 0x19, 0x1C...0x1F:
            delegate?.parserExecute(b)
        case 0x20...0x2F:
            intermediates.append(b)
            state = .escapeIntermediate
        case 0x50:                       // 'P' -> DCS
            enterDCS()
        case 0x58, 0x5E, 0x5F:           // SOS, PM, APC
            state = .sosPmApcString
        case 0x5B:                       // '[' -> CSI
            enterCSI()
        case 0x5D:                       // ']' -> OSC
            enterOSC()
        case 0x7F:
            break
        default:
            delegate?.parserEscape(intermediates: intermediates, final: b)
            state = .ground
        }
    }

    private func escapeIntermediate(_ b: UInt8) {
        switch b {
        case 0x00...0x17, 0x19, 0x1C...0x1F:
            delegate?.parserExecute(b)
        case 0x20...0x2F:
            if intermediates.count < 4 { intermediates.append(b) } else { ignoring = true }
        case 0x7F:
            break
        default:
            if !ignoring { delegate?.parserEscape(intermediates: intermediates, final: b) }
            state = .ground
        }
    }

    // MARK: CSI

    private func enterCSI() {
        params.reset()
        intermediates.removeAll(keepingCapacity: true)
        privatePrefix = 0
        ignoring = false
        state = .csiEntry
    }

    private func csiEntry(_ b: UInt8) {
        switch b {
        case 0x00...0x17, 0x19, 0x1C...0x1F:
            delegate?.parserExecute(b)
        case 0x20...0x2F:
            intermediates.append(b)
            state = .csiIntermediate
        case 0x30...0x39:
            params.digit(Int(b - 0x30))
            state = .csiParam
        case 0x3A:
            params.nextSubParam()
            state = .csiParam
        case 0x3B:
            params.nextParam()
            state = .csiParam
        case 0x3C...0x3F:
            privatePrefix = b
            state = .csiParam
        case 0x7F:
            break
        default:
            dispatchCSI(b)
        }
    }

    private func csiParam(_ b: UInt8) {
        switch b {
        case 0x00...0x17, 0x19, 0x1C...0x1F:
            delegate?.parserExecute(b)
        case 0x30...0x39:
            params.digit(Int(b - 0x30))
        case 0x3A:
            params.nextSubParam()
        case 0x3B:
            params.nextParam()
        case 0x20...0x2F:
            intermediates.append(b)
            state = .csiIntermediate
        case 0x3C...0x3F:
            state = .csiIgnore          // private marker after params is invalid
        case 0x7F:
            break
        default:
            dispatchCSI(b)
        }
    }

    private func csiIntermediate(_ b: UInt8) {
        switch b {
        case 0x00...0x17, 0x19, 0x1C...0x1F:
            delegate?.parserExecute(b)
        case 0x20...0x2F:
            if intermediates.count < 4 { intermediates.append(b) } else { ignoring = true }
        case 0x30...0x3F:
            state = .csiIgnore
        case 0x7F:
            break
        default:
            if ignoring { state = .ground } else { dispatchCSI(b) }
        }
    }

    private func csiIgnore(_ b: UInt8) {
        switch b {
        case 0x00...0x17, 0x19, 0x1C...0x1F:
            delegate?.parserExecute(b)
        case 0x40...0x7E:
            state = .ground
        default:
            break
        }
    }

    private func dispatchCSI(_ final: UInt8) {
        delegate?.parserCSI(private: privatePrefix,
                            params: params,
                            intermediates: intermediates,
                            final: final)
        state = .ground
    }

    // MARK: OSC

    /// Ceiling for an ordinary OSC payload — titles, palette entries, working
    /// directories. Generous for all of them and small enough that a runaway
    /// sequence cannot grow the buffer unbounded.
    static let defaultOSCLimit = 8192

    /// Ceiling for OSC 52. The emulator accepts up to 1 MiB of decoded
    /// clipboard text, and base64 expands by 4/3, so the encoded form needs
    /// this much room plus the `52;c;` prefix. Without it a copy larger than
    /// the default limit was truncated mid-base64 and then silently dropped.
    static let clipboardOSCLimit = ((1 << 20) + 2) / 3 * 4 + 16

    /// Ceiling for OSC 1337, which carries a whole picture. The store keeps
    /// images up to `InlineImageStore.maximumImageBytes` and base64 expands by
    /// 4/3, so anything smaller than this would truncate a picture the store
    /// would happily have taken — and a truncated one is dropped, so it would
    /// read as `imgcat` silently doing nothing on larger files.
    static let imageOSCLimit = (InlineImageStore.maximumImageBytes + 2) / 3 * 4 + 256

    private func enterOSC() {
        oscBuffer.removeAll(keepingCapacity: true)
        oscLimit = Parser.defaultOSCLimit
        oscOverflowed = false
        state = .oscString
    }

    private func osc(_ b: UInt8) {
        switch b {
        case 0x07:                       // BEL terminator (xterm convention)
            dispatchOSC()
            state = .ground
        case 0x00...0x06, 0x08...0x17, 0x19, 0x1C...0x1F:
            break
        default:
            // Cap the payload: a runaway OSC should not be able to grow
            // unbounded from untrusted program output.
            guard oscBuffer.count < oscLimit else { oscOverflowed = true; return }
            oscBuffer.append(b)
            // "52;" — raise the ceiling now that the command is known.
            if oscBuffer.count == 3, oscBuffer[0] == 0x35, oscBuffer[1] == 0x32,
               oscBuffer[2] == UInt8(ascii: ";") {
                oscLimit = Parser.clipboardOSCLimit
            }
            // "1337;" — the same trick for a payload that is a whole picture.
            if oscBuffer.count == 5, oscBuffer[0] == UInt8(ascii: "1"),
               oscBuffer[1] == UInt8(ascii: "3"), oscBuffer[2] == UInt8(ascii: "3"),
               oscBuffer[3] == UInt8(ascii: "7"), oscBuffer[4] == UInt8(ascii: ";") {
                oscLimit = Parser.imageOSCLimit
            }
        }
    }

    private func dispatchOSC() {
        defer {
            oscBuffer.removeAll(keepingCapacity: true)
            oscLimit = Parser.defaultOSCLimit
            oscOverflowed = false
        }
        guard !oscBuffer.isEmpty else { return }
        // A payload that hit the ceiling is a fragment. Acting on half of one
        // is worse than ignoring it: half a title is noise, and half a base64
        // clipboard payload either fails to decode or — if the truncation
        // happens to land on a 4-byte boundary — silently copies the wrong
        // thing. Drop it instead.
        guard !oscOverflowed else { return }
        delegate?.parserOSC(oscBuffer)
    }

    // MARK: DCS

    private func enterDCS() {
        params.reset()
        intermediates.removeAll(keepingCapacity: true)
        privatePrefix = 0
        ignoring = false
        state = .dcsEntry
    }

    private func dcsEntry(_ b: UInt8) {
        switch b {
        case 0x00...0x17, 0x19, 0x1C...0x1F, 0x7F:
            break
        case 0x20...0x2F:
            intermediates.append(b); state = .dcsIntermediate
        case 0x30...0x39:
            params.digit(Int(b - 0x30)); state = .dcsParam
        case 0x3A:
            params.nextSubParam(); state = .dcsParam
        case 0x3B:
            params.nextParam(); state = .dcsParam
        case 0x3C...0x3F:
            privatePrefix = b; state = .dcsParam
        default:
            hookDCS(b)
        }
    }

    private func dcsParam(_ b: UInt8) {
        switch b {
        case 0x00...0x17, 0x19, 0x1C...0x1F, 0x7F:
            break
        case 0x30...0x39: params.digit(Int(b - 0x30))
        case 0x3A: params.nextSubParam()
        case 0x3B: params.nextParam()
        case 0x20...0x2F: intermediates.append(b); state = .dcsIntermediate
        case 0x3C...0x3F: state = .dcsIgnore
        default: hookDCS(b)
        }
    }

    private func dcsIntermediate(_ b: UInt8) {
        switch b {
        case 0x00...0x17, 0x19, 0x1C...0x1F, 0x7F:
            break
        case 0x20...0x2F:
            if intermediates.count < 4 { intermediates.append(b) } else { ignoring = true }
        case 0x30...0x3F:
            state = .dcsIgnore
        default:
            if ignoring { state = .dcsIgnore } else { hookDCS(b) }
        }
    }

    private func hookDCS(_ final: UInt8) {
        delegate?.parserDCSHook(private: privatePrefix,
                                params: params,
                                intermediates: intermediates,
                                final: final)
        state = .dcsPassthrough
    }

    private func dcsPassthrough(_ b: UInt8) {
        switch b {
        case 0x00...0x17, 0x19, 0x1C...0x1F, 0x20...0x7E:
            delegate?.parserDCSPut(b)
        default:
            break
        }
    }

    private func dcsIgnoreState(_ b: UInt8) { _ = b }

    private func sosPmApc(_ b: UInt8) { _ = b }
}
