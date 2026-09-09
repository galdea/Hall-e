import Foundation

/// Notes have stable session IDs and live outside the audio folder. Renaming a
/// recording or deleting its audio cannot delete the user's written notes.
struct MeetingNotesStore {
    let directory: URL

    init(directory: URL = AppPaths.appSupport.appendingPathComponent("Meeting Notes", isDirectory: true)) {
        self.directory = directory
    }

    func url(for sessionID: UUID) -> URL {
        directory.appendingPathComponent(sessionID.uuidString + ".md")
    }

    func load(sessionID: UUID) throws -> String {
        let file = url(for: sessionID)
        guard FileManager.default.fileExists(atPath: file.path) else { return "" }
        return try String(contentsOf: file, encoding: .utf8)
    }

    func save(_ text: String, sessionID: UUID) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let file = url(for: sessionID)
        try Data(text.utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    static func export(title: String, date: Date, notes: String, transcript: String) -> String {
        var markdown = "# \(title.replacingOccurrences(of: "\n", with: " "))\n\n\(date.formatted(date: .abbreviated, time: .shortened))\n\n"
        markdown += "## \(PublicUICopy.text("My notes", "Mis notas"))\n\n\(notes)\n"
        if !transcript.isEmpty {
            markdown += "\n## \(PublicUICopy.text("Transcript", "Transcripción"))\n\n\(transcript)\n"
        }
        return markdown
    }
}
