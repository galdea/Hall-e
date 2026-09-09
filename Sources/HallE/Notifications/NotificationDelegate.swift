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

        if response.actionIdentifier.hasPrefix("RECORDING_") {
            await MainActor.run {
                let recorder = RecordingService.shared
                guard let session = info["recordingSessionID"] as? String,
                      let prompt = info["recordingPromptID"] as? String,
                      recorder.isRecording,
                      recorder.currentSession?.id.uuidString == session,
                      recorder.activePromptID?.uuidString == prompt else { return }
                switch response.actionIdentifier {
                case "RECORDING_STOP":
                    recorder.stop(reason: (info["recordingPrompt"] as? String) == "scheduledEnd" ? .scheduledEnd : .silencePrompt)
                case "RECORDING_KEEP": recorder.keepRecordingAfterSilence()
                case "RECORDING_EXTEND": recorder.extendScheduledEnd()
                default: break
                }
            }
            return
        }
        if info["recordingPrompt"] != nil {
            await MainActor.run { NotificationCenter.default.post(name: .halleShowPopover, object: nil) }
            return
        }
        switch response.actionIdentifier {
        case "JOIN":
            await MainActor.run {
                if let event = Self.event(forDedupKey: dedupKey), MeetingLauncher.join(event) { return }
                if let url = meetingURL ?? htmlLink { NSWorkspace.shared.open(url) }
            }
        case "OPEN_AGENDA", UNNotificationDefaultActionIdentifier:
            await MainActor.run { NotificationCenter.default.post(name: .halleOpenMeeting, object: nil, userInfo: ["dedupKey": dedupKey]) }
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
        guard AppPreferences.notificationsEnabled else { return }
        let content = notification.request.content.mutableCopy() as! UNMutableNotificationContent
        let fire = Date().addingTimeInterval(5 * 60)
        guard !AppPreferences.isQuietHour(fire) else { return }
        content.body = "Snoozed · \(content.body)"
        content.sound = AppPreferences.meetingReminderSound.notificationSound
        content.userInfo["soundChoice"] = AppPreferences.meetingReminderSound.rawValue
        content.userInfo["snoozeFireAt"] = fire.timeIntervalSince1970
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 5 * 60, repeats: false)
        let request = UNNotificationRequest(identifier: notification.request.identifier.replacingOccurrences(of: "|snooze", with: "") + "|snooze",
                                            content: content, trigger: trigger)
        try? await UNUserNotificationCenter.current().add(request)
    }

    private func markDelivered(_ notification: UNNotification) async {
        let info = notification.request.content.userInfo
        guard let key = info["dedupKey"] as? String,
              let epoch = info["startTs"] as? Double else { return }
        await NotificationScheduler.shared.markDelivered(dedupKey: key, startTs: Date(timeIntervalSince1970: epoch))
    }

    @MainActor
    private static func event(forDedupKey key: String) -> UnifiedEvent? {
        AppState.shared.agenda.first { $0.dedupKey == key }
    }
}

extension Notification.Name {
    static let halleShowPopover = Notification.Name("cl.gabriel.hall-e.showPopover")
}
