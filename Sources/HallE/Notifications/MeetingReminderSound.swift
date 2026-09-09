import Foundation
import UserNotifications
import AppKit

enum MeetingReminderSound: String, CaseIterable, Identifiable {
    case gentle, silent, system
    var id: String { rawValue }
    var title: String {
        switch self { case .gentle: "Gentle ring"; case .silent: "Silent"; case .system: "System sound" }
    }
    var notificationSound: UNNotificationSound? {
        switch self {
        case .silent: nil
        case .system: .default
        case .gentle: UNNotificationSound(named: UNNotificationSoundName("GentleRing.wav"))
        }
    }
    func preview() {
        switch self {
        case .silent: break
        case .system: NSSound(named: "Glass")?.play()
        case .gentle:
            if let url = AppResources.bundle.url(forResource: "GentleRing", withExtension: "wav") {
                NSSound(contentsOf: url, byReference: false)?.play()
            }
        }
    }
}

extension AppPreferences {
    static var meetingReminderSound: MeetingReminderSound {
        get { MeetingReminderSound(rawValue: UserDefaults.standard.string(forKey: "meetingReminderSound") ?? "gentle") ?? .gentle }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "meetingReminderSound") }
    }
}
