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
                .contains("active transcription provider"))
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

    @Test func freshInstallUsesLocalSpeechAndExplicitChoicesArePreserved() {
        #expect(TranscriptionEngineResolver.resolve(preference: .auto, language: .spanish) == .sfSpeech(language: "es"))
        #expect(TranscriptionEngineResolver.resolve(preference: .auto, language: .english) == .sfSpeech(language: "en"))
        #expect(TranscriptionEngineResolver.resolve(preference: .deepgram, language: .spanish) == .deepgram)
        #expect(TranscriptionEngineResolver.resolve(preference: .speechmatics, language: .spanish) == .speechmatics)
        // Local recognition stays pinned to the chosen language.
        #expect(TranscriptionEngineResolver.resolve(preference: .sfSpeech, language: .spanish)
                == .sfSpeech(language: "es"))
        #expect(TranscriptionEngineResolver.resolve(preference: .sfSpeech, language: .auto)
                == .sfSpeech(language: TranscriptionLanguagePreference.auto.sfSpeechCode))
        #expect(TranscriptionEngineResolver.resolve(preference: .sfSpeech, language: .english)
                == .sfSpeech(language: "en"))
    }

    @Test func retryPreservesSpeechmaticsRemoteJobCheckpoint() {
        var job = TranscriptionJob(status: .retryableFailed, attemptCount: 1,
                                   cloud: .init(state: .retryableFailure,
                                                requestFingerprint: "fp", estimatedCostUSD: 0.1,
                                                requestID: "job-1", retryAfter: nil,
                                                lastHTTPStatus: 503, lastErrorCode: nil,
                                                updatedAt: Date(), provider: .speechmatics,
                                                phase: .polling, providerJobID: "job-1"))
        job.queueForRetry()
        #expect(job.status == .queued)
        #expect(job.cloud?.provider == .speechmatics)
        #expect(job.cloud?.providerJobID == "job-1")
        #expect(job.cloud?.phase == .polling)
    }

    @Test func ambiguousSpeechmaticsSubmissionCannotBeBlindlyRetried() {
        var job = TranscriptionJob(status: .ambiguousBilling, attemptCount: 1,
                                   cloud: .init(state: .ambiguousBilling,
                                                requestFingerprint: "fp", estimatedCostUSD: 0.1,
                                                requestID: nil, retryAfter: nil,
                                                lastHTTPStatus: nil, lastErrorCode: nil,
                                                updatedAt: Date(), provider: .speechmatics,
                                                phase: .ambiguousSubmission, providerJobID: nil))
        job.queueForRetry()
        #expect(job.status == .ambiguousBilling)
        #expect(job.cloud?.phase == .ambiguousSubmission)
    }

    @Test func appleSpeechLocalesAreScopedToEffectiveLanguage() {
        #expect(LocalTranscriptionProvider.candidateLocales(for: "es") == ["es-CL", "es-419", "es-MX", "es-ES"])
        #expect(LocalTranscriptionProvider.candidateLocales(for: "en") == ["en-US", "en-GB"])
        #expect(LocalTranscriptionProvider.firstAvailableRecognizer(language: "es",
                                                                     isAvailable: { $0 == "es-MX" })?.1 == "es-MX")
        #expect(LocalTranscriptionProvider.firstAvailableRecognizer(language: "es",
                                                                     isAvailable: { _ in false }) == nil)
    }
}
