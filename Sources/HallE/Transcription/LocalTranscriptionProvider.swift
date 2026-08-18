import Foundation
import Speech

/// On-device transcription via SFSpeechRecognizer (no audio leaves the Mac).
/// Probes a locale fallback chain, chunks long files, and shifts segment
/// timestamps by each chunk's offset. No fake speaker labels.
struct LocalTranscriptionProvider: TranscriptionProvider {
    /// Spanish locales, followed by English only when English was explicitly
    /// selected. The old chain silently returned en-US for Spanish recordings.
    static let localeChain = ["es-CL", "es-419", "es-MX", "es-ES", "en-US"]

    struct Checkpoint: Sendable {
        let chunkIndex: Int
        let chunkCount: Int
        let offset: TimeInterval
        let segments: [TranscriptSegment]
    }

    /// Protocol-compatible one-shot entry point. The durable job pipeline uses
    /// the extended overload below to supply and persist checkpoints.
    func transcribe(fileURL: URL, sessionID: UUID, track: String) async throws -> Transcript {
        try await transcribe(fileURL: fileURL, sessionID: sessionID, track: track,
                             existingSegments: [], completedChunkIndexes: [])
    }

    /// `existingSegments` + `completedChunkIndexes` let a resumed job keep its
    /// completed work. Callers persist each checkpoint before this method starts
    /// the next chunk, making interruption recovery deterministic.
    func transcribe(fileURL: URL, sessionID: UUID, track: String,
                    existingSegments: [TranscriptSegment] = [],
                    completedChunkIndexes: Set<Int> = [],
                    language: String = "es",
                    onPrepared: (@Sendable ([(index: Int, offset: TimeInterval)]) async -> Void)? = nil,
                    onCheckpoint: (@Sendable (Checkpoint) async -> Void)? = nil) async throws -> Transcript {
        try await AudioPreflight.validate(fileURL)
        guard await Self.requestAuthorization() else { throw TranscriptionError.notAuthorized }
        guard let (recognizer, localeId) = Self.firstAvailableRecognizer(language: language) else {
            throw TranscriptionError.noLocaleAvailable
        }
        recognizer.defaultTaskHint = .dictation

        let chunks = try await AudioChunker.chunk(fileURL: fileURL)
        defer { AudioChunker.cleanup(chunks, original: fileURL) }
        if let onPrepared {
            await onPrepared(chunks.map { (index: $0.index, offset: $0.offset) })
        }

        var segments = existingSegments.filter { $0.track == track }
        for chunk in chunks {
            if completedChunkIndexes.contains(chunk.index) { continue }
            let result = try await Self.recognizeChunk(recognizer, url: chunk.url, offset: chunk.offset, track: track)
            // Drop the words that fall inside the overlap region of subsequent
            // chunks (the previous chunk already transcribed that audio), then
            // coalesce the kept words into one block per chunk for readability.
            let cutoff = chunk.offset == 0 ? 0 : chunk.offset + AudioChunker.overlapSeconds
            let kept = result.words.enumerated().filter { $0.element.start + $0.element.duration > cutoff }
            if let first = kept.first, let last = kept.last {
                let text = Self.blockText(formatted: result.formatted, words: result.words,
                                          keptIndices: kept.map(\.offset))
                segments.append(TranscriptSegment(
                    start: max(first.element.start, cutoff),
                    duration: max(0, last.element.start + last.element.duration - max(first.element.start, cutoff)),
                    text: text, track: track))
            }
            if let onCheckpoint {
                await onCheckpoint(Checkpoint(chunkIndex: chunk.index, chunkCount: chunks.count,
                                               offset: chunk.offset,
                                               segments: segments.filter { $0.track == track }))
            }
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

    static func candidateLocales(for language: String) -> [String] {
        let prefix = language.split(separator: "-").first.map(String.init)?.lowercased() ?? language.lowercased()
        return localeChain.filter { locale in
            let localePrefix = locale.split(separator: "-").first.map(String.init)?.lowercased() ?? locale.lowercased()
            return localePrefix == prefix
        }
    }

    /// First locale in the language-scoped chain with an available recognizer.
    /// The injected availability closure keeps locale policy unit-testable
    /// without asking the host Speech daemon during tests.
    static func firstAvailableRecognizer(
        language: String = "es",
        isAvailable: ((String) -> Bool)? = nil
    ) -> (SFSpeechRecognizer, String)? {
        for id in candidateLocales(for: language) {
            if let isAvailable {
                guard isAvailable(id), let recognizer = SFSpeechRecognizer(locale: Locale(identifier: id)) else { continue }
                return (recognizer, id)
            }
            if let recognizer = SFSpeechRecognizer(locale: Locale(identifier: id)),
               recognizer.isAvailable, recognizer.supportsOnDeviceRecognition {
                return (recognizer, id)
            }
        }
        return nil
    }

    struct ChunkResult {
        let words: [TranscriptSegment]  // word-level, offset-shifted timestamps
        let formatted: String           // punctuated full text of the chunk
    }

    /// Ceiling on a single chunk's recognition (chunks are ≤ 4 min of audio).
    /// SFSpeechRecognizer can complete without delivering a final result or an
    /// error; without this deadline the continuation would never resume and the
    /// transcript would stay `.inProgress` forever.
    static let recognitionTimeout: TimeInterval = 480

    private static func recognizeChunk(_ recognizer: SFSpeechRecognizer, url: URL,
                                       offset: TimeInterval, track: String) async throws -> ChunkResult {
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.shouldReportPartialResults = false

        return try await withCheckedThrowingContinuation { cont in
            let guardOnce = ResumeGuard()
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    if guardOnce.tryResume() { cont.resume(throwing: TranscriptionError.failed(error.localizedDescription)) }
                    return
                }
                guard let result, result.isFinal else { return }
                let words = result.bestTranscription.segments.map {
                    TranscriptSegment(start: offset + $0.timestamp, duration: $0.duration,
                                      text: $0.substring, track: track)
                }
                if guardOnce.tryResume() {
                    cont.resume(returning: ChunkResult(words: words,
                                                       formatted: result.bestTranscription.formattedString))
                }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + recognitionTimeout) {
                if guardOnce.tryResume() {
                    task.cancel()
                    cont.resume(throwing: TranscriptionError.failed(
                        "recognition timed out after \(Int(recognitionTimeout))s"))
                }
            }
        }
    }

    /// Text for a chunk's coalesced block. Prefers the punctuated formatted
    /// string when its whitespace tokens map 1:1 onto the word segments (the
    /// normal SFSpeechRecognizer case); otherwise joins the raw substrings.
    static func blockText(formatted: String, words: [TranscriptSegment], keptIndices: [Int]) -> String {
        if keptIndices.count == words.count { return formatted }
        let tokens = formatted.split(separator: " ")
        if tokens.count == words.count {
            return keptIndices.map { String(tokens[$0]) }.joined(separator: " ")
        }
        return keptIndices.map { words[$0].text }.joined(separator: " ")
    }
}
