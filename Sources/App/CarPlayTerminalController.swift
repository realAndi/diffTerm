import UIKit

/// How the car's screen frames the terminal.
///
/// While the car leads (see `CarPlayLink`), the shell is exactly the grid the
/// car holds: the size chosen for the phone, stepped down only as far as it
/// takes to make a narrow panel wide enough to be a terminal (`grid`). While
/// the phone leads, the shell is the phone's width, and the car draws smaller
/// to show every column of it (`pointSize(fitting:)`); only a grid too wide
/// even for that — the phone on its side — is shown a slice at a time, the
/// columns and rows the cursor is in.
///
/// Car screens are smaller than they sound: the common 800x480 panel is 2x,
/// so it is 400x240 points, less the car's own bars, less the column of
/// buttons that is the only keyboard CarPlay will give an app.
///
/// Kept free of CarPlay and of any view so the harness can check it.
enum CarPlayFraming {

    /// Room kept clear on the right for the car's buttons, when the car does
    /// not say how much it needs. They are about 44 points across; the rest
    /// is margin.
    static let buttonColumnWidth: CGFloat = 56

    /// Room kept clear on the left for the car's own bar, when the car does
    /// not report the bar at all.
    ///
    /// CarPlay draws that bar over the app's screen and does not reliably
    /// report it as a safe area inset: a map is expected to run underneath
    /// it, and text cannot. Mildly proportional — a wide panel carries a
    /// wider bar — and bounded at both ends, because every point spent here
    /// is a column of terminal nobody gets. A car that does report a bar, on
    /// either side, is believed instead.
    static func dockColumnWidth(for width: CGFloat) -> CGFloat {
        min(72, max(56, width * 0.15))
    }

    /// What a terminal needs to be worth reading: below this the car steps
    /// the text down rather than showing a strip of it. Deliberately modest
    /// — chasing eighty columns on a car screen buys a grid nobody can read.
    static let preferredColumns = 32

    /// How small the car will draw to reach those columns. A glance at a
    /// dashboard is not a session at a desk.
    static let minimumPointSize: CGFloat = 10

    /// The text size and grid for the car's screen.
    ///
    /// It starts at the size the user chose for the phone and steps down only
    /// as far as it must to make the terminal wide enough to be one.
    static func grid(in area: CGSize, preferredPointSize: CGFloat,
                     cellSize: (CGFloat) -> CGSize) -> (points: CGFloat, cols: Int, rows: Int) {
        func measure(_ points: CGFloat) -> (cols: Int, rows: Int) {
            let cell = cellSize(points)
            guard cell.width > 0, cell.height > 0 else { return (1, 1) }
            return (max(1, Int(area.width / cell.width)), max(1, Int(area.height / cell.height)))
        }
        var points = max(preferredPointSize, minimumPointSize)
        var measured = measure(points)
        while measured.cols < preferredColumns, points > minimumPointSize {
            points = max(minimumPointSize, points - 0.5)
            measured = measure(points)
        }
        return (points, measured.cols, measured.rows)
    }

    /// How small the car will draw to show every column of the phone's grid.
    /// Lower than `minimumPointSize`, because the choice is between the whole
    /// line and part of it, and a line cut off at the edge reads as missing
    /// text; below this the car goes back to following the cursor along it.
    static let fitMinimumPointSize: CGFloat = 7

    /// The size at which `cols` columns fit across `width`, while the phone
    /// sets the shell's width and the car has to show the phone's lines.
    ///
    /// The size chosen for the phone if they fit at that, the largest half
    /// point below it at which they do otherwise, and never below `minimum`.
    static func pointSize(fitting cols: Int, in width: CGFloat, preferred: CGFloat,
                          minimum: CGFloat, cellWidth: (CGFloat) -> CGFloat) -> CGFloat {
        let top = max(preferred, minimum)
        guard cols > 0, width > 0 else { return top }
        func fits(_ points: CGFloat) -> Bool { CGFloat(cols) * cellWidth(points) <= width }
        if fits(top) { return top }
        var low = Int((minimum * 2).rounded(.up))
        var high = Int((top * 2).rounded(.up)) - 1
        guard low <= high, fits(CGFloat(low) / 2) else { return minimum }
        while low < high {
            let mid = (low + high + 1) / 2
            if fits(CGFloat(mid) / 2) { low = mid } else { high = mid - 1 }
        }
        return CGFloat(low) / 2
    }

    /// Splits the car's screen into the title line and the room left for the
    /// terminal.
    ///
    /// The safe area is the part of the panel the car's own bars do not
    /// cover, and on some cars that is a fraction of it: 1920x720 with a
    /// 1080x720 safe area, offset to one side, is a configuration Apple
    /// ships as a preset. Drawing outside it puts the terminal under the
    /// car's sidebar. The reserves are measured from the screen's edges —
    /// `rightReserve` is how far in from the right the car's buttons reach —
    /// so they are minimums, not additions: counting one on top of the inset
    /// it already covers cost the terminal a tenth of a car's width.
    static func contentArea(bounds: CGRect, safeArea: UIEdgeInsets,
                            headerHeight: CGFloat,
                            leftReserve: CGFloat,
                            rightReserve: CGFloat) -> (header: CGRect, terminal: CGRect) {
        var insets = safeArea
        insets.left = max(insets.left, leftReserve)
        insets.right = max(insets.right, rightReserve)
        let safe = bounds.inset(by: insets)
        let header = CGRect(x: safe.minX + 8, y: safe.minY + 1,
                            width: max(0, safe.width - 16),
                            height: max(0, headerHeight - 2))
        let terminal = CGRect(x: safe.minX + 6, y: safe.minY + headerHeight,
                              width: max(0, safe.width - 12),
                              height: max(0, safe.height - headerHeight - 2))
        return (header, terminal)
    }

    /// The leftmost column to show, when the grid is wider than the car.
    ///
    /// The cursor is what the car follows: it is where the output is being
    /// written and where what you type on the phone appears. A column of
    /// margin on each side keeps it off the edge, and the view is left alone
    /// while the cursor is comfortably inside it, so ordinary typing does not
    /// slide the text about.
    static func followLeft(cols: Int, visibleCols: Int, cursorCol: Int, current: Int) -> Int {
        guard visibleCols < cols else { return 0 }
        let highest = cols - visibleCols
        var left = min(max(current, 0), highest)
        if cursorCol < left + 1 {
            left = cursorCol - 1
        } else if cursorCol > left + visibleCols - 2 {
            left = cursorCol - visibleCols + 2
        }
        return min(max(left, 0), highest)
    }

    /// The first row to show while following the output, as an absolute row.
    ///
    /// When the car shows fewer rows than the screen has, the window stays on
    /// the screen and ends at the last row with anything on it — after a
    /// `clear`, that is the prompt at the top rather than a car full of blank
    /// lines. When it shows more, the screen sits at the bottom with history
    /// filling the space above it.
    static func followTop(totalRows: Int, screenRows: Int,
                          contentBottom: Int, visibleRows: Int) -> Int {
        let screenTop = totalRows - screenRows
        let top = max(min(screenTop, totalRows - visibleRows), contentBottom + 1 - visibleRows)
        return max(0, top)
    }
}

/// What the car's command line offers for what has been typed into it.
///
/// Kept apart from CarPlay so the harness can check it: the rows and, more
/// to the point, the exact bytes each one writes to the shell.
enum CarPlayCommandRows {

    struct Row: Equatable {
        var title: String
        var detail: String
        /// Exactly what is written to the shell when this row is picked.
        var sends: String
    }

    /// The typed line first, then this session's history that matches it.
    ///
    /// With nothing typed there is nothing to run, so the history stands on
    /// its own and Ctrl-C comes last — a row that stops a command has no
    /// business under a thumb reaching for something else.
    static func rows(for text: String, history: [String]) -> [Row] {
        // A car's field is one line, but nothing about it is ours to trust:
        // control characters would go to the shell as keystrokes.
        let typed = text.filter { !$0.isNewline && !$0.unicodeScalars.contains { $0.properties.generalCategory == .control } }
            .trimmingCharacters(in: .whitespaces)

        var rows: [Row] = []
        if !typed.isEmpty {
            rows.append(Row(title: typed, detail: "Run", sends: typed + "\r"))
        }
        for command in history where command != typed && !command.isEmpty {
            rows.append(Row(title: command, detail: "History", sends: command + "\r"))
        }
        if typed.isEmpty {
            rows.append(Row(title: "Stop the running command", detail: "Ctrl-C", sends: "\u{03}"))
        }
        return rows
    }
}

/// What the car's list of tabs says about each one.
///
/// Kept apart from CarPlay so the harness can check it. The detail line is
/// the thing worth reading at a glance: what is running, what failed, or
/// where the shell is sitting.
enum CarPlayTabRows {

    enum State: Equatable {
        case idle, running, failed, exited
    }

    struct Row: Equatable {
        var title: String
        var detail: String
        var state: State
    }

    struct Tab {
        var title: String
        var paneCount = 1
        /// Nil while the shell is running, its status once it has exited.
        var shellExitCode: Int32?
        /// The newest command the shell reported, if it reports them.
        var command: String?
        var commandRunning = false
        var commandExitCode: Int?
        /// In the app's spelling, as is `home`.
        var directory: String
    }

    static func row(for tab: Tab, home: String) -> Row {
        var title = tab.title.isEmpty ? "shell" : tab.title
        if tab.paneCount > 1 { title += " (\(tab.paneCount) panes)" }

        if let status = tab.shellExitCode {
            return Row(title: title, detail: "Shell exited with status \(status)", state: .exited)
        }
        if tab.commandRunning {
            let detail = tab.command.map { "Running: \($0)" } ?? "Running"
            return Row(title: title, detail: detail, state: .running)
        }
        if let code = tab.commandExitCode, code != 0 {
            let detail = tab.command.map { "Failed: \($0) (exit \(code))" } ?? "Failed (exit \(code))"
            return Row(title: title, detail: detail, state: .failed)
        }
        return Row(title: title, detail: abbreviate(tab.directory, home: home), state: .idle)
    }

    /// `~` for home, as the prompt would say it.
    static func abbreviate(_ path: String, home: String) -> String {
        guard !home.isEmpty, home != "/" else { return path }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}

/// The CarPlay screen: whichever pane is active on the phone, drawn at a size
/// the car can show.
///
/// It has its own `TerminalView` over the pane's emulator, so the phone keeps
/// its own scroll position, selection and keyboard. Switching tabs or panes
/// on the phone switches what the car shows, and the car's list of tabs
/// switches the phone's.
///
/// This runs once per frame of the car's screen, on the same main thread the
/// phone's terminal needs, so a frame with nothing new costs a few integer
/// comparisons: the text size is only worked out again when the car's screen
/// or the font settings change, and nothing here waits on the car.
final class CarPlayTerminalController: UIViewController {

    /// Whether the view has been moved off the live text, in either
    /// direction.
    var isScrolledBack: Bool { pinnedTop != nil || pinnedLeft != nil }

    /// Called when something the car's buttons reflect has changed: the tabs,
    /// or whether the view is scrolled back. At most once per turn of the run
    /// loop and never from inside a frame, so a handler that talks to the car
    /// cannot hold one up.
    var onStateChange: (() -> Void)?

    /// Where the car says its own buttons are, in this view's coordinates, so
    /// the terminal can keep out from under them. Set by the scene delegate
    /// from the car window's map button layout guide; without it a fixed
    /// column is reserved instead.
    var buttonArea: (() -> CGRect)?

    /// Test seam: the car's safe area, for the harness, whose views have no
    /// window to be given one. Nil in normal use.
    var safeAreaOverride: UIEdgeInsets? {
        didSet { areaMayHaveChanged = true }
    }

    private weak var pane: TerminalPaneController?
    private(set) var terminalView: TerminalView?
    /// What the title line says.
    var headerText: String? { header.text }
    /// The window onto the grid. When the phone leads, the grid is as wide as
    /// the phone's screen; when the car cannot show that many columns at a
    /// size worth reading, this is what cuts it off at the edge.
    private let clip = UIView()
    private let header = UILabel()
    private var displayLink: CADisplayLink?
    /// Used only if the car's screen will not hand out a display link.
    private var timer: Timer?

    private var font: TerminalFont?
    /// What `font` was built from.
    private var fontIdentity: FontIdentity?
    /// What the text size and the grid were last worked out from.
    private var layoutKey: LayoutKey?
    /// Where the grid may go now, and with every one of the car's bars
    /// showing: measured again only when that may have changed.
    private var measuredArea: (area: CGRect, steady: CGRect)?
    /// Whole cells that fit the car's screen at `font`, whatever size the
    /// shell happens to be.
    private var fittingCols = 1
    private var fittingRows = 1
    /// The most of each edge the car's own bars have covered since it
    /// connected. Its navigation bar hides itself after a few seconds and
    /// comes back on a tap, and the safe area follows it; a shell sized from
    /// that would be resized, and every program in it redrawn, each time. So
    /// the shell gets the room left with every bar showing, and while the bar
    /// is hidden the car shows more history above it instead.
    private var widestInsets = UIEdgeInsets.zero
    private var visibleRows = 1
    private var visibleCols = 1

    /// The first row shown while the driver has scrolled back through
    /// history; nil while following the output. Fractional during a drag.
    private var pinnedTop: CGFloat?
    /// The leftmost column while the driver has panned sideways; nil while
    /// following the cursor.
    private var pinnedLeft: CGFloat?
    /// The leftmost column actually shown, followed or pinned.
    private var leftColumn = 0
    private var dragStartTop: CGFloat = 0
    private var dragStartLeft: CGFloat = 0
    /// Rows the scrollback ring had dropped when last looked at, so a
    /// scrolled-back view can stay on the same text as old lines age out.
    private var lastEvicted = 0
    private var lastAltScreen = false
    private var observed: Observed?
    /// Set whenever the room the grid has may have changed: a layout pass,
    /// new safe area insets, or the periodic check in `tick` finding that it
    /// did.
    private var areaMayHaveChanged = true
    private var frameCount = 0
    private var stateChangeScheduled = false

    /// Read when the view loads and again when the settings change, rather
    /// than from UserDefaults on every frame.
    private var fontSettings = FontSettings.current

    /// Small: a car screen is about 240 points tall, and every line of it
    /// spent on chrome is a line of terminal nobody can read.
    private static let headerHeight: CGFloat = 15

    /// Every this many frames — five times a second at the car's thirty —
    /// output for the tabs not on screen is taken in. The phone does that
    /// itself while it is drawing; locked, nothing else would, and a build in
    /// another tab would never be seen to finish.
    private static let backgroundPumpInterval = 6
    /// Every this many frames the room left by the car's own bars and buttons
    /// is measured again, twice a second.
    private static let areaCheckInterval = 15

    private struct FontSettings: Equatable {
        var family: String
        var pointSize: CGFloat
        var lineHeightScale: CGFloat

        static var current: FontSettings {
            let prefs = Preferences.shared
            return FontSettings(family: prefs.fontName, pointSize: prefs.fontSize,
                                lineHeightScale: prefs.lineHeightScale)
        }
    }

    private struct FontIdentity: Equatable {
        var settings: FontSettings
        var pointSize: CGFloat
        var scale: CGFloat
    }

    /// Everything the text size and grid depend on. Choosing a size builds a
    /// handful of fonts, so it only happens when one of these changes.
    private struct LayoutKey: Equatable {
        /// Where the grid may go right now.
        var area: CGRect
        /// Where it may go with every one of the car's bars showing.
        var steadyArea: CGRect
        var settings: FontSettings
        var scale: CGFloat
        /// The shell's width while the phone sets it, which the text is sized
        /// to show whole; nil while the car sets it.
        var fitColumns: Int?
    }

    /// What decides whether the car has anything new to draw. Read every
    /// frame, so it only holds what is cheap to read.
    private struct Observed: Equatable {
        var generation: Int
        var cols: Int
        var rows: Int
        var altScreen: Bool
        var tab: Int
        var tabs: Int
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        header.font = .systemFont(ofSize: 11, weight: .semibold)
        header.lineBreakMode = .byTruncatingMiddle
        clip.clipsToBounds = true
        view.addSubview(clip)
        view.addSubview(header)

        NotificationCenter.default.addObserver(
            self, selector: #selector(appearanceChanged),
            name: Preferences.didChangeNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(paletteChanged(_:)),
            name: TerminalSession.paletteDidChangeNotification, object: nil)
    }

    // MARK: - Following the phone

    /// Starts drawing. Frames come from the car's own screen: the phone's
    /// cannot be relied on while it is locked, which is exactly when the car
    /// is the only screen anyone is looking at.
    func start(on screen: UIScreen) {
        stop()
        if let link = screen.displayLink(withTarget: self, selector: #selector(tick)) {
            link.preferredFramesPerSecond = 30
            link.add(to: .main, forMode: .common)
            displayLink = link
        } else {
            // A screen that will not give out a display link still has to be
            // drawn on; thirty times a second by the clock does that.
            let timer = Timer(timeInterval: 1.0 / 30, target: self,
                              selector: #selector(tick), userInfo: nil, repeats: true)
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        tick()
    }

    /// The display link holds on to this controller until it is invalidated.
    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        timer?.invalidate()
        timer = nil
    }

    /// One frame, from the car's display link — or from the harness, which
    /// has no car to give it frames.
    @objc func tick() {
        frameCount &+= 1
        let root = RootViewController.shared
        guard let active = root.activeTab?.activePane else { return }
        if active !== pane { attach(active) }

        let session = active.session
        session.pumpOutput()
        if frameCount % Self.backgroundPumpInterval == 0 {
            for other in root.allPanes where other !== active {
                other.session.pumpOutput()
            }
        }
        // The car can tell us late — or never — that its screen is not all
        // ours: the safe area arrives after the window is handed over, and its
        // buttons can move without this view being laid out again.
        if frameCount % Self.areaCheckInterval == 0, let key = layoutKey,
           areas.terminal != key.area {
            areaMayHaveChanged = true
        }

        let emulator = session.emulator
        let now = Observed(generation: session.frameGeneration,
                           cols: emulator.cols, rows: emulator.rows,
                           altScreen: emulator.modes.altScreen,
                           tab: root.selectedTabIndex, tabs: root.tabCount)
        guard now != observed || areaMayHaveChanged else { return }
        let tabsChanged = now.tab != observed?.tab || now.tabs != observed?.tabs
        observed = now
        refresh()
        if tabsChanged { stateChanged() }
    }

    private func attach(_ pane: TerminalPaneController) {
        self.pane = pane
        observed = nil
        pinnedTop = nil
        pinnedLeft = nil
        leftColumn = 0
        let emulator = pane.session.emulator
        lastAltScreen = emulator.modes.altScreen
        lastEvicted = emulator.buffer.scrollbackEvicted
        terminalView?.emulator = emulator
        // Picture ids are per emulator; another session's would collide.
        terminalView?.imageCache = [:]
        applyPalette()
        stateChanged()
    }

    /// Tells the buttons, once, after whatever is happening now has finished.
    private func stateChanged() {
        guard !stateChangeScheduled else { return }
        stateChangeScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.stateChangeScheduled = false
            self.onStateChange?()
        }
    }

    // MARK: - Layout

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        areaMayHaveChanged = true
        refresh()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        areaMayHaveChanged = true
        view.setNeedsLayout()
    }

    /// How far in from the right edge the car's buttons reach. The car says,
    /// through the map button layout guide — the screen inset by the room its
    /// buttons take — once it has laid them out. Until then, or if it never
    /// does, a column is kept clear inside whatever the car's own bar covers
    /// on that side, because those buttons are the keyboard and must never
    /// sit on top of the text.
    private var rightReserve: CGFloat {
        let fallback = carInsets.right + CarPlayFraming.buttonColumnWidth
        guard let frame = buttonArea?(), frame.width > 0, frame.maxX < view.bounds.maxX else {
            return fallback
        }
        return max(CarPlayFraming.buttonColumnWidth, view.bounds.maxX - frame.maxX)
    }

    private var leftReserve: CGFloat {
        let insets = carInsets
        guard insets.left <= 0, insets.right <= 0 else { return 0 }
        return CarPlayFraming.dockColumnWidth(for: view.bounds.width)
    }

    /// Where the title line and the grid may go: clear of the car's bar on
    /// one side and its buttons on the other.
    private var areas: (header: CGRect, terminal: CGRect) {
        areas(insets: carInsets)
    }

    private var carInsets: UIEdgeInsets { safeAreaOverride ?? view.safeAreaInsets }

    private func areas(insets: UIEdgeInsets) -> (header: CGRect, terminal: CGRect) {
        CarPlayFraming.contentArea(bounds: view.bounds, safeArea: insets,
                                   headerHeight: Self.headerHeight,
                                   leftReserve: leftReserve,
                                   rightReserve: rightReserve)
    }

    /// Places the grid. The text size is only chosen again when the area, the
    /// font settings or the width it has to show have changed; the rest is a
    /// couple of frames.
    private func layoutTerminal() {
        guard let emulator = pane?.session.emulator else { return }
        if areaMayHaveChanged || measuredArea == nil {
            areaMayHaveChanged = false
            let areas = self.areas
            if header.frame != areas.header { header.frame = areas.header }
            guard areas.terminal.width > 0, areas.terminal.height > 0 else { return }
            let insets = carInsets
            widestInsets = UIEdgeInsets(top: max(widestInsets.top, insets.top),
                                        left: max(widestInsets.left, insets.left),
                                        bottom: max(widestInsets.bottom, insets.bottom),
                                        right: max(widestInsets.right, insets.right))
            var steady = self.areas(insets: widestInsets).terminal
            if steady.width <= 0 || steady.height <= 0 { steady = areas.terminal }
            measuredArea = (areas.terminal, steady)
        }
        guard let measured = measuredArea else { return }
        let scale = max(view.window?.screen.scale ?? traitCollection.displayScale, 1)
        // While the phone sets the shell's width, the car's text is sized to
        // show all of it; while the car sets it, the grid is the car's own.
        let key = LayoutKey(area: measured.area, steadyArea: measured.steady,
                            settings: fontSettings, scale: scale,
                            fitColumns: CarPlayLink.shared.leads ? nil : emulator.cols)
        if key != layoutKey {
            layoutKey = key
            chooseFont(for: key)
        }
        let area = key.area

        guard let terminalView, let font else { return }
        let cell = font.cellSize
        visibleRows = fittingRows
        visibleCols = max(1, min(emulator.cols, fittingCols))

        // Whole columns and whole rows, against the top left of what is left
        // of the car's screen: the text starts where the phone's does.
        let window = CGRect(x: area.minX.rounded(.down), y: area.minY.rounded(.down),
                            width: CGFloat(visibleCols) * cell.width,
                            height: CGFloat(visibleRows) * cell.height)
        if clip.frame != window { clip.frame = window }

        // The grid keeps the shell's full width behind that window, so a line
        // too long for the car even at the smallest size is cut off rather
        // than shrunk to nothing.
        let grid = CGRect(x: (-CGFloat(leftColumn) * cell.width).rounded(.down), y: 0,
                          width: CGFloat(emulator.cols) * cell.width, height: window.height)
        if terminalView.frame != grid { terminalView.frame = grid }
    }

    /// The text size, and how much of a grid it holds on this screen.
    ///
    /// Two sizes come out of the steady area — so the car's bars coming and
    /// going change neither — and one of them is drawn. The car's own grid is
    /// the size chosen for the phone, stepped down only as far as it takes to
    /// be a terminal (CarPlayFraming.grid); that is what the shell becomes
    /// when the car sets its size, so it is published either way. While the
    /// phone sets the size instead, the text is whatever shows the phone's
    /// every column (CarPlayFraming.pointSize(fitting:)).
    private func chooseFont(for key: LayoutKey) {
        let settings = key.settings
        func cellSize(_ points: CGFloat) -> CGSize {
            TerminalFont(familyName: settings.family, pointSize: points,
                         lineHeightScale: settings.lineHeightScale, scale: key.scale).cellSize
        }
        let carGrid = CarPlayFraming.grid(in: key.steadyArea.size,
                                          preferredPointSize: settings.pointSize,
                                          cellSize: cellSize)
        let points = key.fitColumns.map { cols in
            CarPlayFraming.pointSize(fitting: cols, in: key.steadyArea.width,
                                     preferred: settings.pointSize,
                                     minimum: CarPlayFraming.fitMinimumPointSize) { cellSize($0).width }
        } ?? carGrid.points

        // The area moving without the size changing keeps the font, and with
        // it the glyphs already drawn.
        let identity = FontIdentity(settings: settings, pointSize: points, scale: key.scale)
        if identity != fontIdentity || terminalView == nil {
            let font = TerminalFont(familyName: settings.family, pointSize: points,
                                    lineHeightScale: settings.lineHeightScale, scale: key.scale)
            self.font = font
            fontIdentity = identity
            if let terminalView {
                terminalView.update(font: font)
            } else {
                makeTerminalView(font: font)
            }
        }
        guard let font else { return }
        let cell = font.cellSize
        fittingCols = max(1, Int(key.area.width / cell.width))
        fittingRows = max(1, Int(key.area.height / cell.height))
        // What this screen holds with its bars showing, whether or not the
        // shell is sized for it: CarPlayLink decides, once it has held still.
        // Last, because deciding can resize the shell under this very frame.
        CarPlayLink.shared.connect(cols: carGrid.cols, rows: carGrid.rows)
    }

    private func makeTerminalView(font: TerminalFont) {
        guard let palette = makePalette() else { return }
        let terminalView = TerminalView(font: font, palette: palette)
        terminalView.emulator = pane?.session.emulator
        // A car's screen does not deliver touches to a navigation app's base
        // view; dragging arrives through the map template instead.
        terminalView.isUserInteractionEnabled = false
        // A solid cursor in the shape the program asked for, as the phone
        // draws it while typing. Blinking in a car is a distraction.
        terminalView.isInputFocused = true
        let prefs = Preferences.shared
        terminalView.boldIsBright = prefs.boldIsBright
        terminalView.useBoldFont = prefs.useBoldFont
        clip.addSubview(terminalView)
        self.terminalView = terminalView
    }

    // MARK: - Drawing

    /// Brings the car up to date with the pane: size, position and contents.
    private func refresh() {
        guard let emulator = pane?.session.emulator else { return }
        layoutTerminal()
        guard let terminalView, let font else { return }

        // History belongs to one buffer; a full-screen program coming or
        // going is a different screen, so the view goes back to following.
        if emulator.modes.altScreen != lastAltScreen {
            lastAltScreen = emulator.modes.altScreen
            if pinnedTop != nil { pinnedTop = nil; stateChanged() }
        }
        // Lines aged out of the top of the ring and everything moved up by
        // that much; move with it rather than drifting through the text.
        let evicted = emulator.buffer.scrollbackEvicted
        if let top = pinnedTop, evicted > lastEvicted {
            pinnedTop = max(0, top - CGFloat(evicted - lastEvicted))
        }
        lastEvicted = evicted

        let follow = CGFloat(followTop())
        if let top = pinnedTop, top >= follow {
            pinnedTop = nil
            stateChanged()
        }
        let top = pinnedTop ?? follow
        terminalView.scrollOffset = top * font.cellSize.height

        // Sideways: the grid is wider than the window whenever the phone's
        // columns do not fit at a size worth reading, and then the view
        // follows the cursor unless the driver has panned away from it.
        let left = resolveLeftColumn()
        let x = (-CGFloat(left) * font.cellSize.width).rounded(.down)
        if terminalView.frame.origin.x != x { terminalView.frame.origin.x = x }

        terminalView.setNeedsDisplay()
        updateHeader(linesBelow: Int((follow - top).rounded(.up)))
    }

    /// Settles the leftmost column: pinned where the driver left it, or
    /// following the cursor.
    @discardableResult
    private func resolveLeftColumn() -> Int {
        guard let emulator = pane?.session.emulator, visibleCols < emulator.cols else {
            leftColumn = 0
            return 0
        }
        let highest = emulator.cols - visibleCols
        if let pinned = pinnedLeft {
            leftColumn = min(max(Int(pinned.rounded()), 0), highest)
        } else {
            leftColumn = CarPlayFraming.followLeft(cols: emulator.cols, visibleCols: visibleCols,
                                                   cursorCol: emulator.buffer.cursorX,
                                                   current: leftColumn)
        }
        return leftColumn
    }

    private func followTop() -> Int {
        guard let emulator = pane?.session.emulator else { return 0 }
        let buffer = emulator.buffer
        let screenTop = buffer.scrollbackCount
        var bottom = buffer.cursorY
        // A full-screen program owns every row, so its cursor is the thing to
        // follow. At a shell, output can end below the cursor.
        if !emulator.modes.altScreen {
            var y = buffer.rows - 1
            while y > bottom, buffer.row(at: screenTop + y).trimmedLength == 0 { y -= 1 }
            bottom = y
        }
        return CarPlayFraming.followTop(totalRows: buffer.totalRows, screenRows: buffer.rows,
                                        contentBottom: screenTop + bottom,
                                        visibleRows: visibleRows)
    }

    private func updateHeader(linesBelow: Int) {
        guard let session = pane?.session else { return }
        let root = RootViewController.shared
        var text = session.displayTitle
        if root.tabCount > 1 {
            text = "\(root.selectedTabIndex + 1)/\(root.tabCount)  \(text)"
        }
        if let emulator = pane?.session.emulator, visibleCols < emulator.cols {
            // Which slice of the line is on screen, because a line cut off at
            // the edge otherwise looks like the shell printed it that way.
            text += "  ·  cols \(leftColumn + 1)–\(leftColumn + visibleCols) of \(emulator.cols)"
        }
        if linesBelow > 0 {
            text += "  ·  \(linesBelow) \(linesBelow == 1 ? "line" : "lines") below"
        }
        if header.text != text { header.text = text }
    }

    // MARK: - Colours

    private func makePalette() -> TerminalPalette? {
        guard let emulator = pane?.session.emulator else { return nil }
        // The car's appearance, not the phone's: under "Match System" the
        // dashboard at night gets the dark theme whatever the phone is doing.
        let theme = Preferences.shared.theme(for: traitCollection.userInterfaceStyle)
        return TerminalPalette(theme: theme,
                               paletteOverrides: emulator.paletteOverrides,
                               foregroundOverride: emulator.overrideForeground,
                               backgroundOverride: emulator.overrideBackground,
                               cursorOverride: emulator.overrideCursorColor)
    }

    private func applyPalette() {
        guard let palette = makePalette() else { return }
        view.backgroundColor = palette.defaultBackground.uiColor
        header.textColor = palette.secondaryForeground().uiColor
        terminalView?.update(palette: palette)
    }

    @objc private func appearanceChanged() {
        let prefs = Preferences.shared
        terminalView?.boldIsBright = prefs.boldIsBright
        terminalView?.useBoldFont = prefs.useBoldFont
        fontSettings = FontSettings.current
        areaMayHaveChanged = true
        applyPalette()
        refresh()
    }

    @objc private func paletteChanged(_ note: Notification) {
        guard let session = note.object as? TerminalSession, session === pane?.session else { return }
        applyPalette()
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        if previous?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            applyPalette()
        }
    }

    // MARK: - Controls

    /// Back to the live text, in both directions.
    func scrollToLive() {
        pinnedTop = nil
        pinnedLeft = nil
        refresh()
        stateChanged()
    }

    /// One press of the panning arrows, or a turn of the knob: half a screen.
    func scrollPage(up: Bool) {
        let step = CGFloat(max(1, visibleRows / 2))
        scroll(to: (currentTop + (up ? -step : step)).rounded())
    }

    /// Sideways, for a line too long for the car: half a screen of columns.
    func panPage(left: Bool) {
        let step = CGFloat(max(1, visibleCols / 2))
        panSideways(to: (CGFloat(leftColumn) + (left ? -step : step)).rounded())
    }

    func beginDrag() {
        dragStartTop = currentTop
        dragStartLeft = CGFloat(leftColumn)
    }

    /// Dragging down pulls older lines into view, as it does on the phone,
    /// and dragging sideways moves along a line that does not fit.
    func drag(by translation: CGPoint) {
        guard let font else { return }
        scroll(to: dragStartTop - translation.y / font.cellSize.height)
        // Only once the drag is clearly sideways, so scrolling back through
        // output does not pin the columns as a side effect.
        if abs(translation.x) > 8 {
            panSideways(to: dragStartLeft - translation.x / font.cellSize.width)
        }
    }

    /// Lands on a whole row and column, so nothing is left cut in half.
    func endDrag() {
        if let top = pinnedTop { scroll(to: top.rounded()) }
        if let left = pinnedLeft { panSideways(to: left.rounded()) }
    }

    private var currentTop: CGFloat { pinnedTop ?? CGFloat(followTop()) }

    private func scroll(to top: CGFloat) {
        let wasScrolledBack = isScrolledBack
        pinnedTop = top < CGFloat(followTop()) ? max(0, top) : nil
        refresh()
        if isScrolledBack != wasScrolledBack { stateChanged() }
    }

    private func panSideways(to left: CGFloat) {
        guard let emulator = pane?.session.emulator, visibleCols < emulator.cols else { return }
        let wasScrolledBack = isScrolledBack
        pinnedLeft = min(max(left, 0), CGFloat(emulator.cols - visibleCols))
        refresh()
        if isScrolledBack != wasScrolledBack { stateChanged() }
    }
}
