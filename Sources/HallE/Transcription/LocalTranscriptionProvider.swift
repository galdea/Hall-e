import Foundation
import Speech

/// On-device transcription via SFSpeechRecognizer (no audio leaves the Mac).
/// Probes a locale fallback chain, chunks long files, and shifts segment
/// timestamps by each chunk's offset. No fake speaker labels.
struct LocalTranscriptionProvider: TranscriptionProvider {
    /// Candidates are always filtered to the selected language. Actual local
    /// model availability is checked at runtime; never substitute another language.
    static let localeChain = ["es-CL", "es-419", "es-MX", "es-ES", "en-US", "en-GB",
                              "pt-BR", "pt-PT", "fr-FR", "fr-CA", "de-DE", "it-IT"]

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
                    language: String = TranscriptionLanguagePreference.auto.sfSpeechCode,
                    timelineOffset: TimeInterval = 0,
                    onPrepared: (@Sendable ([(index: Int, offset: TimeInterval)]) async -> Void)? = nil,
                    onCheckpoint: (@Sendable (Checkpoint) async -> Void)? = nil) async throws -> Transcript {
        try await AudioPreflight.validate(fileURL)
        try Task.checkCancellation()
        guard await Self.requestAuthorization() else { throw TranscriptionError.notAuthorized }
        try Task.checkCancellation()
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
            try Task.checkCancellation()
            if completedChunkIndexes.contains(chunk.index) { continue }
            let result = try await Self.recognizeChunk(recognizer, url: chunk.url, offset: timelineOffset + chunk.offset, track: track)
            // Drop the words that fall inside the overlap region of subsequent
            // chunks (the previous chunk already transcribed that audio), then
            // coalesce the kept words into one block per chunk for readability.
            let cutoff = timelineOffset + (chunk.offset == 0 ? 0 : chunk.offset + AudioChunker.overlapSeconds)
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
        let normalized = language.replacingOccurrences(of: "_", with: "-")
        let prefix = normalized.split(separator: "-").first.map(String.init)?.lowercased() ?? normalized.lowercased()
        return localeChain.filter { locale in
            let localePrefix = locale.split(separator: "-").first.map(String.init)?.lowercased() ?? locale.lowercased()
            return localePrefix == prefix
        }
    }

    /// First locale in the language-scoped chain with an available recognizer.
    /// The injected availability closure keeps locale policy unit-testable
    /// without asking the host Speech daemon during tests.
    static func firstAvailableRecognizer(
        language: String = TranscriptionLanguagePreference.auto.sfSpeechCode,
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
        guard recognizer.supportsOnDeviceRecognition else { throw TranscriptionError.noLocaleAvailable }
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false

        let operation = RecognitionOperation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { cont in
                guard operation.begin(cont) else { return }
                let task = recognizer.recognitionTask(with: request) { result, error in
                    if let error {
                        operation.finish(.failure(TranscriptionError.failed(error.localizedDescription)))
                        return
                    }
                    guard let result, result.isFinal else { return }
                    let words = result.bestTranscription.segments.map {
                        TranscriptSegment(start: offset + $0.timestamp, duration: $0.duration,
                                          text: $0.substring, track: track)
                    }
                    operation.finish(.success(ChunkResult(words: words,
                        formatted: result.bestTranscription.formattedString)))
                }
                operation.attach(task)
                let deadline = DispatchWorkItem { [weak operation] in
                    operation?.finish(.failure(TranscriptionError.failed(
                        "Recognition timed out. Your recording is saved; try transcription again.")))
                }
                operation.attach(deadline)
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + recognitionTimeout, execute: deadline)
            }
        } onCancel: {
            operation.finish(.failure(CancellationError()))
        }
    }

    /// Recognition callbacks, cancellation, and the deadline can race. Finish
    /// once, including cancellation before the continuation/task is installed.
    private final class RecognitionOperation: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<ChunkResult, Error>?
        private var outcome: Result<ChunkResult, Error>?
        private var task: SFSpeechRecognitionTask?
        private var deadline: DispatchWorkItem?

        func begin(_ continuation: CheckedContinuation<ChunkResult, Error>) -> Bool {
            lock.lock()
            if let outcome { lock.unlock(); continuation.resume(with: outcome); return false }
            self.continuation = continuation
            lock.unlock()
            return true
        }
        func attach(_ task: SFSpeechRecognitionTask) {
            lock.lock()
            if outcome != nil { lock.unlock(); task.cancel(); return }
            self.task = task
            lock.unlock()
        }
        func attach(_ deadline: DispatchWorkItem) {
            lock.lock()
            if outcome != nil { lock.unlock(); deadline.cancel(); return }
            self.deadline = deadline
            lock.unlock()
        }
        func finish(_ result: Result<ChunkResult, Error>) {
            lock.lock()
            guard outcome == nil else { lock.unlock(); return }
            outcome = result
            let continuation = self.continuation
            let task = self.task
            let deadline = self.deadline
            self.continuation = nil; self.task = nil; self.deadline = nil
            lock.unlock()
            deadline?.cancel()
            task?.cancel()
            continuation?.resume(with: result)
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
