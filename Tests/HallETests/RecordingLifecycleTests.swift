import Testing
import Foundation
@testable import HallE

@Suite("Recording lifecycle")
struct RecordingLifecycleTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func recordingStoreDeletesOnlyRecordingFolders() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("halle-recording-delete-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = root.appendingPathComponent("session", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: session.appendingPathComponent("mic.m4a"))

        // A folder holding audio but no session.json is not a recording Hall-e
        // wrote, and is left alone rather than removed.
        #expect(throws: RecordingStore.DeletionError.self) {
            try RecordingStore.deleteSessionFolder(relativePath: "session", recordingsDirectory: root)
        }
        try Data("{}".utf8).write(to: session.appendingPathComponent("session.json"))

        try RecordingStore.deleteSessionFolder(relativePath: "session", recordingsDirectory: root)
        #expect(!FileManager.default.fileExists(atPath: session.path))

        #expect(throws: RecordingStore.DeletionError.self) {
            try RecordingStore.deleteSessionFolder(relativePath: "../outside", recordingsDirectory: root)
        }
    }

    @Test func scheduledEndPromptsThenStopsAfterTimeout() {
        var state = RecordingLifecycleState(startedAt: start,
                                            scheduledEndAt: start.addingTimeInterval(60))
        let prompt = state.observe(now: start.addingTimeInterval(60), audioPowerDB: -20,
                                   sourceActive: nil)
        #expect(prompt == [.promptForScheduledEnd])
        let stop = state.observe(now: start.addingTimeInterval(121), audioPowerDB: -20,
                                 sourceActive: nil)
        #expect(stop == [.stop(.scheduledEnd)])
    }

    @Test func exactEndPolicyStopsWithoutPrompt() {
        var state = RecordingLifecycleState(startedAt: start,
                                            scheduledEndAt: start.addingTimeInterval(60))
        var policy = RecordingLifecyclePolicy()
        policy.endPromptTimeout = 0
        #expect(state.observe(now: start.addingTimeInterval(60), audioPowerDB: -20,
                              sourceActive: nil, policy: policy) == [.stop(.scheduledEnd)])
    }

    @Test func meetingLaunchPolicyRequiresARealJoinLink() {
        let oldPreference = AppPreferences.autoRecordCalendarMeetings
        defer { AppPreferences.autoRecordCalendarMeetings = oldPreference }
        AppPreferences.autoRecordCalendarMeetings = true
        var event = UnifiedEvent(dedupKey: "meeting", title: "Meeting",
                                 startTs: start.addingTimeInterval(-60),
                                 endTs: start.addingTimeInterval(600), isAllDay: false,
                                 status: "confirmed", effectiveResponse: "accepted",
                                 meetingURL: nil, location: nil, descriptionText: nil,
                                 htmlLink: nil, organizerEmail: nil, attendeesJSON: nil,
                                 iCalUID: nil, winnerAccountEmail: "a@example.com",
                                 projectId: nil, projectConfidence: nil, sourcesJSON: "[]")
        #expect(!MeetingLaunchPolicy.shouldAutoRecord(event, now: start))
        event.meetingURL = "https://meet.google.com/abc-defg-hij"
        #expect(MeetingLaunchPolicy.shouldAutoRecord(event, now: start))
        event.effectiveResponse = "declined"
        #expect(!MeetingLaunchPolicy.shouldAutoRecord(event, now: start))
    }

    @Test func extensionCreatesANewDeadline() {
        var state = RecordingLifecycleState(startedAt: start,
                                            scheduledEndAt: start.addingTimeInterval(60))
        _ = state.observe(now: start.addingTimeInterval(60), audioPowerDB: -20,
                          sourceActive: nil)
        state.extend(by: 300, now: start.addingTimeInterval(65))
        #expect(state.scheduledEndAt == start.addingTimeInterval(365))
        #expect(state.scheduledEndPromptedAt == nil)
        #expect(state.observe(now: start.addingTimeInterval(300), audioPowerDB: -20,
                              sourceActive: nil).isEmpty)
    }

    @Test func silencePromptsOnceUntilVoiceReturns() {
        var state = RecordingLifecycleState(startedAt: start, scheduledEndAt: nil)
        _ = state.observe(now: start.addingTimeInterval(6), audioPowerDB: -70, sourceActive: nil)
        #expect(state.observe(now: start.addingTimeInterval(27), audioPowerDB: -70,
                              sourceActive: nil) == [.promptForSilence])
        #expect(state.observe(now: start.addingTimeInterval(50), audioPowerDB: -70,
                              sourceActive: nil).isEmpty)
        _ = state.observe(now: start.addingTimeInterval(51), audioPowerDB: -20, sourceActive: nil)
        _ = state.observe(now: start.addingTimeInterval(52), audioPowerDB: -70, sourceActive: nil)
        #expect(state.observe(now: start.addingTimeInterval(73), audioPowerDB: -70,
                              sourceActive: nil) == [.promptForSilence])
    }

    @Test func endedAudioSourceUsesStableConfirmation() {
        var state = RecordingLifecycleState(startedAt: start, scheduledEndAt: nil)
        #expect(state.observe(now: start, audioPowerDB: -20, sourceActive: false).isEmpty)
        #expect(state.observe(now: start.addingTimeInterval(5), audioPowerDB: -20,
                              sourceActive: false).isEmpty)
        #expect(state.observe(now: start.addingTimeInterval(6), audioPowerDB: -20,
                              sourceActive: false) == [.stop(.sourceEnded)])
    }

    /// Stopping a recording before the meeting's booked end used to leave the
    /// agenda row unchanged, which is indistinguishable from the recording
    /// having been deleted.
    @Test func manuallyStoppedRecordingExposesArtifactsBeforeScheduledEnd() {
        let event = Self.event(start: start, duration: 2 * 3600)
        var session = RecordingSession(event: event, notePath: nil)
        let stoppedAt = start.addingTimeInterval(68 * 60)
        let stillInsideTheSlot = start.addingTimeInterval(70 * 60)

        #expect(!session.isFinished)
        #expect(!MeetingArtifactAvailability.showsArtifacts(session: session, eventEnd: event.endTs,
                                                            now: stillInsideTheSlot))

        session.stopReason = .manual
        session.endedAt = stoppedAt
        session.state = .completed

        #expect(session.isFinished)
        #expect(MeetingArtifactAvailability.showsArtifacts(session: session, eventEnd: event.endTs,
                                                           now: stillInsideTheSlot))
    }

    /// A session interrupted before `endedAt` was stamped must still surface
    /// once the meeting is over, as it did before finish-based gating.
    @Test func interruptedRecordingStillAppearsAfterTheMeetingEnds() {
        let event = Self.event(start: start, duration: 3600)
        let session = RecordingSession(event: event, notePath: nil)
        #expect(!session.isFinished)
        #expect(!MeetingArtifactAvailability.showsArtifacts(session: session, eventEnd: event.endTs,
                                                            now: start.addingTimeInterval(600)))
        #expect(MeetingArtifactAvailability.showsArtifacts(session: session, eventEnd: event.endTs,
                                                           now: event.endTs))
    }

    private static func event(start: Date, duration: TimeInterval) -> UnifiedEvent {
        UnifiedEvent(dedupKey: "event", title: "Get Accurate", startTs: start,
                     endTs: start.addingTimeInterval(duration), isAllDay: false,
                     status: "confirmed", effectiveResponse: nil, meetingURL: nil,
                     location: nil, descriptionText: nil, htmlLink: nil,
                     organizerEmail: nil, attendeesJSON: nil, iCalUID: nil,
                     winnerAccountEmail: "a@example.com", projectId: nil,
                     projectConfidence: nil, sourcesJSON: "[]")
    }

    @Test func oldRecordingJSONDecodesWithoutNewMetadata() throws {
        let event = UnifiedEvent(dedupKey: "event", title: "Past meeting", startTs: start,
                                 endTs: start.addingTimeInterval(60), isAllDay: false,
                                 status: "confirmed", effectiveResponse: nil, meetingURL: nil,
                                 location: nil, descriptionText: nil, htmlLink: nil,
                                 organizerEmail: nil, attendeesJSON: nil, iCalUID: nil,
                                 winnerAccountEmail: "a@example.com", projectId: nil,
                                 projectConfidence: nil, sourcesJSON: "[]")
        let session = RecordingSession(event: event, notePath: nil)
        let encoded = try JSONEncoder().encode(session)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for key in ["eventStartAt", "scheduledEndAt", "sourceKind", "stopReason",
                    "playbackFileName", "systemAudioStartedAt"] { object.removeValue(forKey: key) }
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(RecordingSession.self, from: legacy)
        #expect(decoded.eventDedupKey == "event")
        #expect(decoded.sourceKind == nil)
        #expect(decoded.playbackURL == decoded.micURL)
    }
}
