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

    @Test func providerBackoffSurvivesRelaunch() throws {
        let now = Date(timeIntervalSince1970: 1000)
        let job = TranscriptionJob(status: .queued, cloud: .init(
            state: .retryableFailure, requestFingerprint: "fixture", estimatedCostUSD: 0,
            requestID: nil, retryAfter: now.addingTimeInterval(60), lastHTTPStatus: 429,
            lastErrorCode: nil, updatedAt: now))
        let restored = try JSONDecoder().decode(TranscriptionJob.self, from: JSONEncoder().encode(job))
        #expect(!restored.isDueForAutomaticRetry(at: now))
        #expect(restored.isDueForAutomaticRetry(at: now.addingTimeInterval(60)))
        var completed = restored
        completed.status = .completed
        #expect(!completed.isDueForAutomaticRetry(at: now.addingTimeInterval(120)))
        #expect(TranscriptionJob.legacy(status: .pending).isDueForAutomaticRetry(at: now))
    }

    @Test func recoveryWaitsForCaptureToFinishAndResumesAfterFailure() {
        for state in [RecordingState.preparing, .recording, .stopping] {
            #expect(!state.canProcessQueuedTranscriptions)
        }
        for state in [RecordingState.idle, .completed, .failed("Microphone disconnected")] {
            #expect(state.canProcessQueuedTranscriptions)
        }
    }

    @Test func manualRetryPreservesProviderAndBackoffAfterConfigurationChanges() {
        let now = Date()
        for provider in [CloudTranscriptionProvider.deepgram, .speechmatics] {
            var job = TranscriptionJob(status: .retryableFailed, cloud: .init(
                state: .retryableFailure, requestFingerprint: "fixture", estimatedCostUSD: 0.1,
                requestID: nil, retryAfter: now.addingTimeInterval(60), lastHTTPStatus: 429,
                lastErrorCode: nil, updatedAt: now, provider: provider, providerRegion: "eu1"))
            job.queueForRetry()
            #expect(job.status == .queued)
            #expect(!job.isDueForAutomaticRetry(at: now))
            #expect(job.cloud?.provider == provider)
            #expect(job.cloud?.providerRegion == "eu1")
            #expect(TranscriptionEngineResolver.resolve(preference: .auto, language: .auto,
                availability: .init(), checkpoint: job.cloud) == (provider == .deepgram ? .deepgram : .speechmatics))
            job.resetForRetranscription()
            #expect(job.cloud == nil)
        }
    }

    @Test func acceptedJobManualRetryStillHonorsRateLimit() {
        let now = Date()
        let deadline = now.addingTimeInterval(30)
        var job = TranscriptionJob(status: .retryableFailed, cloud: .init(
            state: .retryableFailure, requestFingerprint: "fixture", estimatedCostUSD: 0.1,
            requestID: "accepted", retryAfter: deadline, lastHTTPStatus: 429,
            lastErrorCode: nil, updatedAt: now, provider: .speechmatics,
            phase: .polling, providerJobID: "accepted", providerRegion: "eu1"))
        job.queueForRetry()
        #expect(job.cloud?.providerJobID == "accepted")
        #expect(job.cloud?.retryAfter == deadline)
        #expect(!job.isDueForAutomaticRetry(at: now))
        #expect(job.isDueForAutomaticRetry(at: deadline))
    }

    @Test func preUploadSetupFailureStillAllowsConnectingAProviderLater() {
        var job = TranscriptionJob(status: .consentBlocked, cloud: .init(
            state: .consentBlocked, requestFingerprint: "fixture", estimatedCostUSD: 0,
            requestID: nil, retryAfter: nil, lastHTTPStatus: nil, lastErrorCode: nil, updatedAt: Date()))
        job.queueForRetry()
        let availability = CloudFallbackPolicy.Availability(speechmaticsConfigured: true, speechmaticsConsented: true)
        #expect(TranscriptionEngineResolver.resolve(preference: .auto, language: .auto,
            availability: availability, checkpoint: job.cloud) == .speechmatics)
    }

    @Test(arguments: [CloudTranscriptionState.uploading, .awaitingResponse, .ambiguousBilling])
    func unknownDeepgramOutcomeCannotBeClearedByRetry(state: CloudTranscriptionState) {
        let checkpoint = CloudTranscriptionJob(
            state: state, requestFingerprint: "paid-or-in-flight", estimatedCostUSD: 0.1,
            requestID: nil, retryAfter: nil, lastHTTPStatus: nil, lastErrorCode: nil, updatedAt: Date())
        var job = TranscriptionJob(status: .retryableFailed, cloud: checkpoint)
        job.queueForRetry()
        #expect(job.status == .ambiguousBilling)
        #expect(job.cloud == checkpoint)
        #expect(!job.isDueForAutomaticRetry())
    }

    @Test func unexpectedFailurePreservesAcceptedJobAndOriginalRegion() {
        let checkpoint = CloudTranscriptionJob(
            state: .awaitingResponse, requestFingerprint: "fixture", estimatedCostUSD: 0.1,
            requestID: "accepted-job", retryAfter: nil, lastHTTPStatus: 200,
            lastErrorCode: nil, updatedAt: Date(), provider: .speechmatics,
            phase: .polling, providerJobID: "accepted-job", providerRegion: "eu1")
        var job = TranscriptionJob(status: .running, cloud: checkpoint)
        job.recordUnexpectedFailure("Local persistence failed")
        #expect(job.status == .retryableFailed)
        #expect(job.cloud == checkpoint)
        job.queueForRetry()
        #expect(job.status == .queued)
        #expect(job.cloud?.providerJobID == "accepted-job")
        #expect(job.cloud?.providerRegion == "eu1")
        #expect(job.cloud?.phase == .polling)
    }

    @Test func unexpectedFailureWithoutAcceptedIDRequiresReview() {
        var job = TranscriptionJob(status: .running, cloud: .init(
            state: .uploading, requestFingerprint: "fixture", estimatedCostUSD: 0.1,
            requestID: nil, retryAfter: nil, lastHTTPStatus: nil, lastErrorCode: nil,
            updatedAt: Date(), provider: .speechmatics, phase: .submitting))
        job.recordUnexpectedFailure("Connection interrupted")
        #expect(job.status == .ambiguousBilling)
        job.queueForRetry()
        #expect(job.status == .ambiguousBilling)
    }

    @Test func providerPermissionErrorsDoNotSendUsersToLocalSpeechSettings() {
        let deepgram = TranscriptionErrorSanitizer.guidance(for: "Deepgram API key is unauthorized")
        #expect(deepgram.contains("Deepgram"))
        #expect(!deepgram.contains("Speech Recognition"))
        let speechmatics = TranscriptionErrorSanitizer.guidance(for: "Speechmatics audio permission denied")
        #expect(speechmatics.contains("Speechmatics"))
        #expect(!speechmatics.contains("Speech Recognition"))
        #expect(TranscriptionErrorSanitizer.guidance(for: "Cloud transcription spend guard exceeded")
            .contains("spending guard"))
    }
}
