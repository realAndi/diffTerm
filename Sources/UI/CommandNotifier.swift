import UIKit
import UserNotifications

/// How a tab's most recent command is doing, for the dot on the tab chip.
enum CommandStatus {
    case none
    case running
    case failed

    /// Deliberately no `succeeded` case. A dot on every finished command is
    /// noise; what you want to notice is something still going, or something
    /// that went wrong. Success is the dot disappearing.
    static func from(_ integration: ShellIntegration) -> CommandStatus {
        guard let block = integration.last else { return .none }
        if block.isRunning { return .running }
        if let code = block.exitCode, code != 0 { return .failed }
        return .none
    }
}

/// Posts a local notification when a command finishes while you are somewhere
/// else.
///
/// This is the thing a terminal on a phone can do that one on a desktop cannot
/// be bothered to: you start a build, switch to Safari, and it tells you. It is
/// driven by the OSC 133 marks rather than by output, which is what makes it
/// safe — the text is assembled here from a structured mark and an exit code,
/// not echoed from whatever the program felt like printing.
///
/// Local notifications need no entitlement; only push does.
enum CommandNotifier {

    /// Commands shorter than this are not worth a notification — you were
    /// still looking at the screen when they finished.
    private static let minimumDuration: TimeInterval = 10

    private static var authorizationRequested = false
    private static var authorized = false

    /// Called when a command finishes. Does nothing unless the app is in the
    /// background, the command ran long enough, and the user has not turned
    /// this off.
    static func commandFinished(_ block: CommandBlock, command: String?, title: String) {
        guard Preferences.shared.notifyOnCommandFinish else { return }
        guard UIApplication.shared.applicationState != .active else { return }
        guard let duration = block.duration, duration >= minimumDuration else { return }

        requestAuthorizationIfNeeded { granted in
            guard granted else { return }
            post(block, command: command, title: title, duration: duration)
        }
    }

    private static func requestAuthorizationIfNeeded(_ completion: @escaping (Bool) -> Void) {
        if authorizationRequested {
            completion(authorized)
            return
        }
        authorizationRequested = true
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { granted, _ in
                authorized = granted
                completion(granted)
            }
    }

    private static func post(_ block: CommandBlock, command: String?,
                             title: String, duration: TimeInterval) {
        let content = UNMutableNotificationContent()
        let failed = (block.exitCode ?? 0) != 0

        content.title = failed ? "Command failed" : "Command finished"

        var parts: [String] = []
        if let command, !command.isEmpty { parts.append(command) }
        if let code = block.exitCode, code != 0 { parts.append("exit \(code)") }
        parts.append(format(duration))
        content.body = parts.joined(separator: " · ")

        if !title.isEmpty { content.subtitle = title }
        content.sound = .default

        // No trigger: deliver now.
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private static func format(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded())
        if whole < 60 { return "\(whole)s" }
        if whole < 3600 { return "\(whole / 60)m \(whole % 60)s" }
        return "\(whole / 3600)h \((whole % 3600) / 60)m"
    }
}
