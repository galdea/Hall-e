import Foundation

struct ObsidianNoteDescriptor {
    var vaultRelativePath: String
    var absoluteURL: URL
    var wasCreated: Bool
}

/// Creates and maintains meeting notes, project notes, indexes, and daily notes
/// non-destructively. Classification (project) is provided by the caller; nil →
/// the note lands in the Inbox.
struct MeetingNoteService {
    let config: ObsidianVaultConfig
    let vaultURL: URL
    private var pathBuilder: VaultPathBuilder { VaultPathBuilder(config: config) }
    private var writer: VaultWriter { VaultWriter(vaultURL: vaultURL) }

    static func make() -> MeetingNoteService? {
        guard let config = ObsidianVaultConfig.load(),
              let url = MainActor.assumeIsolated({ VaultAccess.currentVaultURL() }) else { return nil }
        return MeetingNoteService(config: config, vaultURL: url)
    }

    /// Idempotently create (or find) the meeting note for `event`.
    @discardableResult
    func createOrFindMeetingNote(for event: UnifiedEvent, projectName: String?) throws -> ObsidianNoteDescriptor {
        let relPath = projectName != nil
            ? pathBuilder.meetingNote(date: event.startTs, projectName: projectName, title: event.title)
            : pathBuilder.inboxMeetingNote(date: event.startTs, title: event.title)
        let url = pathBuilder.absoluteURL(relPath, vaultURL: vaultURL)

        // Dedupe: if the expected file already carries this event id, reuse it.
        if FileManager.default.fileExists(atPath: url.path),
           let existing = try? String(contentsOf: url, encoding: .utf8),
           FrontmatterCodec.readValue(existing, key: "hall_e_event_id") == event.dedupKey {
            return ObsidianNoteDescriptor(vaultRelativePath: relPath, absoluteURL: url, wasCreated: false)
        }

        let content = renderMeeting(event: event, projectName: projectName)
        let (finalURL, created) = try writer.createIfMissing(relativePath: relPath, content: content, pathBuilder: pathBuilder)

        // Maintain project scaffolding + indexes.
        if let projectName {
            try ensureProject(projectName)
            try appendMeetingsIndex(projectName: projectName, event: event, notePath: relPath)
        } else {
            try appendInboxIndex(event: event, notePath: relPath)
        }
        try appendDailyNote(event: event, notePath: relPath)

        return ObsidianNoteDescriptor(vaultRelativePath: relPath, absoluteURL: finalURL, wasCreated: created)
    }

    // MARK: - Rendering

    private func renderMeeting(event: UnifiedEvent, projectName: String?) -> String {
        let day = HalleDate.day(event.startTs)
        let attendees = event.attendees
        let attendeesYAML = attendees.isEmpty ? " []" : "\n" + attendees.map {
            "  - name: \"\($0.name ?? "")\"\n    email: \"\($0.email ?? "")\""
        }.joined(separator: "\n")
        let attendeesInline = attendees.compactMap { $0.name ?? $0.email }.joined(separator: ", ")

        var links = "- [[\(config.subfolderName)/Daily/\(day)|Daily note]]"
        if let projectName {
            links = "- [[\(config.subfolderName)/Projects/\(FilenameSanitizer.sanitize(projectName, maxBytes: 60))/\(FilenameSanitizer.sanitize(projectName, maxBytes: 60))|\(projectName)]]\n" + links
        }

        return MarkdownTemplateEngine.render(NoteTemplates.meeting, [
            "date": day,
            "start": HalleDate.time(event.startTs),
            "end": HalleDate.time(event.endTs),
            "project": projectName ?? "",
            "project_tag": projectName != nil ? "\n  - project/\(FilenameSanitizer.sanitize(projectName!, maxBytes: 40).lowercased().replacingOccurrences(of: " ", with: "-"))" : "",
            "source_account": event.winnerAccountEmail,
            "calendar": event.sources.first?.calendarId ?? "",
            "attendees_yaml": attendeesYAML,
            "attendees_inline": attendeesInline,
            "meeting_url": event.meetingURL ?? "",
            "recording_path": "",
            "transcript_status": "pending",
            "classification_confidence": event.projectConfidence.map { String(format: "%.2f", $0) } ?? "0.0",
            "hall_e_event_id": event.dedupKey,
            "title": event.title,
            "links": links,
        ])
    }

    // MARK: - Scaffolding

    private func ensureProject(_ projectName: String) throws {
        let notePath = pathBuilder.projectNote(projectName)
        let content = MarkdownTemplateEngine.render(NoteTemplates.project, ["project": projectName])
        try writer.createIfMissing(relativePath: notePath, content: content, pathBuilder: pathBuilder)
    }

    private func appendMeetingsIndex(projectName: String, event: UnifiedEvent, notePath: String) throws {
        let day = HalleDate.day(event.startTs)
        let noteNoExt = String(notePath.dropLast(3))
        let line = "- \(day) — [[\(noteNoExt)|\(event.title)]]"
        let template = MarkdownTemplateEngine.render(NoteTemplates.meetingsIndex, ["project": projectName])
        try writer.mergeSection(relativePath: pathBuilder.projectMeetingsIndex(projectName),
                                section: "meetings-index", newContent: line,
                                headingAnchor: "\(projectName) — Meetings", mode: .appendLines,
                                sortDescending: true, createWith: template, pathBuilder: pathBuilder)
    }

    private func appendInboxIndex(event: UnifiedEvent, notePath: String) throws {
        let day = HalleDate.day(event.startTs)
        let noteNoExt = String(notePath.dropLast(3))
        let line = "- \(day) — [[\(noteNoExt)|\(event.title)]]"
        try writer.mergeSection(relativePath: pathBuilder.inboxIndex(),
                                section: "meetings-index", newContent: line,
                                headingAnchor: "Unclassified Meetings", mode: .appendLines,
                                sortDescending: true, createWith: NoteTemplates.inboxIndex, pathBuilder: pathBuilder)
    }

    private func appendDailyNote(event: UnifiedEvent, notePath: String) throws {
        let day = HalleDate.day(event.startTs)
        let time = HalleDate.time(event.startTs)
        let noteNoExt = String(notePath.dropLast(3))
        let line = "- \(time) — [[\(noteNoExt)|\(event.title)]]"
        let template = MarkdownTemplateEngine.render(NoteTemplates.daily, ["date": day])
        try writer.mergeSection(relativePath: pathBuilder.dailyNote(date: event.startTs),
                                section: "daily-meetings", newContent: line,
                                headingAnchor: "Meetings", mode: .appendLines,
                                sortDescending: false, createWith: template, pathBuilder: pathBuilder)
    }
}

