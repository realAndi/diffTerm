import UIKit

/// What the car needs from the rest of the app, and the one place that
/// answers "is the car leading?".
///
/// Whichever screen someone is looking at decides the shell's size. While the
/// phone shows diffTerm, that is the phone, and the car shows the part of the
/// phone's grid the cursor is in. Once the phone is locked or showing another
/// app, nobody is reading it, so the shell is sized for the car's screen and
/// full-screen programs fit it; unlocking hands the size straight back. The
/// setting only turns the second half off.
///
/// An earlier version sized the shell for the car whenever one was attached
/// and drew that grid, enlarged, on the phone. Forty columns at twenty points
/// is not a terminal anyone can use, and the phone is still where the real
/// typing happens.
final class CarPlayLink {

    static let shared = CarPlayLink()
    private init() {}

    /// Fired when the size the shells should take has changed: a car came or
    /// went, its screen settled on a new grid, or the phone was put away or
    /// picked up. Panes re-measure themselves when they hear it.
    static let didChangeNotification = Notification.Name("dev.diffterm.carPlayLinkDidChange")

    /// How long the car's grid has to hold still before the shells are
    /// resized to it. A car reports its screen in pieces — the safe area late,
    /// its own bars coming and going — and each resize is a reflow and a
    /// SIGWINCH to every shell. Zero publishes at once, for the harness.
    static var settleDelay: TimeInterval = 0.4

    /// The grid the car's screen holds, while one is attached and has settled.
    private(set) var carGrid: (cols: Int, rows: Int)?

    /// Whether the phone's own window is on screen. Kept by the phone's
    /// scene; false until it says otherwise, because CarPlay can launch the
    /// app with no phone window at all.
    private(set) var phoneVisible = false

    private var pendingGrid: (cols: Int, rows: Int)?
    private var settleWork: DispatchWorkItem?

    /// Whether the shell should be sized for the car.
    var leads: Bool { carGrid != nil && !phoneVisible && Preferences.shared.carPlayLeads }

    /// The size the shells should take instead of their own, if any.
    var grid: (cols: Int, rows: Int)? { leads ? carGrid : nil }

    /// Told by the car's screen as it works out what it can show.
    func connect(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        if let pending = pendingGrid, pending == (cols, rows) { return }
        settleWork?.cancel()
        settleWork = nil
        if let current = carGrid, current == (cols, rows) {
            pendingGrid = nil
            return
        }
        pendingGrid = (cols, rows)
        guard Self.settleDelay > 0 else {
            publish()
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.publish() }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay, execute: work)
    }

    func disconnect() {
        settleWork?.cancel()
        settleWork = nil
        pendingGrid = nil
        guard carGrid != nil else { return }
        update { carGrid = nil }
    }

    /// Told by the phone's scene as it comes and goes from the screen.
    func setPhoneVisible(_ visible: Bool) {
        guard visible != phoneVisible else { return }
        update { phoneVisible = visible }
    }

    private func publish() {
        settleWork = nil
        guard let grid = pendingGrid else { return }
        pendingGrid = nil
        update { carGrid = grid }
    }

    /// Makes a change and tells the panes only if the size they should take
    /// is different afterwards. A car settling while the phone is in use, or
    /// the phone being unlocked with no car, changes nothing for them.
    private func update(_ change: () -> Void) {
        let before = grid
        change()
        let after = grid
        let same: Bool
        switch (before, after) {
        case (nil, nil): same = true
        case let (a?, b?): same = a == b
        default: same = false
        }
        guard !same else { return }
        NotificationCenter.default.post(name: CarPlayLink.didChangeNotification, object: self)
    }
}
