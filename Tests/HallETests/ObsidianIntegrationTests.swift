import Testing
import Foundation
@testable import HallE

@Suite("Obsidian write path (integration, temp vault)")
struct ObsidianIntegrationTests {
    private func tempVault() -> (ObsidianVaultConfig, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("halle-test-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (ObsidianVaultConfig(vaultPath: dir.path, bookmarkData: nil, subfolderName: "Hall-e"), dir)
    }

    private func event(project: String?) -> UnifiedEvent {
        UnifiedEvent(dedupKey: "ical:UID-777@1000", title: "Director Dashboard Review",
                     startTs: Date(timeIntervalSince1970: 1_800_000_000),
                     endTs: Date(timeIntervalSince1970: 1_800_003_600), isAllDay: false,
                     status: "confirmed", effectiveResponse: "accepted",
                     meetingURL: "https://meet.google.com/x", location: nil, descriptionText: nil,
                     htmlLink: nil, organizerEmail: "ana@getaccurate.cl", attendeesJSON: nil,
                     iCalUID: "UID-777", winnerAccountEmail: "gabriel@getaccurate.cl",
                     projectId: project, projectConfidence: 0.95, sourcesJSON: "[]")
    }

    @Test func createsMeetingNoteWithScaffolding() throws {
        let (config, dir) = tempVault()
        defer { try? FileManager.default.removeItem(at: dir) }
        let service = MeetingNoteService(config: config, vaultURL: dir)

        let d = try service.createOrFindMeetingNote(for: event(project: "Accurate"), projectName: "Accurate")
        #expect(d.wasCreated)
        #expect(FileManager.default.fileExists(atPath: d.absoluteURL.path))

        let content = try String(contentsOf: d.absoluteURL, encoding: .utf8)
        #expect(content.contains("hall_e_event_id: \"ical:UID-777@1000\""))
        #expect(content.contains("# Director Dashboard Review"))
        #expect(content.contains("<!-- hall-e:transcript:start -->"))
        #expect(content.contains("project/accurate"))

        // Project note, meetings index, and daily note created.
        let base = dir.appendingPathComponent("Hall-e")
        #expect(FileManager.default.fileExists(atPath: base.appendingPathComponent("Projects/Accurate/Accurate.md").path))
        let idx = try String(contentsOf: base.appendingPathComponent("Projects/Accurate/Meetings.md"))
        #expect(idx.contains("Director Dashboard Review"))
    }

    @Test func isIdempotentNoDuplicate() throws {
        let (config, dir) = tempVault()
        defer { try? FileManager.default.removeItem(at: dir) }
        let service = MeetingNoteService(config: config, vaultURL: dir)

        _ = try service.createOrFindMeetingNote(for: event(project: "Accurate"), projectName: "Accurate")
        let second = try service.createOrFindMeetingNote(for: event(project: "Accurate"), projectName: "Accurate")
        #expect(!second.wasCreated)

        // Meetings index has exactly one entry line for this meeting.
        let idx = try String(contentsOf: dir.appendingPathComponent("Hall-e/Projects/Accurate/Meetings.md"))
        let entryLines = idx.components(separatedBy: "\n").filter {
            $0.hasPrefix("- ") && $0.contains("Director Dashboard Review")
        }
        #expect(entryLines.count == 1)
    }

    @Test func mergeTranscriptPreservesUserEdits() throws {
        let (config, dir) = tempVault()
        defer { try? FileManager.default.removeItem(at: dir) }
        let service = MeetingNoteService(config: config, vaultURL: dir)
        let d = try service.createOrFindMeetingNote(for: event(project: "Accurate"), projectName: "Accurate")

        // Simulate the user adding their own pre-meeting notes.
        var content = try String(contentsOf: d.absoluteURL, encoding: .utf8)
        content = content.replacingOccurrences(of: "## Pre-meeting notes\n-",
                                               with: "## Pre-meeting notes\n- MY IMPORTANT PREP NOTE")
        try content.write(to: d.absoluteURL, atomically: true, encoding: .utf8)

        // Merge a transcript into the marker block.
        let writer = VaultWriter(vaultURL: dir)
        let pb = VaultPathBuilder(config: config)
        _ = try writer.mergeSection(relativePath: d.vaultRelativePath, section: "transcript",
                                    newContent: "Speaker: hello world.", headingAnchor: "Transcript",
                                    mode: .replace, pathBuilder: pb)

        let after = try String(contentsOf: d.absoluteURL, encoding: .utf8)
        #expect(after.contains("MY IMPORTANT PREP NOTE"))     // user edit preserved
        #expect(after.contains("Speaker: hello world."))       // transcript merged
        #expect(!after.contains("transcript goes here"))       // placeholder gone
    }

    @Test func unclassifiedGoesToInbox() throws {
        let (config, dir) = tempVault()
        defer { try? FileManager.default.removeItem(at: dir) }
        let service = MeetingNoteService(config: config, vaultURL: dir)
        let d = try service.createOrFindMeetingNote(for: event(project: nil), projectName: nil)
        #expect(d.vaultRelativePath.contains("Hall-e/Inbox/"))
        let inbox = try String(contentsOf: dir.appendingPathComponent("Hall-e/Inbox/Unclassified Meetings.md"))
        #expect(inbox.contains("Director Dashboard Review"))
    }

    @Test func whatsAppCallFilesUnderCallsAsCallType() throws {
        let (config, dir) = tempVault()
        defer { try? FileManager.default.removeItem(at: dir) }
        let service = MeetingNoteService(config: config, vaultURL: dir)
        var ev = CallEvent.makeWhatsAppCall(at: Date(timeIntervalSince1970: 1_800_000_000))
        ev.projectId = "Accurate"
        let d = try service.createOrFindMeetingNote(for: ev, projectName: "Accurate", kind: .call)
        #expect(d.vaultRelativePath.hasPrefix("Hall-e/Calls/"))
        #expect(d.vaultRelativePath.contains("Accurate"))
        let content = try String(contentsOf: d.absoluteURL, encoding: .utf8)
        #expect(content.contains("type: call"))
        #expect(content.contains("<!-- hall-e:transcript:start -->"))
    }

    @Test func unclassifiedCallGoesToCallsInbox() throws {
        let (config, dir) = tempVault()
        defer { try? FileManager.default.removeItem(at: dir) }
        let service = MeetingNoteService(config: config, vaultURL: dir)
        let d = try service.createOrFindMeetingNote(for: CallEvent.makeWhatsAppCall(), projectName: nil, kind: .call)
        #expect(d.vaultRelativePath.contains("Hall-e/Calls/Inbox/"))
    }
}
