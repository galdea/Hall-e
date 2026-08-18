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
        await markDelivered(notification)
        return [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let dedupKey = info["dedupKey"] as? String ?? ""
        let meetingURL = (info["meetingURL"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }
        let htmlLink = (info["htmlLink"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }
        await markDelivered(response.notification)

        switch response.actionIdentifier {
        case "RECORDING_STOP":
            let reason: RecordingStopReason = (info["recordingPrompt"] as? String) == "scheduledEnd"
                ? .scheduledEnd : .silencePrompt
            await MainActor.run { RecordingService.shared.stop(reason: reason) }
        case "RECORDING_KEEP":
            await MainActor.run { RecordingService.shared.keepRecordingAfterSilence() }
        case "RECORDING_EXTEND":
            await MainActor.run { RecordingService.shared.extendScheduledEnd() }
        case "JOIN":
            await MainActor.run {
                if let event = Self.event(forDedupKey: dedupKey), MeetingLauncher.join(event) { return }
                if let url = meetingURL ?? htmlLink { NSWorkspace.shared.open(url) }
            }
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

    private func markDelivered(_ notification: UNNotification) async {
        let info = notification.request.content.userInfo
        guard let key = info["dedupKey"] as? String,
              let event = await MainActor.run(body: { Self.event(forDedupKey: key) }) else { return }
        await NotificationScheduler.shared.markDelivered(dedupKey: key, startTs: event.startTs)
    }

    @MainActor
    private static func event(forDedupKey key: String) -> UnifiedEvent? {
        AppState.shared.agenda.first { $0.dedupKey == key }
    }
}

extension Notification.Name {
    static let halleShowPopover = Notification.Name("cl.gabriel.hall-e.showPopover")
}
