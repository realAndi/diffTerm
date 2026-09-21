import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {

    /// Keeps the process alive for a short while after the user switches away.
    ///
    /// The pty is drained on its own IO queue, not by the display link, so as
    /// long as the process is running the shell keeps making progress and its
    /// output keeps landing in the buffer. Suspended, none of that happens: a
    /// program writing output fills the pty and blocks, and a glance at a
    /// notification can cost you a build. This does not make diffTerm a
    /// background app — iOS grants on the order of thirty seconds — but it
    /// covers the switch-away-and-back that otherwise loses work.
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {

        // The shell writes to a pty whose reader can go away mid-write; the
        // default SIGPIPE disposition would take the whole app down with it.
        signal(SIGPIPE, SIG_IGN)

        // Before the first session starts, so that the socket path is ready
        // to go into its environment. A failure here is not fatal: pbcopy
        // falls back to OSC 52, which is how it works over ssh anyway.
        ClipboardServer.shared.start()

        // The windows belong to the scenes (PhoneSceneDelegate and
        // CarPlaySceneDelegate): CarPlay only exists for apps that use them,
        // and once an app does, a window made here is never shown.
        //
        // With scenes, UIKit stops calling the delegate's background and
        // foreground methods but still posts these, and posts them for the
        // app as a whole: going into the background means no scene is left
        // in front — the phone locked with the car still showing the terminal
        // is not it, and must not end a session the car is displaying.
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(didEnterBackground),
                           name: UIApplication.didEnterBackgroundNotification, object: nil)
        center.addObserver(self, selector: #selector(willEnterForeground),
                           name: UIApplication.willEnterForegroundNotification, object: nil)
        return true
    }

    @objc private func didEnterBackground() {
        beginBackgroundTask(UIApplication.shared)
        RootViewController.shared.saveSessionState()
    }

    @objc private func willEnterForeground() {
        endBackgroundTask()
    }

    private func beginBackgroundTask(_ application: UIApplication) {
        endBackgroundTask()
        backgroundTask = application.beginBackgroundTask(withName: "dev.diffterm.session") { [weak self] in
            // The expiry handler runs on the main thread and must finish
            // quickly, or the app is killed rather than suspended.
            self?.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    func applicationWillTerminate(_ application: UIApplication) {
        // The shells need nothing here: they are our children, and each one
        // gets its SIGHUP when the process exits and its pty master closes.
        RootViewController.shared.saveSessionState()
        ClipboardServer.shared.stop()
        endBackgroundTask()
    }
}
