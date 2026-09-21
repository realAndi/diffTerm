import UIKit

/// The iPhone's (and iPad's) window.
///
/// The tabs are not this scene's to own — see `RootViewController.shared` —
/// so connecting puts them in a window and disconnecting hands them back,
/// ready for the next scene or for the car to keep showing.
///
/// The Objective-C name is fixed because Info.plist names the class, and the
/// Swift module name follows APP_NAME, which a second install changes.
@objc(DTPhoneSceneDelegate)
final class PhoneSceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        // Breadcrumbs, because the other scene this app has can only be
        // tested in a car: see CarPlaySceneDelegate.trace.
        NSLog("diffTerm phone: connecting a window")
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = RootViewController.shared
        window.makeKeyAndVisible()
        self.window = window
        NSLog("diffTerm phone: window up")
    }

    /// The phone is on screen again, so it takes the shell's size back from
    /// the car before anything is drawn. See CarPlayLink.
    func sceneWillEnterForeground(_ scene: UIScene) {
        CarPlayLink.shared.setPhoneVisible(true)
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        CarPlayLink.shared.setPhoneVisible(false)
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        // The software keyboard is shown for the first responder of the *key*
        // window, and connecting CarPlay gives the app a second window that
        // can take that. Without this, tapping the terminal on the phone
        // moved the caret and raised no keyboard.
        PhoneSceneDelegate.takeBackKeyWindow()
    }

    /// Makes the phone's window key again, if the phone is a screen someone
    /// is using. Safe to call with no phone scene: the car's window is left
    /// alone, and it needs no keyboard.
    static func takeBackKeyWindow() {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.session.role == .windowApplication
                      && $0.activationState == .foregroundActive }
            .flatMap { $0.windows }
        guard let window = windows.first(where: { $0.rootViewController != nil }),
              !window.isKeyWindow else { return }
        window.makeKey()
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        // The system may discard the phone's scene while the car still shows
        // the terminal. Let go of the controller so the next window can have
        // it; the shells keep running.
        CarPlayLink.shared.setPhoneVisible(false)
        window?.rootViewController = nil
        window = nil
    }
}
