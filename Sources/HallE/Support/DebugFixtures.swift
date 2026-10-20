import Foundation
import GRDB

/// Inserts sample data for headless UI verification. Only runs when
/// HALLE_DEBUG_FIXTURES=1. Never used in normal operation.
enum DebugFixtures {
    /// True when running with directly-inserted sample data; sync is suppressed so
    /// the fixtures aren't rebuilt away.
    static var isActive: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["HALLE_DEBUG_FIXTURES"] == "1"
        #else
        return false
        #endif
    }

    static func loadIfRequested() {
        guard isActive else { return }
        do { try load() } catch { Log.app.error("fixtures failed: \(error, privacy: .public)") }
    }

    private static func load() throws {
        let db = AppDatabase.shared.dbQueue
        var cal = Calendar(identifier: .gregorian); cal.timeZone = .current
        let today = cal.startOfDay(for: Date())
        func at(_ h: Int, _ m: Int) -> Date { cal.date(byAdding: DateComponents(hour: h, minute: m), to: today)! }

        let accounts = [
            ConnectedAccount(email: "mara@example.test", displayName: "Mara", colorHex: "#3B82F6",
                             addedAt: Date(), needsReauth: false, lastSyncAt: Date(), lastSyncError: nil),
            ConnectedAccount(email: "alex@example.test", displayName: "Alex", colorHex: "#10B981",
                             addedAt: Date(), needsReauth: false, lastSyncAt: Date(), lastSyncError: nil),
        ]

        func source(_ account: String, _ cal: String, _ eventId: String, _ color: String) -> EventSource {
            EventSource(accountEmail: account, calendarId: cal, eventId: eventId, responseStatus: "accepted", colorHex: color)
        }
        func encode(_ s: [EventSource]) -> String { String(decoding: try! JSONEncoder().encode(s), as: UTF8.self) }

        let now = Date()
        let events: [UnifiedEvent] = [
            UnifiedEvent(dedupKey: "fx-allday", title: "Product planning day", startTs: today, endTs: at(23, 59),
                         isAllDay: true, status: "confirmed", effectiveResponse: "accepted", meetingURL: nil,
                         location: nil, descriptionText: nil, htmlLink: "https://calendar.google.com/x",
                         organizerEmail: nil, attendeesJSON: nil, iCalUID: nil, winnerAccountEmail: accounts[0].email,
                         projectId: "Atlas", projectConfidence: 0.9,
                         sourcesJSON: encode([source(accounts[0].email, "c", "1", "#3B82F6")])),
            UnifiedEvent(dedupKey: "fx-now", title: "Atlas · Product review",
                         startTs: now.addingTimeInterval(-600), endTs: now.addingTimeInterval(1800),
                         isAllDay: false, status: "confirmed", effectiveResponse: "accepted",
                         meetingURL: "https://meet.google.com/abc-defg-hij", location: nil, descriptionText: nil,
                         htmlLink: "https://calendar.google.com/y", organizerEmail: "sam@example.test",
                         attendeesJSON: nil, iCalUID: nil, winnerAccountEmail: accounts[1].email,
                         projectId: "Atlas", projectConfidence: 0.95,
                         sourcesJSON: encode([source(accounts[0].email, "c", "2", "#3B82F6"),
                                              source(accounts[1].email, "c", "3", "#10B981")])),
            UnifiedEvent(dedupKey: "fx-next", title: "Studio · Design handoff",
                         startTs: now.addingTimeInterval(2700), endTs: now.addingTimeInterval(5400), isAllDay: false, status: "confirmed",
                         effectiveResponse: "tentative", meetingURL: "https://zoom.us/j/123", location: nil,
                         descriptionText: nil, htmlLink: "https://calendar.google.com/z", organizerEmail: nil,
                         attendeesJSON: nil, iCalUID: nil, winnerAccountEmail: accounts[0].email,
                         projectId: "Studio", projectConfidence: 0.82,
                         sourcesJSON: encode([source(accounts[0].email, "c", "4", "#3B82F6")])),
            UnifiedEvent(dedupKey: "fx-later", title: "Atlas · Launch planning",
                         startTs: now.addingTimeInterval(7200), endTs: now.addingTimeInterval(9000), isAllDay: false, status: "confirmed",
                         effectiveResponse: "accepted", meetingURL: nil, location: "Studio",
                         descriptionText: nil, htmlLink: nil, organizerEmail: nil, attendeesJSON: nil,
                         iCalUID: nil, winnerAccountEmail: accounts[0].email, projectId: "Atlas",
                         projectConfidence: 0.88,
                         sourcesJSON: encode([source(accounts[0].email, "c", "5", "#3B82F6")])),
        ]

        try db.write { db in
            for a in accounts { try a.save(db) }
            for e in events { try e.save(db) }
            let path = AppPaths.appSupport.appendingPathComponent("Atlas product review.md").path
            let body = "# Atlas product review\n\nDecision: test the new onboarding next sprint.\n\n- [ ] Share the revised onboarding design — Alex\n- [x] Gather feedback from the pilot — Mara\n"
            try body.write(toFile: path, atomically: true, encoding: .utf8)
            try VaultDocument(path: path, title: "Atlas product review", type: "meeting",
                project: "Atlas", eventId: "fx-now", contentHash: "preview", modifiedAt: now, body: body).save(db)
            try IndexedActionItem(id: "preview-open", notePath: path, eventId: "fx-now",
                task: "Share the revised onboarding design", owner: "Alex", dueDate: nil,
                project: "Atlas", isCompleted: false, confidence: 1, updatedAt: now).save(db)
            try IndexedActionItem(id: "preview-completed", notePath: path, eventId: "fx-now",
                task: "Gather feedback from the pilot", owner: "Mara", dueDate: nil,
                project: "Atlas", isCompleted: true, confidence: 1, updatedAt: now).save(db)
        }

        // Debug recordings so the per-meeting transcript button (+ its colors) show.
        writeRecording(for: events[1], status: .completed,
                       text: "Reviewed the product plan. Decision: test the new onboarding next sprint. Action item: Alex to share the revised design with the team.")
        writeRecording(for: events[2], status: .inProgress, text: nil)
        writeRecording(for: events[3], status: .failed, text: nil)
    }

    private static func writeRecording(for event: UnifiedEvent, status: TranscriptStatus, text: String?) {
        var s = RecordingSession(event: event, notePath: nil)
        s.state = .completed
        s.endedAt = Date()
        s.transcriptStatus = status
        s.save()
        if let text, status == .completed {
            let t = Transcript(sessionID: s.id, localeUsed: "es-CL",
                               segments: [TranscriptSegment(start: 0, duration: 5, text: text, track: "mic")],
                               status: .completed, source: "sfspeech-on-device")
            TranscriptStore.save(t, to: s)
        }
    }
}
