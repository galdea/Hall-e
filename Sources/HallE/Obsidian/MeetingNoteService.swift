import Foundation
import GRDB

struct ObsidianNoteDescriptor {
    var vaultRelativePath: String
    var absoluteURL: URL
    var wasCreated: Bool
}

enum NoteKind { case meeting, call }

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
    func createOrFindMeetingNote(for event: UnifiedEvent, projectName: String?,
                                 kind: NoteKind = .meeting) throws -> ObsidianNoteDescriptor {
        let relPath: String
        switch kind {
        case .meeting:
            relPath = projectName != nil
                ? pathBuilder.meetingNote(date: event.startTs, projectName: projectName, title: event.title)
                : pathBuilder.inboxMeetingNote(date: event.startTs, title: event.title)
        case .call:
            relPath = projectName != nil
                ? pathBuilder.callNote(date: event.startTs, projectName: projectName, title: event.title)
                : pathBuilder.inboxCallNote(date: event.startTs, title: event.title)
        }
        let url = pathBuilder.absoluteURL(relPath, vaultURL: vaultURL)

        // Event ID is the canonical identity. A renamed or manually moved note
        // must be reused instead of creating a duplicate at the generated path.
        // Scaffolding (project note, indexes, daily link) is re-ensured even on
        // the "already exists" paths: each append is idempotent, and a transient
        // failure after the note write would otherwise drop those links forever.
        if let existing = findNote(eventId: event.dedupKey) {
            try ensureScaffolding(event: event, projectName: projectName, notePath: existing.relativePath)
            return ObsidianNoteDescriptor(vaultRelativePath: existing.relativePath,
                                          absoluteURL: existing.url, wasCreated: false)
        }

        // Dedupe: if the expected file already carries this event id, reuse it.
        if FileManager.default.fileExists(atPath: url.path),
           let existing = try? String(contentsOf: url, encoding: .utf8),
           FrontmatterCodec.readValue(existing, key: "hall_e_event_id") == event.dedupKey {
            try ensureScaffolding(event: event, projectName: projectName, notePath: relPath)
            return ObsidianNoteDescriptor(vaultRelativePath: relPath, absoluteURL: url, wasCreated: false)
        }

        let content = renderMeeting(event: event, projectName: projectName, kind: kind)
        let (finalURL, created) = try writer.createIfMissing(relativePath: relPath, content: content, pathBuilder: pathBuilder)
        try ensureScaffolding(event: event, projectName: projectName, notePath: relPath)

        return ObsidianNoteDescriptor(vaultRelativePath: relPath, absoluteURL: finalURL, wasCreated: created)
    }

    /// Project scaffolding + indexes for a note. Safe to re-run: `mergeSection`
    /// appends are no-ops when the line is already present.
    private func ensureScaffolding(event: UnifiedEvent, projectName: String?, notePath: String) throws {
        if let projectName {
            try ensureProject(projectName)
            try appendMeetingsIndex(projectName: projectName, event: event, notePath: notePath)
        } else {
            try appendInboxIndex(event: event, notePath: notePath)
        }
        try appendDailyNote(event: event, notePath: notePath)
    }

    // MARK: - Rendering

    private func renderMeeting(event: UnifiedEvent, projectName: String?, kind: NoteKind = .meeting) -> String {
        let template = kind == .call ? NoteTemplates.call : NoteTemplates.meeting
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

        return MarkdownTemplateEngine.render(template, [
            "date": day,
            "start": HalleDate.time(event.startTs),
            "end": HalleDate.time(event.endTs),
            "project": FrontmatterCodec.escapedScalar(projectName ?? ""),
            "project_tag": projectName != nil ? "\n  - project/\(FilenameSanitizer.sanitize(projectName!, maxBytes: 40).lowercased().replacingOccurrences(of: " ", with: "-"))" : "",
            "source_account": FrontmatterCodec.escapedScalar(event.winnerAccountEmail),
            "calendar": FrontmatterCodec.escapedScalar(event.sources.first?.calendarId ?? ""),
            "attendees_yaml": attendeesYAML,
            "attendees_inline": FrontmatterCodec.escapedScalar(attendeesInline),
            "meeting_url": FrontmatterCodec.escapedScalar(event.meetingURL ?? ""),
            "recording_path": "",
            "transcript_status": "pending",
            "classification_confidence": event.projectConfidence.map { String(format: "%.2f", $0) } ?? "0.0",
            "hall_e_event_id": event.dedupKey,
            "title": FrontmatterCodec.escapedScalar(event.title),
            "links": links,
        ])
    }

    // MARK: - Scaffolding

    private func ensureProject(_ projectName: String) throws {
        let notePath = pathBuilder.projectNote(projectName)
        let content = MarkdownTemplateEngine.render(NoteTemplates.project, ["project": projectName])
        try writer.createIfMissing(relativePath: notePath, content: content, pathBuilder: pathBuilder)
    }

    func updateProjectAssistantSnapshot(projectName: String, markdown: String) throws {
        try ensureProject(projectName)
        try writer.mergeSection(relativePath: pathBuilder.projectNote(projectName),
                                section: "assistant-brief", newContent: markdown,
                                headingAnchor: "Hall-e Assistant", mode: .replace,
                                pathBuilder: pathBuilder)
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

    /// The Hall-e area under the *bookmark-resolved* vault URL. `config.rootURL`
    /// is derived from the stored path string, which goes stale when the vault
    /// is moved — the bookmark is the live location.
    private var hallRootURL: URL {
        vaultURL.appendingPathComponent(config.subfolderName, isDirectory: true)
    }

    private func findNote(eventId: String) -> (relativePath: String, url: URL)? {
        // Fast path: the vault index already maps eventId → path (relative to
        // the Hall-e subfolder). Verify against the file — the index is a cache.
        if let indexed = try? AppDatabase.shared.dbQueue.read({ db in
            try VaultDocument.filter(VaultDocument.Columns.eventId == eventId).fetchOne(db)
        }) {
            let relative = "\(config.subfolderName)/\(indexed.path)"
            let candidate = pathBuilder.absoluteURL(relative, vaultURL: vaultURL)
            if let content = try? String(contentsOf: candidate, encoding: .utf8),
               FrontmatterCodec.readValue(content, key: "hall_e_event_id") == eventId {
                return (relative, candidate)
            }
        }
        // Slow path: scan the Hall-e area on disk (index missing or stale).
        guard let enumerator = FileManager.default.enumerator(at: hallRootURL,
                                                               includingPropertiesForKeys: nil,
                                                               options: [.skipsHiddenFiles]) else { return nil }
        // Resolve symlinks on both sides: enumerator URLs come back as
        // /private/var/... while the vault URL may be the /var/... alias, and a
        // naive prefix strip would then leak an absolute path as "relative".
        let vaultPath = vaultURL.resolvingSymlinksInPath().path
        for case let candidate as URL in enumerator where candidate.pathExtension == "md" {
            guard let content = try? String(contentsOf: candidate, encoding: .utf8),
                  FrontmatterCodec.readValue(content, key: "hall_e_event_id") == eventId else { continue }
            let candidatePath = candidate.resolvingSymlinksInPath().path
            guard candidatePath.hasPrefix(vaultPath + "/") else { continue }
            let relative = String(candidatePath.dropFirst(vaultPath.count + 1))
            return (relative, candidate)
        }
        return nil
    }
}
