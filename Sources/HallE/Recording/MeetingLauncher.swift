import Foundation
import AppKit

enum MeetingLaunchPolicy {
    static func shouldAutoRecord(_ event: UnifiedEvent, now: Date = Date()) -> Bool {
        guard AppPreferences.autoRecordCalendarMeetings,
              !event.isAllDay,
              event.status != "cancelled",
              event.effectiveResponse != "declined",
              event.endTs > now,
              let link = event.meetingURL,
              URL(string: link) != nil else { return false }
        return true
    }
}

@MainActor
enum MeetingLauncher {
    @discardableResult
    static func join(_ event: UnifiedEvent) -> Bool {
        guard let link = event.meetingURL, let url = URL(string: link) else { return false }
        NSWorkspace.shared.open(url)
        if MeetingLaunchPolicy.shouldAutoRecord(event) {
            RecordingCoordinator.startAutomaticRecording(for: event)
        }
        return true
    }
}
