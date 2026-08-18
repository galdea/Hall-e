import Foundation

/// Decides which thematic folder a recording belongs in.
///
/// `eventSnapshot.projectId` is the obvious answer but it is missing from every
/// recording made before snapshots existed, and nil for meetings the classifier
/// sent to the inbox. Falling back to "Unclassified" for those would scatter
/// most of an existing library, so the meeting note's own path — the filing the
/// user already sees in their vault — is consulted next.
enum RecordingProjectResolver {
    /// Nil means genuinely unclassified; the caller files it under
    /// `RecordingFolderName.unclassifiedProject`.
    static func project(for session: RecordingSession, explicit: String? = nil,
                        knownProjects: [String]) -> String? {
        if let explicit = nonEmpty(explicit) { return explicit }
        if let snapshot = nonEmpty(session.eventSnapshot?.projectId) { return snapshot }
        if let note = session.notePath,
           let fromNote = projectFromNotePath(note, knownProjects: knownProjects) { return fromNote }
        // Already filed under a real project: a re-title must not demote it.
        if let current = session.folderPath?.split(separator: "/").first.map(String.init),
           let known = match(current, in: knownProjects) { return known }
        return nil
    }

    /// `Hall-e/Meetings/2026/2026-07/2026-07-15 - Accurate - Reunión Directorio - 31ff1198.md`
    /// → `Accurate`.
    ///
    /// The second field is only *positionally* a project — in an inbox note it
    /// is the meeting title — so it counts only when it names a project the user
    /// actually has. Inbox notes are unclassified by construction and skipped.
    static func projectFromNotePath(_ notePath: String, knownProjects: [String]) -> String? {
        let parts = notePath.split(separator: "/").map(String.init)
        guard !parts.contains("Inbox"), let file = parts.last else { return nil }
        let name = file.hasSuffix(".md") ? String(file.dropLast(3)) : file
        let fields = name.components(separatedBy: " - ")
        guard fields.count >= 3 else { return nil }
        return match(fields[1], in: knownProjects)
    }

    /// Returns the canonical project name so the folder does not inherit a
    /// sanitized or differently-cased spelling from the note filename.
    private static func match(_ candidate: String, in knownProjects: [String]) -> String? {
        let needle = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
        guard !needle.isEmpty else { return nil }
        return knownProjects.first { project in
            let filed = FilenameSanitizer.sanitize(project, maxBytes: 60)
                .precomposedStringWithCanonicalMapping
            return filed.caseInsensitiveCompare(needle) == .orderedSame
                || project.precomposedStringWithCanonicalMapping.caseInsensitiveCompare(needle) == .orderedSame
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }
}
