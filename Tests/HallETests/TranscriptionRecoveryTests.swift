import Testing
import Foundation
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
        #expect(TranscriptionErrorSanitizer.guidance(for: "The Deepgram primary account reported no remaining credit (HTTP 402).")
                .contains("Top up the Deepgram account"))
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

    /// The original rule survives Whisper's removal: Hall-e must never quietly
    /// substitute a different engine. Automatic now means Deepgram and nothing
    /// else, and Apple Speech is reachable only by choosing it explicitly.
    @Test func resolverNeverSilentlySubstitutesAnEngine() {
        #expect(TranscriptionEngineResolver.resolve(preference: .auto, language: .spanish) == .deepgram)
        #expect(TranscriptionEngineResolver.resolve(preference: .auto, language: .english) == .deepgram)
        #expect(TranscriptionEngineResolver.resolve(preference: .deepgram, language: .spanish) == .deepgram)
        // Apple Speech only when asked for, and still pinned to the chosen language.
        #expect(TranscriptionEngineResolver.resolve(preference: .sfSpeech, language: .spanish)
                == .sfSpeech(language: "es"))
        #expect(TranscriptionEngineResolver.resolve(preference: .sfSpeech, language: .auto)
                == .sfSpeech(language: "es"))
        #expect(TranscriptionEngineResolver.resolve(preference: .sfSpeech, language: .english)
                == .sfSpeech(language: "en"))
    }

    @Test func appleSpeechLocalesAreScopedToEffectiveLanguage() {
        #expect(LocalTranscriptionProvider.candidateLocales(for: "es") == ["es-CL", "es-419", "es-MX", "es-ES"])
        #expect(LocalTranscriptionProvider.candidateLocales(for: "en") == ["en-US"])
        #expect(LocalTranscriptionProvider.firstAvailableRecognizer(language: "es",
                                                                     isAvailable: { $0 == "es-MX" })?.1 == "es-MX")
        #expect(LocalTranscriptionProvider.firstAvailableRecognizer(language: "es",
                                                                     isAvailable: { _ in false }) == nil)
    }
}
