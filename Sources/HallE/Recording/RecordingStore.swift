import Foundation

/// Reads recording sessions from disk (there's no DB table for them) so the UI
/// can show a per-meeting transcript button keyed by the event's dedupKey.
enum RecordingStore {
    static func allSessions() -> [RecordingSession] {
        let dir = AppPaths.recordingsDir
        guard let subs = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return [] }
        return subs.compactMap { sub in
            let file = sub.appendingPathComponent("session.json")
            guard let data = try? Data(contentsOf: file) else { return nil }
            return try? JSONDecoder().decode(RecordingSession.self, from: data)
        }
    }

    /// Latest session per event (by start time).
    static func latestByEvent() -> [String: RecordingSession] {
        var map: [String: RecordingSession] = [:]
        for s in allSessions() {
            if let existing = map[s.eventDedupKey], existing.startedAt >= s.startedAt { continue }
            map[s.eventDedupKey] = s
        }
        return map
    }

    static func transcriptText(for session: RecordingSession) -> String? {
        TranscriptStore.load(session)?.plainText
    }
}
