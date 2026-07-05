import Foundation

/// Persists transcript.json next to the recording; status survives restarts.
enum TranscriptStore {
    static func save(_ transcript: Transcript, to session: RecordingSession) {
        if let data = try? JSONEncoder().encode(transcript) {
            try? data.write(to: session.transcriptFileURL, options: [.atomic])
        }
    }

    static func load(_ session: RecordingSession) -> Transcript? {
        guard let data = try? Data(contentsOf: session.transcriptFileURL) else { return nil }
        return try? JSONDecoder().decode(Transcript.self, from: data)
    }
}
