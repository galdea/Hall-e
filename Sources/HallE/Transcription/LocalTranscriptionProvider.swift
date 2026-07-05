import Foundation
import Speech

/// On-device transcription via SFSpeechRecognizer (no audio leaves the Mac).
/// Probes a locale fallback chain, chunks long files, and shifts segment
/// timestamps by each chunk's offset. No fake speaker labels.
struct LocalTranscriptionProvider: TranscriptionProvider {
    /// Fallback chain: Chilean → LatAm → Mexican → Spain → US English.
    static let localeChain = ["es-CL", "es-419", "es-MX", "es-ES", "en-US"]

    func transcribe(fileURL: URL, sessionID: UUID, track: String) async throws -> Transcript {
        guard await Self.requestAuthorization() else { throw TranscriptionError.notAuthorized }
        guard let (recognizer, localeId) = Self.firstAvailableRecognizer() else {
            throw TranscriptionError.noLocaleAvailable
        }
        recognizer.defaultTaskHint = .dictation

        let chunks = try await AudioChunker.chunk(fileURL: fileURL)
        defer { AudioChunker.cleanup(chunks, original: fileURL) }

        var segments: [TranscriptSegment] = []
        for chunk in chunks {
            let chunkSegments = try await Self.recognizeChunk(recognizer, url: chunk.url, offset: chunk.offset, track: track)
            // Drop segments in the overlap region of subsequent chunks.
            let cutoff = chunk.offset == 0 ? 0 : chunk.offset + AudioChunker.overlapSeconds
            segments.append(contentsOf: chunkSegments.filter { $0.start >= cutoff || chunk.offset == 0 })
        }
        segments.sort { $0.start < $1.start }

        return Transcript(sessionID: sessionID, localeUsed: localeId, segments: segments,
                          status: .completed, source: "sfspeech-on-device")
    }

    // MARK: - Helpers

    static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
    }

    /// First locale in the chain with an available on-device recognizer.
    static func firstAvailableRecognizer() -> (SFSpeechRecognizer, String)? {
        for id in localeChain {
            if let r = SFSpeechRecognizer(locale: Locale(identifier: id)),
               r.isAvailable, r.supportsOnDeviceRecognition {
                return (r, id)
            }
        }
        // Last resort: any available recognizer, even if not on-device.
        if let r = SFSpeechRecognizer(), r.isAvailable {
            return (r, r.locale.identifier)
        }
        return nil
    }

    private static func recognizeChunk(_ recognizer: SFSpeechRecognizer, url: URL,
                                       offset: TimeInterval, track: String) async throws -> [TranscriptSegment] {
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.shouldReportPartialResults = false

        return try await withCheckedThrowingContinuation { cont in
            let guardOnce = ResumeGuard()
            recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    if guardOnce.tryResume() { cont.resume(throwing: TranscriptionError.failed(error.localizedDescription)) }
                    return
                }
                guard let result, result.isFinal else { return }
                let segs = result.bestTranscription.segments.map {
                    TranscriptSegment(start: offset + $0.timestamp, duration: $0.duration,
                                      text: $0.substring, track: track)
                }
                // Coalesce word-level segments into one block per chunk for readability.
                let text = result.bestTranscription.formattedString
                let block = TranscriptSegment(start: offset, duration: segs.last.map { $0.start + $0.duration - offset } ?? 0,
                                              text: text, track: track)
                if guardOnce.tryResume() { cont.resume(returning: [block]) }
            }
        }
    }
}
