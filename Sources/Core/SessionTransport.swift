import Foundation

/// The pipe between a `TerminalSession` and the process on the other end of a
/// pty. Two implementations: `Pty`, which owns the shell directly (the shell
/// dies with the app), and `DaemonTransport`, which relays to the launchd-owned
/// session daemon (the shell outlives the app). The session neither knows nor
/// cares which it has — it reads bytes, writes bytes, and resizes.
protocol SessionTransport: AnyObject {
    var onRead: (([UInt8]) -> Void)? { get set }
    var onExit: ((Int32) -> Void)? { get set }

    func start(executable: String,
               arguments: [String],
               environment: [String: String],
               workingDirectory: String,
               cols: Int,
               rows: Int) throws

    func write(_ bytes: [UInt8])
    func resize(cols: Int, rows: Int, pixelWidth: Int, pixelHeight: Int)
    func terminate()
    func sendSignal(_ signal: Int32)
    func foregroundProcessName() -> String?
}
