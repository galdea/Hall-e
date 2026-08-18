import Foundation
import WhisperKit

struct WhisperKitTranscriptionProvider: TranscriptionProvider {
    func transcribe(fileURL: URL, sessionID: UUID, track: String) async throws -> Transcript {
        try await transcribe(fileURL: fileURL, sessionID: sessionID, track: track,
                             language: AppPreferences.transcriptionLanguage.whisperCode)
    }

    func transcribe(fileURL: URL, sessionID: UUID, track: String,
                    model: String = AppPreferences.whisperKitModel,
                    language: String? = AppPreferences.transcriptionLanguage.whisperCode) async throws -> Transcript {
        try await WhisperKitEngine.shared.transcribe(fileURL: fileURL, sessionID: sessionID,
                                                      track: track, model: model, language: language)
    }

    static func source(for model: String) -> String {
        "whisperkit:\(model)"
    }

    /// Converts WhisperKit's timestamped result windows to Hall-e's stable
    /// transcript schema. Empty windows are discarded and output is sorted so
    /// VAD completion order cannot affect the note.
    static func mapSegments(_ results: [TranscriptionResult], sessionID: UUID? = nil,
                            track: String) -> [TranscriptSegment] {
        results
            .flatMap(\.segments)
            .compactMap { segment in
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                let start = max(0, TimeInterval(segment.start))
                let end = max(start, TimeInterval(segment.end))
                return TranscriptSegment(start: start, duration: end - start,
                                         text: text, track: track)
            }
            .sorted { lhs, rhs in
                if lhs.start == rhs.start { return lhs.duration < rhs.duration }
                return lhs.start < rhs.start
            }
    }
}
