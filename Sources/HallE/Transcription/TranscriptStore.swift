import Foundation

/// Persists transcript.json next to the recording; status survives restarts.
enum TranscriptStore {
    static func save(_ transcript: Transcript, to session: RecordingSession) {
        do {
            let data = try JSONEncoder().encode(transcript)
            try data.write(to: session.transcriptFileURL, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: session.transcriptFileURL.path)
        } catch {
            Log.rec.error("transcript save failed for \(session.slug, privacy: .public): \(error, privacy: .public)")
        }
    }

    static func load(_ session: RecordingSession) -> Transcript? {
        guard FileManager.default.fileExists(atPath: session.transcriptFileURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: session.transcriptFileURL)
            return try JSONDecoder().decode(Transcript.self, from: data)
        } catch {
            Log.rec.error("transcript load failed for \(session.slug, privacy: .public): \(error, privacy: .public)")
            return nil
        }
    }
}
