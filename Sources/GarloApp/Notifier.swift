import Foundation
import UserNotifications
import GarloCore

/// macOS notifications for confirmed slow or stalled findings: the verdict
/// and the first action. Authorization is requested on first use. Only
/// works inside a bundle; the bare binary skips silently.
final class Notifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = Notifier()
    private var available: Bool { Bundle.main.bundleIdentifier != nil }
    private var authorized = false

    func registerCategories() {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([UNNotificationCategory(identifier: "finding", actions: [], intentIdentifiers: [])])
    }

    func post(_ f: Finding) {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        let deliver = { [self] in
            let content = UNMutableNotificationContent()
            content.title = f.verdict
            content.body = f.actions.first.map { "\(f.subject). \($0.title)." } ?? f.subject
            content.categoryIdentifier = "finding"
            content.sound = nil
            _ = self
            center.add(UNNotificationRequest(identifier: f.key, content: content, trigger: nil))
        }
        if authorized {
            deliver()
        } else {
            center.requestAuthorization(options: [.alert]) { [weak self] granted, _ in
                self?.authorized = granted
                if granted { deliver() }
            }
        }
    }

    /// One quiet note after a self-update relaunched the app.
    func postUpdated(version: String) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = "Garlo updated"
        content.body = "Now running version \(version)."
        content.sound = nil
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "updated-\(version)", content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}
