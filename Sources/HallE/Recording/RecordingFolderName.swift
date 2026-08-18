import Foundation

/// Composes the on-disk name of a recording: a sortable timestamp, what the
/// meeting was about, and who took part. Pure — every input is passed in, so the
/// naming rules can be exercised without a filesystem, a calendar, or an LLM.
enum RecordingFolderName {
    /// Recordings whose meeting was never classified into a project. Matches the
    /// vault's wording for the same situation.
    static let unclassifiedProject = "Unclassified"

    /// Beyond this the folder name stops being scannable and starts eating the
    /// 255-byte APFS budget that the timestamp and participants also need.
    static let maximumTopicBytes = 90
    static let maximumNameBytes = 180
    /// Naming every attendee turns the folder into a mailing list.
    static let maximumParticipants = 4

    /// The thematic folder a recording belongs in — `Recordings/Accurate/…`.
    static func projectFolder(_ project: String?) -> String {
        guard let project, !project.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return unclassifiedProject
        }
        return FilenameSanitizer.sanitize(project, maxBytes: 60)
    }

    /// `2026-08-04 1801 - Revisión de resultados - Sebastián, Álvaro`
    ///
    /// The timestamp leads so a project folder sorts chronologically. `topic`
    /// is the transcript-derived subject; without one (no AI, a failed call, an
    /// empty transcript) the calendar title stands in, which is still a truthful
    /// name rather than an invented one.
    static func compose(startedAt: Date, topic: String?, fallbackTitle: String,
                        participants: [String]) -> String {
        let stamp = HalleDate.day(startedAt) + " "
            + HalleDate.time(startedAt).replacingOccurrences(of: ":", with: "")
        let subject = cleanTopic(topic) ?? cleanTopic(fallbackTitle) ?? "Recording"
        var parts = [stamp, FilenameSanitizer.sanitize(subject, maxBytes: maximumTopicBytes)]
        if let people = participantSegment(participants) { parts.append(people) }
        return FilenameSanitizer.sanitize(parts.joined(separator: " - "), maxBytes: maximumNameBytes)
    }

    /// An LLM answers with whatever it likes — quotes, a trailing period, a
    /// preamble, several lines. Keep the first line, strip the decoration, and
    /// reject anything that is clearly not a subject line.
    static func cleanTopic(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var value = raw.components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’`*#-–—.:"))
        value = value.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, value.utf8.count <= 400 else { return nil }
        return value
    }

    /// `Sebastián, Álvaro` — or `Sebastián, Álvaro +3` when the meeting was big.
    static func participantSegment(_ participants: [String]) -> String? {
        let names = participants
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .reduced()
        guard !names.isEmpty else { return nil }
        let shown = names.prefix(maximumParticipants).joined(separator: ", ")
        let hidden = names.count - min(names.count, maximumParticipants)
        return hidden > 0 ? "\(shown) +\(hidden)" : shown
    }

    /// Display name for one attendee: the calendar's own name, else the people
    /// directory, else a readable rendering of the email's local part. Only the
    /// given name is kept — a folder name has no room for four full names, and
    /// `alvaro.carrasco@…` is recognisable as `Alvaro`.
    static func displayName(forEmail email: String?, calendarName: String?,
                            directory: [Person]) -> String? {
        if let given = givenName(calendarName) { return given }
        let normalized = email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let normalized, !normalized.isEmpty else { return nil }
        if let match = directory.first(where: { person in
            person.emails.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalized }
        }), let given = givenName(match.name) {
            return given
        }
        let local = normalized.split(separator: "@").first.map(String.init) ?? normalized
        let words = local.split(whereSeparator: { $0 == "." || $0 == "_" || $0 == "-" || $0 == "+" })
            .map(String.init)
            .filter { !$0.isEmpty && !$0.allSatisfy(\.isNumber) }
        guard let candidate = givenName(words.joined(separator: " ")) else { return nil }
        // A role or initials mailbox (`ac@`, `hi@`) is not a person's name and
        // only adds noise to the folder. Better to leave them out than to
        // pretend "Ac" attended.
        return candidate.count > 2 ? candidate : nil
    }

    private static func givenName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let first = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ").first.map(String.init)
        guard let first, !first.isEmpty else { return nil }
        return first.prefix(1).uppercased() + first.dropFirst()
    }
}

private extension Array where Element == String {
    /// Case-insensitive de-duplication that keeps the first spelling and order.
    func reduced() -> [String] {
        var seen = Set<String>()
        return filter { seen.insert($0.lowercased()).inserted }
    }
}
