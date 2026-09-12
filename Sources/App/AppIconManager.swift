import UIKit
import ObjectiveC

/// Keeps the home screen icon in step with the terminal theme.
///
/// Two things make this less trivial than it sounds. The public
/// `setAlternateIconName` puts up a system alert every single time, which is
/// intolerable for something that fires on a theme change; the private
/// variant does the same work silently and is present through iOS 17. And the
/// call is rejected outright while the app is backgrounded, so the work is
/// deferred to activation rather than fired and forgotten.
enum AppIconManager {

    /// Alternate icon names declared in Info.plist, so a theme added without
    /// regenerating icons degrades to "leave it alone" instead of failing.
    private static let declaredIcons: Set<String> = {
        guard let icons = Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any],
              let alternates = icons["CFBundleAlternateIcons"] as? [String: Any] else { return [] }
        return Set(alternates.keys)
    }()

    static var isSupported: Bool {
        UIApplication.shared.supportsAlternateIcons && !declaredIcons.isEmpty
    }

    /// Applies the icon matching `theme`, or does nothing if the user has
    /// taken the wheel.
    static func apply(theme: Theme) {
        guard Preferences.shared.matchIconToTheme else { return }
        setIcon(named: declaredIcons.contains(theme.id) ? theme.id : nil)
    }

    /// Back to the icon shipped with the app — what icon themers expect to
    /// find when they turn the feature off.
    static func restoreDefault() {
        setIcon(named: nil)
    }

    private static func setIcon(named name: String?) {
        guard isSupported else { return }
        let app = UIApplication.shared

        // Setting the icon it already has still triggers the alert on the
        // public path and churns for nothing on the private one.
        guard app.alternateIconName != name else { return }

        // Rejected outside the active state; retry when we come back.
        guard app.applicationState == .active else {
            pendingIconName = name
            hasPendingIcon = true
            return
        }
        hasPendingIcon = false

        if setIconSilently(app, name: name) { return }

        app.setAlternateIconName(name) { error in
            if let error { print("diffTerm: icon change failed — \(error.localizedDescription)") }
        }
    }

    /// The alert-free path. Returns false if it could not be taken, in which
    /// case the caller falls back to the public API.
    private static func setIconSilently(_ app: UIApplication, name: String?) -> Bool {
        let selector = NSSelectorFromString("_setAlternateIconName:completionHandler:")
        guard app.responds(to: selector),
              let method = class_getInstanceMethod(UIApplication.self, selector),
              let encoding = method_getTypeEncoding(method) else { return false }

        // Calling into a private method with the wrong shape is how you get a
        // segfault instead of a fallback, so the signature is checked first:
        // void return, and a block in the last argument slot. (Passing a nil
        // block here also crashes — it is dereferenced unconditionally.)
        let signature = String(cString: encoding)
        guard signature.hasPrefix("v"), signature.contains("@?"),
              method_getNumberOfArguments(method) == 4 else { return false }

        typealias SilentSetter = @convention(c)
            (AnyObject, Selector, NSString?, @convention(block) (NSError?) -> Void) -> Void
        let setter = unsafeBitCast(method_getImplementation(method), to: SilentSetter.self)
        setter(app, selector, name as NSString?) { error in
            if let error {
                print("diffTerm: icon change failed — \(error.localizedDescription)")
            }
        }
        return true
    }

    private static var pendingIconName: String?
    private static var hasPendingIcon = false

    /// Called when the app becomes active, to run a change the system refused
    /// while we were in the background.
    static func applyPendingIfNeeded() {
        guard hasPendingIcon else { return }
        hasPendingIcon = false
        setIcon(named: pendingIconName)
    }
}
