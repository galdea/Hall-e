import Foundation
import Testing
import GRDB
@testable import HallE

struct LocalBriefingSafetyTests {
    private func fixture() -> (Transcript, MeetingBriefing) {
        let transcript = Transcript(sessionID: UUID(), localeUsed: "en", segments: [
            .init(start: 10, duration: 5, text: "Alex will send the proposal on October 7.", track: "mixed", speaker: 0)
        ], status: .completed, source: "fixture")
        let task = BriefingItem(id: "send-proposal", title: "Send proposal", ownerKind: .explicitName, ownerName: "Alex",
            explicitDate: "October 7", priority: 1, confidence: 0.9,
            evidence: [.init(utteranceIndex: 0, start: 10, end: 15, excerpt: "Alex will send the proposal on October 7")])
        return (transcript, MeetingBriefing(schemaVersion: MeetingBriefing.schema, headline: "Proposal", objectives: [], tasks: [task],
            decisions: [], risks: [], openQuestions: [], milestones: [], confidence: 0.9,
            transcriptHash: transcript.contentHash, promptVersion: "local-v1", model: "local-agent", generatedAt: "2026-10-01T12:00:00Z"))
    }
    @Test func exactEvidenceIsAcceptedButFabricatedExcerptOrWrongTimestampRejected() throws {
        let (transcript, original) = fixture()
        _ = try LocalBriefingImport.decode(JSONEncoder().encode(original), transcript: transcript)
        var fabricated = original; fabricated.tasks[0].evidence[0].excerpt = "Alex will pay $1000 on October 7"
        #expect(throws: BriefingValidationError.self) { try MeetingBriefingValidator.validate(fabricated, transcript: transcript) }
        var wrongTime = original; wrongTime.tasks[0].evidence[0].start = 0
        #expect(throws: BriefingValidationError.self) { try MeetingBriefingValidator.validate(wrongTime, transcript: transcript) }
        wrongTime = original; wrongTime.tasks[0].evidence[0].end = 1000
        #expect(throws: BriefingValidationError.self) { try MeetingBriefingValidator.validate(wrongTime, transcript: transcript) }
    }
    @Test func changedRevisionAnonymousIdentityAndPartialOwnerNamesAreRejected() {
        let (transcript, original) = fixture()
        var revision = original; revision.transcriptHash = "wrong"
        #expect(throws: BriefingValidationError.self) { try MeetingBriefingValidator.validate(revision, transcript: transcript) }
        var owner = original; owner.tasks[0].ownerName = "Gab"
        #expect(throws: BriefingValidationError.self) { try MeetingBriefingValidator.validate(owner, transcript: transcript) }
        owner.tasks[0].ownerKind = .unassigned; owner.tasks[0].ownerName = "Alex"
        #expect(throws: BriefingValidationError.self) { try MeetingBriefingValidator.validate(owner, transcript: transcript) }
    }
    @Test func completedCommitmentIsNotReopenedByRepeatedImportAndEvidenceRemainsLinked() {
        let (transcript, briefing) = fixture()
        let actions = LocalBriefingImport.actions(briefing)
        #expect(actions.contains("[[#Evidence u0|u0 @ 10s]]"))
        #expect(actions.contains("(@Alex)") && actions.contains("— due October 7"))
        #expect(LocalBriefingImport.newActions(briefing, existingNote: actions.replacingOccurrences(of: "- [ ]", with: "- [x]")).isEmpty)
        let appendix = LocalBriefingImport.evidenceAppendix(briefing, transcript: transcript)
        #expect(appendix.contains("### Evidence u0") && appendix.contains("Anonymous speaker 1"))
    }
    @Test func v7MigrationPreservesLegacyEventsAndManualAssignments() throws {
        let queue = try DatabaseQueue()
        var migrator = AppDatabase.migrator; migrator.eraseDatabaseOnSchemaChange = false
        try migrator.migrate(queue, upTo: "v6_recurring_project_assignments")
        try queue.write { db in
            try db.execute(sql: "INSERT INTO calendar_event(accountEmail, calendarId, eventId, title, startTs, endTs, fetchedAt) VALUES (?, ?, ?, ?, ?, ?, ?)",
                arguments: ["fixture", "calendar", "event", "Saved recording meeting", Date(timeIntervalSince1970: 100), Date(timeIntervalSince1970: 200), Date()])
            try db.execute(sql: "INSERT INTO event_project_assignment(dedupKey, projectId, updatedAt) VALUES ('fixture-event', 'explicit-project', ?)", arguments: [Date()])
        }
        try migrator.migrate(queue)
        try queue.read { db throws -> Void in
            #expect(try CalendarEvent.fetchCount(db) == 1)
            #expect(try CalendarEvent.fetchAll(db)[0].title == "Saved recording meeting")
            #expect(try String.fetchOne(db, sql: "SELECT projectId FROM event_project_assignment WHERE dedupKey = 'fixture-event'") == "explicit-project")
            #expect(try CalendarCreationRecord.fetchCount(db) == 0)
        }
    }
    @Test func writeConsentIsExplicitAndDefaultOAuthRemainsReadOnly() {
        let config = GoogleClientConfig(clientId: "fixture", clientSecret: "fixture", authURI: "https://accounts.google.com/o/oauth2/v2/auth", tokenURI: "https://oauth2.googleapis.com/token")
        let pkce = PKCE()
        let initial = GoogleOAuthClient(config: config).buildAuthURL(pkce: pkce, redirectURI: "http://127.0.0.1:12345")
        let write = GoogleOAuthClient(config: config, requestedScopes: GoogleOAuthClient.scope + " " + GoogleOAuthClient.writeScope,
            loginHint: "fixture@example.invalid").buildAuthURL(pkce: pkce, redirectURI: "http://127.0.0.1:12345")
        let initialItems = URLComponents(url: initial, resolvingAgainstBaseURL: false)!.queryItems!
        let writeItems = URLComponents(url: write, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(initialItems.first { $0.name == "scope" }?.value == GoogleOAuthClient.scope)
        #expect(writeItems.first { $0.name == "scope" }?.value?.contains(GoogleOAuthClient.writeScope) == true)
        #expect(writeItems.first { $0.name == "login_hint" }?.value == "fixture@example.invalid")
    }
}
