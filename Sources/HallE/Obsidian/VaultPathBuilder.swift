import Foundation
import CryptoKit

/// Builds vault-relative paths for meeting notes, project notes, indexes, daily
/// notes, and the inbox — all under the configured `Hall-e/` subfolder.
struct VaultPathBuilder {
    let config: ObsidianVaultConfig

    private var root: String {
        let safe = config.subfolderName.split(separator: "/")
            .filter { $0 != "." && $0 != ".." }
            .map(String.init).joined(separator: "/")
        return safe.isEmpty ? "Hall-e" : safe
    }

    /// e.g. Hall-e/Meetings/2026/2026-07/2026-07-04 - Accurate - Director Dashboard Review.md
    func meetingNote(date: Date, projectName: String?, title: String) -> String {
        let day = HalleDate.day(date)
        let proj = projectName.map { FilenameSanitizer.sanitize($0, maxBytes: 40) } ?? "Unclassified"
        let safeTitle = FilenameSanitizer.sanitize(title, maxBytes: 100)
        let file = "\(day) - \(proj) - \(safeTitle) - \(identitySuffix(eventIdentity(title: title, date: date))).md"
        return "\(root)/Meetings/\(HalleDate.year(date))/\(HalleDate.yearMonth(date))/\(file)"
    }

    /// Inbox meeting note for unclassified events.
    func inboxMeetingNote(date: Date, title: String) -> String {
        let day = HalleDate.day(date)
        let safeTitle = FilenameSanitizer.sanitize(title, maxBytes: 100)
        return "\(root)/Inbox/\(day) - \(safeTitle) - \(identitySuffix(eventIdentity(title: title, date: date))).md"
    }

    /// e.g. Hall-e/Calls/2026/2026-07/2026-07-05 - Accurate - Llamada de WhatsApp.md
    func callNote(date: Date, projectName: String?, title: String) -> String {
        let day = HalleDate.day(date)
        let proj = projectName.map { FilenameSanitizer.sanitize($0, maxBytes: 40) } ?? "Unclassified"
        let safeTitle = FilenameSanitizer.sanitize(title, maxBytes: 100)
        let file = "\(day) - \(proj) - \(safeTitle) - \(identitySuffix(eventIdentity(title: title, date: date))).md"
        return "\(root)/Calls/\(HalleDate.year(date))/\(HalleDate.yearMonth(date))/\(file)"
    }

    func inboxCallNote(date: Date, title: String) -> String {
        let day = HalleDate.day(date)
        let safeTitle = FilenameSanitizer.sanitize(title, maxBytes: 100)
        return "\(root)/Calls/Inbox/\(day) - \(safeTitle) - \(identitySuffix(eventIdentity(title: title, date: date))).md"
    }

    func projectFolder(_ projectName: String) -> String {
        "\(root)/Projects/\(FilenameSanitizer.sanitize(projectName, maxBytes: 60))"
    }
    func projectNote(_ projectName: String) -> String {
        let folder = projectFolder(projectName)
        return "\(folder)/\(FilenameSanitizer.sanitize(projectName, maxBytes: 60)).md"
    }
    func projectMeetingsIndex(_ projectName: String) -> String {
        "\(projectFolder(projectName))/Meetings.md"
    }

    func dailyNote(date: Date) -> String {
        "\(root)/Daily/\(HalleDate.day(date)).md"
    }

    func inboxIndex() -> String { "\(root)/Inbox/Unclassified Meetings.md" }

    /// Absolute URL for a vault-relative path.
    func absoluteURL(_ relative: String, vaultURL: URL) -> URL {
        var url = vaultURL
        for part in relative.split(separator: "/") where part != "." && part != ".." {
            url.appendPathComponent(String(part))
        }
        return url
    }

    private func identitySuffix(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    private func eventIdentity(title: String, date: Date) -> String {
        "\(title)|\(date.timeIntervalSince1970)"
    }
}
