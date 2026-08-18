import Foundation

/// Runs the locally installed OpenAI Whisper CLI. This is the production
/// automatic backend on Macs that already have Whisper/ffmpeg installed (the
/// same `large-v3-turbo` runtime used to produce Hall-e's good transcripts).
/// It is deliberately a separate provider: Apple Speech is never selected as
/// an implicit quality fallback.
struct WhisperCLITranscriptionProvider: TranscriptionProvider {
    static let model = "large-v3-turbo"
    static let source = "whisper-large-v3-turbo-cli"

    enum ProviderError: LocalizedError {
        case unavailable
        case failed(String)
        case invalidOutput

        var errorDescription: String? {
            switch self {
            case .unavailable:
                "The local Whisper CLI is not installed."
            case .failed(let message):
                message
            case .invalidOutput:
                "The local Whisper CLI returned no usable transcript."
            }
        }
    }

    private struct Output: Decodable {
        var language: String?
        var segments: [Segment]
    }

    private struct Segment: Decodable {
        var start: Double
        var end: Double
        var text: String
    }

    struct Checkpoint: Sendable {
        let chunkIndex: Int
        let chunkCount: Int
        let offset: TimeInterval
        let segments: [TranscriptSegment]
    }

    static var executableURL: URL? {
        let candidates = [
            ProcessInfo.processInfo.environment["HALLE_WHISPER_BIN"],
            "/usr/local/bin/whisper",
            "/opt/homebrew/bin/whisper",
        ].compactMap { $0 }.map(URL.init(fileURLWithPath:))
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static var isAvailable: Bool { executableURL != nil }

    func transcribe(fileURL: URL, sessionID: UUID, track: String) async throws -> Transcript {
        try await transcribe(fileURL: fileURL, sessionID: sessionID, track: track,
                             language: AppPreferences.transcriptionLanguage.whisperCode)
    }

    func transcribe(fileURL: URL, sessionID: UUID, track: String,
                    language: String?) async throws -> Transcript {
        try await transcribe(fileURL: fileURL, sessionID: sessionID, track: track,
                             existingSegments: [], completedChunkIndexes: [], language: language)
    }

    func transcribe(fileURL: URL, sessionID: UUID, track: String,
                    existingSegments: [TranscriptSegment],
                    completedChunkIndexes: Set<Int>,
                    language: String?,
                    onPrepared: (@Sendable ([(index: Int, offset: TimeInterval)]) async -> Void)? = nil,
                    onCheckpoint: (@Sendable (Checkpoint) async -> Void)? = nil) async throws -> Transcript {
        try await AudioPreflight.validate(fileURL)
        guard Self.executableURL != nil else { throw ProviderError.unavailable }
        let chunks = try await AudioChunker.chunk(fileURL: fileURL)
        defer { AudioChunker.cleanup(chunks, original: fileURL) }
        await onPrepared?(chunks.map { (index: $0.index, offset: $0.offset) })

        var segments = existingSegments.filter { $0.track == track }
        var locale = language ?? "auto"
        for chunk in chunks {
            if completedChunkIndexes.contains(chunk.index) { continue }
            let decoded = try await Self.runChunk(fileURL: chunk.url, language: language)
            locale = decoded.output.language ?? locale
            segments.append(contentsOf: decoded.output.segments.compactMap { segment in
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                let start = chunk.offset + max(0, segment.start)
                let end = chunk.offset + max(segment.start, segment.end)
                return TranscriptSegment(start: start, duration: end - start, text: text, track: track)
            })
            segments.sort { $0.start < $1.start }
            await onCheckpoint?(Checkpoint(chunkIndex: chunk.index, chunkCount: chunks.count,
                                           offset: chunk.offset,
                                           segments: segments.filter { $0.track == track }))
        }
        guard !segments.isEmpty else { throw ProviderError.invalidOutput }
        return Transcript(sessionID: sessionID, localeUsed: locale,
                          segments: segments, status: .completed, source: Self.source)
    }

    private static func runChunk(fileURL: URL, language: String?) async throws -> (output: Output, diagnostic: String) {
        guard let executableURL else { throw ProviderError.unavailable }
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hall-e-whisper-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        var arguments = [
            fileURL.path,
            "--model", Self.model,
            "--fp16", "False",
            "--output_format", "json",
            "--output_dir", outputDirectory.path,
            "--verbose", "False",
            "--device", "cpu",
        ]
        if let language, !language.isEmpty { arguments += ["--language", language] }

        let output = try await Self.run(executableURL: executableURL, arguments: arguments)
        let jsonURL = outputDirectory.appendingPathComponent(fileURL.deletingPathExtension().lastPathComponent + ".json")
        guard let data = try? Data(contentsOf: jsonURL),
              let decoded = try? JSONDecoder().decode(Output.self, from: data) else {
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ProviderError.failed(detail.isEmpty ? ProviderError.invalidOutput.localizedDescription : detail)
        }
        return (decoded, output)
    }

    private static func run(executableURL: URL, arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let pipe = Pipe()
            process.executableURL = executableURL
            process.arguments = arguments
            process.standardOutput = pipe
            process.standardError = pipe
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"
            environment["PYTHONUNBUFFERED"] = "1"
            process.environment = environment

            do {
                try process.run()
                DispatchQueue.global(qos: .userInitiated).async {
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    let text = String(decoding: data, as: UTF8.self)
                    if process.terminationStatus == 0 {
                        continuation.resume(returning: text)
                    } else {
                        continuation.resume(throwing: ProviderError.failed(
                            text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(280).description))
                    }
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
