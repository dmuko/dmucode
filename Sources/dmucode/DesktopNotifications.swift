import AppKit
import dmucodeCore
import UserNotifications

/// macOS notifications for programs' notifications (OSC 9/777) in sessions
/// the user isn't looking at while dmucode is in the background. One per
/// session: a new one replaces the session's previous one, and showing the
/// session removes it. Clicking one shows the session.
final class DesktopNotifier: NSObject, UNUserNotificationCenterDelegate {
    /// Called with the session id when the user clicks a notification.
    var onSelect: ((String) -> Void)?

    private let center = UNUserNotificationCenter.current()
    /// The last authorization error, for the debug hook.
    private var lastError: String?
    static let bodyLimit = 200

    override init() {
        super.init()
        center.delegate = self
    }

    /// Asks for permission if it was never asked. Called once the window is
    /// in front, so the system's question appears over it.
    func requestAuthorizationIfNeeded() {
        center.getNotificationSettings { [weak self] settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            self?.requestAuthorization { _ in }
        }
    }

    /// Nothing is shown if permission was denied. The outcome is read from
    /// the settings: on macOS 26 the request's completion has reported "not
    /// allowed" for an app that the settings then show as authorized.
    func post(sessionID: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = Self.truncated(body)
        content.userInfo = ["sessionID": sessionID]
        content.threadIdentifier = sessionID
        let request = UNNotificationRequest(identifier: Self.identifier(sessionID), content: content, trigger: nil)
        center.getNotificationSettings { [weak self] settings in
            guard let self else { return }
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                self.add(request)
            case .notDetermined:
                self.requestAuthorization { allowed in if allowed { self.add(request) } }
            default:
                break
            }
        }
    }

    private func add(_ request: UNNotificationRequest) {
        center.add(request) { error in
            if let error { Log.ghostty.error("notification: \(String(describing: error), privacy: .public)") }
        }
    }

    private func requestAuthorization(_ then: @escaping (Bool) -> Void) {
        center.requestAuthorization(options: [.alert]) { [weak self] _, error in
            guard let self else { return }
            if let error {
                Log.ghostty.error("notification authorization: \(String(describing: error), privacy: .public)")
                DispatchQueue.main.async { self.lastError = String(describing: error) }
            }
            self.center.getNotificationSettings { then($0.authorizationStatus == .authorized) }
        }
    }

    func clear(sessionID: String) {
        center.removeDeliveredNotifications(withIdentifiers: [Self.identifier(sessionID)])
        center.removePendingNotificationRequests(withIdentifiers: [Self.identifier(sessionID)])
    }

    private static func identifier(_ sessionID: String) -> String { "session:" + sessionID }

    /// The first line, cut to `bodyLimit` characters with an ellipsis.
    static func truncated(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > bodyLimit else { return trimmed }
        return String(trimmed.prefix(bodyLimit - 1)) + "…"
    }

    // MARK: UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let id = response.notification.request.content.userInfo["sessionID"] as? String {
            DispatchQueue.main.async { self.onSelect?(id) }
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // Posted only while dmucode is in the background; if it came to the
        // front meanwhile, show the banner anyway.
        completionHandler([.banner])
    }

    // MARK: Debugging

    /// "authorization=… delivered=[session:$1=Title: body,…]", for the debug hook.
    var debugState: String {
        let done = DispatchSemaphore(value: 0)
        var status = "?", delivered: [String] = []
        center.getNotificationSettings { settings in
            status = "\(settings.authorizationStatus.rawValue)"
            self.center.getDeliveredNotifications { notifications in
                delivered = notifications.map { "\($0.request.identifier)=\($0.request.content.title): \($0.request.content.body)" }
                done.signal()
            }
        }
        _ = done.wait(timeout: .now() + 2)
        return "notifications: authorization=\(status) delivered=[\(delivered.joined(separator: ","))]"
            + (lastError.map { " error=\($0)" } ?? "")
    }
}
