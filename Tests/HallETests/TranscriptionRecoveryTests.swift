import Testing
import Foundation
import WhisperKit
@testable import HallE

@Suite("Durable transcription recovery")
struct TranscriptionRecoveryTests {
    @Test func retryPreservesCompletedChunksAndRequeuesOnlyFailedTracks() {
        var job = TranscriptionJob(status: .retryableFailed, attemptCount: 2, tracks: [
            TranscriptionTrackProgress(track: "mic", fileName: "mic.m4a", status: .completed,
                                       chunks: [TranscriptionChunkProgress(index: 0, offset: 0, completed: true)],
                                       lastError: nil),
            TranscriptionTrackProgress(track: "system", fileName: "system.m4a", status: .failed,
                                       chunks: [TranscriptionChunkProgress(index: 0, offset: 0, completed: false)],
                                       lastError: "The audio file could not be decoded."),
        ], lastError: "The audio file could not be decoded.")

        job.queueForRetry()

        #expect(job.status == .queued)
        #expect(job.attemptCount == 2)
        #expect(job.lastError == nil)
        #expect(job.tracks[0].status == .completed)
        #expect(job.tracks[0].completedChunkIndexes == [0])
        #expect(job.tracks[1].status == .queued)
        #expect(job.tracks[1].lastError == nil)
    }

    @Test func sanitizerProvidesSpecificRecoveryGuidance() {
        #expect(TranscriptionErrorSanitizer.guidance(for: "Speech Recognition permission denied")
                .contains("Speech Recognition"))
        #expect(TranscriptionErrorSanitizer.guidance(for: "The audio file could not be decoded.")
                .contains("Reveal"))
        #expect(TranscriptionErrorSanitizer.guidance(for: TranscriptionError.modelNotDownloaded.localizedDescription)
                .contains("download the WhisperKit model"))
    }

    @Test func retranscriptionResetClearsTracksAndCheckpoints() {
        var job = TranscriptionJob(status: .completed, attemptCount: 4, tracks: [
            TranscriptionTrackProgress(track: "mic", fileName: "mic.m4a", status: .completed,
                                       chunks: [TranscriptionChunkProgress(index: 0, offset: 0, completed: true)],
                                       lastError: nil),
        ], lastError: "old", queuedAt: Date(timeIntervalSince1970: 10),
        startedAt: Date(timeIntervalSince1970: 11), completedAt: Date(timeIntervalSince1970: 12))

        job.resetForRetranscription()

        #expect(job.status == .queued)
        #expect(job.attemptCount == 0)
        #expect(job.tracks.isEmpty)
        #expect(job.lastError == nil)
        #expect(job.startedAt == nil)
        #expect(job.completedAt == nil)
    }

    @Test func resolverNeverFallsThroughToWhisperEnglish() {
        #expect(TranscriptionEngineResolver.resolve(preference: .auto, language: .spanish,
                                                     model: "large", modelDownloaded: false,
                                                     whisperCLIAvailable: false)
                == .whisperKitUnavailable)
        #expect(TranscriptionEngineResolver.resolve(preference: .auto, language: .english,
                                                     model: "large", modelDownloaded: false,
                                                     whisperCLIAvailable: false)
                == .whisperKitUnavailable)
        #expect(TranscriptionEngineResolver.resolve(preference: .auto, language: .spanish,
                                                     model: "large", modelDownloaded: true,
                                                     whisperCLIAvailable: false)
                == .whisperKit(model: "large"))
        #expect(TranscriptionEngineResolver.resolve(preference: .whisperKit, language: .spanish,
                                                     model: "large", modelDownloaded: false)
                == .whisperKitUnavailable)
        #expect(TranscriptionEngineResolver.resolve(preference: .sfSpeech, language: .spanish,
                                                     model: "large", modelDownloaded: false)
                == .sfSpeech(language: "es"))
        #expect(TranscriptionEngineResolver.resolve(preference: .auto, language: .spanish,
                                                     model: "large", modelDownloaded: false,
                                                     whisperCLIAvailable: true)
                == .whisperCLI(model: "large-v3-turbo", language: "es"))
    }

    @Test func appleSpeechLocalesAreScopedToEffectiveLanguage() {
        #expect(LocalTranscriptionProvider.candidateLocales(for: "es") == ["es-CL", "es-419", "es-MX", "es-ES"])
        #expect(LocalTranscriptionProvider.candidateLocales(for: "en") == ["en-US"])
        #expect(LocalTranscriptionProvider.firstAvailableRecognizer(language: "es",
                                                                     isAvailable: { $0 == "es-MX" })?.1 == "es-MX")
        #expect(LocalTranscriptionProvider.firstAvailableRecognizer(language: "es",
                                                                     isAvailable: { _ in false }) == nil)
    }

    @Test func whisperKitSegmentMappingSortsAndDropsEmptyWindows() {
        let timings = TranscriptionTimings()
        let late = TranscriptionSegment(start: 8, end: 10, text: " tarde ")
        let empty = TranscriptionSegment(start: 2, end: 3, text: "   ")
        let early = TranscriptionSegment(start: 1, end: 1.5, text: "Hola")
        let results = [
            TranscriptionResult(text: "tarde", segments: [late], language: "es", timings: timings),
            TranscriptionResult(text: "", segments: [empty], language: "es", timings: timings),
            TranscriptionResult(text: "Hola", segments: [early], language: "es", timings: timings),
        ]

        let mapped = WhisperKitTranscriptionProvider.mapSegments(results, track: "mic")

        #expect(mapped.map(\.text) == ["Hola", "tarde"])
        #expect(mapped.map(\.start) == [1, 8])
        #expect(mapped.map(\.duration) == [0.5, 2])
        #expect(mapped.allSatisfy { $0.track == "mic" })
        #expect(WhisperKitTranscriptionProvider.source(for: "large") == "whisperkit:large")
    }
}
