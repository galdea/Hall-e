import Foundation
import UserNotifications
import AppKit

/// Handles notification presentation and action taps (Join / Open agenda /
/// Prepare note / Snooze).
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    /// Show banners even while Hall-e is frontmost.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async
    -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let dedupKey = info["dedupKey"] as? String ?? ""
        let meetingURL = (info["meetingURL"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }
        let htmlLink = (info["htmlLink"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }

        switch response.actionIdentifier {
        case "JOIN":
            if let url = meetingURL ?? htmlLink { await MainActor.run { NSWorkspace.shared.open(url) } }
        case "OPEN_AGENDA", UNNotificationDefaultActionIdentifier:
            await MainActor.run { NotificationCenter.default.post(name: .halleShowPopover, object: nil) }
        case "PREPARE_NOTE":
            await MainActor.run {
                if let event = Self.event(forDedupKey: dedupKey) { Features.current.prepareNote(for: event) }
            }
        case "SNOOZE_5M":
            await scheduleSnooze(from: response.notification)
        default:
            break
        }
    }

    private func scheduleSnooze(from notification: UNNotification) async {
        let content = notification.request.content.mutableCopy() as! UNMutableNotificationContent
        content.body = "Snoozed · \(content.body)"
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 5 * 60, repeats: false)
        let request = UNNotificationRequest(identifier: notification.request.identifier + "|snooze",
                                            content: content, trigger: trigger)
        try? await UNUserNotificationCenter.current().add(request)
    }

    @MainActor
    private static func event(forDedupKey key: String) -> UnifiedEvent? {
        AppState.shared.agenda.first { $0.dedupKey == key }
    }
}

extension Notification.Name {
    static let halleShowPopover = Notification.Name("cl.gabriel.hall-e.showPopover")
}
