import UIKit

// Shims for the APIs diffTerm would otherwise need a newer iOS for. The
// deployment floor is iOS 14: a jailbroken phone is often an old phone kept on
// an old release deliberately, and refusing to run on one is the wrong answer
// for this audience.

/// The handful of measurements that should not be the same on a phone held at
/// arm's length and an iPad lying on a desk. Everything else in the layout is
/// deliberately identical on both — a terminal is a grid of text, and the grid
/// does not care what it is running on.
///
/// Each of these takes an idiom rather than reading the device, so the checks
/// can exercise the iPad values on a phone.
enum DeviceMetrics {

    static var idiom: UIUserInterfaceIdiom { UIDevice.current.userInterfaceIdiom }

    /// 13pt is right on a phone. On a 12.9-inch iPad it gives 170 columns of
    /// text no larger than the phone's, on a screen held further away — so the
    /// default goes up and the column count comes back to something a person
    /// reads instead of squints at. It is only a default: pinch and Settings
    /// both still win, and an existing install keeps whatever it had.
    static func defaultFontSize(for idiom: UIUserInterfaceIdiom) -> Double {
        idiom == .pad ? 16 : 13
    }

    /// The key row sits above the software keyboard, whose own rows are taller
    /// on iPad; matching that keeps the strip from looking pasted on.
    static func keyRowHeight(for idiom: UIUserInterfaceIdiom) -> CGFloat {
        idiom == .pad ? 54 : 44
    }

    static func tabBarHeight(for idiom: UIUserInterfaceIdiom) -> CGFloat {
        idiom == .pad ? 44 : 40
    }

    static var defaultFontSize: Double { defaultFontSize(for: idiom) }
    static var keyRowHeight: CGFloat { keyRowHeight(for: idiom) }
    static var tabBarHeight: CGFloat { tabBarHeight(for: idiom) }
}

extension UIColor {

    /// `UIColor.tintColor` — the dynamic colour that resolves to whatever the
    /// view hierarchy's tint is — only exists from iOS 15. Before that,
    /// nothing had changed the tint, so the system default is the same colour.
    static var accentCompat: UIColor {
        if #available(iOS 15.0, *) { return .tintColor }
        return .systemBlue
    }
}
