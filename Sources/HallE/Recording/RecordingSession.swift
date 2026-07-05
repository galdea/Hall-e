import Foundation

enum RecordingState: Codable, Equatable {
    case idle, preparing, recording, stopping, completed
    case failed(String)
}

enum TranscriptStatus: String, Codable {
    case pending, inProgress, completed, failed
}

/// Metadata for one recording, linked to a unified event and its Obsidian note.
struct RecordingSession: Codable, Identifiable {
    let id: UUID
    let eventDedupKey: String
    let eventTitle: String
    var notePath: String?          // vault-relative note this attaches to
    var micFileName: String        // relative to the session folder
    var systemAudioFileName: String?
    var startedAt: Date
    var endedAt: Date?
    var state: RecordingState
    var transcriptStatus: TranscriptStatus
    var localeUsed: String?

    /// …/Application Support/Hall-e/Recordings/<slug>/
    var folderURL: URL { AppPaths.recordingsDir.appendingPathComponent(slug, isDirectory: true) }
    var micURL: URL { folderURL.appendingPathComponent(micFileName) }
    var sessionFileURL: URL { folderURL.appendingPathComponent("session.json") }
    var transcriptFileURL: URL { folderURL.appendingPathComponent("transcript.json") }

    let slug: String

    init(event: UnifiedEvent, notePath: String?) {
        id = UUID()
        eventDedupKey = event.dedupKey
        eventTitle = event.title
        self.notePath = notePath
        micFileName = "mic.m4a"
        systemAudioFileName = nil
        startedAt = Date()
        endedAt = nil
        state = .idle
        transcriptStatus = .pending
        let stamp = HalleDate.day(startedAt) + "-" + HalleDate.time(startedAt).replacingOccurrences(of: ":", with: "")
        slug = "\(stamp)-\(FilenameSanitizer.sanitize(event.title, maxBytes: 40))"
    }

    func save() {
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(self) { try? data.write(to: sessionFileURL, options: [.atomic]) }
    }
}
