import UIKit

/// Auto-repeat for a held key.
///
/// iOS supplies none of this for the two ways diffTerm takes input. A hardware
/// key reports `pressesBegan` exactly once however long it is held, and a
/// button in the key row has no notion of a hold at all — so leaning on
/// backspace erased one character and leaning on an arrow moved one cell.
/// Every other keyboard in the world keeps going, so this drives the repeat
/// itself, on the delay-then-accelerate curve people already have in their
/// fingers.
///
/// One repeater tracks one hold. That is not a simplification: pressing a
/// second key while the first is down transfers the repeat to it, which is
/// what a real keyboard does too.
final class KeyRepeater {

    /// How long a key is held before it starts repeating. Shorter than this
    /// and a deliberate single press turns into two.
    static let initialDelay: TimeInterval = 0.4
    /// The gap between the first repeats...
    static let slowInterval: TimeInterval = 0.11
    /// ...and the gap it settles at once the hold is clearly deliberate.
    /// Crossing a long command line one cell at a time at the slow rate takes
    /// longer than anyone will wait.
    static let fastInterval: TimeInterval = 0.035
    /// How many repeats it takes to get from one to the other.
    static let rampLength = 10
    /// A hold whose release is never reported — the app is backgrounded
    /// mid-press, a touch is swallowed — would otherwise repeat for ever.
    static let maximumHold: TimeInterval = 15

    /// The wait before repeat number `index`, counting the first repeat after
    /// the initial delay as 1.
    static func interval(beforeRepeat index: Int) -> TimeInterval {
        guard index > 1 else { return initialDelay }
        let progress = min(1, Double(index - 2) / Double(rampLength))
        return slowInterval + (fastInterval - slowInterval) * progress
    }

    private var timer: Timer?
    private var action: (() -> Void)?
    private var scheduled = 0
    private var startedAt: CFTimeInterval = 0

    /// What is being held, so that a caller can tell its own hold from
    /// somebody else's and so a stale release cancels nothing.
    private(set) var held: AnyHashable?
    /// How many repeats the current — or most recent — hold has produced.
    private(set) var repeatCount = 0

    var isRepeating: Bool { timer != nil }

    func isHolding(_ token: AnyHashable) -> Bool { held == token }

    /// Starts a hold. Nothing is sent now: the caller has already decided
    /// whether the press itself sends, and the first repeat lands after
    /// `initialDelay`.
    func begin(_ token: AnyHashable, action: @escaping () -> Void) {
        stop()
        held = token
        self.action = action
        scheduled = 0
        repeatCount = 0
        startedAt = CACurrentMediaTime()
        schedule()
    }

    /// Ends the hold on `token` and reports how many repeats it produced, so
    /// a caller that sends on release can tell whether the hold already
    /// covered it. Zero if something else is being held.
    @discardableResult
    func stop(_ token: AnyHashable) -> Int {
        guard held == token else { return 0 }
        return stop()
    }

    /// Ends whatever is being held, and reports how many repeats it produced.
    @discardableResult
    func stop() -> Int {
        timer?.invalidate()
        timer = nil
        action = nil
        held = nil
        return repeatCount
    }

    private func schedule() {
        scheduled += 1
        let timer = Timer(timeInterval: KeyRepeater.interval(beforeRepeat: scheduled),
                          repeats: false) { [weak self] _ in
            self?.fire()
        }
        // Common modes, or scrolling the key row would freeze a repeat that is
        // already under way.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func fire() {
        guard let action else { return }
        guard CACurrentMediaTime() - startedAt < KeyRepeater.maximumHold else {
            stop()
            return
        }
        repeatCount += 1
        action()
        // The action can end the hold — a repeat that reaches the start of the
        // line, a pane going away — so only carry on if it is still live.
        if self.action != nil { schedule() }
    }
}

// MARK: - Which keys repeat

extension SpecialKey {

    /// Whether holding this key should keep sending it. Moving and deleting
    /// are what you lean on a key to do; escape, tab, enter and the function
    /// keys are things you mean exactly once, and a repeat of any of them is a
    /// mess someone has to undo.
    var repeatsWhenHeld: Bool {
        switch self {
        case .up, .down, .left, .right, .backspace, .delete, .pageUp, .pageDown:
            return true
        default:
            return false
        }
    }
}

extension KeyRowAction {

    var repeatsWhenHeld: Bool {
        switch self {
        case .special(let id):            return id.key.repeatsWhenHeld
        case .combo(_, .special(let id)): return id.key.repeatsWhenHeld
        default:                          return false
        }
    }
}
